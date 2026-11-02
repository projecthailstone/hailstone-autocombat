-- Auto Combat: what a row's conditions can ask, for the evaluator (lib/conditions.lua) and the window's pickers.
-- A condition is { who = <subject>, what = <property>, op = <operator>, value = <number | text> }; every condition of
-- a row must hold. Pure data: no game calls here.
local M = {}

-- The operators by the kind of value a property has.
M.ops = {
  pct = { "<", "<=", ">", ">=" },
  number = { "<", "<=", ">", ">=", "=", "!=" },
  bool = { "is", "is not" },
  buff = { "has", "lacks" },
}

-- Subjects, in the order the window lists them.
M.subjects = {
  { id = "me", label = "Me" },
  { id = "target", label = "Target" },
  { id = "pet", label = "Pet" },
  { id = "group", label = "Lowest group member" },
  { id = "assist", label = "Assist" },
}

-- Properties of each subject: id, label, kind (above), and for numbers a sensible default.
M.properties = {
  me = {
    { id = "hp", label = "Health %", kind = "pct", default = 50 },
    { id = "mana", label = "Mana %", kind = "pct", default = 30 },
    { id = "endurance", label = "Endurance %", kind = "pct", default = 30 },
    { id = "haters", label = "Mobs on me (extended target)", kind = "number", default = 2 },
    { id = "buff", label = "Buff or song", kind = "buff", default = "" },
    { id = "combat", label = "In combat", kind = "bool" },
    { id = "moving", label = "Moving", kind = "bool" },
  },
  target = {
    { id = "hp", label = "Health %", kind = "pct", default = 90 },
    { id = "distance", label = "Distance", kind = "number", default = 50 },
    { id = "level", label = "Level", kind = "number", default = 1 },
    { id = "named", label = "Named", kind = "bool" },
    { id = "buff", label = "Buff (anyone's)", kind = "buff", default = "" },
    { id = "mybuff", label = "My buff or debuff", kind = "buff", default = "" },
    { id = "mezzed", label = "Mezzed", kind = "bool" },
    { id = "slowed", label = "Slowed", kind = "bool" },
    { id = "snared", label = "Snared", kind = "bool" },
    { id = "rooted", label = "Rooted", kind = "bool" },
    { id = "los", label = "In line of sight", kind = "bool" },
  },
  pet = {
    { id = "exists", label = "Exists", kind = "bool" },
    { id = "hp", label = "Health %", kind = "pct", default = 50 },
    { id = "distance", label = "Distance", kind = "number", default = 100 },
  },
  group = {
    { id = "hp", label = "Health %", kind = "pct", default = 60 },
    { id = "distance", label = "Distance", kind = "number", default = 100 },
  },
  assist = {
    { id = "exists", label = "Exists", kind = "bool" },
    { id = "hp", label = "Health %", kind = "pct", default = 50 },
    { id = "distance", label = "Distance", kind = "number", default = 100 },
  },
}

-- Who a row acts on.
M.targets = {
  { id = "enemy", label = "Fight target" },
  { id = "self", label = "Me" },
  { id = "pet", label = "My pet" },
  { id = "group", label = "Lowest group member" },
  { id = "assist", label = "Assist" },
}

-- When a row may fire.
M.phases = {
  { id = "combat", label = "In combat" },
  { id = "rest", label = "Out of combat" },
  { id = "always", label = "Any time" },
}

M.kinds = {
  spell = "Spell",
  disc = "Combat ability",
  aa = "Alternate ability",
  skill = "Skill",
}

function M.property(who, what)
  for _, p in ipairs(M.properties[who] or {}) do
    if p.id == what then return p end
  end
  return nil
end

function M.valid_op(kind, op)
  for _, o in ipairs(M.ops[kind] or {}) do
    if o == op then return true end
  end
  return false
end

-- A new condition on this subject's first property, with its default.
function M.new_condition(who)
  who = M.properties[who] and who or "me"
  local p = M.properties[who][1]
  return { who = who, what = p.id, op = M.ops[p.kind][1], value = p.default }
end

return M
