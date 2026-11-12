-- test_util.lua — unit tests for the pure helpers in hyprland-zoom.util.

-- Framework and the module under test.
local T = require("framework")
local util = require("hyprland-zoom.util")

T.suite("util")

T.case("trim strips both ends and keeps inner spaces", function()
  -- Inner whitespace must survive; only the ends are cut.
  T.eq(util.trim("  a b \t\n"), "a b")
end)

T.case("split keeps empty parts and treats the separator literally", function()
  -- "+" is a Lua pattern character; it must not be interpreted.
  T.eq(util.split("SUPER + ALT", "+"), { "SUPER ", " ALT" })
  T.eq(util.split("a,,b", ","), { "a", "", "b" })
  T.eq(util.split("", ","), { "" })
end)

T.case("round rounds half away from zero", function()
  -- Positive and negative halves are symmetric.
  T.eq(util.round(1.005 + 0.0001, 2), 1.01)
  T.eq(util.round(-0.125, 2), -0.13)
  T.eq(util.round(2.5, 0), 3)
end)

T.case("clamp limits to the inclusive range", function()
  -- Below, inside and above the range.
  T.eq(util.clamp(0, 1, 10), 1)
  T.eq(util.clamp(5, 1, 10), 5)
  T.eq(util.clamp(11, 1, 10), 10)
end)

T.case("join_path never doubles the slash", function()
  -- Trailing slash on the directory is absorbed.
  T.eq(util.join_path("/a/b/", "c"), "/a/b/c")
  T.eq(util.join_path("/a/b", "c"), "/a/b/c")
end)

T.case("fnv1a_hex is deterministic, 12 hex digits, content sensitive", function()
  -- Known FNV-1a 64 value of the empty string is the offset basis cbf29ce484222325.
  T.eq(util.fnv1a_hex(""), "cbf29ce48422")
  T.eq(util.fnv1a_hex("a"), util.fnv1a_hex("a"))
  T.truthy(util.fnv1a_hex("a") ~= util.fnv1a_hex("b"))
  T.truthy(util.fnv1a_hex("abc"):match("^%x%x%x%x%x%x%x%x%x%x%x%x$"))
end)

T.case("printable_excerpt blanks exotic characters and limits the length", function()
  -- Newlines and quotes must not reach logs or notifications.
  T.eq(util.printable_excerpt("a\nb\"c"), "a?b?c")
  T.eq(#util.printable_excerpt(string.rep("x", 100)), 40)
  T.eq(util.printable_excerpt(nil), "nil")
end)

T.case("to_raw_value renders booleans, integers and floats", function()
  -- Canonical schema spellings for booleans.
  T.eq(util.to_raw_value(true), "on")
  T.eq(util.to_raw_value(false), "off")
  T.eq(util.to_raw_value(3), "3")
  T.eq(util.to_raw_value(1.5), "1.5000")
  T.eq(util.to_raw_value("grayscale"), "grayscale")
end)
