local targeting = require('lib.targeting')
local settings = require('lib.settings')
local fake = require('fake')

case("targeting: the current hater is kept; else the best by priority, mezzed ones last", function()
  local a = fake.spawn({ id = 1, hp = 80, distance = 5 })
  local b = fake.spawn({ id = 2, hp = 20, distance = 30 })
  local c = fake.spawn({ id = 3, hp = 10, distance = 40, mezzed = true })
  eq(targeting.choose_hater({ a, b, c }, 1, "lowest_hp").id, 1, "keeps the current")
  eq(targeting.choose_hater({ a, b, c }, 0, "lowest_hp").id, 2, "lowest awake")
  eq(targeting.choose_hater({ a, b, c }, 3, "lowest_hp").id, 2, "leaves the mezzed current")
  eq(targeting.choose_hater({ a, b, c }, 0, "closest").id, 1, "closest")
  eq(targeting.choose_hater({ a, b, c }, 0, "highest_hp").id, 1, "highest")
  eq(targeting.choose_hater({ c }, 0, "lowest_hp").id, 3, "only mezzed left")
  eq(targeting.choose_hater({}, 0, "lowest_hp"), nil, "none")
end)

case("targeting: the hunter's filters", function()
  local t = settings.repair({ targeting = { ignore = { "guard" }, min_level = 5, max_level = 20, cons = { red = false } } }).targeting
  check(targeting.allowed(fake.spawn({ id = 1, level = 10 }), t), "plain")
  check(not targeting.allowed(fake.spawn({ id = 1, level = 3 }), t), "too low")
  check(not targeting.allowed(fake.spawn({ id = 1, level = 25 }), t), "too high")
  check(not targeting.allowed(fake.spawn({ id = 1, level = 10, con = "red" }), t), "red")
  check(not targeting.allowed(fake.spawn({ id = 1, level = 10, name = "Guard Fippy" }), t), "ignored name")
  t.named = false
  check(not targeting.allowed(fake.spawn({ id = 1, level = 10, named = true }), t), "named off")
  local h = settings.defaults().hunter
  local list = targeting.hunt_candidates({
    fake.spawn({ id = 1, level = 10, x = 100, y = 0 }),
    fake.spawn({ id = 2, level = 10, x = 50, y = 0 }),
    fake.spawn({ id = 3, level = 10, x = 10, y = 0, players_near = true }),
    fake.spawn({ id = 4, level = 10, x = 5000, y = 0 }),
    fake.spawn({ id = 5, level = 10, x = 20, y = 0, z = 500 }),
    fake.spawn({ id = 6, level = 10, x = 30, y = 0 }),
  }, t, h, { 0, 0, 0 }, { [6] = 1 }, false)
  eq(#list, 2, "near players, far, high and skipped left out")
  eq(list[1].id, 2, "closest first")
  eq(list[2].id, 1, "then the next")
end)

case("targeting: someone's pet (a swarm pet too) is never chosen", function()
  local settings = require('lib.settings')
  local t = settings.defaults().targeting
  local corpse = { id = 5, name = "an animated corpse", level = 10, con = "white", owned = true }
  check(not targeting.allowed(corpse, t), "owned: left out")
  corpse.owned = false
  check(targeting.allowed(corpse, t), "else allowed")
  local list = targeting.hunt_candidates({ { id = 5, name = "x", hp = 100, x = 10, y = 0, z = 0, level = 10, con = "white",
    npc = true, owned = true } }, t, settings.defaults().hunter, { 0, 0, 0 }, {}, false)
  eq(#list, 0, "not a hunt candidate")
end)

case("targeting: hunter includes a living NPC at zero percent, but leaves out corpses", function()
  local s = settings.defaults()
  local living = fake.spawn({ id = 9, hp = 0, x = 10 })
  local corpse = fake.spawn({ id = 10, hp = 100, x = 5, npc = false, dead = true })
  local list = targeting.hunt_candidates({ corpse, living }, s.targeting, s.hunter, { 0, 0, 0 }, {}, false)
  eq(#list, 1, "only the living NPC")
  eq(list[1] and list[1].id, 9, "zero percent remains a candidate")
  eq(living.hp, 0, "health is not clamped")
end)
