-- Auto Combat: the modes. One tick reads a snapshot of the world (lib/world.lua) and the settings, decides, and acts
-- through `io` (init.lua in the client, a recorder in the tests). It never reads the game itself.
--
-- io = {
--   cmd(line),                  a command line (/target id 5, /cast 3, /attack on, /stick ..., /nav ...)
--   use(kind, name) -> bool,    a skill, combat ability or AA (hailstone.use_ability)
--   delay(ms [, until_fn]),     waits inside the script's coroutine
--   casting() -> bool,          the player is casting now (read fresh, after a delay)
--   say(text),                  a line for the player (chat window)
-- }
local rules = require('lib.rules')
local targeting = require('lib.targeting')

local M = {}

local SKIP_MS = 5 * 60 * 1000 -- a mob given up on is left this long
local NO_PATH_MS = 20 * 1000  -- a mob with no path while the zone's mesh is still being built is tried again after this
local FACE_MS = 1000          -- how often a fight target is faced when not sticking
local ASSIST_MS = 1500        -- how often /assist asks again while there is nothing to fight
local LOOK_MS = 1000          -- hunter: how often it looks for a mob
local SIT_RETRY_MS = 3000     -- resting: how often /sit is sent again while the player is not sitting yet

function M.new()
  return {
    running = false,
    status = "Paused",
    fight_id = 0,        -- the mob being fought
    engage_id = 0,       -- hunter: the mob walked to (fought once in reach, before it is on me)
    hunt = nil,          -- hunter: { id, since, pulled }
    skip = {},           -- hunter: id -> until (ms)
    stick_id = 0,        -- the spawn /stick was given
    nav = nil,           -- what /nav was sent to ("camp", "mob", "assist")
    sat = false,         -- Auto Combat sat the player down
    pet_sent = {},       -- fight targets the pet was sent on
    memory = rules.new_memory(),
    last_action = { spells = -1e9, abilities = -1e9 },
    last_face = -1e9,
    last_assist = -1e9,
    last = "",           -- the last thing it did, for the window
    log = {},            -- the last few lines
  }
end

local function note(e, text, io)
  e.last = text
  e.log[#e.log + 1] = text
  while #e.log > 12 do table.remove(e.log, 1) end
  if io and io.trace then io.trace(text) end
end

local function stop_moving(e, io)
  if e.stick_id ~= 0 then
    io.cmd('/stick off')
    e.stick_id = 0
  end
  if e.nav then
    io.cmd('/nav stop')
    e.nav = nil
  end
end

-- Stops what Auto Combat started: its walk or /stick, the auto attack it turned on, the pet it sent (/pet back off).
-- Not the player's own attack.
function M.pause(e, io, why)
  if not e.running then return end
  e.running = false
  stop_moving(e, io)
  if e.attack_on then io.cmd('/attack off') end
  if e.pet_out then io.cmd('/pet back off') end
  e.attack_on, e.pet_out = false, false
  e.pet_sent = {}
  e.fight_id, e.engage_id, e.hunt, e.look_why = 0, 0, nil, nil
  e.status = "Paused"
  note(e, why or "Paused", io)
  if why then io.say("Auto Combat: " .. why) end
end

function M.start(e, io)
  if e.running then return end
  e.running = true
  e.status = "Starting"
  e.skip = {}
  note(e, "Started", io)
end

-- ---------------------------------------------------------------- acting

-- A cast or an ability on `to` (a table from the snapshot with an id). A row for someone other than the fight
-- target targets them first and the fight target again after: attack off meanwhile, so it never swings at a
-- friend.
local function fire(e, list, i, row, to, world, io, s)
  local enemy = row.target == "enemy"
  local spell = row.kind == "spell" and world.spell(row.name) or nil
  local self_only = spell and spell.self_only
  local retarget = not enemy and not self_only and to.id ~= world.target_id
  local back, attack_back = world.target_id, false
  if retarget then
    if world.me.combat then
      io.cmd('/attack off')
      attack_back = true
    end
    io.cmd('/target id ' .. to.id)
    io.delay(100)
  end
  local ok
  if row.kind == "spell" then
    io.cmd('/cast ' .. spell.gem)
    ok = true
    if retarget or (spell.cast_time or 0) > 0 then io.delay(1000, io.casting) end
  else
    ok = io.use(row.kind, row.name)
  end
  if retarget then
    if back and back ~= 0 then io.cmd('/target id ' .. back) else io.cmd('/target clear') end
    if attack_back then io.cmd('/attack on') end
  end
  if ok then
    rules.fired(list, i, row, e.memory, world.now, to.id)
    e.last_action[list] = world.now
    note(e, string.format("%s %s on %s", row.kind == "spell" and "Cast" or "Used", row.name, to.name or "?"), io)
  end
  return ok
end

-- Fires the first row that may fire from each page, each page held to the action gap.
local function fire_rows(e, world, s, io)
  for _, list in ipairs({ "abilities", "spells" }) do
    if world.now - e.last_action[list] >= s.general.action_gap * 1000 then
      local i, row, to = rules.next(list, s[list], world, e.memory)
      if i then
        if world.me.sitting and not world.me.feigned then
          io.cmd('/stand')
          e.sat = false
        end
        fire(e, list, i, row, to, world, io, s)
        return true
      end
    end
  end
  return false
end

-- ---------------------------------------------------------------- choosing the fight

local function hater_ids(world)
  local ids = {}
  for _, h in ipairs(world.haters) do ids[h.id] = true end
  return ids
end

-- The mob to fight now, or nil. Full and Hunter fight only what is on the extended target list (the mobs on me) and
-- the one Hunter chose to go after; never a target that is merely selected with auto attack on (an animated corpse,
-- someone's pet), and never someone's pet (lib/world.lua's owned).
local function fight_target(e, world, s)
  local haters = hater_ids(world)
  local pt = world.target
  local player_fights = pt and pt.npc and not pt.owned and (pt.hp or 0) > 0 and (haters[pt.id] or world.me.combat)
  if s.mode == "manual" and s.style == "partial" then
    -- You choose: the NPC you target, once it is on you or you attack it.
    return player_fights and pt or nil
  end
  if s.mode == "assist" then
    local a = world.assist
    -- Keep at the one we fight while it lives; else the assist's target (our target after /assist) once low enough.
    if e.fight_id ~= 0 then
      local f = world.spawn(e.fight_id)
      if f and (f.hp or 0) > 0 then return f end
    end
    if a and pt and pt.npc and not pt.owned and (pt.hp or 0) > 0 and pt.id ~= a.id
        and (pt.hp or 100) <= s.assist.engage_pct then
      return pt
    end
    return nil
  end
  -- Full and hunter: the mobs on me, then the one Hunter chose to go after.
  local awake = {}
  for _, x in ipairs(world.haters) do
    if not x.owned then awake[#awake + 1] = x end
  end
  local h = targeting.choose_hater(awake, e.fight_id, s.targeting.priority)
  if h then return h end
  if e.engage_id ~= 0 then
    local g = world.spawn(e.engage_id)
    if g and (g.hp or 0) > 0 and not g.owned then return g end
    e.engage_id = 0
  end
  return nil
end

-- ---------------------------------------------------------------- fighting

local function fight(e, world, s, io, f)
  if f.id ~= e.fight_id then
    e.fight_id = f.id
    e.memory.fresh = true
    note(e, "Fighting " .. (f.name or "?"), io)
  end
  e.status = "Fighting " .. (f.name or "?")
  if e.nav then
    io.cmd('/nav stop')
    e.nav = nil
  end
  -- Partial: the player's own target; the others: target it.
  if world.target_id ~= f.id then
    io.cmd('/target id ' .. f.id)
    return
  end
  local t = world.target
  if world.me.sitting and not world.me.feigned then
    io.cmd('/stand')
    e.sat = false
  end
  local partial = s.mode == "manual" and s.style == "partial"
  if s.general.stick and not partial then
    if e.stick_id ~= f.id then
      local words = '/stick id ' .. f.id
      if s.general.stick_distance > 0 then words = words .. ' ' .. s.general.stick_distance end
      if s.general.behind then words = words .. ' behind' end
      io.cmd(words)
      e.stick_id = f.id
    end
  elseif world.now - e.last_face >= FACE_MS and not world.me.moving and not world.me.casting then
    io.cmd('/face fast')
    e.last_face = world.now
  end
  if s.general.attack and not world.me.combat and (t.distance or 999) <= (t.max_range or 14) + 10 then
    io.cmd('/attack on')
    e.attack_on = true
  end
  if s.general.pet_attack and world.pet and not e.pet_sent[f.id] then
    io.cmd('/pet attack')
    e.pet_sent[f.id] = true
    e.pet_out = true
  end
  world.fighting = true
  fire_rows(e, world, s, io)
end

local function fight_over(e, world, s, io)
  if e.fight_id == 0 then return end
  local f = world.spawn(e.fight_id)
  note(e, (f and f.name or "The mob") .. ((f and (f.hp or 0) > 0) and " is no longer fought" or " is dead"), io)
  e.fight_id = 0
  if e.stick_id ~= 0 then
    io.cmd('/stick off')
    e.stick_id = 0
  end
  if world.me.combat and #world.haters == 0 then
    io.cmd('/attack off')
    e.attack_on = false
  end
  e.pet_sent = {}
  local alive = {}
  for _, h in ipairs(world.haters) do alive[h.id] = true end
  rules.forget_targets(e.memory, alive)
end

-- ---------------------------------------------------------------- resting

local function below(pct, limit) return limit > 0 and (pct or 100) < limit end

local function rest(e, world, s, io)
  local me, r = world.me, s.rest
  if (me.haters or 0) > 0 or me.moving or me.casting then return false end
  local tired = below(me.hp, r.sit_hp) or below(me.mana, r.sit_mana) or below(me.endurance, r.sit_endurance)
  if me.sitting then
    if e.sat and (me.hp or 100) >= r.stand_hp and (me.mana or 100) >= r.stand_mana
        and (me.endurance or 100) >= r.stand_endurance then
      io.cmd('/stand')
      e.sat = false
      note(e, "Rested", io)
      return false
    end
    if e.sat then
      e.status = "Resting"
      return true
    end
    return false
  end
  if tired then
    -- Not sitting yet: /sit again only now and then (the server may not have answered), and log it once.
    if not e.sat or world.now - (e.sit_at or -1e9) > SIT_RETRY_MS then
      stop_moving(e, io)
      io.cmd('/sit')
      if not e.sat then note(e, "Resting", io) end
      e.sat, e.sit_at = true, world.now
    end
    e.status = "Resting"
    return true
  end
  return false
end

-- ---------------------------------------------------------------- hunting

local function flat(a, b)
  local dx, dy = a[1] - b[1], a[2] - b[2]
  return math.sqrt(dx * dx + dy * dy)
end

local function pull_range(world, s)
  local h = s.hunter
  if h.pull_kind == "spell" and h.pull_name ~= "" then
    local sp = world.spell(h.pull_name)
    return sp and sp.range or 0
  end
  return 0
end

local function hunt(e, world, s, io)
  local h = s.hunter
  if #world.haters >= h.max_haters and h.max_haters > 0 then return end
  -- A camp set in another zone does not count here.
  local camp = h.style == "camp" and h.camp and h.camp.zone == world.zone and { h.camp.x, h.camp.y, h.camp.z } or nil
  local me = world.me
  -- Walking to one: give up after a while; in reach, pull it (camp) or engage it (roam).
  if e.hunt then
    local m = world.spawn(e.hunt.id)
    if not m or (m.hp or 0) <= 0 then
      e.hunt = nil
    elseif world.now - e.hunt.since > h.give_up * 1000 then
      e.skip[e.hunt.id] = world.now + SKIP_MS
      note(e, "Gave up on " .. (m.name or "?"), io)
      e.hunt = nil
      if e.nav then io.cmd('/nav stop') e.nav = nil end
    else
      local reach = pull_range(world, s)
      local pulling = camp and h.pull_name ~= "" and reach > 0
      if pulling and not e.hunt.pulled and (m.distance or 999) <= reach * 0.9 and m.los ~= false then
        if world.target_id ~= m.id then
          io.cmd('/target id ' .. m.id)
          return
        end
        if e.nav then io.cmd('/nav stop') e.nav = nil end
        local ok
        if h.pull_kind == "spell" then
          local sp = world.spell(h.pull_name)
          if sp and sp.gem and sp.ready then
            io.cmd('/cast ' .. sp.gem)
            io.delay(1000, io.casting)
            ok = true
          end
        else
          ok = io.use(h.pull_kind, h.pull_name)
        end
        if ok then
          e.hunt.pulled = true
          note(e, "Pulled " .. (m.name or "?"), io)
          io.cmd(string.format('/nav loc %.1f %.1f %.1f', camp[2], camp[1], camp[3]))
          e.nav = "camp"
        end
        return
      end
      if not pulling and (m.distance or 999) <= 30 then
        e.engage_id = m.id
        e.hunt = nil
        return
      end
      if e.nav ~= "mob" and not e.hunt.pulled then
        io.cmd('/nav id ' .. m.id .. ' distance=' .. (pulling and math.floor(reach * 0.8) or 10))
        e.nav = "mob"
      end
      e.status = (e.hunt.pulled and "Pulling " or "Going to ") .. (m.name or "?")
      return
    end
  end
  -- Camp: back to it first.
  if camp and flat({ me.x, me.y }, camp) > 20 then
    if e.nav ~= "camp" then
      io.cmd(string.format('/nav loc %.1f %.1f %.1f', camp[2], camp[1], camp[3]))
      e.nav = "camp"
    end
    e.status = "Going back to camp"
    return
  end
  if e.nav == "camp" and not world.nav_active then e.nav = nil end
  -- Look for one (the zone's spawns are read at most once a second). Between looks the last look's reason stays.
  e.status = e.look_why or "Looking for mobs"
  if world.now - (e.last_look or -1e9) < LOOK_MS then return end
  e.last_look = world.now
  for id, until_ms in pairs(e.skip) do
    if until_ms <= world.now then e.skip[id] = nil end
  end
  local from = camp or { me.x, me.y, me.z }
  local all = world.hunt_spawns()
  local list, filtered = targeting.hunt_candidates(all, s.targeting, h, from, e.skip, camp ~= nil)
  -- Roam: nothing within the search radius, so anywhere in the zone, nearest first, however long the walk.
  local wide = false
  if #list == 0 and not camp then
    list = targeting.hunt_candidates(all, s.targeting, h, from, e.skip, false, true)
    wide = true
  end
  local mesh = world.mesh or { loaded = true, complete = true }
  local no_path, too_long = 0, 0
  for n = 1, math.min(#list, 5) do
    local m = list[n]
    local len = world.path_length(m.id)
    if len and len >= 0 and (wide or len <= h.max_path) then
      e.hunt = { id = m.id, since = world.now }
      e.look_why = nil
      note(e, "Hunting " .. (m.name or "?"), io)
      return
    end
    if not len or len < 0 then no_path = no_path + 1 else too_long = too_long + 1 end
    -- No path yet while the mesh is still building is not the mob's fault: try it again soon.
    e.skip[m.id] = world.now + ((not len or len < 0) and not mesh.complete and NO_PATH_MS or SKIP_MS)
  end
  local why
  if #all == 0 then
    why = "No NPCs in the zone"
  elseif not mesh.loaded then
    why = "No navigation mesh for this zone yet"
  elseif no_path > 0 and not mesh.complete then
    why = string.format("Waiting for the navigation mesh (%d/%d)", mesh.built or 0, mesh.total or 0)
  elseif #list == 0 and filtered == #all then
    why = string.format("No mobs to hunt: the Targeting page leaves out all %d NPCs", #all)
  elseif #list == 0 then
    why = "No mobs to hunt (the ones left are skipped for now)"
  elseif no_path > 0 then
    why = "No path to the nearest mobs"
  else
    why = "The nearest mobs are past the longest walk"
  end
  e.status = why
  -- The log gets the counts once per change of reason, so a hunt that finds nothing can be told apart.
  if why ~= e.look_why then
    note(e, string.format("%s (NPCs %d, left out %d, candidates %d%s, no path %d, too far %d)", why, #all, filtered,
      #list, wide and " zone-wide" or "", no_path, too_long), io)
  end
  e.look_why = why
end

-- ---------------------------------------------------------------- assisting

local function follow_assist(e, world, s, io)
  local a = world.assist
  if not a then
    e.status = "No assist"
    return
  end
  if world.now - e.last_assist >= ASSIST_MS then
    io.cmd('/assist ' .. a.name)
    e.last_assist = world.now
  end
  if s.assist.follow and (a.distance or 0) > s.assist.follow_distance * 1.5 and e.nav ~= "assist" then
    io.cmd('/nav id ' .. a.id .. ' distance=' .. s.assist.follow_distance)
    e.nav = "assist"
  elseif e.nav == "assist" and not world.nav_active then
    e.nav = nil
  end
  e.status = "Assisting " .. a.name
end

-- ---------------------------------------------------------------- the tick

function M.tick(e, world, s, io)
  if not e.running then return end
  if not world.in_game then return end
  local me = world.me
  if me.dead then return M.pause(e, io, "you died; paused") end
  if s.rest.stop_hp > 0 and (me.hp or 100) < s.rest.stop_hp then
    return M.pause(e, io, string.format("your health fell below %d%%; paused", s.rest.stop_hp))
  end
  if world.allowed[s.mode] == false then
    return M.pause(e, io, "this server does not allow " .. s.mode .. " mode")
  end
  world.fighting = false
  local f = fight_target(e, world, s)
  if f then return fight(e, world, s, io, f) end
  fight_over(e, world, s, io)
  if me.casting then return end
  if fire_rows(e, world, s, io) then return end
  if rest(e, world, s, io) then return end
  if s.mode == "hunter" then return hunt(e, world, s, io) end
  if s.mode == "assist" then return follow_assist(e, world, s, io) end
  e.status = s.style == "partial" and "Waiting for your target" or "Waiting for a fight"
end

return M
