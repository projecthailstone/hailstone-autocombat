-- Auto Combat: the world as one tick sees it, read from the client (mq.TLO and the hailstone module) into plain
-- tables for the pure parts (lib/conditions.lua, rules.lua, targeting.lua, engine.lua). Lookups that are not always
-- needed (a spawn by id, a spell, readiness, the hunt list, path lengths) are functions, read when asked and kept
-- for the tick.
local mq = require('mq')
local hs = require('hailstone')

local M = {}

local CONS = { GREY = "grey", GREEN = "green", ["LIGHT BLUE"] = "lightblue", BLUE = "blue", WHITE = "white",
  YELLOW = "yellow", RED = "red" }

local function pct(v) return tonumber(v) or 100 end

-- A spawn (an MQ spawn value, already known to exist) as a table.
local function spawn_table(sp)
  local populated = sp.BuffsPopulated() == true
  local t = {
    id = sp.ID(),
    name = sp.CleanName() or sp.Name() or "?",
    hp = pct(sp.PctHPs()),
    distance = tonumber(sp.Distance()) or 9999,
    level = tonumber(sp.Level()) or 0,
    named = sp.Named() == true,
    npc = sp.Type() == "NPC",
    pc = sp.Type() == "PC",
    con = CONS[sp.ConColor() or ""] ,
    x = tonumber(sp.X()) or 0, y = tonumber(sp.Y()) or 0, z = tonumber(sp.Z()) or 0,
    max_range = tonumber(sp.MaxRangeTo()) or 14,
    buffs_known = populated,
  }
  t.los = sp.LineOfSight()
  -- What a buff tells: only when the server sent this spawn's buffs (Target.BuffsPopulated); unknown (nil) else.
  if populated then
    t.mezzed = sp.Mezzed() ~= nil
    t.slowed = sp.Slowed() ~= nil
    t.snared = sp.Snared() ~= nil
    t.rooted = sp.Rooted() ~= nil
    t.has_buff = function(name) return sp.Buff(name)() ~= nil end
    t.my_buff = function(name) return sp.MyBuff(name)() ~= nil end
  end
  return t
end

local function spawn_by_id(id)
  if not id or id == 0 then return nil end
  local sp = mq.TLO.Spawn('id ' .. id)
  if not sp() then return nil end
  return spawn_table(sp)
end

-- The player.
local function me_table(me, haters)
  local t = {
    id = me.ID(),
    name = me.CleanName() or me.Name() or "",
    hp = pct(me.PctHPs()), mana = pct(me.PctMana()), endurance = pct(me.PctEndurance()),
    current_mana = tonumber(me.CurrentMana()) or 0,
    casting = me.Casting() ~= nil,
    moving = me.Moving() == true,
    sitting = me.Sitting() == true,
    feigned = me.Feigning() == true,
    dead = me.Dead() == true,
    combat = me.Combat() == true,     -- auto attack on
    in_combat = me.CombatState() == "COMBAT",
    haters = haters,
    x = tonumber(me.X()) or 0, y = tonumber(me.Y()) or 0, z = tonumber(me.Z()) or 0,
    distance = 0,
    los = true,
    buffs_known = true,
  }
  t.has_buff = function(name) return me.Buff(name)() ~= nil or me.Song(name)() ~= nil end
  t.my_buff = t.has_buff
  t.combat_state = t.in_combat
  return t
end

-- The mobs on the player: the extended target list's auto-hater slots (type 1) that hold a live spawn.
local function haters()
  local out = {}
  local n = tonumber(hs.player() and hs.player().xtarget_slots) or 0
  for i = 1, n do
    local x = hs.xtarget(i)
    if x and x.type == 1 and (x.spawn_id or 0) ~= 0 then
      local s = spawn_by_id(x.spawn_id)
      if s and s.hp > 0 then out[#out + 1] = s end
    end
  end
  return out
end

-- The group member with the lowest health (not the player), and the main assist (or the one named).
local function group_tables(settings)
  local lowest, assist
  local my_name = mq.TLO.Me.Name()
  local g = mq.TLO.Group
  local count = tonumber(g.Members()) or 0
  for i = 1, count do
    local m = g.Member(i)
    local name = m and m.Name() or nil
    local sp = name and name ~= my_name and mq.TLO.Spawn('pc =' .. name)
    if sp and sp() then
      local t = spawn_table(sp)
      if not lowest or t.hp < lowest.hp then lowest = t end
    end
  end
  local want = settings.assist.who == "name" and settings.assist.name or nil
  if not want or want == "" then
    local ma = g.MainAssist
    want = ma and ma.Name() or nil
  end
  if want and want ~= "" then
    local sp = mq.TLO.Spawn('pc =' .. want)
    if sp() then assist = spawn_table(sp) end
  end
  return lowest, assist
end

-- The snapshot. `settings` (repaired) says which assist; `allowed` which modes the server lets run.
function M.read(settings, allowed)
  local now = mq.gettime()
  local w = { now = now, allowed = allowed or {} }
  w.in_game = mq.TLO.EverQuest.GameState() == "INGAME" and mq.TLO.Me() ~= nil
  if not w.in_game then
    w.me = { haters = 0 }
    w.haters = {}
    return w
  end
  w.haters = haters()
  w.me = me_table(mq.TLO.Me, #w.haters)
  w.target_id = tonumber(mq.TLO.Target.ID()) or 0
  w.target = w.target_id ~= 0 and spawn_by_id(w.target_id) or nil
  local pet = mq.TLO.Me.Pet
  if pet() and (tonumber(pet.ID()) or 0) ~= 0 then w.pet = spawn_by_id(pet.ID()) end
  w.group, w.assist = group_tables(settings)
  w.nav_active = mq.TLO.Navigation.Active() == true
  w.zone = mq.TLO.Zone.ShortName() or ""

  local spawns = {}
  function w.spawn(id)
    if spawns[id] == nil then spawns[id] = spawn_by_id(id) or false end
    return spawns[id] or nil
  end

  -- A spell by name: the gem it is in, whether that is ready, its range, cast time, mana, and whether it can only
  -- go on the caster (target type 6, Self).
  local spells = {}
  function w.spell(name)
    if spells[name] ~= nil then return spells[name] or nil end
    local sp = mq.TLO.Spell(name)
    if not sp() then
      spells[name] = false
      return nil
    end
    local gem = mq.TLO.Me.Gem(name)()
    local t = {
      gem = tonumber(gem),
      ready = gem ~= nil and mq.TLO.Me.SpellReady(name)() == true,
      range = tonumber(sp.Range()) or 0,
      cast_time = tonumber(sp.MyCastTime()) or 0,
      mana = tonumber(sp.Mana()) or 0,
      self_only = sp.TargetType() == "Self",
    }
    spells[name] = t
    return t
  end

  function w.ready(row)
    if row.kind == "spell" then
      local s = w.spell(row.name)
      if not s then return false, "unknown spell" end
      if not s.gem then return false, "not memorized" end
      if not s.ready then return false, "not ready" end
      if s.mana > w.me.current_mana then return false, "mana" end
      return true
    end
    local member = row.kind == "skill" and "AbilityReady" or row.kind == "disc" and "CombatAbilityReady"
        or "AltAbilityReady"
    if mq.TLO.Me[member](row.name)() == true then return true end
    return false, "not ready"
  end

  -- The walk to a spawn over the mesh; nil when there is none (yet).
  function w.path_length(id)
    local len = tonumber(mq.TLO.Navigation.PathLength('id ' .. id)())
    if not len or len < 0 then return nil end
    return len
  end
  local nav = mq.TLO.Navigation
  w.mesh = {
    loaded = nav.MeshLoaded() == true,
    complete = nav.MeshComplete() == true,
    built = tonumber(nav.TilesBuilt()) or 0,
    total = tonumber(nav.TilesTotal()) or 0,
  }

  -- Hunter: the live NPCs in the zone (not pets), each marked when another player is within the settings' radius.
  function w.hunt_spawns()
    local t = settings.targeting
    local players = {}
    for _, s in ipairs(mq.getFilteredSpawns(function(s) return s.Type() == "PC" and s.ID() ~= w.me.id end)) do
      players[#players + 1] = { tonumber(s.X()) or 0, tonumber(s.Y()) or 0 }
    end
    local out = {}
    local list = mq.getFilteredSpawns(function(s)
      return s.Type() == "NPC" and (tonumber(s.PctHPs()) or 0) > 0 and s.Targetable() ~= false
    end)
    for _, s in ipairs(list) do
      local x = spawn_table(s)
      for _, p in ipairs(players) do
        local dx, dy = p[1] - x.x, p[2] - x.y
        if dx * dx + dy * dy <= t.player_radius * t.player_radius then x.players_near = true end
      end
      out[#out + 1] = x
    end
    return out
  end

  return w
end

return M
