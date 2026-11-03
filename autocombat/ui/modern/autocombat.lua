-- Auto Combat's windows for the Modern pack. The script (../../init.lua) keeps the settings and runs the fight; these
-- show its state and edit the settings through the script's functions (eq.Plugin("autocombat"): state, settings,
-- set, set_rows, set_ignore, command, catalog, row_for_spell).
--   The compact window (opens with the script; /autocombat, or the EQ menu's Plugins > Auto Combat): the mode (Manual,
--           Hunter, Assist; one the server turned off is greyed) and Manual's style (Full, Partial), Start / Pause,
--           what it is doing and the last thing it did. Its gear opens the settings.
--   The settings window (/autocombat settings): a page list down the left.
--     Spells, Abilities: the rotation, ordered rows as icon tiles (drag to reorder, a switch on each, a right-click
--           menu); the first row that is ready and whose conditions hold fires. Each tile says why it is not firing
--           while Auto Combat runs. The selected row at the right: its spell or ability as the books show it (icon,
--           cost, cast, recast, range or reuse; Info opens the spell display), then on whom, when, a recast and the
--           conditions. "+ Add" and "Change" pick from the spell book or the Ability Book (eq.SpellBook,
--           eq.AbilityBook) as icon tiles, with a search and filters.
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

-- ---------------------------------------------------------------- the books: what can be put on a row
-- The Spell Book's and the Ability Book's own lists (eq.SpellBook, eq.AbilityBook), read again every two seconds:
-- the picker shows them, and a row shows its spell's or ability's icon and numbers from them.
local KINDS = { aa = "Alternate ability", disc = "Combat ability", skill = "Skill" }
local KIND_SHORT = { aa = "AA", disc = "Combat", skill = "Skill" }
local KIND_ORDER = { aa = 1, disc = 2, skill = 3 }
local DOT = "  \xC2\xB7  "

local book = { spells = {}, abilities = {}, byName = {}, byKey = {}, read = -1 }

local function lower(t) return (t or ""):lower() end

local function readBooks(force)
  if not force and ui.GetTime() - book.read < 2 then return end
  book.read = ui.GetTime()
  book.spells, book.byName = {}, {}
  for _, e in ipairs(eq.SpellBook() or {}) do
    book.spells[#book.spells + 1] = e
    book.byName[lower(e.name)] = e
  end
  table.sort(book.spells, function(a, b)
    if a.level ~= b.level then return a.level > b.level end
    return a.name < b.name
  end)
  book.abilities, book.byKey = {}, {}
  for _, a in ipairs(eq.AbilityBook() or {}) do
    if not a.passive then
      book.abilities[#book.abilities + 1] = a
      book.byKey[a.kind .. ":" .. lower(a.name)] = a
    end
  end
  table.sort(book.abilities, function(a, b)
    if a.kind ~= b.kind then return (KIND_ORDER[a.kind] or 9) < (KIND_ORDER[b.kind] or 9) end
    return a.name < b.name
  end)
end

-- The book's entry for a row (nil: not in the book, or no longer).
local function entryOf(list, r)
  if list == "spells" then return book.byName[lower(r.name)] end
  return book.byKey[(r.kind or "") .. ":" .. lower(r.name)]
end

-- Seconds as "2.5s", "12s", "1m 30s"; 0 or less as "-".
local function seconds(v)
  v = tonumber(v) or 0
  if v <= 0 then return "-" end
  if v < 10 then return (string.format("%.1f", v):gsub("%.0$", "")) .. "s" end
  if v < 60 then return string.format("%ds", math.floor(v + 0.5)) end
  local m = math.floor(v / 60)
  local r = math.floor(v - m * 60 + 0.5)
  return r > 0 and string.format("%dm %ds", m, r) or string.format("%dm", m)
end

-- A spell or ability icon in a well, as the books draw it; an ability's reuse still to go shades it from the bottom.
local function icon(e, name, x, y, size, s, ring, alpha)
  alpha = alpha or 1
  local tex, u0, v0, u1, v1
  if e and e.icon and e.icon >= 0 then tex, u0, v0, u1, v1 = eq.SpellIcon(e.icon) end
  T.Icon(x, y, size, s, tex, u0, v0, u1, v1, ring, { radius = 5, alpha = alpha })
  if not tex then
    local _, th = T.TextSize("Ag", T.font.small)
    T.Text(x + size / 2, y + (size - th) / 2, (name ~= "" and name or "?"):sub(1, 2), C.muted, T.font.small, "center",
      alpha)
  end
  if e and (e.remaining or 0) > 0 and (e.reuse or 0) > 0 then
    local f = math.min(1, e.remaining / e.reuse)
    ui.DrawRectFilled(x, y + size * (1 - f), x + size, y + size, 0, 0, 0, 0.5 * alpha, 5 * s)
  end
end

-- A small rounded label, right-aligned at xr; returns its width.
local function pill(xr, y, text, col, s, alpha)
  local tw, th = T.TextSize(text, T.font.tiny)
  local x0 = xr - tw - 12 * s
  ui.DrawRectFilled(x0, y, xr, y + th + 4 * s, col[1], col[2], col[3], 0.16 * (alpha or 1), (th + 4 * s) / 2)
  T.Text(x0 + 6 * s, y + 2 * s, text, col, T.font.tiny, nil, alpha)
  return tw + 12 * s
end

-- Burn mode's colour, and a small flame drawn in it.
local BURN = { 1.0, 0.50, 0.14, 1 }

local function flame(cx, cy, size, col, alpha)
  local r = size * 0.32
  ui.DrawCircleFilled(cx, cy + size * 0.18, r, col[1], col[2], col[3], alpha)
  ui.DrawTriangleFilled(cx - r * 0.98, cy + size * 0.12, cx + r * 0.98, cy + size * 0.12, cx + size * 0.05,
    cy - size * 0.5, col[1], col[2], col[3], alpha)
end

-- An on / off switch over a hit box drawn just before it.
local function switch(x0, y0, x1, y1, on, hovered, s, alpha)
  local rad = (y1 - y0) / 2
  local a = on and C.accent or C.ink
  ui.DrawRectFilled(x0, y0, x1, y1, a[1], a[2], a[3], (on and 0.75 or 0.16) * alpha, rad)
  if hovered then ui.DrawRect(x0, y0, x1, y1, C.accent[1], C.accent[2], C.accent[3], 0.8 * alpha, rad, 1) end
  local kx = on and (x1 - rad) or (x0 + rad)
  ui.DrawCircleFilled(kx, (y0 + y1) / 2, rad - 2.5 * s, 1, 1, 1, (on and 0.95 or 0.6) * alpha)
end

-- A filter chip; returns clicked and its width.
local function chip(id, x, y, text, on, s)
  local tw = T.TextSize(text, T.font.small)
  local w, h = tw + 18 * s, 24 * s
  local clicked = T.Hit(id, x, y, x + w, y + h)
  local hov = ui.IsItemHovered()
  local a = C.accent
  if on then
    ui.DrawRectFilled(x, y, x + w, y + h, a[1], a[2], a[3], 0.22, h / 2)
    ui.DrawRect(x, y, x + w, y + h, a[1], a[2], a[3], 0.7, h / 2, 1)
  else
    ui.DrawRectFilled(x, y, x + w, y + h, C.ink[1], C.ink[2], C.ink[3], hov and 0.08 or 0.04, h / 2)
  end
  local _, th = T.TextSize("Ag", T.font.small)
  T.Text(x + w / 2, y + (h - th) / 2, text, (on or hov) and C.text or C.muted, T.font.small, "center")
  return clicked, w
end

-- The cost of a spell or ability: "120 mana", "40 end", "-".
local function cost(e)
  if not e then return "-" end
  local parts = {}
  if (e.mana or 0) > 0 then parts[#parts + 1] = e.mana .. " mana" end
  if (e.endurance or 0) > 0 then parts[#parts + 1] = e.endurance .. " end" end
  return #parts > 0 and table.concat(parts, ", ") or "-"
end

-- ---------------------------------------------------------------- the rows

local function push(list, rows)
  if P then P.set_rows(list, rows) end
  S[list] = rows
end

local function moveRow(list, rows, from, to)
  if to < 1 or to > #rows or to == from then return end
  local r = table.remove(rows, from)
  table.insert(rows, to, r)
  sel[list] = to
  push(list, rows)
end

-- A row as one line: on whom, when, the recast and the conditions.
local function summary(r)
  local parts = { label(cat.targets, r.target), label(cat.phases, r.phase) }
  if (r.recast or 0) > 0 then parts[#parts + 1] = "every " .. seconds(r.recast) .. (r.per_target and " each" or "") end
  local n = #r.conditions
  if n == 1 then parts[#parts + 1] = describe(r.conditions[1])
  elseif n > 1 then parts[#parts + 1] = n .. " conditions" end
  return table.concat(parts, DOT)
end

-- The picker: the spell book or the Ability Book as icon tiles, with a search and filter chips.
local picker = { want = nil, replace = nil, search = "", filter = { spells = "all", abilities = "all" } }
local FILTERS = {
  spells = { { "all", "All" }, { "gems", "Memorized" }, { "good", "Beneficial" }, { "bad", "Detrimental" } },
  abilities = { { "all", "All" }, { "aa", "AAs" }, { "disc", "Combat" }, { "skill", "Skills" } },
}

local function matches(list, e, f, filter)
  if f ~= "" and not lower(e.name):find(f, 1, true) and not lower(e.categoryName):find(f, 1, true)
      and not lower(e.subcategoryName):find(f, 1, true) then
    return false
  end
  if list == "spells" then
    if filter == "gems" then return e.gem ~= nil end
    if filter == "good" then return e.beneficial end
    if filter == "bad" then return not e.beneficial end
    return true
  end
  return filter == "all" or e.kind == filter
end

local function choose(list, rows, e)
  local i = picker.replace
  if i and rows[i] then
    rows[i].name = e.name
    rows[i].kind = list == "spells" and "spell" or e.kind
  else
    local row = list == "spells" and P.row_for_spell(e.name) or nil
    if not row then
      local mine = list == "abilities" and e.beneficial
      row = { enabled = true, kind = list == "spells" and "spell" or e.kind, name = e.name,
        target = mine and "self" or "enemy", phase = "combat", recast = 0, per_target = false, conditions = {} }
    end
    rows[#rows + 1] = row
    sel[list] = #rows
  end
  push(list, rows)
end

local function pickerBody(list, rows, s)
  local x, y = ui.GetCursorScreenPos()
  local pw, ph = 580 * s, 420 * s
  ui.SetNextItemWidth(210 * s)
  picker.search = ui.InputTextWithHint("##acpicksearch", list == "spells" and "Search spells" or "Search abilities",
    picker.search, 64)
  local fx = x + 220 * s
  for _, f in ipairs(FILTERS[list]) do
    local clicked, cw = chip("##acpf" .. f[1], fx, y, f[2], picker.filter[list] == f[1], s)
    if clicked then picker.filter[list] = f[1] end
    fx = fx + cw + 4 * s
  end
  ui.SetCursorScreenPos(x, y + 32 * s)
  local inRotation = {}
  for _, r in ipairs(rows) do inRotation[(list == "spells" and "spell" or r.kind) .. ":" .. lower(r.name)] = true end
  local f, filter = lower(picker.search), picker.filter[list]
  local all = list == "spells" and book.spells or book.abilities
  ui.BeginChild("##acpickgrid", pw, ph, false)
  local cw = ui.GetContentRegionAvail()
  local cellW, cellH = (cw - 6 * s) / 2, 44 * s
  local _, th = T.TextSize("Ag", T.font.small)
  local n, chosen = 0, nil
  for _, e in ipairs(all) do
    if matches(list, e, f, filter) then
      if n % 2 == 1 then ui.SameLine(0, 6 * s) end
      n = n + 1
      local px, py = ui.GetCursorScreenPos()
      if ui.InvisibleButton("##acpk" .. n, cellW, cellH) then chosen = e end
      local hovered = ui.IsItemHovered()
      local have = inRotation[(list == "spells" and "spell" or e.kind) .. ":" .. lower(e.name)]
      ui.DrawRectFilled(px, py, px + cellW, py + cellH, C.ink[1], C.ink[2], C.ink[3], hovered and 0.09 or 0.035, 6 * s)
      if hovered then
        ui.DrawRect(px, py, px + cellW, py + cellH, C.accent[1], C.accent[2], C.accent[3], 0.8, 6 * s, 1)
      end
      local isz = cellH - 8 * s
      icon(e, e.name, px + 4 * s, py + 4 * s, isz, s, have and C.accent or nil)
      local nx = px + isz + 12 * s
      local room = px + cellW - nx - 8 * s
      T.Text(nx, py + 5 * s, T.Fit(e.name, room, T.font.small), C.text, T.font.small)
      local sub
      if list == "spells" then
        sub = "Level " .. e.level
        if e.gem then sub = sub .. DOT .. "gem " .. (e.gem + 1) end
        if (e.subcategoryName or "") ~= "" then sub = sub .. DOT .. e.subcategoryName end
      else
        sub = KIND_SHORT[e.kind] or e.kind
        if (e.reuse or 0) > 0 then sub = sub .. DOT .. seconds(e.reuse) end
      end
      T.Text(nx, py + 7 * s + th, T.Fit(sub, room, T.font.tiny), C.faint, T.font.tiny)
      if hovered then
        ui.SetTooltip(e.name .. "\n" .. cost(e) .. (have and "\nAlready in the rotation" or "")
          .. (picker.replace and "\nClick: put it on this row" or "\nClick: add it to the rotation"))
      end
    end
  end
  if n == 0 then
    T.Text(x + 8 * s, y + 44 * s, #all == 0 and (list == "spells" and "Your spell book is empty."
      or "You have no abilities to use yet.") or "Nothing matches.", C.muted, T.font.small)
  end
  ui.EndChild()
  if chosen then
    choose(list, rows, chosen)
    ui.CloseCurrentPopup()
  end
end

-- The rotation: a tile for each row, in order; drag one to move it, click its switch to turn it on or off.
local TILE_H = 52
local drag = { list = nil, from = nil }

local function rotation(list, rows, w, h, s)
  ui.BeginChild("##aclist" .. list, w, h, false)
  local status = (st.rows or {})[list] or {}
  local x0, y0 = ui.GetCursorScreenPos()
  local cw = ui.GetContentRegionAvail()
  local pitch = (TILE_H + 6) * s
  local tileH = TILE_H * s
  local _, th = T.TextSize("Ag", T.font.small)
  local _, hn = T.TextSize("Ag", T.font.normal)
  local _, my = ui.GetMousePos()
  local dragging = drag.list == list and drag.from ~= nil
  local dropAt = dragging and math.max(1, math.min(#rows + 1, math.floor((my - y0) / pitch + 0.5) + 1)) or nil
  local menuFor = nil
  for i, r in ipairs(rows) do
    local ty = y0 + (i - 1) * pitch
    local tx1 = x0 + cw
    local e = entryOf(list, r)
    if T.Hit("##actile" .. i, x0, ty, tx1, ty + tileH) then sel[list] = i end
    local hovered, active = ui.IsItemHovered(), ui.IsItemActive()
    if ui.IsItemClicked(ui.Mouse.Right) then
      sel[list] = i
      menuFor = i
      T.TakeRightClick()
    end
    if active and not dragging and ui.IsMouseDragging(ui.Mouse.Left) then drag.list, drag.from = list, i end
    local swx1 = tx1 - 10 * s
    local swx0, swy0 = swx1 - 30 * s, ty + 9 * s
    local swy1 = swy0 + 16 * s
    if T.Hit("##acon" .. i, swx0, swy0, swx1, swy1) then
      r.enabled = not r.enabled
      push(list, rows)
    end
    local swHover = ui.IsItemHovered()
    if swHover then ui.SetTooltip(r.enabled and "On: click to skip this row" or "Off: click to use this row again") end

    local alpha = (dragging and drag.from == i) and 0.35 or 1
    local a = C.accent
    if sel[list] == i then
      ui.DrawRectFilled(x0, ty, tx1, ty + tileH, a[1], a[2], a[3], 0.16 * alpha, 7 * s)
      ui.DrawRect(x0, ty, tx1, ty + tileH, a[1], a[2], a[3], 0.6 * alpha, 7 * s, 1)
    else
      ui.DrawRectFilled(x0, ty, tx1, ty + tileH, C.ink[1], C.ink[2], C.ink[3], (hovered and 0.075 or 0.035) * alpha,
        7 * s)
    end
    local dim = (r.enabled and 1 or 0.45) * alpha
    T.Text(x0 + 13 * s, ty + (tileH - th) / 2, tostring(i), C.faint, T.font.small, "center", alpha)
    local isz = tileH - 14 * s
    icon(e, r.name, x0 + 26 * s, ty + 7 * s, isz, s, nil, dim)
    local nx = x0 + 26 * s + isz + 10 * s
    local nameEnd = swx0 - 8 * s
    if r.burn then
      -- burn-only: a flame, lit while burn mode is on
      local lit = st.burn and (0.6 + 0.4 * math.sin(ui.GetTime() * 7)) or 0.55
      flame(swx0 - 14 * s, ty + 17 * s, 13 * s, BURN, lit * dim)
      nameEnd = swx0 - 26 * s
    end
    T.Text(nx, ty + 7 * s, T.Fit(r.name, nameEnd - nx, T.font.normal), C.text, T.font.normal, nil, dim)
    switch(swx0, swy0, swx1, swy1, r.enabled, swHover, s, alpha)
    -- what it is doing now, at the right of the second line
    local ly = ty + 9 * s + hn
    local pw = 0
    if not e then
      pw = pill(swx1, ly, list == "spells" and "not in your book" or "not in the Ability Book", C.danger, s, alpha)
    elseif st.running and r.enabled then
      local why = status[i]
      if why == "" then pw = pill(swx1, ly, "ready", C.good, s, alpha)
      elseif why then pw = pill(swx1, ly, T.Fit(why, 120 * s, T.font.tiny), C.muted, s, alpha) end
    end
    T.Text(nx, ly, T.Fit(summary(r), swx1 - pw - nx - 8 * s, T.font.small), C.muted, T.font.small, nil, dim)
    if hovered and not dragging and not swHover and #r.conditions > 0 then
      local lines = { "Fires when:" }
      for _, c in ipairs(r.conditions) do lines[#lines + 1] = "  " .. describe(c) end
      ui.SetTooltip(table.concat(lines, "\n"))
    end
  end
  if dragging then
    local ly = y0 + (dropAt - 1) * pitch - 3 * s
    ui.DrawLine(x0 + 4 * s, ly, x0 + cw - 4 * s, ly, C.accent[1], C.accent[2], C.accent[3], 1, 2.5 * s)
    if not ui.IsMouseDown(ui.Mouse.Left) then
      local from = drag.from
      drag.list, drag.from = nil, nil
      if rows[from] then moveRow(list, rows, from, dropAt > from and dropAt - 1 or dropAt) end
    end
  end
  if #rows == 0 then
    local _, hl = T.TextSize("Ag", T.font.large)
    T.Text(x0 + cw / 2, y0 + 40 * s, list == "spells" and "No spells yet" or "No abilities yet", C.muted, T.font.large,
      "center")
    T.Text(x0 + cw / 2, y0 + 48 * s + hl, list == "spells" and "Add one from your spell book, or import your spell bar."
      or "Add one from the Ability Book, or import autoskill.", C.faint, T.font.small, "center")
  end
  ui.SetCursorScreenPos(x0, y0 + math.max(#rows, 1) * pitch)
  ui.Dummy(1, 1)

  if menuFor then ui.OpenPopup("##acrowmenu") end
  if ui.BeginPopup("##acrowmenu") then
    local i = sel[list]
    local r = i and rows[i]
    if r then
      if ui.MenuItem("Change " .. (list == "spells" and "spell" or "ability") .. "...") then
        picker.want, picker.replace = list, i
      end
      if ui.MenuItem(r.enabled and "Turn off" or "Turn on") then r.enabled = not r.enabled push(list, rows) end
      ui.Separator()
      if ui.MenuItem("Move to top", false, i > 1) then moveRow(list, rows, i, 1) end
      if ui.MenuItem("Move up", false, i > 1) then moveRow(list, rows, i, i - 1) end
      if ui.MenuItem("Move down", false, i < #rows) then moveRow(list, rows, i, i + 1) end
      if ui.MenuItem("Move to bottom", false, i < #rows) then moveRow(list, rows, i, #rows) end
      ui.Separator()
      if ui.MenuItem("Duplicate") then
        table.insert(rows, i + 1, copy(r))
        sel[list] = i + 1
        push(list, rows)
      end
      if ui.MenuItem("Remove") then
        table.remove(rows, i)
        sel[list] = nil
        push(list, rows)
      end
    end
    ui.EndPopup()
  end
  ui.EndChild()
end

-- A new condition on this property, with its defaults (catalog.condition_for, which the window cannot call).
local function fresh(who, p)
  local op = cat.ops[p.kind][1]
  if p.kind == "count" then op = p.default == 0 and "<=" or ">=" end
  return { who = who, what = p.id, op = op, value = p.default, radius = p.radius }
end

local function conditionEditor(list, row, rows, s)
  local remove = nil
  local avail = ui.GetContentRegionAvail()
  local gap = 4 * s
  local wWho, wWhat, wOp = avail * 0.24, avail * 0.33, avail * 0.13
  local wVal = avail - wWho - wWhat - wOp - 4 * gap - 24 * s
  for i, c in ipairs(row.conditions) do
    ui.PushID("accond" .. i)
    local who = combo("##who", cat.subjects, c.who, wWho)
    if who and who ~= c.who then
      row.conditions[i] = fresh(who, cat.properties[who][1])
      push(list, rows)
    end
    ui.SameLine(0, gap)
    local props = cat.properties[c.who] or {}
    local what = combo("##what", props, c.what, wWhat)
    local prop
    for _, p in ipairs(props) do if p.id == (what or c.what) then prop = p end end
    if what and what ~= c.what and prop then
      row.conditions[i] = fresh(c.who, prop)
      c = row.conditions[i]
      push(list, rows)
    end
    if prop then
      ui.SameLine(0, gap)
      local ops = {}
      for _, o in ipairs(cat.ops[prop.kind]) do ops[#ops + 1] = { o, o } end
      local op = combo("##op", ops, c.op, prop.kind == "bool" and (wOp + wVal + gap) or wOp)
      if op then c.op = op push(list, rows) end
      if prop.kind == "buff" then
        ui.SameLine(0, gap)
        ui.SetNextItemWidth(wVal)
        local text, changed = ui.InputTextWithHint("##val", "buff name", c.value or "", 64)
        if changed then c.value = text push(list, rows) end
      elseif prop.kind == "count" then
        -- how many, and within what distance of the subject
        ui.SameLine(0, gap)
        local v = number("##val", c.value or 0, 40 * s, 0, 100)
        if v then c.value = v push(list, rows) end
        tip("How many mobs")
        ui.SameLine(0, gap)
        local cx, cy = ui.GetCursorPos()
        ui.SetCursorPos(cx, cy + 3 * s)
        caption("in")
        ui.SameLine(0, gap)
        ui.SetCursorPos(ui.GetCursorPos(), cy)
        local rad = number("##rad", c.radius or prop.radius or 30, math.max(36 * s, wVal - 40 * s - T.TextSize("in", T.font.small) - 2 * gap), 1, 300)
        if rad then c.radius = rad push(list, rows) end
        tip("Within this distance of " .. (c.who == "me" and "you" or "the target")
          .. " (a spell's AE range is in its Info window)")
      elseif prop.kind ~= "bool" then
        ui.SameLine(0, gap)
        local v = number("##val", c.value or 0, wVal)
        if v then c.value = v push(list, rows) end
      end
    end
    ui.SameLine(0, gap)
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

-- The selected row: its spell or ability as the book shows it (icon, numbers), then what makes it fire.
local function details(list, rows, x, y, w, h, s)
  ui.SetCursorScreenPos(x, y)
  ui.BeginChild("##acdetail" .. list, w, h, false)
  local i = sel[list]
  local r = i and rows[i]
  local px, py = ui.GetCursorScreenPos()
  local cw = ui.GetContentRegionAvail()
  if not r then
    if #rows > 0 then T.Text(px + 6 * s, py + 10 * s, "Select a row to see it and change it.", C.muted, T.font.small) end
    ui.EndChild()
    return
  end
  local e = entryOf(list, r)
  -- the card
  local cardH = 118 * s
  ui.DrawRectFilled(px, py, px + cw, py + cardH, C.ink[1], C.ink[2], C.ink[3], 0.04, 8 * s)
  ui.DrawRect(px, py, px + cw, py + cardH, C.ink[1], C.ink[2], C.ink[3], 0.08, 8 * s, 1)
  local isz = 48 * s
  icon(e, r.name, px + 10 * s, py + 10 * s, isz, s, C.accent)
  local nx = px + isz + 20 * s
  local bw = 70 * s
  local infoId = e and (list == "spells" and e.id or ((e.spell or 0) > 0 and e.spell)) or nil
  local bx1 = px + cw - 10 * s
  if T.Button("##acchange", bx1 - bw, py + 10 * s, bx1, py + 34 * s, s, "Change", {
        tooltip = "Pick another " .. (list == "spells" and "spell from your spell book" or "ability from the Ability Book") }) then
    picker.want, picker.replace = list, i
  end
  if infoId then
    if T.Button("##acinfo", bx1 - 2 * bw - 6 * s, py + 10 * s, bx1 - bw - 6 * s, py + 34 * s, s, "Info",
          { tooltip = "The spell's display window" }) then
      eq.ShowSpell(infoId)
    end
  end
  local room = bx1 - (infoId and (2 * bw + 6 * s) or bw) - nx - 8 * s
  local _, hl = T.TextSize("Ag", T.font.large)
  T.Text(nx, py + 10 * s, T.Fit(r.name, room, T.font.large), C.text, T.font.large)
  local sub
  if list == "spells" then
    if e then
      sub = "Level " .. e.level
      if (e.subcategoryName or "") ~= "" then sub = sub .. DOT .. e.subcategoryName end
      sub = sub .. DOT .. (e.gem and ("gem " .. (e.gem + 1)) or "not memorized")
    else
      sub = "Not in your spell book"
    end
  else
    sub = e and ((KINDS[e.kind] or e.kind) .. ((e.level or 0) > 0 and (DOT .. "level " .. e.level) or ""))
      or "Not in your Ability Book"
  end
  T.Text(nx, py + 14 * s + hl, T.Fit(sub, room, T.font.small), (e and (list ~= "spells" or e.gem)) and C.muted or C.danger,
    T.font.small)
  local tiles
  if list == "spells" then
    tiles = { { "Cost", cost(e) }, { "Cast", e and seconds(e.castTime / 1000) or "-" },
      { "Recast", e and seconds(e.recastTime / 1000) or "-" },
      { "Range", e and (e.range > 0 and string.format("%.0f", e.range) or "self") or "-" } }
  else
    tiles = { { "Cost", cost(e) }, { "Reuse", e and seconds(e.reuse) or "-" },
      { "Ready", e and (e.ready and "Now" or seconds(e.remaining)) or "-" } }
  end
  local ty = py + 66 * s
  local tw = (cw - 20 * s - (#tiles - 1) * 6 * s) / #tiles
  for k, t in ipairs(tiles) do
    local tx = px + 10 * s + (k - 1) * (tw + 6 * s)
    ui.DrawRectFilled(tx, ty, tx + tw, ty + 42 * s, C.inset[1], C.inset[2], C.inset[3], C.inset[4] * 0.8, 6 * s)
    T.Text(tx + tw / 2, ty + 5 * s, t[1], C.faint, T.font.tiny, "center")
    T.Text(tx + tw / 2, ty + 20 * s, T.Fit(t[2], tw - 6 * s, T.font.small), C.text, T.font.small, "center")
  end

  -- what makes it fire
  ui.SetCursorScreenPos(px, py + cardH + 4 * s)
  local col = 96
  local wide = math.min(240 * s, cw - col * s)
  section("Firing", s)
  field("On", s, col)
  local to = combo("##acto" .. list, cat.targets, r.target, wide)
  if to then r.target = to push(list, rows) end
  field("When", s, col)
  local ph = combo("##acph" .. list, cat.phases, r.phase, wide)
  if ph then r.phase = ph push(list, rows) end
  field("Recast", s, col)
  local rc = number("##acrc" .. list, r.recast or 0, 64 * s, 0, 3600)
  if rc then r.recast = rc push(list, rows) end
  tip("Seconds before this row fires again (0: as soon as it is ready)")
  ui.SameLine()
  local pt = check("for each target##acpt" .. list, r.per_target)
  if pt ~= nil then r.per_target = pt push(list, rows) end
  tip("Count the recast per fight target: a damage over time or a debuff, when the server does not send the target's buffs")
  field("Burn", s, col)
  local bu = check("Only during burn##acbu" .. list, r.burn)
  if bu ~= nil then r.burn = bu push(list, rows) end
  tip("Fires only while burn mode is on (the compact window's Burn, /autocombat burn): your big discs, AAs and nukes")
  section("Conditions", s)
  if #r.conditions == 0 then note("None: it fires whenever it is ready.") end
  conditionEditor(list, r, rows, s)
  ui.Dummy(0, 10 * s)
  if ui.Button("Remove this row") then
    table.remove(rows, i)
    sel[list] = nil
    push(list, rows)
  end
  ui.EndChild()
end

local function rowsPage(list, s, h)
  readBooks(false)
  local rows = S[list]
  local x, y = ui.GetCursorScreenPos()
  local w = ui.GetContentRegionAvail()
  local spells = list == "spells"
  -- the toolbar
  local bh = 28 * s
  local bx = x
  if T.Button("##acadd" .. list, bx, y, bx + 112 * s, y + bh, s, spells and "+ Add spell" or "+ Add ability",
        { primary = true, tooltip = spells and "Pick one from your spell book" or "Pick one from the Ability Book" }) then
    picker.want, picker.replace = list, nil
  end
  bx = bx + 118 * s
  if T.Button("##acimport" .. list, bx, y, bx + 128 * s, y + bh, s, spells and "Import spell bar" or "Import autoskill", {
        tooltip = spells and ("Adds a row for each memorized spell, in gem order: harmful ones on the fight target in"
          .. " combat, buffs on you when you lack them, heals on you under 60% health. Change them to suit.")
          or "Adds the Ability Book's autoskill list here, with its conditions" }) then
    imported[list] = P and P.command(spells and "import_spellbar" or "import_autoskill")
  end
  bx = bx + 136 * s
  local _, th = T.TextSize("Ag", T.font.small)
  if imported[list] then
    T.Text(bx, y + (bh - th) / 2, imported[list] == 0 and "nothing new to add" or (imported[list] .. " added"), C.faint,
      T.font.small)
  end
  if #rows > 1 then
    T.Text(x + w, y + (bh - th) / 2, "first ready row fires; drag to reorder", C.faint, T.font.small, "right")
  end
  -- the rotation at the left, the selected row at the right
  local top = y + bh + 10 * s
  local bodyH = h - (top - y) - 4 * s
  local listW = math.max(260 * s, math.floor(w * 0.44))
  ui.SetCursorScreenPos(x, top)
  rotation(list, rows, listW, bodyH, s)
  details(list, rows, x + listW + 14 * s, top, w - listW - 14 * s, bodyH, s)
  -- the picker
  if picker.want == list then
    picker.want, picker.search = nil, ""
    readBooks(true)
    ui.OpenPopup("##acpick" .. list)
  end
  if ui.BeginPopup("##acpick" .. list) then
    pickerBody(list, rows, s)
    ui.EndPopup()
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

-- ---------------------------------------------------------------- the extended target window
-- The pack's extended target window (lib/xtarget.lua), covered by this one of the same name, with Force and Ignore on
-- each mob: a forced mob gets a pulsing gold outline and FORCED, an ignored one is faded, struck through and IGNORED.
-- An older client without lib/xtarget.lua keeps its own window.
local FORCE = { 1.0, 0.78, 0.25, 1 }
local MARK_W = 52 -- the buttons' part of a row (unscaled)

-- A crosshair (force) or a circle with a bar through it (ignore), in a round button. Returns clicked.
local function markButton(id, kind, x, y, size, s, on, tipText)
  local clicked = T.Hit(id, x, y, x + size, y + size)
  local hovered, active = ui.IsItemHovered(), ui.IsItemActive()
  local col = kind == "force" and FORCE or C.danger
  local cx, cy, r = x + size / 2, y + size / 2, size / 2
  if on then
    ui.DrawCircleFilled(cx, cy, r, col[1], col[2], col[3], active and 0.7 or 0.9)
  else
    ui.DrawCircleFilled(cx, cy, r, C.ink[1], C.ink[2], C.ink[3], active and 0.18 or (hovered and 0.12 or 0.06))
    if hovered then ui.DrawCircle(cx, cy, r - 0.5 * s, col[1], col[2], col[3], 0.8, 1.2 * s) end
  end
  local ic = on and { 0.08, 0.08, 0.1, 1 } or (hovered and col or C.muted)
  local ir = r * 0.48
  if kind == "force" then
    ui.DrawCircle(cx, cy, ir, ic[1], ic[2], ic[3], 1, 1.4 * s)
    for _, d in ipairs({ { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 } }) do
      ui.DrawLine(cx + d[1] * ir * 0.45, cy + d[2] * ir * 0.45, cx + d[1] * ir * 1.45, cy + d[2] * ir * 1.45,
        ic[1], ic[2], ic[3], 1, 1.4 * s)
    end
  else
    ui.DrawCircle(cx, cy, ir, ic[1], ic[2], ic[3], 1, 1.5 * s)
    ui.DrawLine(cx - ir * 0.7, cy + ir * 0.7, cx + ir * 0.7, cy - ir * 0.7, ic[1], ic[2], ic[3], 1, 1.5 * s)
  end
  if hovered then ui.SetTooltip(tipText) end
  return clicked
end

local xtOk, xtarget = pcall(dofile, "lib/xtarget.lua")
if not xtOk or type(xtarget) ~= "table" or not xtarget.window then xtarget = nil end

-- The mob in a slot (r.n, 0-based) and its marks, from the script's state.
local function slotMob(r)
  local x = (st.xtargets or {})[r.n + 1]
  if not x or (x.id or 0) == 0 then return nil end
  local ignored = false
  for _, id in ipairs(st.ignored or {}) do if id == x.id then ignored = true end end
  return x, st.force_id == x.id, ignored
end

local XT_ROW = {
  width = MARK_W,
  style = function(r)
    local x, forced, ignored = slotMob(r)
    if not x then return nil end
    if forced then
      local p = 0.55 + 0.45 * math.sin(ui.GetTime() * 5)
      return { ring = { FORCE[1], FORCE[2], FORCE[3], 0.5 + 0.4 * p }, tag = { "FORCED", FORCE } }
    end
    if ignored then return { alpha = 0.45, strike = true, tag = { "IGNORED", C.muted } } end
    return nil
  end,
  draw = function(r, x0, y0, x1, y1, s)
    local x, forced, ignored = slotMob(r)
    if not x then return end
    local size = math.min(20 * s, y1 - y0 - 6 * s)
    local by = (y0 + y1 - size) / 2
    local fx = x1 - 6 * s - size
    local ix = fx - 4 * s - size
    if markButton("##acig" .. r.n, "ignore", ix, by, size, s, ignored, ignored
          and "Ignored: click to fight it again"
          or "Ignore: Auto Combat leaves it alone while anything else is on the list") then
      P.command("ignore", x.id)
    end
    if markButton("##acfo" .. r.n, "force", fx, by, size, s, forced, forced
          and "Forced: click to let Auto Combat choose again"
          or "Force: Auto Combat fights this one first, until it dies") then
      P.command("force", x.id)
    end
  end,
}

local STYLE_TIPS = {
  full = "It targets the mobs on you and keeps you in range",
  partial = "You pick the mob and stand where you want; it only turns you to face it",
}
local MODE_TIPS = {
  manual = "You bring the fight; it fights it",
  hunter = "It finds mobs and walks to them until you pause it",
  assist = "It fights what your assist fights",
}

-- The Burn button: lit and pulsing while burn mode is on. Returns clicked.
local function burnButton(x0, y0, x1, y1, s, on)
  local hit = T.Hit("##acburn", x0, y0, x1, y1)
  local hovered, active = ui.IsItemHovered(), ui.IsItemActive()
  local rad = 8 * s
  local pulse = on and (0.5 + 0.5 * math.sin(ui.GetTime() * 7)) or 0
  if on then
    ui.DrawRectFilled(x0 - 4 * s, y0 - 4 * s, x1 + 4 * s, y1 + 4 * s, BURN[1], BURN[2], BURN[3], 0.10 + 0.30 * pulse,
      rad + 4 * s)
    local top, bottom = mix(BURN, { 1, 0.9, 0.5 }, 0.25 + 0.35 * pulse), mix(BURN, { 0.5, 0.05, 0 }, 0.35)
    ui.DrawRectFilled(x0, y0 + 2 * s, x1, y1 + 2 * s, 0, 0, 0, 0.30, rad)
    ui.DrawRectFilled(x0, y0, x1, y1, bottom[1], bottom[2], bottom[3], active and 0.8 or 0.95, rad)
    ui.DrawRectFilled(x0, y0, x1, y0 + (y1 - y0) * 0.55, top[1], top[2], top[3], 0.9, rad)
    ui.DrawRect(x0, y0, x1, y1, 1, 0.85, 0.5, 0.6 + 0.4 * pulse, rad, 1.5 * s)
  else
    ui.DrawRectFilled(x0, y0, x1, y1, BURN[1], BURN[2], BURN[3], active and 0.20 or (hovered and 0.14 or 0.07), rad)
    ui.DrawRect(x0, y0, x1, y1, BURN[1], BURN[2], BURN[3], hovered and 0.8 or 0.45, rad, 1.2 * s)
  end
  local word = "Burn"
  local tw, th = T.TextSize(word, T.font.normal)
  local fw = 10 * s
  local gx = (x0 + x1 - tw - fw - 5 * s) / 2
  local cy = (y0 + y1) / 2
  local ic = on and (C.barText or { 1, 1, 1, 1 }) or BURN
  flame(gx + fw / 2, cy, 14 * s, ic, 1)
  T.Text(gx + fw + 5 * s, cy - th / 2, word, ic, T.font.normal, nil, 1, on and C.barShadow or nil)
  if hovered then
    ui.SetTooltip(on and "Burn mode is on: the burn rows fire. It ends by itself once the extended target list is clear;"
      .. " click to end it now (/autocombat burn off)."
      or "Burn mode: rows marked \"Only during burn\" fire until this fight is over (/autocombat burn)")
  end
  return hit
end

-- The compact window: the mode, Start / Pause, Burn and what it is doing.
local function compactSize(s)
  return 380, S.mode == "manual" and 160 or 128
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
  if st.burn then
    local tw = T.TextSize("AUTO COMBAT", T.font.small)
    local bx = x + pad + 24 * s + tw
    local a = 0.55 + 0.45 * math.sin(t * 7)
    flame(bx + 5 * s, y + 15 * s, 12 * s, BURN, a)
    T.Text(bx + 13 * s, y + 8 * s, "BURNING", BURN, T.font.small, nil, a)
  end
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
  local kx0 = bx0 + bw + 8 * s
  if burnButton(kx0, by0, kx0 + 76 * s, by0 + bh, s, st.burn) then P.command("burn") end

  -- the status and the last thing it did
  local sx = kx0 + 76 * s + 12 * s
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
    size = function() return 920, 600 end,
    resizable = { 780, 480 },
    place = K.Centered,
    onClose = function() P.command("close_settings") end,
  }, settingsBody)
end)

-- The extended target window, with Force and Ignore on each mob (the pack's own when this client has no
-- lib/xtarget.lua, or the script is not running).
ui.window("Extended Target", function()
  local p = eq.Plugin("autocombat")
  if not xtarget or not p then return ui.base_window() end
  P = p
  st = p.state() or {}
  xtarget.window({ width = 210 + MARK_W, row = XT_ROW })
end)
