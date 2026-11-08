-- Auto Combat: the world as one tick sees it, read from the client (mq.TLO and the hailstone module) into plain
-- tables for the pure parts (lib/conditions.lua, rules.lua, targeting.lua, engine.lua). Lookups that are not always
-- needed (a spawn by id, a spell, an item, readiness, the hunt list, path lengths) are functions, read when asked and
-- kept for the tick.
local mq = require('mq')
local hs = require('hailstone')

local M = {}

local CONS = { GREY = "grey", GREEN = "green", ["LIGHT BLUE"] = "lightblue", BLUE = "blue", WHITE = "white",
  YELLOW = "yellow", RED = "red" }

local function pct(v) return tonumber(v) or 100 end

-- Someone's pet, a swarm pet among them. A swarm pet (an animated corpse, a necromancer's skeletons, a wizard's
-- familiar burst ...) comes with no owner in its spawn record on stock EQEmu (NPC::PetOnSpawn); what marks it is the
-- surname "<owner>'s Pet" (the rule Pets:ClientPetsUseOwnerNameInLastName, on by default). A server with that rule
-- off sends nothing to tell it by, so a swarm pet there looks like any NPC.
-- Some are also named for their owner: "<owner>`s Animated Corpse" (Wake the Dead, Mob::WakeTheDead), and
-- "<owner>`s warder" and the like; the name counts when a player of that name is in the zone.
local function owned(sp)
  if sp.Type() == "Pet" then return true end -- one with an owner in its record
  local surname = (sp.Surname() or ""):lower()
  if surname:find("['`]s pet$") then return true end
  local owner = (sp.CleanName() or sp.Name() or ""):match("^(%a+)[`']s[ _]")
  return owner ~= nil and mq.TLO.Spawn('pc =' .. owner)() ~= nil
end

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
  t.owned = owned(sp)
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

-- How many mobs are on the player (the extended target's auto haters), without reading each one; for burn mode
-- while Auto Combat is paused.
function M.hater_count()
  local n = 0
  local slots = tonumber(hs.player() and hs.player().xtarget_slots) or 0
  for i = 1, slots do
    local x = hs.xtarget(i)
    if x and x.type == 1 and (x.spawn_id or 0) ~= 0 then n = n + 1 end
  end
  return n
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

-- ---------------------------------------------------------------- items with a click effect
-- /useitem's slots: 0..22 worn, 23..32 the general slots (a bag's items by their place in it, from 0).
local WORN_LAST, GENERAL_FIRST, GENERAL_LAST = 22, 23, 32

-- Calls fn(item, slot, sub) for each item the player carries (worn, the general slots and their bags); stops when fn
-- returns true.
local function carried(fn)
  for slot = 0, GENERAL_LAST do
    local it = hs.item(slot)
    if it then
      if fn(it, slot, nil) then return end
      if slot >= GENERAL_FIRST and (it.bag_slots or 0) > 0 then
        for sub = 0, it.bag_slots - 1 do
          local b = hs.item(slot, sub)
          if b and fn(b, slot, sub) then return end
        end
      end
    end
  end
end

-- An item with a click effect as a table: where it is, its click spell (and what the spell is), cast time (ms),
-- recast (s) and how long it still has to go, charges.
local function click_table(it, slot, sub)
  local sp = mq.TLO.Spell(it.click_spell)
  local known = sp() ~= nil
  return {
    name = it.name, id = it.id, icon = it.icon, slot = slot, sub = sub, worn = slot <= WORN_LAST,
    spell_id = it.click_spell, spell = known and (sp.Name() or "") or "",
    cast_time = tonumber(it.click_cast_time) or 0, recast = tonumber(it.click_recast) or 0,
    ready_in = tonumber(it.click_ready_in) or 0, level = tonumber(it.click_level) or 0,
    req_level = tonumber(it.req_level) or 0, charges = tonumber(it.charges) or 0,
    max_charges = tonumber(it.click_max_charges) or -1,
    range = known and tonumber(sp.Range()) or 0, self_only = known and sp.TargetType() == "Self",
    beneficial = known and sp.Beneficial() == true, target_type = known and (sp.TargetType() or "") or "",
    duration = known and tonumber(sp.Duration.TotalSeconds()) or 0, ae_range = known and tonumber(sp.AERange()) or 0,
  }
end

-- Every item the player carries with a click effect, for the Items page's picker.
function M.clickies()
  local out = {}
  carried(function(it, slot, sub)
    if (it.click_spell or 0) > 0 then out[#out + 1] = click_table(it, slot, sub) end
  end)
  return out
end

-- Where each item was found last (by lower-case name), and when one was last looked for and not found: an item
-- that has moved is looked for again, one not carried at most every 2 s (a search reads every slot).
local item_at, item_missed = {}, {}

local function find_item(name, now)
  local key = name:lower()
  local at = item_at[key]
  if at then
    local it = hs.item(at[1], at[2])
    if it and it.name:lower() == key and (it.click_spell or 0) > 0 then return click_table(it, at[1], at[2]) end
    item_at[key] = nil
  end
  if item_missed[key] and now - item_missed[key] < 2000 then return nil end
  local found
  carried(function(it, slot, sub)
    if (it.click_spell or 0) > 0 and it.name:lower() == key then
      found = click_table(it, slot, sub)
      return true
    end
  end)
  if found then
    item_at[key], item_missed[key] = { found.slot, found.sub }, nil
  else
    item_missed[key] = now
  end
  return found
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

  -- A carried item with a click effect, by name (nil: not carried, or no click).
  local items = {}
  function w.item(name)
    if items[name] == nil then items[name] = find_item(name, now) or false end
    return items[name] or nil
  end

  function w.ready(row)
    if row.kind == "item" then
      local it = w.item(row.name)
      if not it then return false, "not carried" end
      if it.ready_in > 0 then return false, "ready in " .. it.ready_in .. "s" end
      if it.max_charges > 0 and it.charges == 0 then return false, "no charges" end
      return true
    end
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

  -- What the game itself lets a player target: the Targetable flag on and body type not 11 (EQEmu's NoTarget, which
  -- servers give portal and trigger NPCs such as Project Triune's #TPTriggerN). Spawn.Targetable is the flag alone.
  local function targetable(s)
    return s.Targetable() ~= false and tonumber(s.BodyType()) ~= 11
  end

  -- The live NPCs within 400 of me, not pets and not untargetable ones, for the count conditions (read once a tick,
  -- when asked).
  local npcs
  function w.npcs()
    if not npcs then
      npcs = {}
      local list = mq.getFilteredSpawns(function(s)
        return s.Type() == "NPC" and (tonumber(s.PctHPs()) or 0) > 0 and (tonumber(s.Distance3D()) or 9999) <= 400
          and targetable(s) and not owned(s)
      end)
      for _, s in ipairs(list) do
        npcs[#npcs + 1] = { id = s.ID(), x = tonumber(s.X()) or 0, y = tonumber(s.Y()) or 0, z = tonumber(s.Z()) or 0,
          hp = tonumber(s.PctHPs()) or 0 }
      end
    end
    return npcs
  end

  -- Hunter: the live NPCs in the zone (not pets), each marked when another player is within the settings' radius.
  function w.hunt_spawns()
    local t = settings.targeting
    local players = {}
    for _, s in ipairs(mq.getFilteredSpawns(function(s) return s.Type() == "PC" and s.ID() ~= w.me.id end)) do
      players[#players + 1] = { tonumber(s.X()) or 0, tonumber(s.Y()) or 0 }
    end
    local out = {}
    local list = mq.getFilteredSpawns(function(s)
      return s.Type() == "NPC" and (tonumber(s.PctHPs()) or 0) > 0 and targetable(s) and not owned(s)
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
