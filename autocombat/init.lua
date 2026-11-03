-- Auto Combat for Hailstone: fights for you in one of three modes.
--   Manual  full:    run into a pack; it targets the mobs on you (the extended target list's auto haters), keeps in
--                    melee range, attacks, sends the pet, and fires your Spells and Abilities rows.
--           partial: you position yourself and pick the mob; it fires the rows on the NPC you target once it is on
--                    you or you attack it, and only turns to face it.
--   Hunter:          as Manual full, and when nothing is on you it rests, then finds a mob and walks to it
--                    (/nav), roaming the zone or pulling back to a camp, until paused.
--   Assist:          as Manual full, but it fights only what the assist (the group's main assist, or a name) is on,
--                    once its health is low enough, and follows the assist between fights.
-- The Spells and Abilities pages are ordered rows: the first row whose conditions hold and that is ready fires.
--
-- Two windows: a compact one (the mode, Start / Pause, what it is doing; it opens when the script starts) and the
-- settings (its gear button, or /autocombat settings).
--
-- /autocombat [show | settings | on | off | toggle | mode manual|hunter|assist | style full|partial | camp | status]
-- Settings are kept per server and character in scripts/config/autocombat/. A server may turn modes off in its
-- hailstone.cfg: [autocombat] manual = off, hunter = off, assist = off.
local mq = require('mq')
local hs = require('hailstone')
local catalog = require('lib.catalog')
local settings_mod = require('lib.settings')
local engine = require('lib.engine')
local world_mod = require('lib.world')
local rules = require('lib.rules')

local NAME = "autocombat"
local TICK_MS = 100

local S = settings_mod.defaults()   -- the settings in use
local rev = 1                       -- bumped on every change, so the window knows to read them again
local dirty_at = nil                -- when an unsaved change was made
local loaded_for = nil              -- the settings file loaded ("" before a character is in the world)
local open = true                   -- the compact window shows (from the start, so /lua run brings it up)
local settings_open = false         -- the settings window shows
local E = engine.new()
local held = false                  -- autoskill held
local row_status = { spells = {}, abilities = {} }
local spell_cache = nil

local function say(text) hs.chat('[Auto Combat] ' .. text, 15) end

-- ---------------------------------------------------------------- settings

local function clean(s) return (tostring(s or ""):gsub("[^%w_%-]", "_")) end

local function settings_path()
  local server = mq.TLO.EverQuest.Server() or ""
  local char = mq.TLO.Me.Name() or ""
  if server == "" or char == "" then return nil end
  return "autocombat/" .. clean(server) .. "_" .. clean(char) .. ".lua"
end

local function load_settings()
  local path = settings_path()
  if not path or path == loaded_for then return end
  loaded_for = path
  local chunk = loadfile(path)
  local ok, t = false, nil
  if chunk then ok, t = pcall(chunk) end
  S = settings_mod.repair(ok and t or nil)
  rev = rev + 1
  spell_cache = nil
end

local function changed()
  rev = rev + 1
  dirty_at = mq.gettime()
end

local function save_if_due()
  if dirty_at and loaded_for and mq.gettime() - dirty_at > 1500 then
    mq.pickle(loaded_for, S)
    dirty_at = nil
  end
end

-- ---------------------------------------------------------------- the server's rules

local function allowed()
  local a = {}
  for _, m in ipairs(settings_mod.MODES) do
    local v = hs.server_rule("autocombat", m)
    a[m] = not (v and (v:lower() == "off" or v:lower() == "no" or v == "0"))
  end
  return a
end

-- ---------------------------------------------------------------- acting

local act = {
  cmd = function(line) mq.cmd(line) end,
  use = function(kind, name) return hs.use_ability(kind, name) end,
  delay = function(ms, fn) mq.delay(ms, fn) end,
  casting = function() return mq.TLO.Me.Casting() ~= nil end,
  say = say,
}

local function start()
  load_settings()
  local a = allowed()
  if a[S.mode] == false then
    say("this server does not allow " .. S.mode .. " mode.")
    return
  end
  engine.start(E, act)
  say("on (" .. S.mode .. (S.mode == "manual" and (", " .. S.style) or "") .. ").")
end

local function pause(why)
  if E.running then engine.pause(E, act, why) end
  if not why then say("paused.") end
end

local function set_camp()
  load_settings()
  S.hunter.camp = { x = mq.TLO.Me.X(), y = mq.TLO.Me.Y(), z = mq.TLO.Me.Z(), zone = mq.TLO.Zone.ShortName() or "" }
  S = settings_mod.repair(S)
  changed()
  say(string.format("camp set here (%.0f, %.0f).", S.hunter.camp.y, S.hunter.camp.x))
end

-- Rows from the Ability Book's autoskill list, added to the Abilities page (not twice).
local function import_autoskill()
  local have = {}
  for _, r in ipairs(S.abilities) do have[r.kind .. ":" .. r.name:lower()] = true end
  local added = 0
  for _, a in ipairs(hs.autoskill_list() or {}) do
    local kind = a.key:match("^(%a+):")
    kind = kind == "spell" and "disc" or kind
    if a.name ~= "" and (kind == "aa" or kind == "disc" or kind == "skill") and not have[kind .. ":" .. a.name:lower()] then
      local row = { name = a.name, kind = kind, target = "enemy", phase = "combat", conditions = {} }
      if a.when == "always" then row.phase = "always" elseif a.when == "resting" then row.phase = "rest" end
      if a.when ~= "fighting" then row.target = "self" end
      local c = row.conditions
      if a.endurance > 0 then c[#c + 1] = { who = "me", what = "endurance", op = ">=", value = a.endurance } end
      if a.mana > 0 then c[#c + 1] = { who = "me", what = "mana", op = ">=", value = a.mana } end
      if a.target_hp_below > 0 then c[#c + 1] = { who = "target", what = "hp", op = "<", value = a.target_hp_below } end
      if a.target_hp_above > 0 then c[#c + 1] = { who = "target", what = "hp", op = ">", value = a.target_hp_above } end
      if a.self_hp_below > 0 then c[#c + 1] = { who = "me", what = "hp", op = "<", value = a.self_hp_below } end
      S.abilities[#S.abilities + 1] = row
      have[kind .. ":" .. a.name:lower()] = true
      added = added + 1
    end
  end
  S = settings_mod.repair(S)
  changed()
  return added
end

-- A starting row for a spell (settings.row_for_spell): what the spell is decides its target, phase and conditions.
local function spell_row(sp, name)
  return settings_mod.row_for_spell({
    name = name,
    beneficial = sp.Beneficial() == true,
    target_type = sp.TargetType() or "",
    duration = tonumber(sp.Duration.TotalSeconds()) or 0,
  })
end

-- Rows for the memorized spells (the spell bar), added to the Spells page in gem order (not twice).
local function import_spellbar()
  load_settings()
  local have = {}
  for _, r in ipairs(S.spells) do have[r.name:lower()] = true end
  local added = 0
  local gems = tonumber(mq.TLO.Me.NumGems()) or 0
  for i = 1, gems do
    local g = mq.TLO.Me.Gem(i)
    local name = g.Name()
    if name and name ~= "" and not have[name:lower()] then
      local row = spell_row(g, name)
      if row then
        S.spells[#S.spells + 1] = row
        have[name:lower()] = true
        added = added + 1
      end
    end
  end
  S = settings_mod.repair(S)
  changed()
  return added
end

-- The spells to pick from: the memorized ones first, then the spell book's, by name.
local function spell_names(refresh)
  if spell_cache and not refresh then return spell_cache end
  local out, seen = {}, {}
  local gems = tonumber(mq.TLO.Me.NumGems()) or 0
  for i = 1, gems do
    local n = mq.TLO.Me.Gem(i).Name()
    if n and not seen[n] then out[#out + 1] = { name = n, gem = i } seen[n] = true end
  end
  local book = {}
  for i = 1, 720 do
    local n = mq.TLO.Me.Book(i).Name()
    if n and not seen[n] then book[#book + 1] = n seen[n] = true end
  end
  table.sort(book)
  for _, n in ipairs(book) do out[#out + 1] = { name = n, gem = 0 } end
  spell_cache = out
  return out
end

-- ---------------------------------------------------------------- the window's functions

hs.ui_function("state", function()
  return {
    open = open,
    settings_open = settings_open,
    running = E.running,
    mode = S.mode,
    style = S.style,
    status = E.running and E.status or "Paused",
    last = E.last,
    log = E.log,
    rev = rev,
    allowed = allowed(),
    rows = row_status,
    character = loaded_for ~= nil,
  }
end)
hs.ui_function("settings", function() load_settings() return S end)
hs.ui_function("catalog", function() return catalog end)
hs.ui_function("spells", function(refresh) return spell_names(refresh) end)
hs.ui_function("row_for_spell", function(name)
  if type(name) ~= "string" or name == "" then return nil end
  return spell_row(mq.TLO.Spell(name), name)
end)
hs.ui_function("set", function(path, value)
  local ok
  S, ok = settings_mod.set(S, path, value)
  if ok then
    changed()
    if path == "mode" and E.running and allowed()[S.mode] == false then pause("this server does not allow " .. S.mode .. " mode") end
  end
  return ok
end)
hs.ui_function("set_rows", function(list, rows)
  if list ~= "spells" and list ~= "abilities" then return false end
  S[list] = rows or {}
  S = settings_mod.repair(S)
  changed()
  return true
end)
hs.ui_function("set_ignore", function(list)
  S.targeting.ignore = list or {}
  S = settings_mod.repair(S)
  changed()
  return true
end)
hs.ui_function("command", function(what)
  if what == "start" then start()
  elseif what == "pause" then pause()
  elseif what == "toggle" then if E.running then pause() else start() end
  elseif what == "close" then open = false
  elseif what == "settings" then settings_open = not settings_open
  elseif what == "close_settings" then settings_open = false
  elseif what == "camp" then set_camp()
  elseif what == "clear_camp" then S.hunter.camp = nil changed()
  elseif what == "import_autoskill" then return import_autoskill()
  elseif what == "import_spellbar" then return import_spellbar()
  end
  return true
end)
hs.menu("Auto Combat", "/autocombat show")

-- ---------------------------------------------------------------- the command

mq.bind('/autocombat', function(a, b)
  a = (a or ""):lower()
  if a == "" or a == "show" then open = not open
  elseif a == "settings" or a == "setup" then settings_open = not settings_open
  elseif a == "on" or a == "start" then start()
  elseif a == "off" or a == "pause" or a == "stop" then pause()
  elseif a == "toggle" then if E.running then pause() else start() end
  elseif a == "camp" then set_camp()
  elseif a == "mode" or a == "style" then
    local list = a == "mode" and settings_mod.MODES or settings_mod.STYLES
    local v = (b or ""):lower()
    local ok
    for _, m in ipairs(list) do ok = ok or m == v end
    if not ok then return say("usage: /autocombat " .. a .. " " .. table.concat(list, "|")) end
    load_settings()
    S = settings_mod.set(S, a, v)
    changed()
    if E.running and allowed()[S.mode] == false then pause("this server does not allow " .. S.mode .. " mode") end
    say(a .. " " .. v .. ".")
  elseif a == "status" then
    say((E.running and E.status or "paused") .. " (" .. S.mode .. (S.mode == "manual" and (", " .. S.style) or "") .. ")")
  else
    say("/autocombat [show | settings | on | off | toggle | mode manual|hunter|assist | style full|partial | camp | status]")
  end
end)

-- ---------------------------------------------------------------- the loop

local last_status = -1e9
while true do
  load_settings()
  local want_hold = E.running and S.general.hold_autoskill
  if want_hold ~= held then
    hs.hold_autoskill(want_hold)
    held = want_hold
  end
  if E.running then
    local w = world_mod.read(S, allowed())
    local ok, err = pcall(engine.tick, E, w, S, act)
    if not ok then
      pause("stopped by an error: " .. tostring(err))
    elseif settings_open and w.in_game and mq.gettime() - last_status > 500 then
      -- Why each row would not fire now, for the window.
      last_status = mq.gettime()
      for _, list in ipairs({ "spells", "abilities" }) do
        local out = {}
        for i, r in ipairs(S[list]) do out[i] = rules.blocker(list, i, r, w, E.memory) end
        row_status[list] = out
      end
    end
  end
  save_if_due()
  mq.delay(TICK_MS)
end
