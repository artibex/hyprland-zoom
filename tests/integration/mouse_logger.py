#!/usr/bin/env python3
"""Terminal mouse-report logger: shows whether scroll events reach a client window.

Usage (inside a terminal window): mouse_logger.py <log-file>
Enables SGR mouse reporting, appends every byte read from the terminal to the log file
and writes "READY" first, so a test can wait for the window. A leaked scroll notch shows up as
an escape sequence like ESC[<64;x;yM in the log; a consumed one leaves the log empty.
"""

# Raw terminal handling and file output.
import os
import sys
import termios
import tty

# Enable button/wheel reporting (1000) in the SGR encoding (1006).
ENABLE_MOUSE = b"\x1b[?1000h\x1b[?1006h"
# Disable it again when leaving.
DISABLE_MOUSE = b"\x1b[?1000l\x1b[?1006l"


def append_to_log(log_path, text):
    """Append bytes to the log file and flush them to disk.

    Args:
        log_path: file path.
        text: bytes to append.

    Returns:
        None.
    """
    # Open per write so the test can truncate the file at any time.
    with open(log_path, "ab") as handle:
        handle.write(text)


def main(arguments):
    """Command-line entry point: log terminal input until the window closes.

    Args:
        arguments: argv without the program name (the log path).

    Returns:
        Process exit status.
    """
    # Raw mode so escape sequences arrive unprocessed.
    if len(arguments) != 1:
        print(__doc__)
        return 2
    log_path = arguments[0]
    saved_attributes = termios.tcgetattr(sys.stdin)
    tty.setraw(sys.stdin.fileno())
    os.write(sys.stdout.fileno(), ENABLE_MOUSE)
    append_to_log(log_path, b"READY\n")
    try:
        while True:
            # Block on the terminal; an empty read means the terminal closed.
            data = os.read(sys.stdin.fileno(), 4096)
            if not data:
                break
            append_to_log(log_path, data)
    finally:
        os.write(sys.stdout.fileno(), DISABLE_MOUSE)
        termios.tcsetattr(sys.stdin, termios.TCSADRAIN, saved_attributes)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
