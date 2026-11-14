-- Auto Combat: which mob to fight. Pure: spawns are plain tables from the snapshot (lib/world.lua):
-- { id, name, hp, npc, dead, distance, level, named, con ("green", "lightblue" ...), mezzed, x, y, z, players_near }.
local M = {}

local function lower(s) return (s or ""):lower() end

-- Whether the targeting settings let this mob be chosen.
function M.allowed(spawn, t)
  if spawn.owned then return false end -- someone's pet (a swarm pet too: lib/world.lua)
  if t.min_level > 0 and (spawn.level or 0) < t.min_level then return false end
  if t.max_level > 0 and (spawn.level or 0) > t.max_level then return false end
  if spawn.con and t.cons[spawn.con] == false then return false end
  if spawn.named and not t.named then return false end
  local name = lower(spawn.name)
  for _, n in ipairs(t.ignore) do
    if n ~= "" and name:find(lower(n), 1, true) then return false end
  end
  return true
end

local function better(priority)
  if priority == "highest_hp" then
    return function(a, b) if a.hp ~= b.hp then return a.hp > b.hp end return a.distance < b.distance end
  end
  if priority == "closest" then
    return function(a, b) if a.distance ~= b.distance then return a.distance < b.distance end return a.id < b.id end
  end
  if priority == "named_first" then
    return function(a, b)
      if (a.named or false) ~= (b.named or false) then return a.named == true end
      return a.distance < b.distance
    end
  end
  return function(a, b) if a.hp ~= b.hp then return a.hp < b.hp end return a.distance < b.distance end
end

-- The mob on me to fight: the current one while it is still on me and not mezzed (no switching mid-fight), else the
-- best by priority, leaving mezzed ones until nothing else is left. Haters are fought whatever the filters say:
-- they are fighting me.
function M.choose_hater(haters, current_id, priority)
  if #haters == 0 then return nil end
  for _, h in ipairs(haters) do
    if h.id == current_id and not h.mezzed then return h end
  end
  local awake = {}
  for _, h in ipairs(haters) do
    if not h.mezzed then awake[#awake + 1] = h end
  end
  local pool = #awake > 0 and awake or haters
  table.sort(pool, better(priority))
  return pool[1]
end

local function flat(a, b)
  local dx, dy = a[1] - b[1], a[2] - b[2]
  return math.sqrt(dx * dx + dy * dy)
end

-- Hunter: the mobs worth walking to, best first. `from` is where it looks from (me, or the camp), `skip` the ids
-- given up on. `whole_zone` drops the search radius (roam, when nothing is near). The second result counts the mobs
-- the targeting settings left out, for the status line.
function M.hunt_candidates(spawns, t, h, from, skip, camp_style, whole_zone)
  local out, filtered = {}, 0
  for _, s in ipairs(spawns) do
    local wanted = s.npc and not s.dead and M.allowed(s, t) and not (t.skip_near_players and s.players_near)
    if not wanted then filtered = filtered + 1 end
    if wanted and not skip[s.id] then
      local d = flat({ s.x, s.y }, from)
      local dz = math.abs((s.z or 0) - (from[3] or 0))
      local reach = camp_style and h.leash or t.radius
      if whole_zone or (d <= reach and dz <= t.zradius) then
        s.from_distance = d
        out[#out + 1] = s
      end
    end
  end
  table.sort(out, function(a, b)
    if t.priority == "named_first" and (a.named or false) ~= (b.named or false) then return a.named == true end
    if a.from_distance ~= b.from_distance then return a.from_distance < b.from_distance end
    return a.id < b.id
  end)
  return out, filtered
end

return M
