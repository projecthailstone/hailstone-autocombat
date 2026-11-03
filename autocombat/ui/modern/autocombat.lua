-- Auto Combat's windows for the Modern pack. The script (../../init.lua) keeps the settings and runs the fight; these
-- show its state and edit the settings through the script's functions (eq.Plugin("autocombat"): state, settings,
-- set, set_rows, set_ignore, command, catalog, spells).
--   The compact window (opens with the script; /autocombat, or the EQ menu's Plugins > Auto Combat): the mode (Manual,
--           Hunter, Assist; one the server turned off is greyed) and Manual's style (Full, Partial), Start / Pause,
--           what it is doing and the last thing it did. Its gear opens the settings.
--   The settings window (/autocombat settings): a page list down the left.
--     Spells, Abilities: ordered rows; the first row that is ready and whose conditions hold fires. A row: what
--           (a memorized or book spell; an ability from the Ability Book), on whom, when, a recast, conditions.
--           The Now column says why a row is not firing.
--     Targeting, Hunter, Assist, Rest, General: the other settings. Log: the last things it did.
local hud = dofile("lib/hud.lua")
local K = dofile("lib/dialogs_kit.lua")
local T = hud.T
local C = T.color
local SETTINGS_KEY = "AutoCombatSettingsWnd" -- the settings window

local P                          -- the script's functions (nil while it is not running)
local st = {}                    -- its state, read each frame
local S = nil                    -- its settings, read again when they change (rev)
local rev = -1
local cat = nil                  -- the conditions' catalog
local sel = { spells = nil, abilities = nil } -- the selected row of each page
local pick = { spells = "", abilities = "" }   -- the name pickers' filter text
local spellList, abilityList, abilityRead = nil, nil, -1
local imported = {}               -- the last import's count, by page
local describe                   -- a condition as words (below)

local MODES = { { "manual", "Manual" }, { "hunter", "Hunter" }, { "assist", "Assist" } }
local STYLES = { { "full", "Full" }, { "partial", "Partial" } }
local PRIORITIES = { { "lowest_hp", "Lowest health" }, { "highest_hp", "Highest health" }, { "closest", "Closest" },
  { "named_first", "Named first" } }
local CONS = { { "grey", "Grey" }, { "green", "Green" }, { "lightblue", "Light blue" }, { "blue", "Blue" },
  { "white", "White" }, { "yellow", "Yellow" }, { "red", "Red" } }

-- ---------------------------------------------------------------- helpers

local function set(path, value)
  if P then P.set(path, value) end
end

local function label(list, id)
  for _, e in ipairs(list) do
    if e[1] == id or e.id == id then return e[2] or e.label end
  end
  return tostring(id)
end

local function combo(id, list, current, width, disabled)
  ui.SetNextItemWidth(width)
  local chosen = nil
  if ui.BeginCombo(id, label(list, current), 0) then
    for _, e in ipairs(list) do
      local key, text = e[1] or e.id, e[2] or e.label
      local off = disabled and disabled[key]
      if off then ui.BeginDisabled(true) end
      if ui.Selectable(text .. (off and "  (off on this server)" or ""), key == current) then chosen = key end
      if off then ui.EndDisabled() end
    end
    ui.EndCombo()
  end
  return chosen
end

local function number(id, value, width, lo, hi)
  ui.SetNextItemWidth(width)
  local text, changed = ui.InputText(id, tostring(value), 12, ui.InputTextFlags.CharsDecimal)
  if not changed then return nil end
  local v = tonumber(text)
  if not v then return nil end
  if lo and v < lo then v = lo end
  if hi and v > hi then v = hi end
  return v
end

local function pct(id, value, width)
  ui.SetNextItemWidth(width)
  local v, changed = ui.SliderInt(id, value, 0, 100, value == 0 and "off" or (value .. "%"))
  return changed and v or nil
end

local function check(text, value)
  local v, changed = ui.Checkbox(text, value)
  return changed and v or nil
end

local function caption(text) K.Caption(text) end

local LABEL_W = 270 -- the settings' label column (design pixels)

-- A muted label level with the control after it, which starts at the label column.
local function field(text, s, col)
  local cx, cy = ui.GetCursorPos()
  ui.SetCursorPos(cx, cy + 3 * s)
  caption(text)
  ui.SameLine((col or LABEL_W) * s)
  local nx, _ = ui.GetCursorPos()
  ui.SetCursorPos(nx, cy)
end

-- A section heading: the heading colour, a hairline under it.
local function section(text, s, first)
  if not first then ui.Dummy(0, 8 * s) end
  local hc = C.heading or C.accent
  ui.TextColored(hc[1], hc[2], hc[3], 1, text)
  local x, y = ui.GetCursorScreenPos()
  local w = ui.GetContentRegionAvail()
  ui.DrawLine(x, y, x + w, y, C.ink[1], C.ink[2], C.ink[3], 0.10, 1)
  ui.Dummy(0, 4 * s)
end

local function note(text)
  ui.PushTextWrapPos(0)
  ui.TextColored(C.faint[1], C.faint[2], C.faint[3], 1, text)
  ui.PopTextWrapPos()
end

local function tip(text)
  if ui.IsItemHovered() then ui.SetTooltip(text) end
end

local function copy(t)
  if type(t) ~= "table" then return t end
  local out = {}
  for k, v in pairs(t) do out[k] = copy(v) end
  return out
end

-- ---------------------------------------------------------------- what can be put on a row

local function spells()
  if not spellList and P then spellList = P.spells(false) or {} end
  return spellList or {}
end

-- The Ability Book's usable abilities (not passive), by kind.
local function abilities()
  if not abilityList or ui.GetTime() - abilityRead > 5 then
    abilityRead = ui.GetTime()
    abilityList = {}
    for _, a in ipairs(eq.AbilityBook() or {}) do
      if not a.passive then abilityList[#abilityList + 1] = { name = a.name, kind = a.kind } end
    end
    table.sort(abilityList, function(a, b) return a.name < b.name end)
  end
  return abilityList
end

-- ---------------------------------------------------------------- the rows

local function push(list, rows)
  if P then P.set_rows(list, rows) end
  S[list] = rows
end

local function namePicker(list, row, rows, s)
  ui.SetNextItemWidth(260 * s)
  local preview = row.name ~= "" and row.name or "(choose)"
  if ui.BeginCombo("##acname" .. list, preview, ui.ComboFlags.HeightLarge) then
    ui.SetNextItemWidth(-1)
    pick[list] = ui.InputTextWithHint("##acfilter" .. list, "Filter", pick[list] or "", 64)
    local f = (pick[list] or ""):lower()
    if list == "spells" then
      for _, e in ipairs(spells()) do
        if f == "" or e.name:lower():find(f, 1, true) then
          local text = e.gem > 0 and string.format("%s  (gem %d)", e.name, e.gem) or e.name
          if ui.Selectable(text, e.name == row.name) then
            row.name, row.kind = e.name, "spell"
            push(list, rows)
          end
        end
      end
    else
      for _, e in ipairs(abilities()) do
        if f == "" or e.name:lower():find(f, 1, true) then
          local text = string.format("%s  (%s)", e.name, cat and cat.kinds[e.kind] or e.kind)
          if ui.Selectable(text, e.name == row.name and e.kind == row.kind) then
            row.name, row.kind = e.name, e.kind
            push(list, rows)
          end
        end
      end
    end
    ui.EndCombo()
  end
end

local function conditionEditor(list, row, rows, s)
  local remove = nil
  for i, c in ipairs(row.conditions) do
    ui.PushID("accond" .. i)
    local who = combo("##who", cat.subjects, c.who, 150 * s)
    if who and who ~= c.who then
      row.conditions[i] = { who = who }
      local p = cat.properties[who][1]
      row.conditions[i].what, row.conditions[i].op, row.conditions[i].value = p.id, cat.ops[p.kind][1], p.default
      push(list, rows)
    end
    ui.SameLine()
    local props = cat.properties[c.who] or {}
    local what = combo("##what", props, c.what, 190 * s)
    local prop
    for _, p in ipairs(props) do if p.id == (what or c.what) then prop = p end end
    if what and what ~= c.what and prop then
      c.what, c.op, c.value = what, cat.ops[prop.kind][1], prop.default
      push(list, rows)
    end
    if prop then
      ui.SameLine()
      local ops = {}
      for _, o in ipairs(cat.ops[prop.kind]) do ops[#ops + 1] = { o, o } end
      local op = combo("##op", ops, c.op, 70 * s)
      if op then c.op = op push(list, rows) end
      if prop.kind == "buff" then
        ui.SameLine()
        ui.SetNextItemWidth(170 * s)
        local text, changed = ui.InputTextWithHint("##val", "buff name", c.value or "", 64)
        if changed then c.value = text push(list, rows) end
      elseif prop.kind ~= "bool" then
        ui.SameLine()
        local v = number("##val", c.value or 0, 70 * s)
        if v then c.value = v push(list, rows) end
      end
    end
    ui.SameLine()
    if ui.SmallButton("x") then remove = i end
    tip("Remove this condition")
    ui.PopID()
  end
  if remove then
    table.remove(row.conditions, remove)
    push(list, rows)
  end
  if ui.SmallButton("+ Condition##ac" .. list) then
    row.conditions[#row.conditions + 1] = { who = "me", what = "hp", op = "<", value = 50 }
    push(list, rows)
  end
  tip("Every condition must hold for the row to fire")
end

local function rowEditor(list, row, rows, s, index)
  section(string.format("Row %d", index), s)
  field(list == "spells" and "Spell" or "Ability", s, 90)
  namePicker(list, row, rows, s)
  ui.SameLine()
  local on = check("Enabled##acen" .. list, row.enabled)
  if on ~= nil then row.enabled = on push(list, rows) end
  field("On", s, 90)
  local to = combo("##acto" .. list, cat.targets, row.target, 170 * s)
  if to then row.target = to push(list, rows) end
  ui.SameLine()
  local cx, cy = ui.GetCursorPos()
  ui.SetCursorPos(cx + 8 * s, cy + 3 * s)
  caption("When")
  ui.SameLine()
  ui.SetCursorPos(ui.GetCursorPos(), cy)
  local ph = combo("##acph" .. list, cat.phases, row.phase, 140 * s)
  if ph then row.phase = ph push(list, rows) end
  field("Recast", s, 90)
  local rc = number("##acrc" .. list, row.recast or 0, 60 * s, 0, 3600)
  if rc then row.recast = rc push(list, rows) end
  tip("Seconds before this row fires again (0: as soon as it is ready)")
  ui.SameLine()
  local pt = check("for each target##acpt" .. list, row.per_target)
  if pt ~= nil then row.per_target = pt push(list, rows) end
  tip("Count the recast per fight target: a damage over time or a debuff, when the server does not send the target's buffs")
  field("Conditions", s, 90)
  if #row.conditions == 0 then ui.TextColored(C.faint[1], C.faint[2], C.faint[3], 1, "none: it fires whenever it is ready") end
  if #row.conditions > 0 then ui.NewLine() end
  conditionEditor(list, row, rows, s)
end

local function rowsPage(list, s, h)
  local rows = S[list]
  local status = (st.rows or {})[list] or {}
  local flags = ui.TableFlags.RowBg + ui.TableFlags.ScrollY + ui.TableFlags.SizingFixedFit + ui.TableFlags.BordersInnerV
  local tableH = math.max(110 * s, h * 0.42)
  if ui.BeginTable("##acrows" .. list, 7, flags, 0, tableH) then
    ui.TableSetupColumn("#", ui.TableColumnFlags.WidthFixed, 24 * s)
    ui.TableSetupColumn("On", ui.TableColumnFlags.WidthFixed, 30 * s)
    ui.TableSetupColumn(list == "spells" and "Spell" or "Ability", ui.TableColumnFlags.WidthStretch, 0)
    ui.TableSetupColumn("Target", ui.TableColumnFlags.WidthFixed, 110 * s)
    ui.TableSetupColumn("When", ui.TableColumnFlags.WidthFixed, 100 * s)
    ui.TableSetupColumn("Now", ui.TableColumnFlags.WidthFixed, 110 * s)
    ui.TableSetupColumn("", ui.TableColumnFlags.WidthFixed, 70 * s)
    ui.TableHeadersRow()
    local move, remove = nil, nil
    for i, r in ipairs(rows) do
      ui.PushID("acrow" .. list .. i)
      ui.TableNextRow()
      ui.TableNextColumn()
      if ui.Selectable(tostring(i), sel[list] == i, ui.SelectableFlags.SpanAllColumns) then sel[list] = i end
      ui.TableNextColumn()
      local on = check("##on", r.enabled)
      if on ~= nil then r.enabled = on push(list, rows) end
      ui.TableNextColumn()
      ui.Text(r.name .. (list == "abilities" and ("  (" .. (cat.kinds[r.kind] or r.kind) .. ")") or ""))
      if #r.conditions > 0 and ui.IsItemHovered() then
        local lines = {}
        for _, c in ipairs(r.conditions) do lines[#lines + 1] = describe(c) end
        ui.SetTooltip(table.concat(lines, "\n"))
      end
      ui.TableNextColumn()
      ui.Text(label(cat.targets, r.target))
      ui.TableNextColumn()
      ui.Text(label(cat.phases, r.phase))
      ui.TableNextColumn()
      local why = status[i]
      if not st.running then ui.TextDisabled("-")
      elseif why == "" then ui.TextColored(C.good[1], C.good[2], C.good[3], 1, "ready")
      else ui.TextDisabled(why or "-") end
      ui.TableNextColumn()
      if ui.SmallButton("^") and i > 1 then move = { i, i - 1 } end
      ui.SameLine()
      if ui.SmallButton("v") and i < #rows then move = { i, i + 1 } end
      ui.SameLine()
      if ui.SmallButton("x") then remove = i end
      ui.PopID()
    end
    ui.EndTable()
    if #rows == 0 then
      note(list == "spells" and "No spells yet. Import your spell bar, or add one and give it the conditions it fires on."
        or "No abilities yet. Add one, or import the Ability Book's autoskill list.")
    end
    if move then
      rows[move[1]], rows[move[2]] = rows[move[2]], rows[move[1]]
      if sel[list] == move[1] then sel[list] = move[2] end
      push(list, rows)
    elseif remove then
      table.remove(rows, remove)
      sel[list] = nil
      push(list, rows)
    end
  end
  if ui.Button("+ Add " .. (list == "spells" and "spell" or "ability")) then
    rows[#rows + 1] = { enabled = true, kind = list == "spells" and "spell" or "skill", name = "", target = "enemy",
      phase = "combat", recast = 0, per_target = false, conditions = {} }
    sel[list] = #rows
    S[list] = rows -- pushed once it has a name (a row without one is not kept)
  end
  if list == "abilities" then
    ui.SameLine()
    if ui.Button("Import from Autoskill") then imported.abilities = P and P.command("import_autoskill") end
    tip("Adds the Ability Book's autoskill list here, with its conditions")
    if imported[list] then
      ui.SameLine()
      ui.TextDisabled(imported[list] == 0 and "nothing new to add" or (imported[list] .. " added"))
    end
  else
    ui.SameLine()
    if ui.Button("Import spell bar") then imported.spells = P and P.command("import_spellbar") end
    tip("Adds a row for each memorized spell, in gem order: harmful ones on the fight target in combat, buffs on you"
      .. " when you lack them, heals on you under 60% health. Change them to suit.")
    if imported[list] then
      ui.SameLine()
      ui.TextDisabled(imported[list] == 0 and "nothing new to add" or (imported[list] .. " added"))
    end
    ui.SameLine()
    if ui.Button("Refresh spells") then spellList = P and P.spells(true) or nil end
    tip("Read the memorized spells and the spell book again")
  end
  local r = sel[list] and rows[sel[list]]
  if r then rowEditor(list, r, rows, s, sel[list])
  elseif #rows > 0 then
    ui.Dummy(0, 6 * s)
    note("Select a row to edit it.")
  end
end

-- ---------------------------------------------------------------- the other pages

local function targetingPage(s)
  local t = S.targeting
  section("Who to fight first", s, true)
  field("When several mobs are on you, fight", s)
  local p = combo("##acprio", PRIORITIES, t.priority, 180 * s)
  if p then set("targeting.priority", p) end
  section("Which mobs it may choose", s)
  field("Levels (0: any)", s)
  local lo = number("##aclo", t.min_level, 60 * s, 0, 200)
  if lo then set("targeting.min_level", lo) end
  ui.SameLine()
  ui.Text("to")
  ui.SameLine()
  local hi = number("##achi", t.max_level, 60 * s, 0, 200)
  if hi then set("targeting.max_level", hi) end
  field("Con colours", s)
  for i, c in ipairs(CONS) do
    if i > 1 then ui.SameLine() end
    local v = check(c[2] .. "##accon" .. c[1], t.cons[c[1]])
    if v ~= nil then set("targeting.cons." .. c[1], v) end
  end
  field("Named mobs", s)
  local n = check("##acnamed", t.named)
  if n ~= nil then set("targeting.named", n) end
  section("Never choose", s)
  note("Names, or parts of names, one per line.")
  local text, changed = ui.InputTextMultiline("##acignore", table.concat(t.ignore, "\n"), 4096, -1, 80 * s)
  if changed and P then
    local list = {}
    for line in (text .. "\n"):gmatch("([^\n]*)\n") do
      line = line:gsub("^%s+", ""):gsub("%s+$", "")
      if line ~= "" then list[#list + 1] = line end
    end
    P.set_ignore(list)
  end
  ui.Dummy(0, 4 * s)
  note("These choose the mobs Hunter goes after. Mobs already fighting you are fought whatever they are.")
end

local function hunterPage(s)
  local h, t = S.hunter, S.targeting
  section("How it hunts", s, true)
  field("Style", s)
  local style = combo("##achs", { { "roam", "Roam the zone" }, { "camp", "Pull back to a camp" } }, h.style, 200 * s)
  if style then set("hunter.style", style) end
  if h.style == "camp" then
    ui.SameLine()
    if ui.Button("Set camp here") then P.command("camp") end
    ui.SameLine()
    if h.camp then ui.TextDisabled(string.format("%s %.0f, %.0f", h.camp.zone or "", h.camp.y or 0, h.camp.x or 0))
    else ui.TextColored(C.gold[1], C.gold[2], C.gold[3], 1, "no camp yet") end
    field("Leash (how far from camp)", s)
    local l = number("##acleash", h.leash, 80 * s, 10, 5000)
    if l then set("hunter.leash", l) end
    field("Pull with", s)
    local kinds = { { "", "Walk up and attack" }, { "spell", "A spell" }, { "disc", "A combat ability" },
      { "aa", "An alternate ability" }, { "skill", "A skill" } }
    local k = combo("##acpk", kinds, h.pull_kind, 180 * s)
    if k then set("hunter.pull_kind", k) end
    if h.pull_kind ~= "" then
      ui.SameLine()
      ui.SetNextItemWidth(200 * s)
      local text, changed = ui.InputTextWithHint("##acpn", "name", h.pull_name, 64)
      if changed then set("hunter.pull_name", text) end
    end
  else
    field("Search radius", s)
    local r = number("##acrad", t.radius, 80 * s, 10, 5000)
    if r then set("targeting.radius", r) end
    ui.SameLine()
    ui.TextColored(C.faint[1], C.faint[2], C.faint[3], 1, "nearer mobs first; with none there, anywhere in the zone")
  end
  section("Limits", s)
  field("Height range", s)
  local z = number("##aczr", t.zradius, 80 * s, 5, 1000)
  if z then set("targeting.zradius", z) end
  field("Longest walk", s)
  local mp = number("##acmp", h.max_path, 80 * s, 10, 10000)
  if mp then set("hunter.max_path", mp) end
  field("Give up on a mob after (seconds)", s)
  local g = number("##acgu", h.give_up, 80 * s, 5, 600)
  if g then set("hunter.give_up", g) end
  field("Stop looking while this many are on you", s)
  local mh = number("##acmh", h.max_haters, 80 * s, 0, 20)
  if mh then set("hunter.max_haters", mh) end
  field("Skip mobs with a player within", s)
  local near = check("##acnear", t.skip_near_players)
  if near ~= nil then set("targeting.skip_near_players", near) end
  if t.skip_near_players then
    ui.SameLine()
    local pr = number("##acpr", t.player_radius, 60 * s, 5, 500)
    if pr then set("targeting.player_radius", pr) end
  end
  ui.Dummy(0, 4 * s)
  note("Hunter walks over the zone's navigation mesh (/nav). Your own movement keys stop a walk; pause to stop hunting.")
end

local function assistPage(s)
  local a = S.assist
  section("Who to assist", s, true)
  field("Assist", s)
  local who = combo("##acwho", { { "group", "The group's main assist" }, { "name", "This player" } }, a.who, 220 * s)
  if who then set("assist.who", who) end
  if a.who == "name" then
    ui.SameLine()
    ui.SetNextItemWidth(180 * s)
    local text, changed = ui.InputTextWithHint("##acan", "name", a.name, 64)
    if changed then set("assist.name", text) end
  end
  section("When to join in", s)
  field("Join when the mob's health is at most", s)
  local e = pct("##aceng", a.engage_pct, 220 * s)
  if e then set("assist.engage_pct", e) end
  section("Between fights", s)
  field("Follow the assist, at a distance of", s)
  local f = check("##acfol", a.follow)
  if f ~= nil then set("assist.follow", f) end
  if a.follow then
    ui.SameLine()
    local d = number("##acfd", a.follow_distance, 60 * s, 5, 200)
    if d then set("assist.follow_distance", d) end
  end
end

local function restPage(s)
  local r = S.rest
  section("Sitting between fights", s, true)
  note("Out of combat it sits when one of these is below its mark, and stands when all are back.")
  ui.Dummy(0, 2 * s)
  for _, k in ipairs({ { "hp", "Health" }, { "mana", "Mana" }, { "endurance", "Endurance" } }) do
    field(k[2] .. ": sit below", s, 150)
    local a = pct("##acsit" .. k[1], r["sit_" .. k[1]], 200 * s)
    if a then set("rest.sit_" .. k[1], a) end
    ui.SameLine()
    ui.Text("stand at")
    ui.SameLine()
    local b = pct("##acstand" .. k[1], r["stand_" .. k[1]], 200 * s)
    if b then set("rest.stand_" .. k[1], b) end
  end
  section("Safety", s)
  field("Pause when my health falls below", s)
  local sh = pct("##acstop", r.stop_hp, 220 * s)
  if sh then set("rest.stop_hp", sh) end
end

local function generalPage(s)
  local g = S.general
  section("Melee", s, true)
  local v = check("Auto attack the fight target##acatk", g.attack)
  if v ~= nil then set("general.attack", v) end
  v = check("Stay in melee range (/stick)##acstick", g.stick)
  if v ~= nil then set("general.stick", v) end
  tip("Off: it only turns to face the target. Manual partial never moves you.")
  if g.stick then
    ui.SameLine()
    local d = number("##acsd", g.stick_distance, 60 * s, 0, 200)
    if d then set("general.stick_distance", d) end
    tip("0: inside your melee range")
    ui.SameLine()
    v = check("behind##acbehind", g.behind)
    if v ~= nil then set("general.behind", v) end
  end
  section("Pet and autoskill", s)
  v = check("Send my pet on each new target##acpet", g.pet_attack)
  if v ~= nil then set("general.pet_attack", v) end
  v = check("Hold the Ability Book's autoskill while Auto Combat runs##achold", g.hold_autoskill)
  if v ~= nil then set("general.hold_autoskill", v) end
  section("Pacing", s)
  field("Seconds between two actions", s)
  local gap = number("##acgap", g.action_gap, 60 * s, 0.1, 5)
  if gap then set("general.action_gap", gap) end
end

local function logPage(s)
  if #(st.log or {}) == 0 then note("Nothing yet.") return end
  for i = #st.log, 1, -1 do
    local c = i == #st.log and C.text or C.muted
    ui.TextColored(c[1], c[2], c[3], 1, st.log[i])
  end
end

-- ---------------------------------------------------------------- the windows

describe = function(c)
  local who = label(cat.subjects, c.who)
  local prop
  for _, p in ipairs(cat.properties[c.who] or {}) do if p.id == c.what then prop = p end end
  if not prop then return "?" end
  if prop.kind == "bool" then return who .. " " .. c.op .. " " .. prop.label:lower() end
  if prop.kind == "buff" then return who .. " " .. c.op .. " " .. tostring(c.value) end
  return who .. " " .. prop.label .. " " .. c.op .. " " .. tostring(c.value)
end

local function mix(a, b, t) return { a[1] + (b[1] - a[1]) * t, a[2] + (b[2] - a[2]) * t, a[3] + (b[3] - a[3]) * t } end

-- A row of pills, one chosen: list = { {id, label}, ... }; off[id]: greyed (the server turned it off). Returns the
-- id clicked, if any.
local function segmented(id, x0, y0, x1, y1, s, list, current, off, tips)
  local n = #list
  local gap = 4 * s
  local w = (x1 - x0 - gap * (n - 1)) / n
  local rad = (y1 - y0) / 2
  local clicked = nil
  ui.DrawRectFilled(x0 - 2 * s, y0 - 2 * s, x1 + 2 * s, y1 + 2 * s, C.inset[1], C.inset[2], C.inset[3], C.inset[4],
    rad + 2 * s)
  for i, e in ipairs(list) do
    local bx0 = x0 + (i - 1) * (w + gap)
    local bx1 = bx0 + w
    local disabled = off and off[e[1]]
    local hit = T.Hit(id .. e[1], bx0, y0, bx1, y1)
    local hovered = ui.IsItemHovered()
    local on = e[1] == current
    local a = C.accent
    if on then
      ui.DrawRectFilled(bx0, y0, bx1, y1, a[1], a[2], a[3], 0.30, rad)
      ui.DrawRect(bx0, y0, bx1, y1, a[1], a[2], a[3], 0.85, rad, 1.2 * s)
    elseif hovered and not disabled then
      ui.DrawRectFilled(bx0, y0, bx1, y1, C.ink[1], C.ink[2], C.ink[3], 0.07, rad)
    end
    local _, th = T.TextSize("Ag", T.font.small)
    local tc = disabled and C.faint or (on and C.text or C.muted)
    T.Text((bx0 + bx1) / 2, y0 + (y1 - y0 - th) / 2, e[2], tc, T.font.small, "center")
    if hovered then
      if disabled then ui.SetTooltip(e[2] .. " is turned off on this server")
      elseif tips and tips[e[1]] then ui.SetTooltip(tips[e[1]]) end
    end
    if hit and not disabled and not on then clicked = e[1] end
  end
  return clicked
end

-- A gear: the settings button. Returns clicked.
local function gearButton(id, x, y, size, s, lit)
  local clicked = T.Hit(id, x, y, x + size, y + size)
  local hovered, active = ui.IsItemHovered(), ui.IsItemActive()
  if hovered or lit then
    local a = lit and C.accent or C.ink
    ui.DrawRectFilled(x, y, x + size, y + size, a[1], a[2], a[3], lit and (hovered and 0.35 or 0.25) or (active and 0.16 or 0.10),
      size / 4)
  end
  local c = (hovered or lit) and C.text or C.muted
  local cx, cy = x + size / 2, y + size / 2
  local r = size * 0.24
  for k = 0, 7 do
    local ang = k * math.pi / 4
    local dx, dy = math.cos(ang), math.sin(ang)
    ui.DrawLine(cx + dx * r, cy + dy * r, cx + dx * (r + size * 0.14), cy + dy * (r + size * 0.14), c[1], c[2], c[3], 1,
      size * 0.12)
  end
  ui.DrawCircle(cx, cy, r, c[1], c[2], c[3], 1, size * 0.10)
  if hovered then ui.SetTooltip("Settings") end
  return clicked
end

local STYLE_TIPS = {
  full = "It targets the mobs on you and keeps you in range",
  partial = "You pick the mob and stand where you want; it only turns you to face it",
}
local MODE_TIPS = {
  manual = "You bring the fight; it fights it",
  hunter = "It finds mobs and walks to them until you pause it",
  assist = "It fights what your assist fights",
}

-- The compact window: the mode, Start / Pause and what it is doing.
local function compactSize(s)
  return 340, S.mode == "manual" and 160 or 128
end

local function compact(x, y, w, h, s)
  local running = st.running
  local pad = 12 * s
  -- title row: a status light, the name; the gear (the close X is the frame's, at the right)
  local t = ui.GetTime()
  local light = running and C.good or C.faint
  local glow = running and (0.25 + 0.20 * math.sin(t * 4)) or 0
  if running then ui.DrawCircleFilled(x + pad + 4 * s, y + 15 * s, 7 * s, light[1], light[2], light[3], glow) end
  ui.DrawCircleFilled(x + pad + 4 * s, y + 15 * s, 4 * s, light[1], light[2], light[3], 1)
  T.Text(x + pad + 14 * s, y + 8 * s, "AUTO COMBAT", C.muted, T.font.small)
  if gearButton("##acgear", x + w - 44 * s, y + 4 * s, 18 * s, s, st.settings_open) then P.command("settings") end

  -- the mode, and Manual's style
  local off = {}
  for k, v in pairs(st.allowed or {}) do off[k] = v == false end
  local yy = y + 32 * s
  local m = segmented("##acmode", x + pad, yy, x + w - pad, yy + 24 * s, s, MODES, S.mode, off, MODE_TIPS)
  if m then set("mode", m) S.mode = m end
  yy = yy + 32 * s
  if S.mode == "manual" then
    local sty = segmented("##acstyle", x + pad + 40 * s, yy, x + w - pad - 40 * s, yy + 22 * s, s, STYLES, S.style, nil,
      STYLE_TIPS)
    if sty then set("style", sty) S.style = sty end
    yy = yy + 32 * s
  end

  -- Start / Pause, and what it is doing
  local bw, bh = 92 * s, 40 * s
  local bx0, by0 = x + pad, y + h - pad - bh
  local hit = T.Hit("##acgo", bx0, by0, bx0 + bw, by0 + bh)
  local hovered, active = ui.IsItemHovered(), ui.IsItemActive()
  local base = running and C.danger or C.accent
  local f = active and 0.62 or (hovered and 0.85 or 0.72)
  local top, bottom = mix(base, { 1, 1, 1 }, 0.10), mix(base, { 0, 0, 0 }, 0.25)
  local rad = 8 * s
  ui.DrawRectFilled(bx0, by0 + 2 * s, bx0 + bw, by0 + bh + 2 * s, 0, 0, 0, 0.30, rad)
  ui.DrawRectFilled(bx0, by0, bx0 + bw, by0 + bh, bottom[1], bottom[2], bottom[3], f, rad)
  ui.DrawRectFilled(bx0, by0, bx0 + bw, by0 + bh * 0.55, top[1], top[2], top[3], f, rad)
  ui.DrawRect(bx0, by0, bx0 + bw, by0 + bh, base[1], base[2], base[3], 1, rad, 1.2 * s)
  -- a play triangle or pause bars before the word
  local word = running and "Pause" or "Start"
  local tw, th = T.TextSize(word, T.font.normal)
  local iconW = 10 * s
  local gx = bx0 + (bw - tw - iconW - 6 * s) / 2
  local cy = by0 + bh / 2
  local ic = C.barText or { 1, 1, 1, 1 }
  if running then
    ui.DrawRectFilled(gx, cy - 6 * s, gx + 3.5 * s, cy + 6 * s, ic[1], ic[2], ic[3], 1, 1 * s)
    ui.DrawRectFilled(gx + 6.5 * s, cy - 6 * s, gx + 10 * s, cy + 6 * s, ic[1], ic[2], ic[3], 1, 1 * s)
  else
    ui.DrawTriangleFilled(gx, cy - 6.5 * s, gx, cy + 6.5 * s, gx + iconW, cy, ic[1], ic[2], ic[3], 1)
  end
  T.Text(gx + iconW + 6 * s, cy - th / 2, word, ic, T.font.normal, nil, 1, C.barShadow)
  if hit then P.command(running and "pause" or "start") end
  if hovered then ui.SetTooltip(running and "Pause (/autocombat off)" or "Start (/autocombat on)") end

  -- the status and the last thing it did
  local sx = bx0 + bw + 12 * s
  local room = x + w - pad - sx
  local status = st.status or ""
  local sc = running and C.text or C.muted
  local _, h1 = T.TextSize("Ag", T.font.normal)
  local last = st.last ~= nil and st.last ~= "" and st.last ~= status and st.last or nil
  local sy = last and (by0 + 2 * s) or (cy - h1 / 2)
  T.Text(sx, sy, T.Fit(status, room, T.font.normal), sc, T.font.normal)
  if last then T.Text(sx, sy + h1 + 3 * s, T.Fit(last, room, T.font.small), C.faint, T.font.small) end
  if ui.IsMouseHoveringRect(sx, by0, x + w - pad, by0 + bh) and (status ~= "" or last) then
    ui.SetTooltip(status .. (last and ("\nLast: " .. last) or ""))
  end
end

-- The settings window: the pages down the left, the chosen one on the right.
local PAGES = {
  { "spells", "Spells", "Ordered rows: the first one that is ready and whose conditions all hold fires." },
  { "abilities", "Abilities", "Skills, combat abilities and alternate abilities, in the same way as spells." },
  { "targeting", "Targeting", "Which mobs it fights first, and which it may go after." },
  { "hunter", "Hunter", "Finding mobs on its own: roaming the zone, or pulling to a camp." },
  { "assist", "Assist", "Fighting what your assist fights." },
  { "rest", "Rest", "Sitting between fights, and when to stop." },
  { "general", "General", "Melee, your pet, and pacing." },
  { "log", "Log", "The last things it did, newest first." },
}
local page = "spells"

local function sidebar(x, y, w, h, s)
  ui.DrawRectFilled(x, y, x + w, y + h, C.inset[1], C.inset[2], C.inset[3], C.inset[4] * 0.6, 8 * s)
  local rowH = 30 * s
  local yy = y + 8 * s
  for _, p in ipairs(PAGES) do
    local x0, x1 = x + 6 * s, x + w - 6 * s
    local hit = T.Hit("##acpage" .. p[1], x0, yy, x1, yy + rowH)
    local hovered = ui.IsItemHovered()
    local on = page == p[1]
    local a = C.accent
    if on then
      ui.DrawRectFilled(x0, yy, x1, yy + rowH, a[1], a[2], a[3], 0.18, 6 * s)
      ui.DrawRectFilled(x0, yy + 6 * s, x0 + 3 * s, yy + rowH - 6 * s, a[1], a[2], a[3], 1, 2 * s)
    elseif hovered then
      ui.DrawRectFilled(x0, yy, x1, yy + rowH, C.ink[1], C.ink[2], C.ink[3], 0.06, 6 * s)
    end
    local _, th = T.TextSize("Ag", T.font.normal)
    local text = p[2]
    if p[1] == "spells" or p[1] == "abilities" then
      local n = #(S[p[1]] or {})
      if n > 0 then
        T.Text(x1 - 8 * s, yy + (rowH - th) / 2, tostring(n), C.faint, T.font.small, "right")
      end
    end
    T.Text(x0 + 12 * s, yy + (rowH - th) / 2, text, on and C.text or C.muted, T.font.normal)
    if hit then page = p[1] end
    yy = yy + rowH + 2 * s
  end
  -- at the foot: the mode and whether it runs
  local mode = label(MODES, S.mode) .. (S.mode == "manual" and (" / " .. label(STYLES, S.style)) or "")
  local c = st.running and C.good or C.faint
  ui.DrawCircleFilled(x + 16 * s, y + h - 18 * s, 3.5 * s, c[1], c[2], c[3], 1)
  T.Text(x + 26 * s, y + h - 25 * s, T.Fit(mode .. (st.running and " - on" or " - paused"), w - 34 * s, T.font.small),
    C.muted, T.font.small)
end

local function settingsBody(x, y, w, h, s)
  local sideW = 150 * s
  sidebar(x, y, sideW, h, s)
  local cx = x + sideW + 14 * s
  local cw = w - sideW - 14 * s
  local info
  for _, p in ipairs(PAGES) do if p[1] == page then info = p end end
  -- the page's title and what it is for
  local _, th = T.TextSize("Ag", T.font.large)
  T.Text(cx, y + 2 * s, info[2], C.text, T.font.large)
  T.Text(cx, y + th + 6 * s, info[3], C.muted, T.font.small)
  local top = y + th + 28 * s
  ui.DrawLine(cx, top - 6 * s, cx + cw, top - 6 * s, C.ink[1], C.ink[2], C.ink[3], 0.10, 1)
  ui.SetCursorScreenPos(cx, top)
  local ch = y + h - top
  ui.BeginChild("##acpagebody", cw, ch, false)
  if page == "spells" then rowsPage("spells", s, ch)
  elseif page == "abilities" then rowsPage("abilities", s, ch)
  elseif page == "targeting" then targetingPage(s)
  elseif page == "hunter" then hunterPage(s)
  elseif page == "assist" then assistPage(s)
  elseif page == "rest" then restPage(s)
  elseif page == "general" then generalPage(s)
  else logPage(s) end
  ui.EndChild()
end

ui.window("Auto Combat", function()
  P = eq.Plugin("autocombat")
  if not P or not eq.InGame() then return end
  st = P.state() or {}
  if not st.open and not st.settings_open then return end
  if st.rev ~= rev or not S then
    S = P.settings()
    rev = st.rev
  end
  cat = cat or P.catalog()
  if not S or not cat then return end
  hud.Window(nil, "Auto Combat", {
    shown = function() return st.open end,
    size = compactSize,
    place = function(W, H, w, h) return W - w - 40, H * 0.30 end,
    onClose = function() P.command("close") end,
  }, compact)
  hud.Dialog(SETTINGS_KEY, "Auto Combat Settings", {
    shown = st.settings_open == true,
    keepTitle = true,
    size = function() return 820, 580 end,
    resizable = { 680, 460 },
    place = K.Centered,
    onClose = function() P.command("close_settings") end,
  }, settingsBody)
end)
