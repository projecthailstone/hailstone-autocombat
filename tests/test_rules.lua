local rules = require('lib.rules')
local settings = require('lib.settings')
local fake = require('fake')

local function rows(list) return settings.repair({ spells = list }).spells end

case("rules: the first ready row whose conditions hold fires; blockers say why the others do not", function()
  local r = rows({
    { name = "Heal", target = "self", phase = "always", conditions = { { who = "me", what = "hp", op = "<", value = 50 } } },
    { name = "Nuke", target = "enemy", phase = "combat" },
    { name = "Buff", target = "self", phase = "rest" },
  })
  local spells = { Heal = { gem = 1, ready = true, range = 100 }, Nuke = { gem = 2, ready = true, range = 200 },
    Buff = { gem = 3, ready = true, range = 0 } }
  local w = fake.world({ target = fake.spawn({ id = 9, distance = 50 }), spells = spells, haters = { fake.spawn({ id = 9 }) } })
  w.fighting = true
  local m = rules.new_memory()
  local i, row, to = rules.next("spells", r, w, m)
  eq(i, 2, "the nuke: health is fine")
  eq(to.id, 9, "on the target")
  eq(rules.blocker("spells", 1, r[1], w, m), "conditions", "heal waits")
  eq(rules.blocker("spells", 3, r[3], w, m), "phase", "buff waits for rest")
  w.me.hp = 30
  i = rules.next("spells", r, w, m)
  eq(i, 1, "the heal first now")
  -- Out of range, out of sight, moving with a cast time, casting.
  w.me.hp = 100
  w.target.distance = 250
  eq(rules.blocker("spells", 2, r[2], w, m), "out of range", "range")
  w.target.distance = 50
  w.target.los = false
  eq(rules.blocker("spells", 2, r[2], w, m), "not in sight", "sight")
  w.target.los = true
  spells.Nuke.cast_time = 2000
  w.me.moving = true
  eq(rules.blocker("spells", 2, r[2], w, m), "moving", "moving")
  w.me.moving = false
  w.me.casting = true
  eq(rules.blocker("spells", 2, r[2], w, m), "casting", "casting")
  w.me.casting = false
  spells.Nuke.ready = false
  eq(rules.blocker("spells", 2, r[2], w, m), "not ready", "not ready")
  spells.Nuke.gem = nil
  eq(rules.blocker("spells", 2, r[2], w, m), "not memorized", "not memorized")
end)

case("rules: recast, per target", function()
  local r = rows({ { name = "Dot", target = "enemy", recast = 30, per_target = true } })
  local w = fake.world({ target = fake.spawn({ id = 9 }), spells = { Dot = { gem = 1, ready = true, range = 200 } } })
  w.fighting = true
  local m = rules.new_memory()
  eq(rules.next("spells", r, w, m), 1, "fires")
  rules.fired("spells", 1, r[1], m, w.now, 9)
  eq(rules.blocker("spells", 1, r[1], w, m), "recast", "not again on 9")
  w.target = fake.spawn({ id = 10 })
  eq(rules.blocker("spells", 1, r[1], w, m), "", "a new target is fair game")
  w.target = fake.spawn({ id = 9 })
  w.now = w.now + 30000
  eq(rules.blocker("spells", 1, r[1], w, m), "", "after 30 s")
  rules.forget_targets(m, {})
  local any = false
  for _, by in pairs(m.per_target) do for id in pairs(by) do any = any or id ~= 0 end end
  check(not any, "dead mobs forgotten")
end)

case("rules: a row for someone missing does not fire; disabled rows never", function()
  local r = rows({ { name = "Pet Heal", target = "pet", phase = "always" }, { name = "Off", enabled = false, phase = "always", target = "self" } })
  local w = fake.world({ spells = { ["Pet Heal"] = { gem = 1, ready = true }, Off = { gem = 2, ready = true } } })
  local m = rules.new_memory()
  eq(rules.blocker("spells", 1, r[1], w, m), "no pet", "no pet")
  eq(rules.blocker("spells", 2, r[2], w, m), "off", "off")
  eq(rules.next("spells", r, w, m), nil, "nothing")
end)

case("rules: a burn row fires only in burn mode; \"burn mode on\" is a condition too", function()
  local r = rows({
    { name = "Big Nuke", target = "enemy", phase = "combat", burn = true },
    { name = "Cheap Nuke", target = "enemy", phase = "combat",
      conditions = { { who = "me", what = "burning", op = "is not" } } },
  })
  eq(r[1].burn, true, "the flag is kept")
  eq(r[2].burn, false, "and defaults off")
  local spells = { ["Big Nuke"] = { gem = 1, ready = true, range = 200 }, ["Cheap Nuke"] = { gem = 2, ready = true, range = 200 } }
  local w = fake.world({ target = fake.spawn({ id = 9 }), spells = spells, haters = { fake.spawn({ id = 9 }) },
    me = { burning = false } })
  w.fighting = true
  local m = rules.new_memory()
  eq(rules.blocker("spells", 1, r[1], w, m), "burn only", "waits for burn mode")
  eq(rules.next("spells", r, w, m), 2, "the cheap one meanwhile")
  w.burn, w.me.burning = true, true
  eq(rules.next("spells", r, w, m), 1, "the burn row first in burn mode")
  eq(rules.blocker("spells", 2, r[2], w, m), "conditions", "the cheap one holds off while burning")
end)
