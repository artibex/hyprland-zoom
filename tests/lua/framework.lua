-- framework.lua — a tiny test framework (no external dependencies) for the engine suites.
-- A suite file calls `T.suite(name)`, then `T.case(label, fn)` per behaviour; run.lua reports.

-- The module table returned to callers.
local T = {}

-- Counters and the failure list shared by all suites of one run.
local results = { passed = 0, failed = 0, failures = {} }
-- Name of the suite currently being registered (used to prefix labels).
local current_suite = ""
-- Labels already used, so duplicates cannot hide a missing test.
local used_labels = {}

-- describe_value — render any value for a failure message.
-- Args:    value any Lua value
-- Returns: a short, deterministic string (tables are listed with sorted keys)
local function describe_value(value)
  -- Strings are quoted so whitespace differences are visible.
  if type(value) == "string" then
    return string.format("%q", value)
  end
  -- Tables list their entries in key order to make diffs readable.
  if type(value) == "table" then
    local keys = {}
    for key in pairs(value) do
      keys[#keys + 1] = key
    end
    table.sort(keys, function(first, second)
      return tostring(first) < tostring(second)
    end)
    local parts = {}
    for _, key in ipairs(keys) do
      parts[#parts + 1] = tostring(key) .. "=" .. describe_value(value[key])
    end
    return "{" .. table.concat(parts, ", ") .. "}"
  end
  return tostring(value)
end

-- deep_equal — compare two values structurally.
-- Args:    first any; second any
-- Returns: true when equal (tables compared key by key, numbers with ==)
local function deep_equal(first, second)
  -- Different types are never equal; non-tables compare directly.
  if type(first) ~= type(second) then
    return false
  end
  if type(first) ~= "table" then
    return first == second
  end
  -- Every key of each table must exist in the other with an equal value.
  for key, value in pairs(first) do
    if not deep_equal(value, second[key]) then
      return false
    end
  end
  for key in pairs(second) do
    if first[key] == nil then
      return false
    end
  end
  return true
end

-- T.suite — start a named group of cases.
-- Args:    name string
-- Returns: nothing
function T.suite(name)
  -- Later T.case calls prefix their label with this name.
  current_suite = name
end

-- T.case — run one test body and record pass/fail.
-- Args:    label string (unique, stable across runs); body function
-- Returns: nothing
function T.case(label, body)
  -- A stable "suite: label" key names the case in reports.
  local full_label = current_suite .. ": " .. label
  assert(not used_labels[full_label], "duplicate test label: " .. full_label)
  used_labels[full_label] = true
  -- Run in protected mode so one failing case does not stop the run.
  local succeeded, problem = pcall(body)
  if succeeded then
    results.passed = results.passed + 1
    print("PASS " .. full_label)
  else
    results.failed = results.failed + 1
    results.failures[#results.failures + 1] = full_label .. "\n    " .. tostring(problem)
    print("FAIL " .. full_label)
  end
end

-- T.eq — assert deep equality.
-- Args:    actual any; expected any; note string (optional)
-- Returns: nothing; raises with both values on mismatch
function T.eq(actual, expected, note)
  -- Show both sides so the failing comparison is obvious.
  if not deep_equal(actual, expected) then
    error(string.format("%sexpected %s, got %s", note and (note .. ": ") or "",
      describe_value(expected), describe_value(actual)), 2)
  end
end

-- T.near — assert two numbers are close.
-- Args:    actual number; expected number; tolerance number (default 1e-6)
-- Returns: nothing; raises on mismatch
function T.near(actual, expected, tolerance)
  -- Non-numbers fail with a readable message instead of an arithmetic error.
  if type(actual) ~= "number" or math.abs(actual - expected) > (tolerance or 1e-6) then
    error(string.format("expected about %s, got %s", tostring(expected), tostring(actual)), 2)
  end
end

-- T.truthy — assert a condition.
-- Args:    condition any; note string (optional)
-- Returns: nothing; raises when the condition is false or nil
function T.truthy(condition, note)
  -- Lua truthiness: only nil and false fail.
  if not condition then
    error(note or "expected a truthy value", 2)
  end
end

-- T.contains — assert a string contains a plain substring.
-- Args:    text string; needle string
-- Returns: nothing; raises when the needle is missing
function T.contains(text, needle)
  -- Plain find so pattern characters in the needle stay literal.
  if type(text) ~= "string" or not text:find(needle, 1, true) then
    error(string.format("expected %s to contain %q", describe_value(text), needle), 2)
  end
end

-- T.summary — print the final counts and list failures.
-- Args:    none
-- Returns: true when every case passed
function T.summary()
  -- Failures are repeated at the end so they are not lost in the PASS lines.
  for _, failure in ipairs(results.failures) do
    print("FAILURE " .. failure)
  end
  print(string.format("lua tests: %d passed, %d failed", results.passed, results.failed))
  return results.failed == 0
end

return T
