-- test_host.lua — the real platform adapter against a real (sandbox) filesystem.

-- Framework and the module under test.
local T = require("framework")
local host_module = require("hyprland-zoom.host")

-- Throwaway directory prepared by run.sh; never the user's real directories.
local SANDBOX = assert(os.getenv("ZOOMCTL_TEST_SANDBOX"), "run via tests/lua/run.sh")
-- Directory used by this suite inside the sandbox.
local WORK = SANDBOX .. "/host-suite"

-- new_host — build a real host around a recording fake `hl`.
-- Args:    calls table receiving notifications and timers; omarchy_helper any (the global `o`)
-- Returns: host table
local function new_host(calls, omarchy_helper)
  -- Only the hl members the adapter uses are needed.
  local fake_hl = {
    notification = { create = function(spec) calls.notification = spec end },
    timer = function(callback, options) calls.timer = { callback = callback, options = options } end,
  }
  return host_module.system({ hl = fake_hl, o = omarchy_helper })
end

T.suite("host")

T.case("ensure_dir creates a private directory and is idempotent", function()
  -- Mode 0700 on the final component; a second call still succeeds.
  local host = new_host({})
  T.truthy(host.ensure_dir(WORK))
  T.truthy(host.ensure_dir(WORK))
  local pipe = assert(io.popen("stat -c %a '" .. WORK .. "'"))
  local mode = pipe:read("l")
  pipe:close()
  T.eq(mode, "700")
end)

T.case("ensure_dir tightens an existing wider directory to 0700", function()
  -- mkdir -m only applies to a new directory; an old 0755 one must become private as well.
  local host = new_host({})
  local wide = WORK .. "/wide"
  os.execute("mkdir -p -m 0755 '" .. wide .. "'")
  T.truthy(host.ensure_dir(wide))
  local pipe = assert(io.popen("stat -c %a '" .. wide .. "'"))
  local mode = pipe:read("l")
  pipe:close()
  T.eq(mode, "700")
end)

T.case("write_file then read_file round-trips and leaves no temp file", function()
  -- Atomic write: only the final file remains.
  local host = new_host({})
  T.truthy(host.write_file(WORK .. "/a.txt", "hello\nworld\n"))
  T.eq(host.read_file(WORK .. "/a.txt"), "hello\nworld\n")
  T.eq(host.read_file(WORK .. "/a.txt.tmp"), nil)
end)

T.case("read_file of a missing file is nil and write into a missing directory fails", function()
  -- Failures are values, not exceptions.
  local host = new_host({})
  T.eq(host.read_file(WORK .. "/missing"), nil)
  local written, problem = host.write_file(WORK .. "/no/such/dir/file", "x")
  T.eq(written, nil)
  T.truthy(problem)
end)

T.case("list_dir lists names, also with spaces and quotes in the directory name", function()
  -- shell_quote must keep awkward names from breaking the command.
  local host = new_host({})
  local awkward = WORK .. "/it's a dir"
  T.truthy(host.ensure_dir(awkward))
  host.write_file(awkward .. "/one", "1")
  host.write_file(awkward .. "/two words", "2")
  local names = host.list_dir(awkward)
  table.sort(names)
  T.eq(names, { "one", "two words" })
  T.eq(host.list_dir(WORK .. "/missing-dir"), {})
end)

T.case("shell_quote neutralises quotes and shell syntax", function()
  -- The quoted text, evaluated by a shell, yields the original string.
  local nasty = "a'b\"c $(touch x) `y` ;"
  local pipe = assert(io.popen("printf %s " .. host_module.shell_quote(nasty)))
  local echoed = pipe:read("a")
  pipe:close()
  T.eq(echoed, nasty)
end)

T.case("remove_file deletes", function()
  -- The adapter exposes os.remove directly.
  local host = new_host({})
  host.write_file(WORK .. "/gone", "x")
  host.remove_file(WORK .. "/gone")
  T.eq(host.read_file(WORK .. "/gone"), nil)
end)

T.case("omarchy_present needs the global helper `o` with a bind function", function()
  -- Plain Hyprland: no helper; Omarchy: table with bind.
  T.eq(new_host({}).omarchy_present(), false)
  T.eq(new_host({}, { bind = function() end }).omarchy_present(), true)
  T.eq(new_host({}, { other = true }).omarchy_present(), false)
end)

T.case("notify and after forward to hl.notification.create and hl.timer", function()
  -- One-shot timer in milliseconds; notification with a duration.
  local calls = {}
  local host = new_host(calls)
  host.notify("hello")
  T.eq(calls.notification.text, "hello")
  T.truthy(calls.notification.duration > 0)
  local function callback() end
  host.after(1500, callback)
  T.eq(calls.timer.options, { timeout = 1500, type = "oneshot" })
  T.eq(calls.timer.callback, callback)
end)
