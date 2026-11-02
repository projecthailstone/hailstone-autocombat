-- Auto Combat: which row of the Spells or Abilities page fires next. Pure: the snapshot (lib/world.lua) answers
-- what needs the game (world.ready(row), world.spell(name)), and `memory` keeps when each row last fired.
--
-- A row fires when it is enabled, its phase holds, the one it acts on is there (and for the fight target in sight),
-- it is ready (a memorized, ready spell with the mana; a ready ability), within range, its recast has passed and
-- every condition holds. Rows are tried in order: the first that may fire is the one.
local conditions = require('lib.conditions')

local M = {}

-- The table a row acts on: the fight target, me, the pet, the lowest group member or the assist.
function M.recipient(row, world)
  if row.target == "enemy" then return world.target end
  if row.target == "self" then return world.me end
  if row.target == "pet" then return world.pet end
  if row.target == "group" then return world.group end
  if row.target == "assist" then return world.assist end
  return nil
end

function M.phase_holds(row, world)
  if row.phase == "combat" then return world.fighting == true end
  if row.phase == "rest" then return not world.fighting and (world.me.haters or 0) == 0 end
  return true
end

local function key(list, i, row) return list .. ":" .. i .. ":" .. row.kind .. ":" .. row.name end

function M.recast_passed(row, memory, k, now, target_id)
  if (row.recast or 0) <= 0 then return true end
  local last
  if row.per_target then
    last = memory.per_target[k] and memory.per_target[k][target_id or 0]
  else
    last = memory.last[k]
  end
  return not last or now - last >= row.recast * 1000
end

-- Why a row cannot fire now ("" when it can), for the window's "why not" column and the tests.
function M.blocker(list, i, row, world, memory)
  if not row.enabled then return "off" end
  if world.me.casting then return "casting" end
  if not M.phase_holds(row, world) then return "phase" end
  local to = M.recipient(row, world)
  if not to then return "no " .. row.target end
  if row.target == "enemy" and to.los == false then return "not in sight" end
  local ready, why = world.ready(row)
  if not ready then return why or "not ready" end
  if row.kind == "spell" then
    local s = world.spell(row.name)
    if not s then return "unknown spell" end
    if (s.range or 0) > 0 and to ~= world.me and (to.distance or 0) > s.range then return "out of range" end
    if (s.cast_time or 0) > 0 and world.me.moving then return "moving" end
  end
  local k = key(list, i, row)
  if not M.recast_passed(row, memory, k, world.now, to.id) then return "recast" end
  if not conditions.all(row.conditions, world) then return "conditions" end
  return ""
end

-- The first row of `rows` that may fire: index, row, recipient; nil when none.
function M.next(list, rows, world, memory)
  for i, row in ipairs(rows) do
    if M.blocker(list, i, row, world, memory) == "" then return i, row, M.recipient(row, world) end
  end
  return nil
end

-- Note that a row fired at `now` on `target_id`.
function M.fired(list, i, row, memory, now, target_id)
  local k = key(list, i, row)
  memory.last[k] = now
  memory.per_target[k] = memory.per_target[k] or {}
  memory.per_target[k][target_id or 0] = now
end

function M.new_memory() return { last = {}, per_target = {} } end

-- A new fight forgets the per-target recasts of mobs that are gone (kept small).
function M.forget_targets(memory, alive)
  for _, by in pairs(memory.per_target) do
    for id in pairs(by) do
      if id ~= 0 and not alive[id] then by[id] = nil end
    end
  end
end

return M
