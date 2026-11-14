-- Auto Combat, tested with plain Lua 5.4 (no client): lua5.4 tests/run.lua
-- Pure logic uses tests/fake.lua; world adapter tests supply mocked mq and hailstone modules.
local root = arg[0]:match("^(.*)/tests/run%.lua$") or "."
package.path = root .. "/autocombat/?.lua;" .. root .. "/tests/?.lua;" .. package.path

local passed, failed = 0, 0
local current = ""

function check(cond, what)
  if cond then
    passed = passed + 1
  else
    failed = failed + 1
    print(string.format("FAIL [%s] %s\n  %s", current, what or "", debug.traceback("", 2):match("\n[^\n]*\n([^\n]*)")))
  end
end

function eq(a, b, what)
  check(a == b, (what or "") .. ": expected " .. tostring(b) .. ", got " .. tostring(a))
end

function case(name, fn)
  current = name
  local ok, err = pcall(fn)
  if not ok then
    failed = failed + 1
    print("ERROR [" .. name .. "] " .. tostring(err))
  end
end

for _, file in ipairs({ "test_settings", "test_conditions", "test_rules", "test_targeting", "test_engine", "test_world" }) do
  require(file)
end

print(string.format("%d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
