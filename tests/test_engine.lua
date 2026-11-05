local engine = require('lib.engine')
local settings = require('lib.settings')
local fake = require('fake')

local function setup(given)
  local s = settings.repair(given)
  local e = engine.new()
  local io = fake.io()
  engine.start(e, io)
  return s, e, io
end

case("engine: manual full targets the mob on you, sticks, attacks, sends the pet, fires a row from each page", function()
  local s, e, io = setup({ abilities = { { name = "Kick", kind = "skill", target = "enemy" } },
    spells = { { name = "Flame Lick", target = "enemy" } } })
  local mob = fake.spawn({ id = 9, name = "a gnoll", distance = 12 })
  local pet = fake.spawn({ id = 50, npc = false })
  engine.tick(e, fake.world({ haters = { mob }, pet = pet }), s, io)
  check(io.has("/target id 9"), "targets it")
  io.clear()
  local w = fake.world({ haters = { mob }, target = mob, pet = pet, ready = { ["skill:Kick"] = true },
    spells = { ["Flame Lick"] = { gem = 2, ready = true, range = 100 } } })
  engine.tick(e, w, s, io)
  check(io.has("/stick id 9"), "sticks")
  check(io.has("/attack on"), "attacks")
  check(io.has("/pet attack"), "pet")
  eq(io.used[1], "skill:Kick", "the ability first")
  eq(e.fight_id, 9, "fighting it")
  io.clear()
  -- The ability page waits for its gap; the spell page fires.
  w.now = w.now + 100
  w.me.combat = true
  engine.tick(e, w, s, io)
  check(io.has("/cast 2"), "the spell")
  check(not io.has("/stick id 9") and not io.has("/pet attack"), "not again")
end)

case("engine: a heal on yourself mid-fight targets you, casts, and goes back to the mob with attack", function()
  local s, e, io = setup({ spells = { { name = "Heal", target = "self", phase = "always",
    conditions = { { who = "me", what = "hp", op = "<", value = 50 } } } } })
  local mob = fake.spawn({ id = 9 })
  local w = fake.world({ haters = { mob }, target = mob, me = { hp = 30, combat = true },
    spells = { Heal = { gem = 1, ready = true, range = 100 } } })
  engine.tick(e, w, s, io)
  local seq = table.concat(io.lines, "|")
  check(seq:find("/attack off|/target id 1|/cast 1|/target id 9|/attack on", 1, true) ~= nil, "sequence: " .. seq)
  -- A self-only spell needs no target change.
  io.clear()
  w.now = w.now + 5000
  w.spell = function() return { gem = 1, ready = true, range = 0, self_only = true } end
  engine.tick(e, w, s, io)
  check(io.has("/cast 1") and not io.has("/target id 1"), "self only: just cast")
end)

case("engine: manual partial fights only the NPC you target once you attack or it is on you, and never moves you", function()
  local s, e, io = setup({ style = "partial" })
  local mob = fake.spawn({ id = 9 })
  engine.tick(e, fake.world({ target = mob }), s, io)
  eq(#io.lines, 0, "not yet")
  eq(e.status, "Waiting for your target", "status")
  -- Another mob on me is not chosen in partial.
  engine.tick(e, fake.world({ target = mob, haters = { fake.spawn({ id = 11 }) } }), s, io)
  eq(e.fight_id, 0, "not the other")
  engine.tick(e, fake.world({ target = mob, me = { combat = true } }), s, io)
  eq(e.fight_id, 9, "fights once you attack")
  check(io.has("/face fast"), "faces")
  for _, l in ipairs(io.lines) do check(not l:find("^/stick") and not l:find("^/nav") and not l:find("^/target"), "no moving: " .. l) end
end)

case("engine: a fight ends, then it rests and stands up", function()
  local s, e, io = setup({})
  local mob = fake.spawn({ id = 9 })
  engine.tick(e, fake.world({ haters = { mob }, target = mob }), s, io)
  io.clear()
  engine.tick(e, fake.world({ me = { combat = true, mana = 20 } }), s, io)
  check(io.has("/stick off"), "unstick")
  check(io.has("/attack off"), "attack off")
  check(io.has("/sit"), "sits for mana")
  eq(e.status, "Resting", "resting")
  -- Not sitting yet (no answer): no /sit every tick, and one log line.
  io.clear()
  engine.tick(e, fake.world({ me = { mana = 20 }, now = 100100 }), s, io)
  eq(#io.lines, 0, "no /sit again at once")
  engine.tick(e, fake.world({ me = { mana = 20 }, now = 104000 }), s, io)
  check(io.has("/sit"), "/sit again later")
  local n = 0
  for _, l in ipairs(e.log) do if l == "Resting" then n = n + 1 end end
  eq(n, 1, "logged once")
  io.clear()
  engine.tick(e, fake.world({ me = { sitting = true, mana = 60 } }), s, io)
  eq(#io.lines, 0, "keeps sitting")
  engine.tick(e, fake.world({ me = { sitting = true, mana = 96 } }), s, io)
  check(io.has("/stand"), "stands when full")
end)

case("engine: pauses on death, low health, and a mode the server turned off", function()
  local s, e, io = setup({ rest = { stop_hp = 20 } })
  engine.tick(e, fake.world({ me = { hp = 10 } }), s, io)
  check(not e.running, "paused on health")
  check(io.said[1]:find("below 20%%") ~= nil, "said why")
  engine.start(e, io)
  engine.tick(e, fake.world({ me = { dead = true } }), s, io)
  check(not e.running, "paused on death")
  engine.start(e, io)
  engine.tick(e, fake.world({ allowed = { manual = false } }), s, io)
  check(not e.running, "paused: not allowed")
end)

case("engine: hunter roams to a mob over the mesh, engages it in reach, and gives up on one it cannot reach", function()
  local s, e, io = setup({ mode = "hunter" })
  local mob = fake.spawn({ id = 20, name = "a bat", x = 100, y = 0, distance = 100, level = 10 })
  local w = fake.world({ hunt = { mob }, spawns = { mob }, paths = { [20] = 120 } })
  engine.tick(e, w, s, io)
  eq(e.hunt and e.hunt.id, 20, "chose it")
  engine.tick(e, w, s, io)
  check(io.has("/nav id 20 distance=10"), "walks there")
  mob.distance = 20
  engine.tick(e, w, s, io)
  eq(e.engage_id, 20, "engages in reach")
  io.clear()
  engine.tick(e, w, s, io)
  check(io.has("/target id 20"), "targets it to fight")
  -- One it cannot reach is skipped; one it walks to for too long is given up.
  local s2, e2, io2 = setup({ mode = "hunter" })
  local far = fake.spawn({ id = 30, x = 50, y = 0, distance = 50 })
  local w2 = fake.world({ hunt = { far }, spawns = { far }, paths = { [30] = 5000 } })
  engine.tick(e2, w2, s2, io2)
  eq(e2.hunt, nil, "path too long")
  check(e2.skip[30] ~= nil, "skipped")
  local s3, e3, io3 = setup({ mode = "hunter", hunter = { give_up = 10 } })
  local slow = fake.spawn({ id = 40, x = 50, y = 0, distance = 50 })
  local w3 = fake.world({ hunt = { slow }, spawns = { slow }, paths = { [40] = 60 } })
  engine.tick(e3, w3, s3, io3)
  engine.tick(e3, w3, s3, io3)
  check(io3.has("/nav id 40 distance=10"), "walking")
  w3.now = w3.now + 11000
  engine.tick(e3, w3, s3, io3)
  eq(e3.hunt, nil, "given up")
  check(io3.has("/nav stop"), "walk stopped")
end)

case("engine: hunter roaming looks past the search radius when nothing is near", function()
  local s, e, io = setup({ mode = "hunter" })
  local far = fake.spawn({ id = 50, name = "a far wolf", x = 3000, y = 0, distance = 3000 })
  local w = fake.world({ hunt = { far }, spawns = { far }, paths = { [50] = 3500 } })
  engine.tick(e, w, s, io)
  eq(e.hunt and e.hunt.id, 50, "chose the far one, however long the walk")
  -- A camp keeps to its leash.
  local s2, e2, io2 = setup({ mode = "hunter", hunter = { style = "camp", camp = { x = 0, y = 0, z = 0, zone = "testzone" } } })
  local w2 = fake.world({ hunt = { far }, spawns = { far }, paths = { [50] = 3500 } })
  engine.tick(e2, w2, s2, io2)
  eq(e2.hunt, nil, "camp: not past the leash")
end)

case("engine: hunter waits for the mesh instead of skipping mobs for long, and says why it finds none", function()
  local s, e, io = setup({ mode = "hunter" })
  local mob = fake.spawn({ id = 60, x = 80, y = 0, distance = 80 })
  local w = fake.world({ hunt = { mob }, spawns = { mob }, paths = {},
    mesh = { loaded = true, complete = false, built = 3, total = 10 } })
  engine.tick(e, w, s, io)
  eq(e.hunt, nil, "no path yet")
  eq(e.status, "Waiting for the navigation mesh (3/10)", "status")
  w.now = w.now + 100
  engine.tick(e, w, s, io)
  eq(e.status, "Waiting for the navigation mesh (3/10)", "the reason stays between looks")
  check(e.last:find("NPCs 1", 1, true), "logged with counts: " .. e.last)
  check(e.skip[60] and e.skip[60] - w.now <= 20000, "tried again soon")
  -- Once the mesh has its path, it goes.
  w.now = w.now + 21000
  w.path_length = function() return 90 end
  engine.tick(e, w, s, io)
  eq(e.hunt and e.hunt.id, 60, "chose it once there is a path")
  -- All left out by the Targeting page.
  local s2, e2, io2 = setup({ mode = "hunter" })
  local grey = fake.spawn({ id = 70, x = 50, y = 0, distance = 50, con = "grey" })
  engine.tick(e2, fake.world({ hunt = { grey }, spawns = { grey }, paths = { [70] = 60 } }), s2, io2)
  eq(e2.status, "No mobs to hunt: the Targeting page leaves out all 1 NPCs", "filtered status")
  local s3, e3, io3 = setup({ mode = "hunter" })
  engine.tick(e3, fake.world({ hunt = {} }), s3, io3)
  eq(e3.status, "No NPCs in the zone", "empty zone")
end)

case("engine: hunter at a camp pulls with a spell and walks back", function()
  local s, e, io = setup({ mode = "hunter", hunter = { style = "camp", camp = { x = 0, y = 0, z = 0, zone = "testzone" },
    pull_kind = "spell", pull_name = "Pull" } })
  local mob = fake.spawn({ id = 20, x = 80, y = 0, distance = 80 })
  local w = fake.world({ hunt = { mob }, spawns = { mob }, paths = { [20] = 90 },
    spells = { Pull = { gem = 4, ready = true, range = 200 } } })
  engine.tick(e, w, s, io)
  eq(e.hunt and e.hunt.id, 20, "chose it")
  engine.tick(e, w, s, io)
  check(io.has("/target id 20"), "targets it from range")
  w.target, w.target_id = mob, 20
  engine.tick(e, w, s, io)
  check(io.has("/cast 4"), "pulls")
  check(io.has("/nav loc 0.0 0.0 0.0"), "back to camp")
  check(e.hunt.pulled, "pulled")
  -- A camp in another zone does not count.
  local s2, e2, io2 = setup({ mode = "hunter", hunter = { style = "camp", camp = { x = 500, y = 0, z = 0, zone = "elsewhere" } } })
  engine.tick(e2, fake.world({}), s2, io2)
  check(not io2.has("/nav loc 0.0 500.0 0.0"), "no walk to another zone's camp")
end)

case("engine: assist asks the assist's target, joins it once low enough, follows between fights", function()
  local s, e, io = setup({ mode = "assist", assist = { engage_pct = 90, follow_distance = 20 } })
  local ma = fake.spawn({ id = 2, name = "Tank", npc = false, pc = true, distance = 60 })
  engine.tick(e, fake.world({ assist = ma }), s, io)
  check(io.has("/assist Tank"), "assists")
  check(io.has("/nav id 2 distance=20"), "follows")
  local mob = fake.spawn({ id = 9, hp = 95 })
  io.clear()
  engine.tick(e, fake.world({ assist = ma, target = mob, haters = { fake.spawn({ id = 12 }) } }), s, io)
  eq(e.fight_id, 0, "waits at 95%, and ignores what is on me")
  mob.hp = 85
  engine.tick(e, fake.world({ assist = ma, target = mob }), s, io)
  eq(e.fight_id, 9, "joins at 85%")
  check(io.has("/stick id 9"), "sticks")
  local s2, e2, io2 = setup({ mode = "assist" })
  engine.tick(e2, fake.world({}), s2, io2)
  eq(e2.status, "No assist", "no assist")
end)

case("engine: Full and Hunter fight only the extended target's mobs and Hunter's own pick, never a target merely selected", function()
  for _, mode in ipairs({ "manual", "hunter" }) do
    local s, e, io = setup({ mode = mode })
    engine.start(e, io)
    -- My animated corpse targeted, auto attack on, nothing on me.
    local corpse = fake.spawn({ id = 30, name = "Gennro`s animated corpse", owned = true })
    engine.tick(e, fake.world({ target = corpse, me = { combat = true }, pet = fake.spawn({ id = 2, npc = false }) }), s, io)
    eq(e.fight_id, 0, mode .. ": not fought")
    check(not io.has("/pet attack"), mode .. ": the pet is not sent")
    -- An ordinary NPC targeted with attack on but not on me: not Auto Combat's fight either.
    io.clear()
    local bystander = fake.spawn({ id = 31 })
    engine.tick(e, fake.world({ target = bystander, me = { combat = true } }), s, io)
    eq(e.fight_id, 0, mode .. ": a bystander is not fought")
  end
  -- Partial: the player's pick, but never someone's pet.
  local s, e, io = setup({ style = "partial" })
  engine.start(e, io)
  local corpse = fake.spawn({ id = 30, owned = true })
  engine.tick(e, fake.world({ target = corpse, me = { combat = true } }), s, io)
  eq(e.fight_id, 0, "partial: not a pet")
end)

case("engine: pause calls the pet back and turns off the attack Auto Combat started", function()
  local s, e, io = setup({})
  engine.start(e, io)
  local mob = fake.spawn({ id = 9, distance = 5 })
  local pet = fake.spawn({ id = 2, npc = false })
  engine.tick(e, fake.world({ haters = { mob }, target = mob, pet = pet }), s, io)
  check(io.has("/attack on"), "attacking")
  check(io.has("/pet attack"), "pet sent")
  io.clear()
  engine.pause(e, io)
  check(io.has("/pet back off"), "pet called back")
  check(io.has("/attack off"), "attack off")
  -- Paused with nothing started: nothing said to the pet or the attack.
  local s2, e2, io2 = setup({})
  engine.start(e2, io2)
  engine.pause(e2, io2)
  check(not io2.has("/pet back off") and not io2.has("/attack off"), "nothing to undo")
end)

case("engine: burn mode ends once the extended target list is clear after a fight", function()
  local e = engine.new()
  local io = fake.io()
  engine.set_burn(e, true, io)
  check(e.burn, "on")
  check(not engine.burn_tick(e, 0, io), "on before the pull: it waits for a fight")
  check(e.burn, "still on")
  check(not engine.burn_tick(e, 2, io), "mobs on me")
  check(not engine.burn_tick(e, 1, io), "one left")
  check(engine.burn_tick(e, 0, io), "all gone: over")
  check(not e.burn, "off")
  check(not engine.burn_tick(e, 0, io), "stays off")
  -- Turned off by hand mid-fight; on again forgets the last fight.
  engine.set_burn(e, true, io)
  engine.burn_tick(e, 3, io)
  engine.set_burn(e, false, io)
  check(not e.burn, "off by hand")
  engine.set_burn(e, true, io)
  check(not engine.burn_tick(e, 0, io), "a fresh burn waits for its own fight")
  -- Pausing Auto Combat leaves it alone.
  engine.start(e, io)
  engine.pause(e, io)
  check(e.burn, "pause keeps burn mode")
end)

case("engine: a forced mob is fought first in every mode until it dies; an ignored one is left alone", function()
  local a = fake.spawn({ id = 9, name = "a gnoll", hp = 30 })
  local b = fake.spawn({ id = 10, name = "a gnoll pup", hp = 90 })
  local c = fake.spawn({ id = 11, name = "a gnoll scout", hp = 60 })
  local s, e, io = setup({ targeting = { priority = "lowest_hp" } })
  engine.tick(e, fake.world({ haters = { a, b, c } }), s, io)
  check(io.has("/target id 9"), "lowest health first")
  -- Force the healthiest one: it is fought now.
  io.clear()
  engine.force(e, 10, "a gnoll pup", io)
  engine.tick(e, fake.world({ haters = { a, b, c }, target = a }), s, io)
  check(io.has("/target id 10"), "the forced one")
  -- Ignore it instead: the force goes; ignore the next best too: the third.
  io.clear()
  engine.ignore(e, 10, "a gnoll pup", io)
  eq(e.force_id, 0, "ignoring the forced one unforces it")
  engine.ignore(e, 9, "a gnoll", io)
  engine.tick(e, fake.world({ haters = { a, b, c }, target = b }), s, io)
  check(io.has("/target id 11"), "the one not ignored")
  -- Forcing an ignored mob takes the ignore off.
  engine.force(e, 9, "a gnoll", io)
  check(not e.ignore[9], "unignored by force")
  engine.force(e, 9, "a gnoll", io)
  eq(e.force_id, 0, "force again: unforced")

  -- Assist and Partial: the force wins over the assist's or the player's pick.
  for _, mode in ipairs({ { mode = "assist" }, { mode = "manual", style = "partial" } }) do
    local s2, e2, io2 = setup(mode)
    engine.force(e2, 11, "a gnoll scout", io2)
    engine.tick(e2, fake.world({ haters = { a, b, c }, target = a, assist = fake.spawn({ id = 70, pc = true, npc = false }),
      me = { combat = true } }), s2, io2)
    check(io2.has("/target id 11"), mode.mode .. ": the forced one")
  end
  -- Partial: an ignored target is not fought even when the player attacks it.
  local s3, e3, io3 = setup({ mode = "manual", style = "partial" })
  engine.ignore(e3, 9, "a gnoll", io3)
  engine.tick(e3, fake.world({ haters = { a }, target = a, me = { combat = true } }), s3, io3)
  eq(e3.fight_id, 0, "partial leaves the ignored target alone")
end)

case("engine: a force ends when its mob dies; ignores end when nothing else is on the list", function()
  local e = engine.new()
  local io = fake.io()
  local living = { [9] = true, [10] = true, [11] = true }
  local function alive(id) return living[id] == true end
  engine.force(e, 9, "a gnoll", io)
  engine.ignore(e, 10, "a pup", io)
  engine.update_marks(e, { 9, 10, 11 }, alive, io)
  eq(e.force_id, 9, "kept while it lives")
  living[9] = nil
  engine.update_marks(e, { 10, 11 }, alive, io)
  eq(e.force_id, 0, "dead: the force is over")
  check(e.ignore[10], "the ignore stays while 11 is on the list")
  engine.update_marks(e, { 10 }, alive, io)
  check(not e.ignore[10], "only the ignored one left: ignores cleared")
  -- An ignored mob that dies is forgotten; one off the list is kept while others are on it.
  engine.ignore(e, 10, "a pup", io)
  engine.ignore(e, 11, "a scout", io)
  living[11] = nil
  engine.update_marks(e, { 10, 12 }, function(id) return id == 10 or id == 12 end, io)
  check(e.ignore[10] and not e.ignore[11], "the dead one forgotten")
  engine.update_marks(e, {}, function() return true end, io)
  check(not e.ignore[10], "an empty list clears them")
end)

case("engine: an Items row clicks the item where it is (/useitem slot and bag place), on the fight target", function()
  local s, e, io = setup({ items = { { name = "Wand of Testing", kind = "item", target = "enemy" } } })
  local mob = fake.spawn({ id = 9, distance = 40 })
  local w = fake.world({ haters = { mob }, target = mob, me = { combat = true },
    items = { ["Wand of Testing"] = { slot = 24, sub = 3, cast_time = 0, range = 200 } } })
  engine.tick(e, w, s, io)
  check(io.has("/useitem 24 3"), "clicked in its bag: " .. table.concat(io.lines, "|"))
  check(not io.has("/target id 1"), "no target change for the fight target")
  eq(e.last, "Clicked Wand of Testing on mob9", "noted")
  -- Not again within the item gap, though the server has not started its recast yet.
  io.clear()
  w.now = w.now + 1000
  engine.tick(e, w, s, io)
  check(not io.has("/useitem 24 3"), "not clicked again at once")
  w.now = w.now + 3000
  engine.tick(e, w, s, io)
  check(io.has("/useitem 24 3"), "clicked again after the gap")
end)

case("engine: a worn click item on yourself mid-fight targets you and goes back; one on its recast waits", function()
  local s, e, io = setup({ items = { { name = "Mask of Mending", kind = "item", target = "self", phase = "always",
    conditions = { { who = "me", what = "hp", op = "<", value = 50 } } } } })
  local mob = fake.spawn({ id = 9 })
  local items = { ["Mask of Mending"] = { slot = 3, cast_time = 1500, range = 0, ready_in = 40 } }
  local w = fake.world({ haters = { mob }, target = mob, me = { hp = 30, combat = true }, items = items })
  engine.tick(e, w, s, io)
  check(not io.has("/useitem 3"), "on its recast: waits")
  items["Mask of Mending"].ready_in = 0
  w.now = w.now + 5000
  engine.tick(e, w, s, io)
  local seq = table.concat(io.lines, "|")
  check(seq:find("/attack off|/target id 1|/useitem 3|/target id 9|/attack on", 1, true) ~= nil, "sequence: " .. seq)
end)
