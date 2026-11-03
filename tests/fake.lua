-- A world snapshot and an io recorder for the tests, shaped as lib/world.lua and init.lua give them.
local M = {}

function M.spawn(t)
  local s = {
    id = t.id, name = t.name or ("mob" .. t.id), hp = t.hp or 100, distance = t.distance or 10, level = t.level or 10,
    named = t.named or false, npc = t.npc ~= false, pc = t.pc or false, con = t.con or "white",
    x = t.x or 0, y = t.y or 0, z = t.z or 0, max_range = t.max_range or 14, los = t.los,
    mezzed = t.mezzed, slowed = t.slowed, snared = t.snared, rooted = t.rooted, players_near = t.players_near,
    owned = t.owned,
  }
  if t.buffs then
    s.has_buff = function(n) return t.buffs[n] ~= nil end
    s.my_buff = function(n) return t.buffs[n] == "mine" end
  end
  return s
end

-- opts: me = {...}, target = spawn, haters = {spawns}, spells = {name = {...}}, ready = {kind:name = true},
-- spawns = {spawns (by id)}, hunt = {spawns}, paths = {id = length}, pet, group, assist, now, allowed,
-- mesh = {loaded, complete, built, total}, npcs = {spawns} (the NPCs about, for the counts)
function M.world(opts)
  opts = opts or {}
  local me = {
    id = 1, name = "Tester", hp = 100, mana = 100, endurance = 100, current_mana = 1000, casting = false,
    moving = false, sitting = false, feigned = false, dead = false, combat = false, in_combat = false,
    x = 0, y = 0, z = 0, distance = 0, los = true,
  }
  for k, v in pairs(opts.me or {}) do me[k] = v end
  local haters = opts.haters or {}
  me.haters = #haters
  me.has_buff = function(n) return (opts.my_buffs or {})[n] == true end
  me.my_buff = me.has_buff
  local by_id = {}
  for _, s in ipairs(opts.spawns or {}) do by_id[s.id] = s end
  for _, s in ipairs(haters) do by_id[s.id] = s end
  if opts.target then by_id[opts.target.id] = opts.target end
  local w = {
    now = opts.now or 100000,
    in_game = opts.in_game ~= false,
    allowed = opts.allowed or {},
    me = me,
    haters = haters,
    target = opts.target,
    target_id = opts.target and opts.target.id or 0,
    pet = opts.pet, group = opts.group, assist = opts.assist,
    nav_active = opts.nav_active or false,
    mesh = opts.mesh,
    zone = opts.zone or "testzone",
  }
  function w.spawn(id) return by_id[id] end
  function w.spell(name) return (opts.spells or {})[name] end
  function w.ready(row)
    if row.kind == "spell" then
      local s = w.spell(row.name)
      if not s then return false, "unknown spell" end
      if not s.gem then return false, "not memorized" end
      if not s.ready then return false, "not ready" end
      return true
    end
    if (opts.ready or {})[row.kind .. ":" .. row.name] then return true end
    return false, "not ready"
  end
  function w.path_length(id) return (opts.paths or {})[id] end
  function w.hunt_spawns() return opts.hunt or {} end
  if opts.npcs then function w.npcs() return opts.npcs end end
  return w
end

function M.io()
  local io = { lines = {}, used = {}, said = {}, casting_now = false }
  io.cmd = function(line) io.lines[#io.lines + 1] = line end
  io.use = function(kind, name)
    io.used[#io.used + 1] = kind .. ":" .. name
    return true
  end
  io.delay = function() end
  io.casting = function() return io.casting_now end
  io.say = function(t) io.said[#io.said + 1] = t end
  function io.has(line)
    for _, l in ipairs(io.lines) do if l == line then return true end end
    return false
  end
  function io.clear() io.lines, io.used, io.said = {}, {}, {} end
  return io
end

return M
