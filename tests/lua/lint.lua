-- lint.lua — a small style checker for the engine's Lua files (coding-standards for Lua).
-- Rules: lines <= 100 chars; every named function has a `-- name — purpose` header with
-- Args and Returns lines; never more than 3 consecutive uncommented statements after a comment.

-- The module table returned to callers.
local M = {}

-- Longest allowed line.
local MAX_LINE_LENGTH = 100
-- Longest allowed run of statements without an intent comment.
local MAX_UNCOMMENTED_RUN = 3

-- strip_strings — blank out string literals so brackets in text do not confuse the counter.
-- Args:    line source line
-- Returns: the line with "..." and '...' contents removed
local function strip_strings(line)
  -- Remove escaped quotes first, then whole literals.
  local without_escapes = line:gsub('\\"', ""):gsub("\\'", "")
  return (without_escapes:gsub('"[^"]*"', '""'):gsub("'[^']*'", "''"))
end

-- bracket_balance — net count of opening minus closing brackets on a line.
-- Args:    line source line without strings
-- Returns: integer (positive when the statement continues on the next line)
local function bracket_balance(line)
  -- Count each bracket kind with gsub's replacement counter.
  local _, opening = line:gsub("[%(%{%[]", "")
  local _, closing = line:gsub("[%)%}%]]", "")
  return opening - closing
end

-- function_name — extract the name of a function defined on this line.
-- Args:    line source line
-- Returns: the last identifier of `function a.b.name(` / `local function name(`; or nil
local function function_name(line)
  -- Anonymous callbacks (`function(`) have no name and need no header.
  local dotted = line:match("^%s*local function ([%w_]+)%(")
    or line:match("^%s*function ([%w_%.:]+)%(")
  return dotted and dotted:match("([%w_]+)$") or nil
end

-- check_header — verify the comment block above a function line.
-- Args:    lines array of source lines; index function line index; name string
-- Returns: problem string, or nil when the header is fine
local function check_header(lines, index, name)
  -- Walk upwards over the contiguous comment block.
  local block = {}
  local cursor = index - 1
  while cursor >= 1 and lines[cursor]:match("^%s*%-%-") do
    table.insert(block, 1, lines[cursor])
    cursor = cursor - 1
  end
  if #block == 0 then
    return "function " .. name .. " has no header comment"
  end
  -- First line must be `-- name — purpose`; Args and Returns must follow.
  if not block[1]:match("^%s*%-%- [%w_%.]*" .. name .. " — ") then
    return "header of " .. name .. " must start with '-- " .. name .. " — '"
  end
  local text = table.concat(block, "\n")
  if not text:find("Args:", 1, true) or not text:find("Returns:", 1, true) then
    return "header of " .. name .. " needs Args: and Returns: lines"
  end
  return nil
end

-- is_closer_only — true for lines that only close blocks or tables (not a statement).
-- Args:    code trimmed code line
-- Returns: boolean
local function is_closer_only(code)
  -- `end`, `else`, `},` and friends do not need a comment of their own.
  return code:match("^end[%)%},;]*$") ~= nil or code:match("^[%)%}%]]+[,;]*$") ~= nil
    or code == "else" or code:match("^until") ~= nil or code:match("^elseif ") ~= nil
    or code:match("^local function ") ~= nil or code:match("^function ") ~= nil
    or code:match("^or ") ~= nil or code:match("^and ") ~= nil or code == "return M"
end

-- M.check_file — lint one Lua file.
-- Args:    path file path
-- Returns: array of "path:line: problem" strings (empty when clean)
function M.check_file(path)
  local handle = assert(io.open(path, "rb"))
  local lines = {}
  for line in handle:lines() do
    lines[#lines + 1] = line
  end
  handle:close()
  local problems = {}
  local run_length, depth = 0, 0
  -- The statement directly below a comment counts as commented (like the shell R4 rule).
  local comment_pending = false
  for index, line in ipairs(lines) do
    local code = line:match("^%s*(.-)%s*$")
    -- Line length applies to every line.
    if #line > MAX_LINE_LENGTH then
      problems[#problems + 1] = string.format("%s:%d: line longer than %d", path, index,
        MAX_LINE_LENGTH)
    end
    -- Named functions need a contract header.
    local name = function_name(line)
    local header_problem = name and check_header(lines, index, name)
    if header_problem then
      problems[#problems + 1] = string.format("%s:%d: %s", path, index, header_problem)
    end
    -- A comment line resets the run; blank lines and closers neither count nor reset.
    if code:match("^%-%-") then
      run_length, comment_pending = 0, true
    elseif code ~= "" and depth <= 0 and not is_closer_only(code) and comment_pending then
      comment_pending = false
    elseif code ~= "" and depth <= 0 and not is_closer_only(code) then
      run_length = run_length + 1
      if run_length > MAX_UNCOMMENTED_RUN then
        problems[#problems + 1] = string.format("%s:%d: more than %d uncommented statements",
          path, index, MAX_UNCOMMENTED_RUN)
        run_length = 0
      end
    end
    -- Track multi-line constructors so their inner lines count as one statement.
    depth = depth + bracket_balance(strip_strings(code:gsub("%-%-.*$", "")))
  end
  return problems
end

return M
