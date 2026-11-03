-- Auto Combat's window for the Modern pack (/autocombat, or the EQ menu's Plugins > Auto Combat). The script
-- (../../init.lua) keeps the settings and runs the fight; this window shows its state and edits the settings through
-- the script's functions (eq.Plugin("autocombat"): state, settings, set, set_rows, command, catalog, spells).
--   Header: Start / Pause, the mode (Manual, Hunter, Assist; one the server turned off is greyed) and Manual's style
--           (Full, Partial), what it is doing.
--   Spells, Abilities: ordered rows; the first row that is ready and whose conditions hold fires. A row: what
--           (a memorized or book spell; an ability from the Ability Book), on whom, when, a recast, conditions.
--           The status column says why a row is not firing now.
--   Targeting, Hunter, Assist, Rest, General: the other settings. Log: the last things it did.
local hud = dofile("lib/hud.lua")
local K = dofile("lib/dialogs_kit.lua")
local T = hud.T
local C = T.color
local KEY = "AutoCombatWnd"

local P                          -- the script's functions (nil while it is not running)
local st = {}                    -- its state, read each frame
local S = nil                    -- its settings, read again when they change (rev)
local rev = -1
local cat = nil                  -- the conditions' catalog
local sel = { spells = nil, abilities = nil } -- the selected row of each page
local pick = { spells = "", abilities = "" }   -- the name pickers' filter text
local spellList, abilityList, abilityRead = nil, nil, -1
local imported = nil
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

local function rowEditor(list, row, rows, s)
  ui.Separator()
  caption(list == "spells" and "Spell" or "Ability")
  namePicker(list, row, rows, s)
  ui.SameLine()
  local on = check("Enabled##acen" .. list, row.enabled)
  if on ~= nil then row.enabled = on push(list, rows) end
  caption("On")
  ui.SameLine(70 * s)
  local to = combo("##acto" .. list, cat.targets, row.target, 170 * s)
  if to then row.target = to push(list, rows) end
  ui.SameLine()
  caption("When")
  ui.SameLine()
  local ph = combo("##acph" .. list, cat.phases, row.phase, 140 * s)
  if ph then row.phase = ph push(list, rows) end
  caption("Recast")
  ui.SameLine(70 * s)
  local rc = number("##acrc" .. list, row.recast or 0, 60 * s, 0, 3600)
  if rc then row.recast = rc push(list, rows) end
  tip("Seconds before this row fires again (0: as soon as it is ready)")
  ui.SameLine()
  local pt = check("for each target##acpt" .. list, row.per_target)
  if pt ~= nil then row.per_target = pt push(list, rows) end
  tip("Count the recast per fight target: a damage over time or a debuff, when the server does not send the target's buffs")
  caption("Conditions")
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
    if ui.Button("Import from Autoskill") then imported = P and P.command("import_autoskill") end
    tip("Adds the Ability Book's autoskill list here, with its conditions")
    if imported then
      ui.SameLine()
      ui.TextDisabled(imported == 0 and "nothing new to add" or (imported .. " added"))
    end
  else
    ui.SameLine()
    if ui.Button("Refresh spells") then spellList = P and P.spells(true) or nil end
    tip("Read the memorized spells and the spell book again")
  end
  local r = sel[list] and rows[sel[list]]
  if r then rowEditor(list, r, rows, s) end
end

-- ---------------------------------------------------------------- the other pages

local function targetingPage(s)
  local t = S.targeting
  caption("When several mobs are on you, fight")
  ui.SameLine(260 * s)
  local p = combo("##acprio", PRIORITIES, t.priority, 180 * s)
  if p then set("targeting.priority", p) end
  caption("Levels (0: any)")
  ui.SameLine(260 * s)
  local lo = number("##aclo", t.min_level, 60 * s, 0, 200)
  if lo then set("targeting.min_level", lo) end
  ui.SameLine()
  ui.Text("to")
  ui.SameLine()
  local hi = number("##achi", t.max_level, 60 * s, 0, 200)
  if hi then set("targeting.max_level", hi) end
  caption("Con colours it may choose")
  for i, c in ipairs(CONS) do
    if i > 1 then ui.SameLine() end
    local v = check(c[2] .. "##accon" .. c[1], t.cons[c[1]])
    if v ~= nil then set("targeting.cons." .. c[1], v) end
  end
  local n = check("Named mobs##acnamed", t.named)
  if n ~= nil then set("targeting.named", n) end
  caption("Never choose (names or parts of names, one per line)")
  local text, changed = ui.InputTextMultiline("##acignore", table.concat(t.ignore, "\n"), 4096, -1, 80 * s)
  if changed and P then
    local list = {}
    for line in (text .. "\n"):gmatch("([^\n]*)\n") do
      line = line:gsub("^%s+", ""):gsub("%s+$", "")
      if line ~= "" then list[#list + 1] = line end
    end
    P.set_ignore(list)
  end
  ui.TextDisabled("These choose mobs for Hunter. Mobs already fighting you are fought whatever they are.")
end

local function hunterPage(s)
  local h, t = S.hunter, S.targeting
  local style = combo("##achs", { { "roam", "Roam the zone" }, { "camp", "Pull back to a camp" } }, h.style, 200 * s)
  if style then set("hunter.style", style) end
  if h.style == "camp" then
    ui.SameLine()
    if ui.Button("Set camp here") then P.command("camp") end
    ui.SameLine()
    if h.camp then ui.TextDisabled(string.format("%s %.0f, %.0f", h.camp.zone or "", h.camp.y or 0, h.camp.x or 0))
    else ui.TextColored(C.gold[1], C.gold[2], C.gold[3], 1, "no camp yet") end
    caption("Leash (how far from camp)")
    ui.SameLine(260 * s)
    local l = number("##acleash", h.leash, 80 * s, 10, 5000)
    if l then set("hunter.leash", l) end
    caption("Pull with")
    ui.SameLine(260 * s)
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
    caption("Search radius")
    ui.SameLine(260 * s)
    local r = number("##acrad", t.radius, 80 * s, 10, 5000)
    if r then set("targeting.radius", r) end
    ui.TextDisabled("Mobs within the radius come first. With none there, it goes anywhere in the zone.")
  end
  caption("Height range")
  ui.SameLine(260 * s)
  local z = number("##aczr", t.zradius, 80 * s, 5, 1000)
  if z then set("targeting.zradius", z) end
  caption("Longest walk")
  ui.SameLine(260 * s)
  local mp = number("##acmp", h.max_path, 80 * s, 10, 10000)
  if mp then set("hunter.max_path", mp) end
  caption("Give up on a mob after (seconds)")
  ui.SameLine(260 * s)
  local g = number("##acgu", h.give_up, 80 * s, 5, 600)
  if g then set("hunter.give_up", g) end
  caption("Stop looking while this many are on you")
  ui.SameLine(260 * s)
  local mh = number("##acmh", h.max_haters, 80 * s, 0, 20)
  if mh then set("hunter.max_haters", mh) end
  local near = check("Leave mobs with another player near them##acnear", t.skip_near_players)
  if near ~= nil then set("targeting.skip_near_players", near) end
  if t.skip_near_players then
    ui.SameLine()
    local pr = number("##acpr", t.player_radius, 60 * s, 5, 500)
    if pr then set("targeting.player_radius", pr) end
  end
  ui.TextDisabled("Hunter needs the zone's navigation mesh (/nav). Your own movement keys stop a walk; pause to stop hunting.")
end

local function assistPage(s)
  local a = S.assist
  local who = combo("##acwho", { { "group", "The group's main assist" }, { "name", "This player" } }, a.who, 220 * s)
  if who then set("assist.who", who) end
  if a.who == "name" then
    ui.SameLine()
    ui.SetNextItemWidth(180 * s)
    local text, changed = ui.InputTextWithHint("##acan", "name", a.name, 64)
    if changed then set("assist.name", text) end
  end
  caption("Join when the target's health is at or below")
  local e = pct("##aceng", a.engage_pct, 220 * s)
  if e then set("assist.engage_pct", e) end
  local f = check("Follow the assist between fights##acfol", a.follow)
  if f ~= nil then set("assist.follow", f) end
  if a.follow then
    ui.SameLine()
    local d = number("##acfd", a.follow_distance, 60 * s, 5, 200)
    if d then set("assist.follow_distance", d) end
  end
end

local function restPage(s)
  local r = S.rest
  ui.TextDisabled("Out of combat it sits when one of these is below its mark, and stands when all are back.")
  for _, k in ipairs({ { "hp", "Health" }, { "mana", "Mana" }, { "endurance", "Endurance" } }) do
    caption(k[2] .. ": sit below")
    ui.SameLine(160 * s)
    local a = pct("##acsit" .. k[1], r["sit_" .. k[1]], 200 * s)
    if a then set("rest.sit_" .. k[1], a) end
    ui.SameLine()
    ui.Text("stand at")
    ui.SameLine()
    local b = pct("##acstand" .. k[1], r["stand_" .. k[1]], 200 * s)
    if b then set("rest.stand_" .. k[1], b) end
  end
  ui.Separator()
  caption("Pause Auto Combat when my health falls below")
  local sh = pct("##acstop", r.stop_hp, 220 * s)
  if sh then set("rest.stop_hp", sh) end
end

local function generalPage(s)
  local g = S.general
  local v = check("Melee: auto attack the fight target##acatk", g.attack)
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
  v = check("Send my pet on each new target##acpet", g.pet_attack)
  if v ~= nil then set("general.pet_attack", v) end
  v = check("Hold the Ability Book's autoskill while Auto Combat runs##achold", g.hold_autoskill)
  if v ~= nil then set("general.hold_autoskill", v) end
  caption("Seconds between two actions")
  ui.SameLine(260 * s)
  local gap = number("##acgap", g.action_gap, 60 * s, 0.1, 5)
  if gap then set("general.action_gap", gap) end
end

local function logPage()
  for i = #(st.log or {}), 1, -1 do ui.Text(st.log[i]) end
end

-- ---------------------------------------------------------------- the window

describe = function(c)
  local who = label(cat.subjects, c.who)
  local prop
  for _, p in ipairs(cat.properties[c.who] or {}) do if p.id == c.what then prop = p end end
  if not prop then return "?" end
  if prop.kind == "bool" then return who .. " " .. c.op .. " " .. prop.label:lower() end
  if prop.kind == "buff" then return who .. " " .. c.op .. " " .. tostring(c.value) end
  return who .. " " .. prop.label .. " " .. c.op .. " " .. tostring(c.value)
end

local function header(s)
  local running = st.running
  local a = running and C.danger or C.accent
  ui.PushStyleColor(ui.Col.Button, a[1], a[2], a[3], 0.30)
  ui.PushStyleColor(ui.Col.ButtonHovered, a[1], a[2], a[3], 0.45)
  ui.PushStyleColor(ui.Col.ButtonActive, a[1], a[2], a[3], 0.60)
  if ui.Button(running and "Pause##acgo" or "Start##acgo", 90 * s, 0) then P.command(running and "pause" or "start") end
  ui.PopStyleColor(3)
  ui.SameLine()
  local off = {}
  for k, v in pairs(st.allowed or {}) do off[k] = v == false end
  local m = combo("##acmode", MODES, S.mode, 120 * s, off)
  if m then set("mode", m) end
  if S.mode == "manual" then
    ui.SameLine()
    local sty = combo("##acstyle", STYLES, S.style, 110 * s)
    if sty then set("style", sty) end
    tip("Full: it targets the mobs on you and keeps in range. Partial: you pick the mob and position yourself.")
  end
  ui.SameLine()
  local c = running and C.good or C.muted
  ui.TextColored(c[1], c[2], c[3], 1, st.status or "")
  if st.last and st.last ~= "" then
    ui.SameLine()
    ui.TextDisabled("  " .. st.last)
  end
end

ui.window("Auto Combat", function()
  P = eq.Plugin("autocombat")
  if not P or not eq.InGame() then return end
  st = P.state() or {}
  if not st.open then return end
  if st.rev ~= rev or not S then
    S = P.settings()
    rev = st.rev
  end
  cat = cat or P.catalog()
  if not S or not cat then return end
  hud.Dialog(KEY, "Auto Combat", {
    shown = true,
    keepTitle = true,
    size = function() return 780, 560 end,
    resizable = { 620, 420 },
    place = K.Centered,
    onClose = function() P.command("close") end,
  }, function(x, y, w, h, s)
    header(s)
    if ui.BeginTabBar("##actabs", 0) then
      local _, cy = ui.GetCursorScreenPos()
      local pageH = (y + h) - cy - 30 * s
      if ui.BeginTabItem("Spells") then rowsPage("spells", s, pageH) ui.EndTabItem() end
      if ui.BeginTabItem("Abilities") then rowsPage("abilities", s, pageH) ui.EndTabItem() end
      if ui.BeginTabItem("Targeting") then targetingPage(s) ui.EndTabItem() end
      if ui.BeginTabItem("Hunter") then hunterPage(s) ui.EndTabItem() end
      if ui.BeginTabItem("Assist") then assistPage(s) ui.EndTabItem() end
      if ui.BeginTabItem("Rest") then restPage(s) ui.EndTabItem() end
      if ui.BeginTabItem("General") then generalPage(s) ui.EndTabItem() end
      if ui.BeginTabItem("Log") then logPage() ui.EndTabItem() end
      ui.EndTabBar()
    end
  end)
end)
