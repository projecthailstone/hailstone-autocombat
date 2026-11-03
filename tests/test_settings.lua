local settings = require('lib.settings')

case("settings: defaults survive a repair unchanged; nonsense takes the default", function()
  local d = settings.repair(nil)
  eq(d.mode, "manual", "mode")
  eq(d.style, "full", "style")
  eq(d.targeting.cons.green, true, "green allowed")
  eq(d.targeting.cons.red, false, "red not")
  eq(#d.spells, 0, "no spells")
  local r = settings.repair({ mode = "berserk", style = 3, general = { attack = "yes", action_gap = 99 },
    rest = { sit_hp = 150, stop_hp = -5 }, targeting = { ignore = { "a_rat", "", 5 } } })
  eq(r.mode, "manual", "bad mode")
  eq(r.style, "full", "bad style")
  eq(r.general.attack, true, "bad bool")
  eq(r.general.action_gap, 5, "gap clamped")
  eq(r.rest.sit_hp, 100, "pct clamped")
  eq(r.rest.stop_hp, 0, "pct floor")
  eq(#r.targeting.ignore, 1, "only real names kept")
end)

case("settings: rows and conditions are repaired; ones that make no sense are dropped", function()
  local r = settings.repair({ spells = {
    { name = "Flame Lick", kind = "spell", target = "enemy", phase = "combat",
      conditions = { { who = "target", what = "hp", op = "<", value = "80" },
        { who = "target", what = "colour", op = "<", value = 1 },
        { who = "me", what = "buff", op = "lacks", value = "Shield" },
        { who = "target", what = "named", op = ">", value = 1 } } },
    { name = "", kind = "spell" },
    { kind = "spell" },
    { name = "Minor Healing", kind = "potion", target = "nobody", phase = "never", recast = -3 },
  } })
  eq(#r.spells, 2, "two rows kept")
  local a = r.spells[1]
  eq(#a.conditions, 2, "two good conditions")
  eq(a.conditions[1].value, 80, "value made a number")
  eq(a.conditions[2].value, "Shield", "buff value text")
  local b = r.spells[2]
  eq(b.kind, "spell", "kind default")
  eq(b.target, "enemy", "target default")
  eq(b.phase, "combat", "phase default")
  eq(b.recast, 0, "recast floor")
  eq(b.enabled, true, "enabled default")
end)

case("settings: the camp needs all its parts", function()
  eq(settings.repair({ hunter = { camp = { x = 1, y = 2, z = 3, zone = "qeynos" } } }).hunter.camp.zone, "qeynos", "kept")
  eq(settings.repair({ hunter = { camp = { x = 1, y = 2 } } }).hunter.camp, nil, "dropped")
end)

case("settings: set by path changes plain values only", function()
  local s = settings.repair(nil)
  local ok
  s, ok = settings.set(s, "targeting.radius", 350)
  check(ok, "radius set")
  eq(s.targeting.radius, 350, "radius")
  s, ok = settings.set(s, "targeting.cons.red", true)
  check(ok and s.targeting.cons.red == true, "con set")
  s, ok = settings.set(s, "mode", "hunter")
  check(ok and s.mode == "hunter", "mode set")
  s, ok = settings.set(s, "mode", "nonsense")
  eq(s.mode, "manual", "a bad mode is repaired to the default")
  s, ok = settings.set(s, "spells", {})
  check(not ok, "a list is not a plain value")
  s, ok = settings.set(s, "nothing.here", 1)
  check(not ok, "unknown path")
  s, ok = settings.set(s, "rest.stand_hp", 140)
  eq(s.rest.stand_hp, 100, "clamped through repair")
end)

case("settings: Import spell bar makes a row from what each spell is", function()
  local nuke = settings.row_for_spell({ name = "Flame Lick", beneficial = false, target_type = "Single", duration = 0 })
  eq(nuke.target, "enemy", "nuke on the fight target")
  eq(nuke.phase, "combat", "in combat")
  eq(#nuke.conditions, 0, "no conditions")
  local buff = settings.row_for_spell({ name = "Skin like Wood", beneficial = true, target_type = "Single", duration = 1800 })
  eq(buff.target, "self", "buff on me")
  eq(buff.phase, "always", "any time")
  eq(buff.conditions[1].what, "buff", "when I lack it")
  eq(buff.conditions[1].op, "lacks", "lacks")
  eq(buff.conditions[1].value, "Skin like Wood", "its own name")
  local heal = settings.row_for_spell({ name = "Minor Healing", beneficial = true, target_type = "Single", duration = 0 })
  eq(heal.target, "self", "heal on me")
  eq(heal.conditions[1].what, "hp", "under a health mark")
  local petbuff = settings.row_for_spell({ name = "Spirit Strength", beneficial = true, target_type = "Pet", duration = 600 })
  eq(petbuff.target, "pet", "pet buff on the pet")
  eq(petbuff.recast, 600, "again once it runs out")
end)

case("settings: a count keeps its radius, clamped; an AE spell imports with the AE guards", function()
  local r = settings.row({ name = "Fire Storm", conditions = {
    { who = "target", what = "near_haters", op = ">=", value = 3, radius = 25 },
    { who = "me", what = "near_idle", op = "<=", value = 0, radius = 9999 },
    { who = "me", what = "near_npcs", op = "<=", value = "x" },
    { who = "me", what = "near_haters", op = "is", value = 1 },  -- not a count's operator: dropped
  } })
  eq(#r.conditions, 3, "three kept")
  eq(r.conditions[1].radius, 25, "radius kept")
  eq(r.conditions[2].radius, 300, "radius clamped")
  eq(r.conditions[3].radius, 30, "radius defaulted")
  eq(r.conditions[3].value, 3, "count defaulted")

  local pb = settings.row_for_spell({ name = "Upheaval", beneficial = false, target_type = "PB AE", ae_range = 35 })
  eq(pb.target, "enemy", "PB AE on the fight")
  eq(#pb.conditions, 2, "two guards")
  eq(pb.conditions[1].who, "me", "centred on me")
  eq(pb.conditions[1].what, "near_haters", "enough mobs on me")
  eq(pb.conditions[1].radius, 35, "in its reach")
  eq(pb.conditions[2].what, "near_idle", "and no adds")
  eq(pb.conditions[2].op, "<=", "none")
  local ta = settings.row_for_spell({ name = "Rain of Fire", beneficial = false, target_type = "Targeted AE", ae_range = 0 })
  eq(ta.conditions[1].who, "target", "centred on the target")
  eq(ta.conditions[1].radius, 30, "a missing range guessed")
  local hl = settings.row_for_spell({ name = "Hate Wave", beneficial = false, target_type = "Hatelist" })
  eq(hl.conditions[1].what, "haters", "a hatelist spell counts the extended target")
  local nuke = settings.row_for_spell({ name = "Flame Lick", beneficial = false, target_type = "Single" })
  eq(#nuke.conditions, 0, "a single-target spell gets none")
end)
