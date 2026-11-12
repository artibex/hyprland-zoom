-- run.lua — run every Lua unit suite with the host `lua` (no Hyprland needed).
-- Usage: lua tests/lua/run.lua [suite-name ...]   (default: all test_*.lua files)

-- Directory of this script, derived from the interpreter's argument vector.
local tests_directory = (arg[0]:match("^(.*)/[^/]*$") or ".")
-- Repository root: two levels above tests/lua.
local repository_root = tests_directory .. "/../.."

-- Make engine modules and test helpers requirable.
package.path = table.concat({
  repository_root .. "/src/lua/?.lua",
  tests_directory .. "/?.lua",
  package.path,
}, ";")

-- Shared test framework and the repository location for suites that need files.
local T = require("framework")
T.repository_root = repository_root
T.tests_directory = tests_directory

-- Suites in a fixed order so the PASS list is stable between runs.
local ALL_SUITES = {
  "test_util", "test_schema", "test_config", "test_state", "test_zoom", "test_tracking",
  "test_filter", "test_binds", "test_collisions", "test_options", "test_api", "test_host", "test_entry", "test_lint",
}

-- suites_to_run — choose the suites named on the command line, or all of them.
-- Args:    none (reads the global `arg` table)
-- Returns: array of suite module names
local function suites_to_run()
  -- No arguments means the full list.
  if #arg == 0 then
    return ALL_SUITES
  end
  local selected = {}
  for index = 1, #arg do
    selected[#selected + 1] = arg[index]
  end
  return selected
end

-- Load each suite module; its top-level code registers the cases and runs them.
for _, suite_name in ipairs(suites_to_run()) do
  -- A missing suite is a hard error: silently skipping would hide a typo.
  local loaded, problem = pcall(require, suite_name)
  if not loaded then
    print("FAIL (suite did not load) " .. suite_name .. ": " .. tostring(problem))
    os.exit(1)
  end
end

-- Exit status 0 only when every case passed.
os.exit(T.summary() and 0 or 1)
