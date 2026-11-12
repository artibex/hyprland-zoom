"""hyprland-zoom settings app: GTK4 + libadwaita front end for ``zoomctl`` (contract C8).

Layers, from the bottom up:

* ``schema``, ``values``, ``keys``, ``porcelain``, ``presentation`` - pure Python model
  (no GTK import, unit-testable without a display).
* ``backend``, ``controller``, ``tryit`` - asynchronous ``zoomctl`` client and the state
  machines built on it (GLib/Gio only).
* ``rows``, ``key_capture``, ``pages``, ``tryit_bar``, ``dialogs``, ``window``, ``app`` -
  the widgets.
"""
