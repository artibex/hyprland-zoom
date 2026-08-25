-- hyprland-zoom keybindings for Hyprland's Lua config (Hyprland 0.55+).
--
-- Hyprland 0.55 replaced the legacy config format with a Lua-based parser,
-- so the old `bind = ...` lines in hyprland-bindings.conf are only read by
-- legacy installs. On a Lua setup, reference this file from hyprland.lua:
--
--   dofile("/usr/share/hyprland-zoom/hyprland-bindings.lua")
--
-- (`zoomctl setup` does this automatically.) Only the raw Hyprland Lua API
-- (hl.bind / hl.dsp.exec_cmd) is used, so this works on any Hyprland 0.55+
-- install, with or without Omarchy. Note the key syntax: every modifier and
-- the key itself are joined with " + ".

hl.bind("SUPER + ALT + mouse_down", hl.dsp.exec_cmd("zoomctl in"), { description = "Zoom in" })
hl.bind("SUPER + ALT + mouse_up", hl.dsp.exec_cmd("zoomctl out"), { description = "Zoom out" })
hl.bind("SUPER + ALT + mouse:274", hl.dsp.exec_cmd("zoomctl toggle"), { description = "Toggle zoom", mouse = true })

hl.bind("SUPER + ALT + K", hl.dsp.exec_cmd("zoomctl in"), { repeating = true, description = "Zoom in" })
hl.bind("SUPER + ALT + J", hl.dsp.exec_cmd("zoomctl out"), { repeating = true, description = "Zoom out" })
hl.bind("SUPER + ALT + L", hl.dsp.exec_cmd("zoomctl toggle"), { description = "Toggle zoom" })

-- Optional hard reset on its own key:
-- hl.bind("SUPER + ALT + R", hl.dsp.exec_cmd("zoomctl reset"), { description = "Reset zoom" })
