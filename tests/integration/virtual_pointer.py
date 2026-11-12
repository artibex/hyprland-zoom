#!/usr/bin/env python3
"""Tiny zwlr_virtual_pointer_v1 client for the nested-Hyprland tests (stdlib only).

Usage: virtual_pointer.py <wayland-socket> <step>...
Steps:
  up | down | left | right   one wheel notch (vertical or horizontal)
  <step>*<count>             repeat a step back to back, e.g. up*20
  sleep:<ms>                 pause
  move:<dx>,<dy>             relative pointer motion
Example: virtual_pointer.py wayland-2 move:3,0 sleep:100 up*20
Speaks the raw Wayland wire protocol, so no libraries are needed.
"""

# Environment (runtime directory), sockets and timing.
import os
import socket
import struct
import sys
import time

# wl_display requests and the registry events/requests used here.
DISPLAY_SYNC, DISPLAY_GET_REGISTRY = 0, 1
REGISTRY_BIND, REGISTRY_GLOBAL_EVENT = 0, 0
# Object id of wl_display; ids of objects we create start right after it.
DISPLAY_ID, FIRST_NEW_ID = 1, 2
# zwlr_virtual_pointer_v1 request opcodes.
POINTER_MOTION, POINTER_AXIS, POINTER_FRAME = 0, 3, 4
POINTER_AXIS_SOURCE, POINTER_AXIS_DISCRETE = 5, 7
# Wheel axis source and the two scroll axes.
AXIS_SOURCE_WHEEL, AXIS_VERTICAL, AXIS_HORIZONTAL = 0, 0, 1
# Pixels one wheel notch reports (Hyprland only looks at the sign and the discrete count).
NOTCH_PIXELS = 15.0
# Notch names -> (axis, direction sign).
NOTCHES = {"down": (AXIS_VERTICAL, 1), "up": (AXIS_VERTICAL, -1),
           "right": (AXIS_HORIZONTAL, 1), "left": (AXIS_HORIZONTAL, -1)}


def fixed(value):
    """Encode a number as a Wayland 24.8 fixed-point integer.

    Args:
        value: any float.

    Returns:
        4 bytes, little endian.
    """
    # Fixed-point: multiply by 256 and round.
    return struct.pack("<i", int(round(value * 256)))


def wire_string(text):
    """Encode a string argument (length, NUL-terminated bytes, padding to 4).

    Args:
        text: ASCII string.

    Returns:
        The encoded bytes.
    """
    # Length counts the terminating NUL; padding keeps 32-bit alignment.
    raw = text.encode() + b"\0"
    return struct.pack("<I", len(raw)) + raw + b"\0" * (-len(raw) % 4)


class Connection:
    """A minimal Wayland client connection (requests out, events in)."""

    def __init__(self, socket_name):
        """Connect to the compositor socket.

        Args:
            socket_name: socket file name inside $XDG_RUNTIME_DIR, e.g. wayland-2.

        Returns:
            None.
        """
        # Connect over the unix socket; remember the next free object id.
        self.stream = socket.socket(socket.AF_UNIX)
        self.stream.connect(os.path.join(os.environ["XDG_RUNTIME_DIR"], socket_name))
        self.next_id = FIRST_NEW_ID
        self.pending = b""

    def new_id(self):
        """Allocate a client-side object id.

        Returns:
            The new id.
        """
        # Ids only ever grow in this short-lived client.
        allocated = self.next_id
        self.next_id += 1
        return allocated

    def send(self, object_id, opcode, payload=b""):
        """Send one request.

        Args:
            object_id: target object.
            opcode: request number of that object's interface.
            payload: already encoded arguments.

        Returns:
            None.
        """
        # Header: object id, then (total size << 16) | opcode.
        header = struct.pack("<II", object_id, ((8 + len(payload)) << 16) | opcode)
        self.stream.sendall(header + payload)

    def read_events(self, timeout=1.0):
        """Read and decode the events that are available.

        Args:
            timeout: seconds to wait for data.

        Returns:
            list of (object id, opcode, payload bytes).
        """
        # A timeout simply means no events arrived.
        self.stream.settimeout(timeout)
        try:
            self.pending += self.stream.recv(65536)
        except socket.timeout:
            return []
        events = []
        while len(self.pending) >= 8:
            object_id, size_and_opcode = struct.unpack("<II", self.pending[:8])
            size = size_and_opcode >> 16
            if len(self.pending) < size:
                break
            events.append((object_id, size_and_opcode & 0xFFFF, self.pending[8:size]))
            self.pending = self.pending[size:]
        return events

    def round_trip(self):
        """Wait until the compositor processed everything sent so far.

        Returns:
            All events received while waiting.
        """
        # wl_display.sync answers with a callback "done" event after all earlier requests.
        callback = self.new_id()
        self.send(DISPLAY_ID, DISPLAY_SYNC, struct.pack("<I", callback))
        received = []
        while True:
            events = self.read_events()
            received += events
            if not events or any(event[0] == callback for event in events):
                return received


def list_globals(connection):
    """Fetch the registry globals of the compositor.

    Args:
        connection: an open Connection.

    Returns:
        (registry object id, dict interface name -> (global name, version)).
    """
    # Ask for the registry and read the "global" announcements.
    registry = connection.new_id()
    connection.send(DISPLAY_ID, DISPLAY_GET_REGISTRY, struct.pack("<I", registry))
    found = {}
    for object_id, opcode, payload in connection.round_trip():
        if object_id == registry and opcode == REGISTRY_GLOBAL_EVENT:
            name, length = struct.unpack("<II", payload[:8])
            interface = payload[8:8 + length - 1].decode()
            version_at = 8 + (length + 3) // 4 * 4
            found[interface] = (name, struct.unpack("<I", payload[version_at:version_at + 4])[0])
    return registry, found


def bind_global(connection, registry, globals_found, interface):
    """Bind a registry global (version 1) and return the new object id.

    Args:
        connection: an open Connection.
        registry: registry object id.
        globals_found: result of list_globals.
        interface: interface name such as wl_seat.

    Returns:
        The id of the bound object.
    """
    # bind(name, interface, version, new id)
    name, _version = globals_found[interface]
    bound = connection.new_id()
    payload = struct.pack("<I", name) + wire_string(interface) + struct.pack("<II", 1, bound)
    connection.send(registry, REGISTRY_BIND, payload)
    return bound


def create_pointer(connection):
    """Create the virtual pointer object.

    Args:
        connection: an open Connection.

    Returns:
        The virtual pointer's object id.
    """
    # The manager needs the seat; the pointer is created from the manager.
    registry, globals_found = list_globals(connection)
    seat = bind_global(connection, registry, globals_found, "wl_seat")
    manager = bind_global(connection, registry, globals_found, "zwlr_virtual_pointer_manager_v1")
    pointer = connection.new_id()
    connection.send(manager, 0, struct.pack("<II", seat, pointer))
    return pointer


def timestamp(start):
    """Milliseconds since the client started (plus an offset the compositor accepts).

    Args:
        start: time.time() at client start.

    Returns:
        Integer milliseconds.
    """
    # Event times only need to be monotonic.
    return int((time.time() - start) * 1000) + 1000


def send_notch(connection, pointer, name, start):
    """Send one wheel notch (axis_source, axis, axis_discrete, frame).

    Args:
        connection: an open Connection.
        pointer: virtual pointer object id.
        name: up, down, left or right.
        start: client start time for timestamps.

    Returns:
        None.
    """
    # One notch = source "wheel", the axis value, the discrete step and a frame.
    axis, sign = NOTCHES[name]
    now = timestamp(start)
    connection.send(pointer, POINTER_AXIS_SOURCE, struct.pack("<I", AXIS_SOURCE_WHEEL))
    connection.send(pointer, POINTER_AXIS, struct.pack("<II", now, axis) + fixed(sign * NOTCH_PIXELS))
    connection.send(pointer, POINTER_AXIS_DISCRETE,
                    struct.pack("<II", now, axis) + fixed(sign * NOTCH_PIXELS)
                    + struct.pack("<i", sign))
    connection.send(pointer, POINTER_FRAME)


def run_step(connection, pointer, step, start):
    """Execute one step of the command line.

    Args:
        connection: an open Connection.
        pointer: virtual pointer object id.
        step: text such as up, up*20, sleep:50 or move:3,0.
        start: client start time.

    Returns:
        None.
    """
    # Repetition: "up*20" is twenty back-to-back notches.
    name, _, count = step.partition("*")
    if name.startswith("sleep:"):
        time.sleep(int(name[6:]) / 1000)
    elif name.startswith("move:"):
        delta_x, delta_y = (float(value) for value in name[5:].split(","))
        connection.send(pointer, POINTER_MOTION,
                        struct.pack("<I", timestamp(start)) + fixed(delta_x) + fixed(delta_y))
        connection.send(pointer, POINTER_FRAME)
    else:
        for _ in range(int(count or 1)):
            send_notch(connection, pointer, name, start)


def main(arguments):
    """Command-line entry point.

    Args:
        arguments: argv without the program name.

    Returns:
        Process exit status (2 for bad usage).
    """
    # Need a socket name and at least one step.
    if len(arguments) < 2:
        print(__doc__)
        return 2
    connection = Connection(arguments[0])
    pointer = create_pointer(connection)
    start = time.time()
    for step in arguments[1:]:
        run_step(connection, pointer, step, start)
    # A final round trip makes sure the compositor handled everything before we exit.
    connection.round_trip()
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
