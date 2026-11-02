-- Auto Combat: a row's conditions against the world snapshot (lib/world.lua). Pure: everything it reads is in the
-- snapshot, so it runs the same in the client and in the tests.
--
-- A subject in the snapshot is a table or nil: me, target, pet, group (the lowest-health member), assist. Each has
-- the numbers the catalog names (hp, mana, distance ...), booleans (named, mezzed, los ...) and for buffs
-- has_buff(name) / my_buff(name) functions answering true, false, or nil when it cannot be known (a target whose
-- buffs the server did not send).
local catalog = require('lib.catalog')

local M = {}

local function compare(a, op, b)
  if a == nil or b == nil then return false end
  if op == "<" then return a < b end
  if op == "<=" then return a <= b end
  if op == ">" then return a > b end
  if op == ">=" then return a >= b end
  if op == "=" then return a == b end
  if op == "!=" then return a ~= b end
  return false
end

-- Whether one condition holds; false for anything it cannot know (a missing subject, an unknown buff state), except
-- "<subject> exists is not" which holds for a missing subject.
function M.holds(c, world)
  local p = catalog.property(c.who, c.what)
  if not p or not catalog.valid_op(p.kind, c.op) then return false end
  local subject = world[c.who]
  if c.what == "exists" then
    local exists = subject ~= nil
    if c.op == "is" then return exists end
    return not exists
  end
  if not subject then return false end
  if p.kind == "bool" then
    local v = subject[c.what]
    if v == nil then return false end
    if c.op == "is" then return v == true end
    return v == false
  end
  if p.kind == "buff" then
    local name = tostring(c.value or "")
    if name == "" then return false end
    local fn = c.what == "mybuff" and subject.my_buff or subject.has_buff
    if not fn then return false end
    local on = fn(name)
    if on == nil then return false end
    if c.op == "has" then return on end
    return not on
  end
  return compare(subject[c.what], c.op, tonumber(c.value))
end

function M.all(conditions, world)
  for _, c in ipairs(conditions or {}) do
    if not M.holds(c, world) then return false end
  end
  return true
end

-- A condition as words, for the window ("Target Health % < 90").
function M.describe(c)
  local who
  for _, s in ipairs(catalog.subjects) do
    if s.id == c.who then who = s.label end
  end
  local p = catalog.property(c.who, c.what)
  if not who or not p then return "(unknown condition)" end
  if p.kind == "bool" then return string.format("%s %s %s", who, c.op, p.label:lower()) end
  if p.kind == "buff" then return string.format("%s %s %s", who, c.op, tostring(c.value or "")) end
  return string.format("%s %s %s %s", who, p.label, c.op, tostring(c.value))
end

return M
