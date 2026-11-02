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
