local settings = require('lib.settings')
local engine = require('lib.engine')
local fake = require('fake')

-- MQ values are callable, with callable members. Read the real adapter against a small client-shaped fixture.
local function value(fields, exists)
  return setmetatable({}, {
    __call = function() if exists ~= false then return true end end,
    __index = function(_, name)
      local field = fields[name]
      if type(field) == "table" then return field end
      return function() return field end
    end,
  })
end

local function client(spawns, xtargets, target_id)
  local state = { spawns = spawns, xtargets = xtargets or {}, target_id = target_id or 0, now = 100000 }
  local absent = value({}, false)
  local function spawn(s)
    return value({ ID = s.id, Name = s.name or ("mob" .. s.id), CleanName = s.name or ("mob" .. s.id),
      Type = s.kind or "NPC", PctHPs = s.hp, Dead = s.dead == true, Distance = s.distance or 10,
      Distance3D = s.distance or 10, Level = 10, ConColor = "WHITE", X = s.x or 0, Y = s.y or 0, Z = s.z or 0,
      Surname = s.surname, BodyType = s.body or 1, Targetable = s.targetable ~= false,
      MaxRangeTo = 14, LineOfSight = true, BuffsPopulated = false })
  end
  local mq = { TLO = {}, gettime = function() return state.now end }
  mq.TLO.Me = value({ ID = 1, Name = "Tester", CleanName = "Tester", PctHPs = 100, PctMana = 100,
    PctEndurance = 100, CurrentMana = 1000, Combat = true, CombatState = "COMBAT", Pet = absent })
  mq.TLO.EverQuest = value({ GameState = "INGAME" })
  mq.TLO.Group = value({ Members = 0, MainAssist = absent })
  mq.TLO.Navigation = value({ Active = false, MeshLoaded = true, MeshComplete = true, TilesBuilt = 1, TilesTotal = 1 })
  mq.TLO.Navigation.PathLength = function() return function() return 100 end end
  mq.TLO.Zone = value({ ShortName = "testzone" })
  mq.TLO.Target = { ID = function() return state.target_id end }
  mq.TLO.Spawn = function(query)
    local id = tonumber(query:match("^id (%d+)$"))
    local name = query:match("^pc =(.+)$")
    for _, s in ipairs(state.spawns) do
      if s.id == id or (name and s.kind == "PC" and s.name == name) then return spawn(s) end
    end
    return absent
  end
  mq.getFilteredSpawns = function(filter)
    local out = {}
    for _, s in ipairs(state.spawns) do
      local sp = spawn(s)
      if filter(sp) then out[#out + 1] = sp end
    end
    return out
  end
  local hs = {
    player = function() return { xtarget_slots = #state.xtargets } end,
    xtarget = function(i) return state.xtargets[i] end,
  }
  local saved_mq, saved_hs, saved_world = package.loaded.mq, package.loaded.hailstone, package.loaded['lib.world']
  package.loaded.mq, package.loaded.hailstone, package.loaded['lib.world'] = mq, hs, nil
  local ok, world = pcall(require, 'lib.world')
  package.loaded.mq, package.loaded.hailstone, package.loaded['lib.world'] = saved_mq, saved_hs, saved_world
  if not ok then error(world) end
  return state, world
end

local function ids(list)
  local out = {}
  for _, s in ipairs(list) do out[s.id] = s end
  return out
end

case("world: zero percent stays on the hater list until death or despawn", function()
  local state, world = client({
    { id = 10, hp = 0 },
    { id = 11, hp = 80, dead = true, kind = "Corpse" },
    { id = 12, hp = 100, kind = "PC" },
  }, {
    { type = 1, spawn_id = 10 }, { type = 1, spawn_id = 11 }, { type = 1, spawn_id = 12 },
    { type = 1, spawn_id = 99 }, { type = 2, spawn_id = 10 }, { type = 1, spawn_id = 0 },
  }, 10)
  local w = world.read(settings.defaults())
  eq(#w.haters, 1, "only the living NPC is a hater")
  eq(w.haters[1] and w.haters[1].id, 10, "the zero-percent NPC stays")
  eq(w.me.haters, 1, "combat count keeps it")
  eq(w.target.hp, 0, "health percentage remains zero")
  eq(w.target.dead, false, "zero percentage is not death")
  eq(w.spawn(11).dead, true, "death state copied independently of HP")
  eq(w.spawn(99), nil, "despawn is absent")
  check(world.alive(10), "zero-percent NPC remains alive for marks")
  check(not world.alive(11), "corpse with stale positive HP is not alive")
  check(not world.alive(99), "missing spawn is not alive")
  check(not world.alive(12), "player is not a live combat NPC")
  local e, io = engine.new(), fake.io()
  engine.force(e, 10, "mob10", io)
  engine.update_marks(e, { 10 }, world.alive, io)
  eq(e.force_id, 10, "force stays until actual death")
  state.spawns[1].dead, state.spawns[1].kind = true, "Corpse"
  eq(#world.read(settings.defaults()).haters, 0, "corpse leaves the hater list")
  engine.update_marks(e, { 10 }, world.alive, io)
  eq(e.force_id, 0, "corpse clears force even if extended target slot remains")
end)

case("world: hunter and nearby NPC lists retain zero percent with their other filters", function()
  local _, world = client({
    { id = 10, hp = 0 },
    { id = 11, hp = 0, distance = 500, x = 500 },
    { id = 12, hp = 80, dead = true, kind = "Corpse" },
    { id = 13, hp = 80, dead = true },
    { id = 14, hp = 100, kind = "Pet" },
    { id = 15, hp = 100, surname = "Tester`s Pet" },
    { id = 16, hp = 100, targetable = false },
    { id = 17, hp = 100, body = 11 },
    { id = 18, hp = 100, kind = "PC", name = "Other", x = 500 },
  })
  local w = world.read(settings.defaults())
  local hunt = w.hunt_spawns()
  eq(#hunt, 2, "only living targetable unowned NPCs")
  local by_id = ids(hunt)
  check(by_id[10] ~= nil and by_id[11] ~= nil, "both zero-percent NPCs remain")
  eq(by_id[10] and by_id[10].hp, 0, "hunter retains actual HP")
  check(by_id[11] and by_id[11].players_near, "nearby player marker remains")
  check(by_id[10] and not by_id[10].players_near, "distant player does not mark it")
  local nearby = w.npcs()
  eq(#nearby, 1, "nearby list retains the 400-unit bound and other filters")
  eq(nearby[1] and nearby[1].id, 10, "zero-percent NPC counts nearby")
  eq(nearby[1] and nearby[1].hp, 0, "count snapshot keeps actual HP")
end)

case("world and engine: hunter finishes a living zero-percent target before choosing another", function()
  for _, ending in ipairs({ "corpse", "despawn" }) do
    local mob = { id = 10, hp = 1, name = "a gnoll" }
    local next_mob = { id = 11, hp = 100, name = "another gnoll", x = 100, distance = 100 }
    local state, world = client({ mob, next_mob }, { { type = 1, spawn_id = 10 } }, 10)
    local s, e, io = settings.repair({ mode = "hunter" }), engine.new(), fake.io()
    engine.start(e, io)
    engine.tick(e, world.read(s), s, io)
    eq(e.fight_id, 10, ending .. ": starts fighting")
    mob.hp, state.now = 0, state.now + 1000
    io.clear()
    engine.tick(e, world.read(s), s, io)
    eq(e.fight_id, 10, ending .. ": keeps fighting at zero percent")
    check(not io.has('/attack off') and not io.has('/stick off'), ending .. ": keeps combat active")
    eq(e.hunt, nil, ending .. ": does not select the next mob early")
    if ending == "corpse" then mob.kind, mob.dead = "Corpse", true else state.spawns = { next_mob } end
    state.now = state.now + 1000
    io.clear()
    engine.tick(e, world.read(s), s, io)
    eq(e.fight_id, 0, ending .. ": fight ends on actual death or removal")
    check(io.has('/attack off') and io.has('/stick off'), ending .. ": stops the completed fight")
    eq(e.hunt and e.hunt.id, 11, ending .. ": may choose the next mob now")
  end
end)
