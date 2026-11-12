-- test_lint.lua — the Lua style rules hold for every engine file, and the linter itself bites.

-- Framework and the linter under test.
local T = require("framework")
local lint = require("lint")

-- Sandbox used for the deliberately bad sample files.
local SANDBOX = assert(os.getenv("ZOOMCTL_TEST_SANDBOX"), "run via tests/lua/run.sh")

-- Production Lua files that must satisfy the rules (relative to the repository root).
local PRODUCTION_FILES = {
  "src/lua/hyprland-zoom.lua", "config/hyprland-bindings.lua",
  "src/lua/hyprland-zoom/api.lua", "src/lua/hyprland-zoom/binds.lua",
  "src/lua/hyprland-zoom/config.lua", "src/lua/hyprland-zoom/engine.lua",
  "src/lua/hyprland-zoom/filter.lua", "src/lua/hyprland-zoom/host.lua",
  "src/lua/hyprland-zoom/schema.lua", "src/lua/hyprland-zoom/state.lua",
  "src/lua/hyprland-zoom/tracking.lua", "src/lua/hyprland-zoom/util.lua",
  "src/lua/hyprland-zoom/zoom.lua",
}

-- write_sample — write a throwaway Lua file into the sandbox.
-- Args:    name string; text string
-- Returns: the file path
local function write_sample(name, text)
  -- Plain write; the file is removed with the sandbox.
  local path = SANDBOX .. "/" .. name
  local handle = assert(io.open(path, "wb"))
  handle:write(text)
  handle:close()
  return path
end

T.suite("lint")

T.case("every production Lua file satisfies the style rules", function()
  -- Collect all problems first so one failure message lists everything.
  local problems = {}
  for _, relative in ipairs(PRODUCTION_FILES) do
    for _, problem in ipairs(lint.check_file(T.repository_root .. "/" .. relative)) do
      problems[#problems + 1] = problem
    end
  end
  -- Show at most the first ten findings; a full list would drown the test report.
  T.eq(table.concat(problems, "\n", 1, math.min(#problems, 10)), "")
end)

T.case("the linter flags a missing header, a long line and an uncommented run", function()
  -- Three deliberate violations in one sample.
  local sample = "local function bad(x)\n  return x\nend\n"
    .. "local a = 1\nlocal b = 2\nlocal c = 3\nlocal d = 4\n"
    .. "-- " .. string.rep("x", 100) .. "\n"
  local problems = lint.check_file(write_sample("bad.lua", sample))
  local joined = table.concat(problems, "\n")
  T.contains(joined, "function bad has no header comment")
  T.contains(joined, "more than 3 uncommented statements")
  T.contains(joined, "line longer than 100")
end)

T.case("the linter accepts a correct header and counts multi-line tables as one statement", function()
  -- A compliant sample produces no findings.
  local sample = "-- good — does a thing.\n-- Args:    none\n-- Returns: nothing\n"
    .. "local function good()\n  -- one table, many lines\n  local t = {\n    a = 1,\n    b = 2,\n"
    .. "    c = 3,\n    d = 4,\n  }\n  return t\nend\n"
  T.eq(lint.check_file(write_sample("good.lua", sample)), {})
end)
