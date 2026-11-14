-- Auto Combat: a row's conditions against the world snapshot (lib/world.lua). Pure: everything it reads is in the
-- snapshot, so it runs the same in the client and in the tests.
--
-- A subject in the snapshot is a table or nil: me, target, pet, group (the lowest-health member), assist. Each has
-- the numbers the catalog names (hp, mana, distance ...), booleans (named, mezzed, los ...) and for buffs
-- has_buff(name) / my_buff(name) functions answering true, false, or nil when it cannot be known (a target whose
-- buffs the server did not send). Counts read world.haters (the mobs on the player, with x, y, z) and world.npcs()
-- (the live NPCs about, not pets: { id, x, y, z }).
local catalog = require('lib.catalog')

local M = {}

-- How many of `list` are alive within `radius` of `at` (three dimensions); `skip` (a set of ids) are left out.
local function count_near(list, at, radius, skip)
  local n, r2 = 0, radius * radius
  for _, s in ipairs(list or {}) do
    if not s.dead and not (skip and skip[s.id]) then
      local dx, dy, dz = (s.x or 0) - (at.x or 0), (s.y or 0) - (at.y or 0), (s.z or 0) - (at.z or 0)
      if dx * dx + dy * dy + dz * dz <= r2 then n = n + 1 end
    end
  end
  return n
end

-- A count condition's number: the mobs on me, any NPCs, or the NPCs not on me, within its radius of the subject. The
-- subject itself counts when it is one of them (a targeted AE's target is hit too).
local function count(c, p, subject, world)
  local radius = tonumber(c.radius) or p.radius or 30
  if c.what == "near_haters" then return count_near(world.haters, subject, radius) end
  local npcs = world.npcs and world.npcs() or nil
  if not npcs then return nil end
  if c.what == "near_npcs" then return count_near(npcs, subject, radius) end
  local on_me = {}
  for _, h in ipairs(world.haters or {}) do on_me[h.id] = true end
  return count_near(npcs, subject, radius, on_me)
end

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
  if p.kind == "count" then return compare(count(c, p, subject, world), c.op, tonumber(c.value)) end
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
  if p.kind == "count" then
    local what = ({ near_haters = "Mobs on me", near_npcs = "NPCs", near_idle = "NPCs not on me" })[c.what] or p.label
    return string.format("%s within %s of %s %s %s", what, tostring(c.radius or p.radius), c.who == "me" and "me"
      or "the target", c.op, tostring(c.value))
  end
  return string.format("%s %s %s %s", who, p.label, c.op, tostring(c.value))
end

return M
