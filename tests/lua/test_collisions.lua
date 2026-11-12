-- test_collisions.lua — canonical chords, bind-file scanning and collision warnings (R-P1a-09).

-- Framework, fake host and the module under test.
local T = require("framework")
local stub_host = require("stub_host")
local collisions = require("hyprland-zoom.collisions")

T.suite("collisions")

T.case("a canonical chord ignores modifier order, case, spacing and aliases", function()
  -- All spellings of the same shortcut must compare equal.
  local expected = collisions.canonical_chord("SUPER + CTRL + I")
  T.eq(expected, "ctrl+super+i")
  T.eq(collisions.canonical_chord("ctrl+super+I"), expected)
  T.eq(collisions.canonical_chord("Control + Super + i"), expected)
  T.eq(collisions.canonical_chord("SUPER + ALT + mouse:274"), "alt+super+mouse:274")
  T.eq(collisions.canonical_chord("  "), nil)
end)

T.case("extract_chords reads bind calls and skips unbind", function()
  -- o.bind, o.bind_toggle, o.rebind and hl.bind carry chords; hl.unbind frees one.
  local text = table.concat({
    'o.bind("SUPER + CTRL + C", "Capture", { menu = "capture" })',
    'o.bind_toggle("SUPER + CTRL + I", "Idle", "idle")',
    'o.rebind("SUPER + SHIFT + X", "Mine", "cmd")',
    'hl.bind("SUPER + mouse_down", hl.dsp.focus({ workspace = "m+1" }))',
    'hl.unbind("SUPER + ALT + mouse_up")',
    '-- hl.bind("SUPER + Q") in a comment is still text, but the line below has no call',
    'local name = "SUPER + Z"',
  }, "\n")
  T.eq(collisions.extract_chords(text), { "ctrl+super+c", "ctrl+super+i", "shift+super+x",
    "super+mouse_down", "super+q" })
end)

T.case("scan reads Omarchy's bind files and the user's bindings.lua", function()
  -- The fake filesystem stands in for /usr/share/omarchy and ~/.config.
  local host = stub_host.new()
  host.files["/usr/share/omarchy/default/hypr/bindings/utilities.lua"] =
    'o.bind("SUPER + CTRL + O", "Menu", { menu = "toggle" })\n'
  host.files["/usr/share/omarchy/default/hypr/bindings/notes.txt"] = 'o.bind("SUPER + CTRL + N")'
  host.files["/home/test/.config/hypr/bindings.lua"] = 'hl.bind("SUPER + ALT + I", f)\n'
  local map = collisions.scan(host)
  T.eq(map["ctrl+super+o"], "Omarchy bindings/utilities.lua")
  T.eq(map["alt+super+i"], "your hypr/bindings.lua")
  -- Only .lua files count.
  T.eq(map["ctrl+super+n"], nil)
end)

T.case("find warns for a shared chord but not for a deliberate takeover", function()
  -- The takeover chords are in plan.unbind: Omarchy's bind is removed, so nothing collides.
  local plan = { binds = { { keys = "SUPER + CTRL + I", action = "zoom_in" },
    { keys = "SUPER + CTRL + Z", action = "zoom_in" } }, unbind = { "SUPER + CTRL + Z" },
    warnings = {} }
  local foreign = { ["ctrl+super+i"] = "Omarchy bindings/utilities.lua",
    ["ctrl+super+z"] = "Omarchy bindings/utilities.lua" }
  local warnings = collisions.find(plan, foreign)
  T.eq(#warnings, 1)
  T.contains(warnings[1], "SUPER + CTRL + I is also bound in Omarchy bindings/utilities.lua")
  T.eq(collisions.find(plan, nil), {})
end)
