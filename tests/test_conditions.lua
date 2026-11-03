local conditions = require('lib.conditions')
local fake = require('fake')

case("conditions: numbers, booleans, buffs, missing subjects", function()
  local t = fake.spawn({ id = 5, hp = 40, named = true, buffs = { ["Tashan's Lingering Cry"] = "mine", Slow = "other" } })
  local w = fake.world({ target = t, me = { mana = 30 }, my_buffs = { ["Shield of Words"] = true } })
  check(conditions.holds({ who = "target", what = "hp", op = "<", value = 50 }, w), "hp < 50")
  check(not conditions.holds({ who = "target", what = "hp", op = ">=", value = 50 }, w), "hp >= 50")
  check(conditions.holds({ who = "target", what = "named", op = "is" }, w), "named")
  check(not conditions.holds({ who = "target", what = "named", op = "is not" }, w), "not named")
  check(conditions.holds({ who = "me", what = "mana", op = "<=", value = 30 }, w), "mana")
  check(conditions.holds({ who = "me", what = "buff", op = "has", value = "Shield of Words" }, w), "my buff")
  check(conditions.holds({ who = "me", what = "buff", op = "lacks", value = "Spirit of Wolf" }, w), "lacks")
  check(conditions.holds({ who = "target", what = "mybuff", op = "has", value = "Tashan's Lingering Cry" }, w), "my debuff")
  check(conditions.holds({ who = "target", what = "mybuff", op = "lacks", value = "Slow" }, w), "someone else's")
  check(conditions.holds({ who = "target", what = "buff", op = "has", value = "Slow" }, w), "anyone's")
  -- No pet: its numbers never hold, "exists is not" does.
  check(not conditions.holds({ who = "pet", what = "hp", op = "<", value = 100 }, w), "no pet")
  check(conditions.holds({ who = "pet", what = "exists", op = "is not" }, w), "pet missing")
  check(not conditions.holds({ who = "pet", what = "exists", op = "is" }, w), "pet exists")
  -- Unknown buffs (the server did not send them): neither has nor lacks holds.
  local blind = fake.world({ target = fake.spawn({ id = 6 }) })
  check(not conditions.holds({ who = "target", what = "buff", op = "lacks", value = "Slow" }, blind), "unknown lacks")
  check(not conditions.holds({ who = "target", what = "mezzed", op = "is not" }, blind), "unknown mez")
  -- A bad condition never holds.
  check(not conditions.holds({ who = "target", what = "hp", op = "is", value = 1 }, w), "wrong op")
  check(not conditions.holds({ who = "nobody", what = "hp", op = "<", value = 1 }, w), "unknown subject")
  check(conditions.all({}, w), "no conditions")
  eq(conditions.describe({ who = "target", what = "hp", op = "<", value = 50 }), "Target Health % < 50", "described")
end)

case("conditions: mobs counted within a radius of me or the target", function()
  -- Three mobs on me, two NPCs about that are not; the target at (100, 0).
  local a = fake.spawn({ id = 1, x = 100, y = 0 })
  local b = fake.spawn({ id = 2, x = 110, y = 0 })
  local c = fake.spawn({ id = 3, x = 10, y = 0 })
  local idle = fake.spawn({ id = 4, x = 105, y = 5 })
  local far = fake.spawn({ id = 5, x = 100, y = 0, z = 80 }) -- above the target: out of reach in three dimensions
  local w = fake.world({ haters = { a, b, c }, target = a, npcs = { a, b, c, idle, far } })
  local function n(who, what, op, value, radius)
    return conditions.holds({ who = who, what = what, op = op, value = value, radius = radius }, w)
  end
  check(n("target", "near_haters", ">=", 2, 20), "the target and one more on me near it")
  check(not n("target", "near_haters", ">=", 3, 20), "the third is far from it")
  check(n("target", "near_npcs", "=", 3, 20), "any NPCs near it: two on me and the idle one")
  check(n("target", "near_idle", "=", 1, 20), "one near it is not on me")
  check(not n("target", "near_idle", "<=", 0, 20), "so an AE there would pull it")
  check(n("me", "near_haters", "=", 1, 30), "one on me near me")
  check(n("me", "near_idle", "<=", 0, 30), "nothing else near me")
  check(n("me", "near_haters", ">=", 3, 120), "all three within 120")
  check(n("me", "near_npcs", "=", 4, 120), "the one above the target is not")
  -- A dead mob does not count; the radius falls back to the catalog's.
  a.hp = 0
  check(n("target", "near_haters", "=", 1, 20), "the dead target left out")
  check(conditions.holds({ who = "me", what = "near_haters", op = "=", value = 1 }, w), "default radius 30: the one at 10")
  -- No target, or no NPC list: it never holds.
  local blind = fake.world({ haters = { c } })
  check(not conditions.holds({ who = "target", what = "near_haters", op = "<=", value = 5, radius = 30 }, blind), "no target")
  check(not conditions.holds({ who = "me", what = "near_idle", op = "<=", value = 0, radius = 30 }, blind), "no NPC list")
  eq(conditions.describe({ who = "target", what = "near_idle", op = "<=", value = 0, radius = 25 }),
    "NPCs not on me within 25 of the target <= 0", "described")
  eq(conditions.describe({ who = "me", what = "near_haters", op = ">=", value = 3, radius = 30 }),
    "Mobs on me within 30 of me >= 3", "described, me")
end)
