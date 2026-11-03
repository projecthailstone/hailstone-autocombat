-- Auto Combat: the settings, their defaults, and the repair of a loaded file (a missing or wrong-typed value takes
-- its default, numbers are clamped, rows and conditions that make no sense are dropped). Pure.
local catalog = require('lib.catalog')

local M = {}

M.VERSION = 1

M.MODES = { "manual", "hunter", "assist" }
M.STYLES = { "full", "partial" }
M.HUNT_STYLES = { "roam", "camp" }
M.PRIORITIES = { "lowest_hp", "highest_hp", "closest", "named_first" }
M.CONS = { "grey", "green", "lightblue", "blue", "white", "yellow", "red" }

function M.defaults()
  return {
    version = M.VERSION,
    mode = "manual",
    style = "full",               -- manual mode: full (it targets the mobs on you) or partial (you pick them)
    general = {
      attack = true,              -- melee auto attack on the fight target
      stick = true,               -- keep in melee range (/stick); off: face it only
      stick_distance = 0,         -- 0: inside melee range
      behind = false,             -- /stick behind
      pet_attack = true,          -- send the pet on each new fight target
      hold_autoskill = true,      -- the Ability Book's autoskill waits while Auto Combat runs
      action_gap = 0.4,           -- seconds between two actions
    },
    targeting = {
      priority = "lowest_hp",
      min_level = 0,              -- 0: any
      max_level = 0,
      cons = { grey = false, green = true, lightblue = true, blue = true, white = true, yellow = true, red = false },
      named = true,               -- named mobs may be chosen
      ignore = {},                -- names (or parts of names) never chosen
      radius = 200,               -- hunter: how far it looks
      zradius = 50,
      skip_near_players = true,   -- hunter: leave mobs with another player close to them
      player_radius = 50,
    },
    hunter = {
      style = "roam",             -- roam the zone, or pull back to a camp
      camp = nil,                 -- camp style: {x, y, z (the server's coordinates), zone (short name)}
      leash = 400,                -- camp: how far from the camp it goes for a mob
      max_path = 800,             -- the longest walk to a mob
      pull_kind = "",             -- camp: the pull (a spell or ability; "" walks up and attacks)
      pull_name = "",
      max_haters = 2,             -- do not go looking while this many are on you
      give_up = 60,               -- seconds before a walk to a mob is given up (the mob is skipped for 5 minutes)
    },
    assist = {
      who = "group",              -- "group": the group's main assist; "name": the name below
      name = "",
      engage_pct = 95,            -- join when the assist's target is at or below this health
      follow = true,              -- follow the assist out of combat
      follow_distance = 20,
    },
    rest = {
      sit_hp = 60, sit_mana = 40, sit_endurance = 30,  -- sit when one is below (0: never for that one)
      stand_hp = 95, stand_mana = 95, stand_endurance = 90,
      stop_hp = 0,                -- pause Auto Combat when your health falls below this (0: off)
    },
    spells = {},
    abilities = {},
  }
end

local function one_of(v, list, default)
  for _, x in ipairs(list) do
    if v == x then return v end
  end
  return default
end

local function number(v, default, lo, hi)
  v = tonumber(v)
  if not v or v ~= v then return default end
  if lo and v < lo then v = lo end
  if hi and v > hi then v = hi end
  return v
end

local function bool(v, default)
  if type(v) == "boolean" then return v end
  return default
end

local function text(v, default)
  if type(v) == "string" then return v end
  return default
end

-- Fills `out` from `given` following the shape of `defaults`.
local function fill(defaults, given)
  local out = {}
  given = type(given) == "table" and given or {}
  for k, d in pairs(defaults) do
    local g = given[k]
    if type(d) == "table" then out[k] = fill(d, g)
    elseif type(d) == "number" then out[k] = number(g, d)
    elseif type(d) == "boolean" then out[k] = bool(g, d)
    elseif type(d) == "string" then out[k] = text(g, d)
    end
  end
  return out
end

function M.condition(c)
  if type(c) ~= "table" then return nil end
  local p = catalog.property(c.who, c.what)
  if not p or not catalog.valid_op(p.kind, c.op) then return nil end
  local out = { who = c.who, what = c.what, op = c.op }
  if p.kind == "buff" then out.value = text(c.value, "")
  elseif p.kind == "count" then
    out.value = number(c.value, p.default or 0, 0, 100)
    out.radius = number(c.radius, p.radius or 30, 1, 300)
  elseif p.kind ~= "bool" then out.value = number(c.value, p.default or 0) end
  return out
end

M.ROW_KINDS = { "spell", "disc", "aa", "skill" }
M.ROW_TARGETS = { "enemy", "self", "pet", "group", "assist" }
M.ROW_PHASES = { "combat", "rest", "always" }

function M.row(r)
  if type(r) ~= "table" or type(r.name) ~= "string" or r.name == "" then return nil end
  local out = {
    enabled = bool(r.enabled, true),
    kind = one_of(r.kind, M.ROW_KINDS, "spell"),
    name = r.name,
    target = one_of(r.target, M.ROW_TARGETS, "enemy"),
    phase = one_of(r.phase, M.ROW_PHASES, "combat"),
    recast = number(r.recast, 0, 0, 3600),      -- seconds before this row fires again
    per_target = bool(r.per_target, false),     -- the recast counts per fight target (a DoT, a debuff)
    conditions = {},
  }
  for _, c in ipairs(type(r.conditions) == "table" and r.conditions or {}) do
    local ok = M.condition(c)
    if ok then out.conditions[#out.conditions + 1] = ok end
  end
  return out
end

-- A loaded (or edited) settings table made whole: defaults for what is missing or wrong.
-- A Spells row for a memorized spell (Import spell bar), from what the spell is: info = { name, beneficial,
-- target_type (MQ's TargetType: "Self", "Single", "Pet" ...), duration (seconds, 0: none) }. A starting point the
-- player edits:
--   detrimental                  on the fight target, in combat
--   beneficial on the pet        on my pet, any time, again once it has run out (the recast)
--   beneficial with a duration   on me, any time, when I lack it
--   beneficial, instant          on me, any time, when my health is under 60%
-- The AE target types (the Spell TLO's TargetType), by where the AE is centred.
M.PB_AE = { ["PB AE"] = true, ["AE Undead"] = true, ["AE Summoned"] = true, ["Caster PB NPC"] = true,
  ["Directional AE"] = true, ["Beam"] = true }
M.TARGET_AE = { ["Targeted AE"] = true, ["Targeted AE Tap"] = true, ["Free Target"] = true }

function M.row_for_spell(info)
  local r = { enabled = true, kind = "spell", name = info.name, target = "enemy", phase = "combat", recast = 0,
    per_target = false, conditions = {} }
  if info.beneficial then
    r.phase = "always"
    if info.target_type == "Pet" then
      r.target = "pet"
      r.recast = math.max(0, math.min(3600, info.duration or 0))
    elseif (info.duration or 0) > 0 then
      r.target = "self"
      r.conditions = { { who = "me", what = "buff", op = "lacks", value = info.name } }
    else
      r.target = "self"
      r.conditions = { { who = "me", what = "hp", op = "<", value = 60 } }
    end
  else
    -- An AE: enough mobs on me in its reach, and none in it that are not (no adds). Hatelist spells hit only the
    -- mobs on me, wherever they are.
    local tt = info.target_type or ""
    local reach = math.floor(tonumber(info.ae_range) or 0)
    reach = reach > 0 and reach or 30
    local at = M.PB_AE[tt] and "me" or (M.TARGET_AE[tt] and "target") or nil
    if at then
      r.conditions = { { who = at, what = "near_haters", op = ">=", value = 3, radius = reach },
        { who = at, what = "near_idle", op = "<=", value = 0, radius = reach } }
    elseif tt == "Hatelist" or tt == "Hatelist2" then
      r.conditions = { { who = "me", what = "haters", op = ">=", value = 3 } }
    end
  end
  return M.row(r)
end

function M.repair(given)
  local d = M.defaults()
  local out = fill(d, given)
  given = type(given) == "table" and given or {}
  out.version = M.VERSION
  out.mode = one_of(given.mode, M.MODES, d.mode)
  out.style = one_of(given.style, M.STYLES, d.style)
  out.targeting.priority = one_of(out.targeting.priority, M.PRIORITIES, d.targeting.priority)
  out.hunter.style = one_of(out.hunter.style, M.HUNT_STYLES, d.hunter.style)
  out.assist.who = one_of(out.assist.who, { "group", "name" }, d.assist.who)
  for _, k in ipairs({ "engage_pct" }) do out.assist[k] = number(out.assist[k], d.assist[k], 0, 100) end
  for _, k in ipairs({ "sit_hp", "sit_mana", "sit_endurance", "stand_hp", "stand_mana", "stand_endurance", "stop_hp" }) do
    out.rest[k] = number(out.rest[k], d.rest[k], 0, 100)
  end
  out.general.action_gap = number(out.general.action_gap, d.general.action_gap, 0.1, 5)
  -- Lists and the camp (not in the defaults' shape).
  out.targeting.ignore = {}
  local ign = given.targeting and given.targeting.ignore
  for _, n in ipairs(type(ign) == "table" and ign or {}) do
    if type(n) == "string" and n ~= "" then out.targeting.ignore[#out.targeting.ignore + 1] = n end
  end
  local camp = given.hunter and given.hunter.camp
  if type(camp) == "table" and tonumber(camp.x) and tonumber(camp.y) and tonumber(camp.z) and type(camp.zone) == "string" then
    out.hunter.camp = { x = tonumber(camp.x), y = tonumber(camp.y), z = tonumber(camp.z), zone = camp.zone }
  end
  if out.hunter.pull_kind ~= "" then out.hunter.pull_kind = one_of(out.hunter.pull_kind, M.ROW_KINDS, "") end
  for _, list in ipairs({ "spells", "abilities" }) do
    out[list] = {}
    for _, r in ipairs(type(given[list]) == "table" and given[list] or {}) do
      local ok = M.row(r)
      if ok then out[list][#out[list] + 1] = ok end
    end
  end
  return out
end

-- Sets one value by a dotted path ("targeting.radius") when the path names a plain value of the defaults' shape;
-- returns the repaired settings and whether it changed anything.
function M.set(settings, path, value)
  local d = M.defaults()
  local node, dnode = settings, d
  local keys = {}
  for k in tostring(path):gmatch("[^%.]+") do keys[#keys + 1] = k end
  if #keys == 0 then return settings, false end
  for i = 1, #keys - 1 do
    node, dnode = node[keys[i]], dnode[keys[i]]
    if type(node) ~= "table" or type(dnode) ~= "table" then return settings, false end
  end
  local last = keys[#keys]
  local dv = dnode[last]
  local allowed = dv ~= nil and type(dv) ~= "table"
  if not allowed and not (#keys == 1 and (last == "mode" or last == "style")) then
    if not (keys[1] == "hunter" and last == "camp") then return settings, false end
  end
  node[last] = value
  return M.repair(settings), true
end

return M
