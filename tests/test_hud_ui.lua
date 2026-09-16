-- Execute the production HUD with synthetic adapter snapshots and a drawing recorder.
-- No game, native probe, filesystem writes, or commercial car data are used.
-- Drawing bounds check geometry/text boxes, not actual Windows font glyph rendering.
local checks, cases = 0, 0
local function check(condition, message)
  checks = checks + 1
  assert(condition, message)
end
local function near(a, b) return math.abs(a - b) < 0.00001 end
local function copy(value)
  if type(value) ~= 'table' then return value end
  local result = {}
  for key, child in pairs(value) do result[key] = copy(child) end
  return result
end
function vec2(x, y) return { x = x, y = y or x } end
function rgbm(r, g, b, m) return { r = r, g = g, b = b, m = m } end
local function colorEquals(a, b)
  return a and b and near(a.r, b.r) and near(a.g, b.g) and near(a.b, b.b) and near(a.m, b.m)
end
local dark = rgbm(0.09, 0.09, 0.09, 1)
local green = rgbm(49 / 255, 172 / 255, 51 / 255, 1)
local boostColor = rgbm(0.92, 0.2, 0.58, 1)
local panelColor = rgbm(0, 0, 0, 0.62)
local sim = { carsCount = 4, focusedCar = 0, closelyFocusedCar = 0, isReplayActive = false }
local cfg, snapshots, lastReadIndex, lastReadMode, recordCalls = nil, {}, nil, nil, 0
local canonicalView, currentPath = nil, nil
local callbacks = { replay = {}, session = {}, carSwap = {} }
local commands, cursor, canvas, canvasOrigin, rotating, activeFont = {}, vec2(0, 0), nil, nil, false, nil
local function emit(command) commands[#commands + 1] = command end

local function readSnapshot(target, index, mode)
  lastReadIndex, lastReadMode = index, mode
  local fixture = snapshots[index]
  if fixture == false or fixture == nil then return false end
  -- Deliberately does not clear target: refreshView must remove previous car fields.
  for key, value in pairs(fixture) do target[key] = copy(value) end
  canonicalView = target
  return true
end
local adapter = {
  new = function()
    return {
      can = {}, RS = {}, VRS = {},
      readLive = function(target, index) return readSnapshot(target, index, 'live') end,
      readReplay = function(target, index) return readSnapshot(target, index, 'replay') end,
      recordAll = function() recordCalls = recordCalls + 1; return 1 end,
    }
  end,
}
local previousRequire = require
function require(name) if name == 'hud_data' then return adapter end; return previousRequire(name) end

local savedLogWrites = 0
io.load = function() return '' end
io.save = function() savedLogWrites = savedLogWrites + 1; return true end
ac = {
  getSim = function() return sim end,
  storage = function(defaults)
    cfg = defaults
    cfg.diagnostics, cfg.logDiag = false, false
    return cfg
  end,
  FolderID = { Logs = 1 }, getFolder = function() return 'synthetic-logs' end,
  ControlButton = function() return { pressed = function() return false end, control = function() end } end,
  getPatchVersionCode = function() return 0 end,
  getTrackFullID = function() return 'synthetic-track' end,
  getCarID = function(index) return 'synthetic-car-' .. tostring(index) end,
  onReplay = function(fn) callbacks.replay[#callbacks.replay + 1] = fn end,
  onSessionStart = function(fn) callbacks.session[#callbacks.session + 1] = fn end,
  onCarSwap = function(index, fn)
    check(index == -1, 'display response observes swaps of every car')
    callbacks.carSwap[#callbacks.carSwap + 1] = fn
  end,
  log = function() end,
}
local fontFactory = { Weight = { Bold = 700, Medium = 500 } }
setmetatable(fontFactory, { __call = function(_, name)
  local result = { name = name }
  function result:weight(value) self.weightValue = value; return self end
  return result
end })
ui = {
  DWriteFont = fontFactory, Alignment = { Start = 0, Center = 1, End = 2 },
  pushDWriteFont = function(font) activeFont = font end,
  popDWriteFont = function() activeFont = nil end,
  getCursor = function() return vec2(cursor.x, cursor.y) end,
  setCursor = function(position) cursor = vec2(position.x, position.y) end,
  measureDWriteText = function(value, size) return vec2(#value * size * 0.55, size) end,
  dwriteTextAligned = function(value, size, horizontal, vertical, box, _, color)
    emit({ kind = 'text', text = tostring(value), x = cursor.x, y = cursor.y, w = box.x, h = box.y,
      size = size, color = color, rotating = rotating, font = activeFont and activeFont.name,
      horizontal = horizontal })
  end,
  drawCircleFilled = function(center, radius, color)
    emit({ kind = 'circle', x = center.x, y = center.y, r = radius, color = color })
  end,
  drawRectFilled = function(a, b, color, rounding, corners)
    emit({ kind = 'rect', x = a.x, y = a.y, w = b.x - a.x, h = b.y - a.y, color = color, rounding = rounding, corners = corners })
  end,
  drawRect = function(a, b, color, rounding, corners)
    emit({ kind = 'border', x = a.x, y = a.y, w = b.x - a.x, h = b.y - a.y, color = color, rounding = rounding, corners = corners })
  end,
  drawQuadFilled = function(a, b, c, d, color)
    local x1, y1 = math.min(a.x, b.x, c.x, d.x), math.min(a.y, b.y, c.y, d.y)
    local x2, y2 = math.max(a.x, b.x, c.x, d.x), math.max(a.y, b.y, c.y, d.y)
    -- ImGui's anti-aliased convex fill needs clockwise winding in screen space (y down): shoelace sum > 0
    local shoelace = (a.x * b.y - b.x * a.y) + (b.x * c.y - c.x * b.y) + (c.x * d.y - d.x * c.y) + (d.x * a.y - a.x * d.y)
    check(shoelace > 0, 'filled quad is wound clockwise for the anti-aliased fringe')
    emit({ kind = 'quad', x = x1, y = y1, w = x2 - x1, h = y2 - y1, color = color })
  end,
  CornerFlags = { None = 0, All = 15, Left = 5, Right = 10 },
  pathClear = function() currentPath = nil end,
  pathArcTo = function(center, radius, startAngle, endAngle)
    currentPath = { kind = 'arc', x = center.x, y = center.y, r = radius, a0 = startAngle, a1 = endAngle }
  end,
  pathStroke = function(color, _, width)
    local command = copy(currentPath)
    command.color, command.width = color, width
    emit(command)
  end,
  beginRotation = function() rotating = true end,
  endPivotRotation = function() rotating = false end,
  dummy = function(size) canvas = vec2(size.x, size.y); canvasOrigin = vec2(cursor.x, cursor.y) end,
}
script = {}
loadHud()
check(savedLogWrites == 1, 'only the existing launch diagnostic is written to the in-memory stub')
check(cfg.batteryTerminal == 'right', 'the battery terminal is on the right unless the user chooses otherwise')

local function fixture(kind)
  local result = { kind = kind, name = 'Synthetic', source = 'fixture', index = 0,
    speed = 123, rpm = 11001, gear = 7, gas = 0.4, brake = 0.1, valid = {}, full = false }
  if kind == 'pro' then
    result.soc, result.esoc, result.kw, result.cap = 0.75, 7, 175, 350
    result.deploy, result.regen, result.regenLimit, result.strat, result.split, result.puMode = 1.25, 2, 8, 3, 2, 1
    result.smActive, result.otActive, result.boost = true, true, true
    result.otPending, result.charge, result.pl, result.plp, result.pitLimiter = false, false, false, false, false
  elseif kind == 'vanilla' then
    result.soc, result.strategyName, result.recovering, result.smActive, result.boost = 0.5, 'NODEPLOY', true, true, true
    result.strategy, result.otActive, result.otPending, result.deployInput = 3, false, false, 0
  else
    result.drsPresent, result.drsActive = true, true
  end
  for key in pairs(result) do result.valid[key] = true end
  return result
end
local function render(skipUpdate)
  commands, cursor, canvas, canvasOrigin, rotating = {}, vec2(0, 0), nil, nil, false
  if not skipUpdate then script.update(0.016) end
  script.windowMain(0.016)
  check(canvas ~= nil, 'window declares its layout size')
  check(near(canvasOrigin.x, 0) and near(canvasOrigin.y, 0), 'layout size is anchored at the original window cursor')
  return commands
end
local function findText(value)
  for _, command in ipairs(commands) do
    if command.kind == 'text' and command.text == value then return command end
  end
end
local function textContains(value)
  for _, command in ipairs(commands) do
    if command.kind == 'text' and command.text:find(value, 1, true) then return true end
  end
  return false
end
local function matchingFill(textCommand)
  if not textCommand then return nil end
  for _, command in ipairs(commands) do
    if command.kind == 'rect' and near(command.x, textCommand.x) and near(command.y, textCommand.y)
      and near(command.w, textCommand.w) and near(command.h, textCommand.h) then return command.color end
  end
end
local function panels()
  local count = 0
  for _, command in ipairs(commands) do
    if command.kind == 'rect' and colorEquals(command.color, panelColor) then count = count + 1 end
  end
  return count
end
local function assertBounds(context)
  for _, command in ipairs(commands) do
    if command.kind == 'circle' then
      check(command.x - command.r >= -0.001 and command.y - command.r >= -0.001
        and command.x + command.r <= canvas.x + 0.001 and command.y + command.r <= canvas.y + 0.001,
        context .. ': circle within declared canvas')
    elseif command.kind == 'arc' then
      local edge = command.r + command.width * 0.5
      check(command.x - edge >= -0.001 and command.y - edge >= -0.001
        and command.x + edge <= canvas.x + 0.001 and command.y + edge <= canvas.y + 0.001,
        context .. ': arc stroke within declared canvas')
    elseif command.kind ~= 'text' or not command.rotating then
      check(command.w >= 0 and command.h >= 0 and command.x >= -0.001 and command.y >= -0.001
        and command.x + command.w <= canvas.x + 0.001 and command.y + command.h <= canvas.y + 0.001,
        context .. ': box within declared canvas: ' .. tostring(command.text or command.kind))
    end
  end
end
-- Battery glyph geometry at scale 1, terminal on the right (the default since 0.9.38): body (122, 270)
-- 92 x 20, bolt 128-136, digits box (138, 270) 72 x 20 right-aligned beside the terminal, nub (214, 276)
-- 4 x 8. The left terminal (0.9.3-0.9.37) is the mirror image about x = 170: body (126, 270), digits box
-- (130, 270) left-aligned, bolt 204-212, nub (122, 276). Since 0.9.39 the digits sit beside the terminal
-- and the bolt at the anchored end (before: the other way round). The helpers follow the current setting,
-- including its fallback for unrecognised values.
local BODY_X, DIGITS_X = { left = 126, right = 122 }, { left = 130, right = 138 }
local function terminal() return cfg.batteryTerminal == 'left' and 'left' or 'right' end
local batteryColor = rgbm(0.91, 0.92, 0.93, 0.92)
local batteryIdle = rgbm(1, 1, 1, 0.30)
local yellow = rgbm(0.95, 0.75, 0.15, 1)
local function findTextAt(value, x, y)
  for _, command in ipairs(commands) do
    if command.kind == 'text' and command.text == value and near(command.x, x) and near(command.y, y) then return command end
  end
end
local function boxAt(kind, x, y, w, h)
  for _, command in ipairs(commands) do
    if command.kind == kind and near(command.x, x) and near(command.y, y) and near(command.w, w) and near(command.h, h) then return command end
  end
end
local function quads()
  local count = 0
  for _, command in ipairs(commands) do if command.kind == 'quad' then count = count + 1 end end
  return count
end
-- The bolt is two convex quads, drawn four times as its black outline (one unit off in each direction),
-- then once as an opaque core in the body colour and once in its own colour, in that order.
local BOLT_QUADS = 12
local function boltQuads()
  local list = {}
  for _, command in ipairs(commands) do if command.kind == 'quad' then list[#list + 1] = command end end
  return list
end
local function batteryBody(scale) scale = scale or 1; return boxAt('rect', BODY_X[terminal()] * scale, 270 * scale, 92 * scale, 20 * scale) end
local function batteryRing(scale) scale = scale or 1; return boxAt('border', BODY_X[terminal()] * scale, 270 * scale, 92 * scale, 20 * scale) end
local function batteryDigits(value, scale) scale = scale or 1; return findTextAt(value, DIGITS_X[terminal()] * scale, 270 * scale) end
-- The word BOOST is centred on the body, so its text box is the body itself; the badge is the wider pill.
local function batteryWord(scale) scale = scale or 1; return findTextAt('BOOST', BODY_X[terminal()] * scale, 270 * scale) end
local function boostBadge(scale) scale = scale or 1; return boxAt('rect', 122 * scale, 270 * scale, 96 * scale, 20 * scale) end
local function sameHue(a, b) return a and b and near(a.r, b.r) and near(a.g, b.g) and near(a.b, b.b) end
for _, kind in ipairs({ 'pro', 'vanilla', 'drs' }) do
  for _, lang in ipairs({ 'en', 'zh' }) do
    for _, scale in ipairs({ 0.5, 1, 2.5 }) do
      for _, showBattery in ipairs({ false, true }) do
        for _, showPanel in ipairs({ false, true }) do
          for _, side in ipairs({ 'left', 'right' }) do
            cases = cases + 1
            cfg.lang, cfg.scale, cfg.showBattery, cfg.showPanel, cfg.batteryTerminal = lang, scale, showBattery, showPanel, side
            snapshots[0] = fixture(kind)
            render()
            local panel = showPanel and kind ~= 'drs'
            local panelWidth = kind == 'vanilla' and 248 or 308
            check(near(canvas.x, (340 + (panel and (12 + panelWidth) or 0)) * scale)
              and near(canvas.y, 340 * scale), kind .. ': expected canvas dimensions')
            local disc = commands[1]
            check(disc.kind == 'circle' and near(disc.x, 170 * scale)
              and near(disc.y, 170 * scale) and near(disc.r, 169 * scale), 'v0.9.1 circular dial geometry retained')
            local speedText = findText('123')
            check(speedText and near(speedText.y, 78 * scale) and near(speedText.h, 62 * scale), 'speed stack geometry retained')
            check(findText('11001') and findText('KMH') and findText('RPM') and findText('GEAR'), 'base instrument labels retained')
            check(panels() == (panel and 1 or 0), 'panel visibility follows settings and vehicle layout')
            if kind == 'drs' then
              local drs = findText('DRS')
              check(drs and near(drs.x + drs.w * 0.5, 170 * scale) and near(drs.y, 251 * scale), 'single DRS badge centered')
              check(not findText('SM') and not findText('OT') and not findText('BOOST'), 'legacy layout has no 2026 badge cluster')
              check(not batteryBody(scale) and quads() == 0, 'legacy layout has no battery glyph')
              check(colorEquals(matchingFill(drs), green), 'valid active native DRS illuminates')
              check(not textContains('MJ') and not textContains('kW') and not textContains('PU '), 'legacy layout has no Pro energy fields')
            else
              local sm = findText('SM')
              check(sm and not findText('DRS') and near(sm.y, 240 * scale) and near(sm.h, 24 * scale), '2026 SM badge keeps its row')
              check(colorEquals(matchingFill(sm), green), 'a valid open SM is green')
              if kind == 'pro' then
                local ot = findText('OT')
                check(ot and near(sm.x, 122 * scale) and near(sm.w, 45 * scale)
                  and near(ot.x, 173 * scale) and near(ot.w, 45 * scale) and near(ot.y, 240 * scale), 'the Pro keeps the SM | OT pair')
              else
                -- The standard FA26 has no Overtake Mode: no OT badge, and SM spans the 96-unit slot.
                check(not findText('OT'), 'the standard FA26 draws no OT badge')
                check(near(sm.x, 122 * scale) and near(sm.w, 96 * scale), 'its SM badge takes the whole row')
              end
              if showBattery then
                check(not boostBadge(scale) and batteryBody(scale) and batteryRing(scale), 'battery glyph replaces the BOOST badge: ' .. side)
                -- both fixtures hold the Boost command, so the body reads BOOST instead of the charge
                check(batteryWord(scale) and not batteryDigits(kind == 'pro' and '75%' or '50%', scale), 'the held Boost command reads BOOST inside the glyph')
                check(near(batteryWord(scale).w, 92 * scale) and near(batteryWord(scale).size, 13 * scale)
                  and batteryWord(scale).horizontal == ui.Alignment.Center, 'the word is centred on the whole body at every scale')
                check(colorEquals(batteryBody(scale).color, boostColor) and quads() == BOLT_QUADS, 'Boost button colours the battery body; bolt drawn')
              else
                check(findText('BOOST') and not batteryBody(scale) and quads() == 0, 'BOOST badge returns when the glyph is off')
                check(colorEquals(matchingFill(findText('BOOST')), boostColor), 'BOOST badge shows the button')
                check(boostBadge(scale), 'the badge keeps its own slot whichever terminal side is set')
              end
              if kind == 'pro' then
                check(colorEquals(matchingFill(findText('OT')), green), 'Pro OT retains its active indication')
                if panel then check(findText('MGU-K') and textContains('MJ') and findText('PU RACE'), 'Pro panel keeps energy and PU fields') end
              else
                check(not textContains('MJ') and not textContains('kW') and not textContains('PU ') and not findText('MGU-K'), 'ordinary layout excludes Pro-only quantities')
                if panel then
                  check(findText('NODEPLOY') and findText('50%'), 'ordinary strategy and battery percentage shown')
                  local label = findText(lang == 'zh' and '电池' or 'Battery')
                  check(label and label.font == (lang == 'zh' and 'Microsoft YaHei UI' or 'Bahnschrift'), 'localized label uses expected font family')
                end
              end
            end
            assertBounds(kind .. '/' .. lang .. '/' .. tostring(scale) .. '/' .. side)
          end
        end
      end
    end
  end
end
-- The flow-state section below spells out the left terminal's coordinates; the right terminal's follow in
-- the mirror section, which compares the two shape by shape.
cfg.batteryTerminal = 'left'
print('UI matrix: ' .. tostring(cases) .. ' vehicle/language/scale/panel/battery/terminal combinations passed')

cfg.scale, cfg.lang, cfg.showPanel, cfg.showBattery = 1, 'en', true, true
snapshots[0] = fixture('pro')
sim.focusedCar = 0
render()
check(findText('PU RACE') and colorEquals(batteryBody().color, boostColor), 'Pro fixture starts with active data')
snapshots[1] = { kind = 'vanilla', source = 'missing native history', speed = 99, rpm = 8001, gear = 5, valid = {} }
sim.focusedCar = 1
render()
check(lastReadIndex == 1 and findText('99') and findText('8001'), 'camera selects new car snapshot')
check(not findText('75%') and not findText('50%') and not findText('NODEPLOY') and not textContains('PU '), 'camera switch clears previous energy and strategy values')
check(colorEquals(matchingFill(findText('SM')), dark) and colorEquals(batteryBody().color, dark), 'missing snapshot does not retain previous illuminated lamps')
check(findText('Recovering --') and findText('--'), 'missing native historical fields remain visibly unavailable')

snapshots[1] = fixture('vanilla')
snapshots[1].soc, snapshots[1].recovering, snapshots[1].smActive, snapshots[1].boost = 0, false, false, false
render()
check(findText('0%') and not findText('Recovering --'), 'valid zero battery and false recovery differ from missing data')
check(colorEquals(batteryBody().color, dark), 'valid false manual boost is dark')
snapshots[1].soc, snapshots[1].strategyName, snapshots[1].smActive, snapshots[1].boost = 0.87, 'HIGH', true, true
snapshots[1].valid = { recovering = true }
render()
check(not findText('87%') and not findText('HIGH'), 'raw values with invalid fields never become valid readouts')
check(colorEquals(matchingFill(findText('SM')), dark) and colorEquals(batteryBody().color, dark), 'raw true states cannot illuminate without validity')
check(not findText('BOOST'), 'an unverified Boost flag never prints the word either')

-- Battery glyph: state and hue from the current update, body from the Boost button, fill anchored to the
-- wall opposite the terminal (here the left terminal, so the right wall), easing of the ring brightness only.
cfg.batterySmoothing = false
local redHue = rgbm(245 / 255, 45 / 255, 33 / 255, 1)
local function batteryFill()
  for _, command in ipairs(commands) do
    if command.kind == 'rect' and (colorEquals(command.color, batteryColor) or colorEquals(command.color, yellow))
      and command.y > 270 and command.y < 290 and command.x > 122 and command.x < 218 then return command end
  end
end
-- the terminal nub: 4 x 8, centred on the body's height, beside the body on the configured side
local function batteryNub()
  return boxAt('rect', terminal() == 'right' and 214 or 122, 276, 4, 8)
end
local outlineColor = rgbm(0, 0, 0, 0.85)
-- colours of the bolt's last pass (the symbol itself) and of the core under it
local function boltColors()
  local list, colors = boltQuads(), {}
  if #list >= 2 then colors = { list[#list - 1].color, list[#list].color } end
  return colors
end
local function boltCoreColors()
  local list, colors = boltQuads(), {}
  if #list >= 4 then colors = { list[#list - 3].color, list[#list - 2].color } end
  return colors
end
local function boltSpan()
  local list = boltQuads()
  local x1, x2 = math.huge, -math.huge
  for k = #list - 1, #list do x1, x2 = math.min(x1, list[k].x), math.max(x2, list[k].x + list[k].w) end
  return x1, x2
end
local function commandIndex(target)
  for k, command in ipairs(commands) do if command == target then return k end end
end
snapshots[1] = fixture('pro')                                   -- kw 175, boost true
render()
check(sameHue(batteryRing().color, boostColor) and near(batteryRing().color.m, 0.35 + 0.65 * 0.5), 'Boost while deploying: magenta ring at |kW| / 350 brightness')
check(colorEquals(batteryBody().color, boostColor), 'Boost button colours the body')
check(#boltCoreColors() == 2 and colorEquals(boltCoreColors()[1], boostColor) and colorEquals(boltCoreColors()[2], boostColor),
  'the bolt core takes the magenta body colour')
snapshots[1].boost, snapshots[1].kw = false, 200
render()
check(sameHue(batteryRing().color, green) and colorEquals(batteryBody().color, dark), 'deploying without Boost: green ring, dark body')
local fill = batteryFill()
check(fill and near(fill.x + fill.w, 215.5) and near(fill.w, 87 * 0.75), 'charge fill is anchored to the right wall and scaled by SoC')
check(fill.corners == ui.CornerFlags.Right, 'only the anchored end of a partial fill is rounded')
check(batteryNub() and batteryNub().corners == ui.CornerFlags.Left and sameHue(batteryNub().color, green),
  'the terminal sits left of the body, rounded on its outer side, in the flow hue')
-- left terminal: the percentage beside the terminal, the bolt at the anchored end
local leftDigits = batteryDigits('75%')
check(leftDigits and near(leftDigits.x, 130) and near(leftDigits.w, 72) and leftDigits.horizontal == ui.Alignment.Start,
  'left terminal: the percentage is left-aligned beside the terminal')
local boltLeft, boltRight = boltSpan()
check(near(boltLeft, 204) and near(boltRight, 212), 'left terminal: the bolt sits at the anchored end')
check(leftDigits.x + leftDigits.w <= boltLeft - 2 + 0.001, 'left terminal: the percentage box stops 2 units before the bolt')
check(boltLeft >= fill.x and boltRight <= fill.x + fill.w, 'at 75 % the bolt lies over the fill')
local quadList = boltQuads()
check(#quadList == BOLT_QUADS and commandIndex(quadList[1]) > commandIndex(fill), 'the bolt is drawn over the fill')
for k = 1, 8 do check(colorEquals(quadList[k].color, outlineColor), 'the bolt starts with its black outline') end
check(colorEquals(boltCoreColors()[1], dark) and colorEquals(boltCoreColors()[2], dark), 'the bolt core takes the dark body colour')
for q = 1, 2 do
  local symbol, core = quadList[10 + q], quadList[8 + q]
  check(near(core.x, symbol.x) and near(core.y, symbol.y) and near(core.w, symbol.w) and near(core.h, symbol.h), 'the core lies exactly under the symbol')
  for k, d in ipairs({ { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 } }) do
    local ghost = quadList[(k - 1) * 2 + q]
    check(near(ghost.x, symbol.x + d[1]) and near(ghost.y, symbol.y + d[2]) and near(ghost.w, symbol.w) and near(ghost.h, symbol.h),
      'each outline copy of the bolt sits one unit off the symbol')
  end
end
check(sameHue(boltColors()[1], green) and near(boltColors()[1].m, 0.45 + 0.55 * 200 / 350), 'the bolt keeps its flow-hue brightness')
snapshots[1].kw = 3
render()
check(colorEquals(boltColors()[1], rgbm(1, 1, 1, 0.70)) and colorEquals(boltColors()[2], rgbm(1, 1, 1, 0.70)), 'the resting bolt keeps its translucent white')
snapshots[1].kw = 200
snapshots[1].soc = 1
render()
check(batteryFill().corners == ui.CornerFlags.All and near(batteryFill().w, 87), 'a full fill is rounded at both ends')
snapshots[1].soc = 0.75
snapshots[1].kw = -200
render()
check(sameHue(batteryRing().color, redHue) and near(batteryRing().color.m, 0.35 + 0.65 * 200 / 350), 'harvesting: red ring')
check(#boltColors() == 2 and sameHue(boltColors()[1], redHue), 'the bolt takes the flow hue')
snapshots[1].boost = true
render()
check(sameHue(batteryRing().color, redHue) and colorEquals(batteryBody().color, boostColor), 'Boost held while harvesting: magenta body, red ring')
check(#boltColors() == 2 and colorEquals(boltColors()[1], rgbm(1, 1, 1, 1)) and colorEquals(boltColors()[2], rgbm(1, 1, 1, 1)), 'the bolt is white on the magenta Boost body')
snapshots[1].boost, snapshots[1].kw = false, 3
render()
check(colorEquals(batteryRing().color, batteryIdle) and quads() == BOLT_QUADS, 'inside the 5 kW deadband the ring is idle and the bolt stays')
snapshots[1].kw, snapshots[1].valid.kw = 300, false
render()
check(colorEquals(batteryRing().color, batteryIdle) and batteryDigits('75%'), 'unknown power leaves the ring idle while the charge is shown')
snapshots[1].valid.kw, snapshots[1].valid.soc = true, false
render()
check(batteryDigits('--') and quads() == 0 and not batteryFill(), 'invalid charge shows -- without fill or bolt')
check(sameHue(batteryRing().color, green), 'a valid flow still colours the ring while the charge is invalid')
snapshots[1].valid.soc, snapshots[1].soc, snapshots[1].kw = true, 0.08, 250
render()
check(batteryDigits('8%') and colorEquals(batteryDigits('8%').color, yellow) and colorEquals(batteryFill().color, yellow), 'low charge turns the fill and digits amber')
snapshots[1].soc = 0.104
render()
check(batteryDigits('10%') and colorEquals(batteryDigits('10%').color, yellow) and colorEquals(batteryFill().color, yellow), 'the low-charge rule follows the displayed figure: 10% is amber')
snapshots[1].soc = 0.105
render()
check(batteryDigits('11%') and colorEquals(batteryDigits('11%').color, rgbm(1, 1, 1, 1)) and colorEquals(batteryFill().color, batteryColor), '11% is drawn in the normal colours')

-- The word BOOST inside the body while the command is held, and the single-digit exception.
snapshots[1].soc, snapshots[1].boost = 0.75, true
render()
check(batteryWord() and not batteryDigits('75%'), 'the held Boost command replaces the charge with BOOST')
check(colorEquals(batteryWord().color, rgbm(1, 1, 1, 1)) and near(batteryWord().w, 92), 'the word is white and centred on the body')
check(batteryFill() and near(batteryFill().x + batteryFill().w, 215.5) and near(batteryFill().w, 87 * 0.75),
  'the charge fill still reads the level behind the word')
snapshots[1].boost = false
render()
check(batteryDigits('75%') and not batteryWord(), 'releasing Boost brings the charge straight back')
snapshots[1].soc, snapshots[1].boost = 0.104, true
render()
check(batteryWord() and not batteryDigits('10%'), 'a two-figure charge stays hidden while Boost is held')
snapshots[1].soc = 0.094
render()
-- left terminal: the number leads, left-aligned from 130, and the word fills the room up to the bolt
-- (which starts at 204); findTextAt matches the drawn text itself, not the four outline copies around it
local numberWidth = 2 * 13 * 0.55
local boostWord = findTextAt('BOOST', 130 + numberWidth, 270)
check(boostWord and batteryDigits('9%') and batteryDigits('9%').horizontal == ui.Alignment.Start, 'a single-digit charge is shown before BOOST')
check(colorEquals(batteryDigits('9%').color, yellow), 'that number keeps the amber low-charge colour')
check(near(boostWord.x + boostWord.w, 204), 'the word stops at the bolt')
check(not batteryWord(), 'and is no longer centred on the body')
check(colorEquals(boostWord.color, rgbm(1, 1, 1, 1)) and near(boostWord.size, 13) and boostWord.horizontal == ui.Alignment.Center,
  'the word beside the number is the same centred white body text')
check(boostWord.w >= ui.measureDWriteText('BOOST', 13).x, 'the word still has room between the number and the bolt')
cfg.scale = 2.5
render()
local scaledWord = findTextAt('BOOST', (130 + numberWidth) * 2.5, 270 * 2.5)
check(scaledWord and near(scaledWord.w, boostWord.w * 2.5) and batteryDigits('9%', 2.5), 'the single-digit layout scales with the HUD')
cfg.scale = 1
render()
snapshots[1].valid.soc = false
render()
check(batteryWord() and not batteryDigits('--'), 'an unknown charge under Boost still reads BOOST, never --')
snapshots[1].valid.soc, snapshots[1].soc, snapshots[1].boost = true, 0.75, false
render()
check(batteryDigits('75%') and not findText('BOOST'), 'without the command neither the word nor the badge is drawn')
snapshots[1] = fixture('vanilla')                                -- recovering true, boost true, no deployment
render()
check(sameHue(batteryRing().color, redHue) and near(batteryRing().color.m, 0.35 + 0.65 * 0.6), 'native recovery: red ring at the declared fixed intensity')
check(colorEquals(batteryBody().color, boostColor), 'native Boost button colours the body only')
snapshots[1].recovering = false
render()
check(colorEquals(batteryRing().color, batteryIdle), 'native car neither deploying nor recovering: idle ring')
-- Native deployment: the share the car's delivery controller requests, not a measured power.
snapshots[1].boost, snapshots[1].deployInput = false, 0.5
render()
check(sameHue(batteryRing().color, green) and near(batteryRing().color.m, 0.35 + 0.65 * 0.5), 'native deployment: green ring at the requested share')
check(colorEquals(batteryBody().color, dark), 'automatic deployment never colours the body')
check(#boltColors() == 2 and sameHue(boltColors()[1], green), 'the native bolt takes the deployment hue')
snapshots[1].boost = true
render()
check(sameHue(batteryRing().color, boostColor) and colorEquals(batteryBody().color, boostColor), 'native Boost while deploying: magenta ring and body')
check(#boltColors() == 2 and colorEquals(boltColors()[1], rgbm(1, 1, 1, 1)), 'the bolt is white on the native magenta body')
snapshots[1].boost, snapshots[1].deployInput = false, 0.02
render()
check(colorEquals(batteryRing().color, batteryIdle), 'a requested share inside the deadband leaves the ring idle')
snapshots[1].deployInput, snapshots[1].recovering = 0.4, true
render()
check(sameHue(batteryRing().color, green), 'the requested share of this update outranks the recovery status')
snapshots[1].valid.deployInput = false
render()
check(sameHue(batteryRing().color, redHue) and near(batteryRing().color.m, 0.35 + 0.65 * 0.6), 'without a requested share the recovery status still draws red')
-- The native panel names both flow states, in the glyph's colours.
snapshots[1] = fixture('vanilla')
snapshots[1].deployInput, snapshots[1].recovering = 0.5, false
render()
check(colorEquals(matchingFill(findText('Deploying')), green), 'the native panel lights its deployment chip')
check(colorEquals(matchingFill(findText('Recovering')), dark), 'the recovery chip stays dark while the car deploys')
snapshots[1].deployInput, snapshots[1].recovering = 0, true
render()
check(colorEquals(matchingFill(findText('Deploying')), dark) and colorEquals(matchingFill(findText('Recovering')), redHue), 'a valid zero share leaves the deployment chip dark while recovery lights')
snapshots[1].valid.deployInput = false
render()
check(findText('Deploying --') and colorEquals(matchingFill(findText('Deploying --')), dark), 'an unavailable share is marked and never lit')
snapshots[1] = fixture('drs')
render()
check(not batteryBody() and quads() == 0, 'conventional cars draw no battery glyph')
cfg.batterySmoothing = true
sim.dt = 0.015
snapshots[1] = fixture('pro')
snapshots[1].index, snapshots[1].boost, snapshots[1].kw = 7, false, 350
render()
check(near(batteryRing().color.m, 1), 'easing restarts from the raw value on a new car')
snapshots[1].kw = 100
render()
local eased = batteryRing().color.m
check(sameHue(batteryRing().color, green) and eased > 0.9 and eased < 1, 'ring brightness eases towards the new value')
sim.dt = 0
snapshots[1].kw = -100
render()
check(sameHue(batteryRing().color, redHue) and near(batteryRing().color.m, 0.35 + 0.65 * 100 / 350), "hue changes at once; a paused replay draws the shown frame's own brightness")
cfg.batterySmoothing = false
render()
check(near(batteryRing().color.m, 0.35 + 0.65 * 100 / 350), 'easing off draws the raw brightness')
cfg.batterySmoothing, sim.dt = true, 0.015
local lightHarvest = 0.35 + 0.65 * 20 / 350
snapshots[1].kw = 350
for _ = 1, 30 do render() end
check(batteryRing().color.m > 0.98, 'eased brightness settles at full power')
snapshots[1].kw = 0
for _ = 1, 40 do render() end
check(colorEquals(batteryRing().color, batteryIdle), 'idle frames draw the idle ring while the easing decays')
snapshots[1].kw = -20
render()
check(sameHue(batteryRing().color, redHue) and batteryRing().color.m <= lightHarvest + 0.001, 'a flow after an idle stretch never inherits an earlier brightness')
snapshots[1].kw = 350
for _ = 1, 30 do render() end
snapshots[1].valid.kw = false
render()
snapshots[1].valid.kw, snapshots[1].kw = true, -20
render()
check(sameHue(batteryRing().color, redHue) and batteryRing().color.m <= lightHarvest + 0.001, 'an invalid update clears the easing at once')
snapshots[1].kw = 350
for _ = 1, 30 do render() end
for _ = 1, 30 do script.update(0.016) end   -- HUD window hidden: updates without drawing
snapshots[1].kw = -20
render()
check(sameHue(batteryRing().color, redHue) and near(batteryRing().color.m, lightHarvest), 'after a stretch without drawing the easing restarts from the raw value')
cfg.batterySmoothing = false
sim.dt = nil
print('Battery glyph (left terminal): flow states, Boost body, right-anchored fill, low charge, native and conventional cars, easing passed')

-- The two terminal sides are mirror images of each other about the dial's vertical axis. Every shape and
-- text box is mirrored, and text keeps its reading direction, so End and Start swap; the bolt is moved as
-- a whole, not flipped; the outline copies of the bolt and of the text keep their own offsets from what
-- they belong to.
local MIRROR_ALIGN = { [ui.Alignment.Start] = ui.Alignment.End, [ui.Alignment.Center] = ui.Alignment.Center,
  [ui.Alignment.End] = ui.Alignment.Start }
local MIRROR_CORNERS = { [0] = 0, [1] = 2, [2] = 1, [3] = 3, [4] = 8, [8] = 4, [12] = 12, [5] = 10, [10] = 5, [15] = 15 }
-- bolt = the core and the coloured symbol (outline colour excluded); outlines = every outline-coloured draw
local function glyphParts(scale)
  local part = { shapes = {}, bolt = {}, outlines = {} }
  for _, command in ipairs(commands) do
    if (command.kind == 'rect' or command.kind == 'border' or command.kind == 'quad' or command.kind == 'text')
      and not command.rotating and command.x + command.w <= 340 * scale + 0.001
      and command.y >= 265 * scale - 0.001 and command.y + command.h <= 295 * scale + 0.001 then
      local list = colorEquals(command.color, outlineColor) and part.outlines
        or (command.kind == 'quad' and part.bolt or part.shapes)
      list[#list + 1] = command
    end
  end
  return part
end
local function mirrored(a, b, scale)
  if a.kind ~= b.kind or not colorEquals(a.color, b.color) then return false end
  if not (near(b.x, 340 * scale - a.x - a.w) and near(b.y, a.y) and near(b.w, a.w) and near(b.h, a.h)) then return false end
  if a.kind == 'text' then return a.text == b.text and near(a.size, b.size) and b.horizontal == MIRROR_ALIGN[a.horizontal] end
  local corners = (a.corners == nil and b.corners == nil) or (a.corners ~= nil and MIRROR_CORNERS[a.corners] == b.corners)
  local rounding = (a.rounding == nil and b.rounding == nil) or (a.rounding ~= nil and b.rounding ~= nil and near(a.rounding, b.rounding))
  return corners and rounding
end
local function span(list)
  local x1, x2 = math.huge, -math.huge
  for _, command in ipairs(list) do x1, x2 = math.min(x1, command.x), math.max(x2, command.x + command.w) end
  return x1, x2
end
local BOLT_OUTLINE = { { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 } }
local function checkOutlines(part, scale, label)
  local outlineQuads = {}
  for _, command in ipairs(part.outlines) do
    if command.kind == 'quad' then
      outlineQuads[#outlineQuads + 1] = command
    else
      local owned = false
      for _, shape in ipairs(part.shapes) do
        if shape.kind == 'text' and shape.text == command.text and shape.horizontal == command.horizontal
          and near(shape.w, command.w) and near(shape.h, command.h)
          and near(math.abs(command.x - shape.x) + math.abs(command.y - shape.y), scale) then owned = true end
      end
      check(owned, label .. ': each outline copy sits one unit off its own text: ' .. tostring(command.text))
    end
  end
  -- the bolt: four outline copies, then the core, then the symbol, two quads each
  check(#part.bolt == 0 or #part.bolt == 4, label .. ': the bolt is a core and a symbol')
  check(#outlineQuads == 2 * #part.bolt, label .. ': four outline copies per bolt quad')
  if #part.bolt == 4 then
    local y1, y2 = math.huge, -math.huge
    for q = 3, 4 do y1, y2 = math.min(y1, part.bolt[q].y), math.max(y2, part.bolt[q].y + part.bolt[q].h) end
    check(near(y1, 274 * scale) and near(y2, 286 * scale), label .. ': the bolt spans y 274-286 at every scale')
    for q = 1, 2 do
      local core, symbol = part.bolt[q], part.bolt[q + 2]
      check(near(core.x, symbol.x) and near(core.y, symbol.y) and near(core.w, symbol.w) and near(core.h, symbol.h),
        label .. ': the core lies under the symbol')
      for k, d in ipairs(BOLT_OUTLINE) do
        local ghost = outlineQuads[(k - 1) * 2 + q]
        check(near(ghost.x, symbol.x + d[1] * scale) and near(ghost.y, symbol.y + d[2] * scale)
          and near(ghost.w, symbol.w) and near(ghost.h, symbol.h),
          label .. ': each bolt outline copy keeps its own offset')
      end
    end
  end
end
local mirrorStates = {
  { 'Pro deploying', 'pro', { boost = false, kw = 200 } },
  { 'Pro harvesting', 'pro', { boost = false, kw = -200 } },
  { 'Pro Boost', 'pro', { boost = true, kw = 175 } },
  { 'Pro Boost at a single-digit charge', 'pro', { boost = true, kw = 350, soc = 0.094 } },
  { 'Pro low charge', 'pro', { boost = false, kw = 250, soc = 0.08 } },
  { 'Pro full and idle', 'pro', { boost = false, kw = 3, soc = 1 } },
  { 'Pro empty', 'pro', { boost = false, kw = -100, soc = 0 } },
  { 'Pro unknown charge', 'pro', { boost = false, kw = 120 }, { soc = false } },
  { 'Pro unknown power', 'pro', { boost = false }, { kw = false } },
  { 'native recovering under Boost', 'vanilla', {} },
  { 'native deploying', 'vanilla', { boost = false, recovering = false, deployInput = 0.5 } },
  { 'native Boost with an unknown charge', 'vanilla', { deployInput = 0.5 }, { soc = false } },
}
cfg.batterySmoothing, cfg.showBattery, cfg.showPanel, cfg.lang, sim.focusedCar = false, true, true, 'en', 1
local mirrorCases = 0
for _, scale in ipairs({ 0.5, 1, 2.5 }) do
  cfg.scale = scale
  for _, case in ipairs(mirrorStates) do
    local label = case[1] .. ' at scale ' .. tostring(scale)
    local parts = {}
    for _, side in ipairs({ 'left', 'right' }) do
      cfg.batteryTerminal = side
      snapshots[1] = fixture(case[2])
      for key, value in pairs(case[3]) do snapshots[1][key] = value end
      for key, value in pairs(case[4] or {}) do snapshots[1].valid[key] = value end
      render()
      parts[side] = glyphParts(scale)
      checkOutlines(parts[side], scale, label .. ' (' .. side .. ')')
    end
    local left, right = parts.left, parts.right
    check(#left.shapes >= 5 and #left.shapes == #right.shapes, label .. ': the same shapes on both sides')
    for k = 1, #left.shapes do
      check(mirrored(left.shapes[k], right.shapes[k], scale),
        label .. ': ' .. tostring(left.shapes[k].text or left.shapes[k].kind) .. ' #' .. k .. ' is mirrored')
    end
    check(#left.bolt == #right.bolt and #left.outlines == #right.outlines, label .. ': the same bolt and outline draws on both sides')
    if #left.bolt > 0 then
      local l1, l2 = span(left.bolt)
      local r1, r2 = span(right.bolt)
      check(near(r1, 340 * scale - l2) and near(r2, 340 * scale - l1), label .. ': the bolt takes the mirrored place')
      for k = 1, #left.bolt do
        local a, b = left.bolt[k], right.bolt[k]
        check(colorEquals(a.color, b.color) and near(b.x - r1, a.x - l1) and near(b.y, a.y) and near(b.w, a.w) and near(b.h, a.h),
          label .. ': the bolt symbol is moved, not flipped')
      end
    end
    mirrorCases = mirrorCases + 1
  end
end

-- The default right-terminal layout spelled out at scale 1.
cfg.scale, cfg.batteryTerminal = 1, 'right'
snapshots[1] = fixture('pro')
snapshots[1].boost, snapshots[1].kw = false, 200
render()
check(batteryBody() and near(batteryBody().x, 122) and colorEquals(batteryBody().color, dark) and batteryRing(),
  'right terminal: the body starts at the left edge of the slot')
check(batteryNub() and batteryNub().corners == ui.CornerFlags.Right and sameHue(batteryNub().color, green),
  'right terminal: the nub closes the slot on the right, rounded on its outer side, in the flow hue')
fill = batteryFill()
check(fill and near(fill.x, 124.5) and near(fill.w, 87 * 0.75) and fill.corners == ui.CornerFlags.Left,
  'right terminal: the fill is anchored to the left wall')
local rightDigits = batteryDigits('75%')
check(rightDigits and near(rightDigits.w, 72) and near(rightDigits.x + rightDigits.w, 210) and rightDigits.horizontal == ui.Alignment.End,
  'right terminal: the percentage is right-aligned beside the terminal')
boltLeft, boltRight = boltSpan()
check(near(boltLeft, 128) and near(boltRight, 136), 'right terminal: the bolt sits at the anchored end')
check(near(span(glyphParts(1).bolt), 128), 'right terminal: the core lies under the bolt')
check(rightDigits.x >= boltRight + 2 - 0.001, 'right terminal: the percentage box starts 2 units after the bolt')
check(boltLeft >= fill.x and boltRight <= fill.x + fill.w, 'right terminal: at 75 % the bolt lies over the fill')
snapshots[1].soc = 0.5
render()
check(batteryFill() and near(batteryFill().x + batteryFill().w, 124.5 + 87 * 0.5), 'right terminal: less charge ends the fill further left')
snapshots[1].soc, snapshots[1].boost = 0.094, true
render()
local rightWord = findTextAt('BOOST', 136, 270)
check(rightWord and batteryDigits('9%') and batteryDigits('9%').horizontal == ui.Alignment.End,
  'right terminal: a single-digit charge follows BOOST, right-aligned beside the terminal')
check(near(rightWord.x + rightWord.w, 210 - numberWidth) and rightWord.horizontal == ui.Alignment.Center,
  'right terminal: the word is centred between the bolt and the number')
check(rightWord.w >= ui.measureDWriteText('BOOST', 13).x, 'right terminal: the word still fits')
snapshots[1].boost, snapshots[1].valid.soc = false, false
render()
check(batteryDigits('--') and batteryDigits('--').horizontal == ui.Alignment.End and not batteryFill() and quads() == 0,
  'right terminal: an invalid charge reads -- in the same place, without fill or bolt')
cfg.batteryTerminal = 'up'
snapshots[1] = fixture('pro')
render()
check(boxAt('rect', 122, 270, 92, 20) and boxAt('rect', 214, 276, 4, 8) and not boxAt('rect', 126, 270, 92, 20),
  'any stored value other than left draws the default right terminal')
cfg.batteryTerminal = 'right'
print('Battery terminal: ' .. tostring(mirrorCases) .. ' mirrored state/scale pairs and the right-terminal layout passed')

-- Settings window: the terminal side is a pair of radio buttons right under the glyph switch.
local widgets, clickOn = {}, nil
local function widget(kind, label, state) widgets[#widgets + 1] = { kind = kind, label = label, state = state } end
ui.header = function(label) widget('header', label) end
ui.alignTextToFramePadding = function() widget('align') end
ui.text = function(value) widget('text', value) end
ui.sameLine = function() end
ui.itemHovered = function() return true end
ui.setTooltip = function(value) widget('tooltip', value) end
ui.radioButton = function(label, checked) widget('radio', label, checked); return label == clickOn end
ui.checkbox = function(label, checked) widget('checkbox', label, checked); return label == clickOn end
ui.slider = function(_, value) return value end
ui.inputText = function(_, value) return value, false end
local function openSettings(click)
  widgets, clickOn = {}, click
  script.windowSettings(0.016)
end
local function widgetAt(kind, label)
  for k, item in ipairs(widgets) do
    if item.kind == kind and item.label == label then return k, item end
  end
end
local leftButton, rightButton = 'Left##batteryTerminal', 'Right##batteryTerminal'
local function sides()
  local _, left = widgetAt('radio', leftButton)
  local _, right = widgetAt('radio', rightButton)
  return left, right
end
cfg.lang, cfg.batteryTerminal, cfg.showDiagText = 'en', 'right', false
openSettings()
local glyphRow = widgetAt('checkbox', 'Battery glyph in the dial (off: BOOST badge)')
local labelRow = widgetAt('text', 'Battery terminal:')
local leftRadio, rightRadio = sides()
check(glyphRow and labelRow == glyphRow + 2 and widgets[glyphRow + 1].kind == 'align',
  'the terminal row follows the glyph switch, its label aligned with the buttons')
check(leftRadio and leftRadio.state == false and rightRadio and rightRadio.state == true, 'the default side is shown as Right')
local tips = 0
for _, item in ipairs(widgets) do
  if item.kind == 'tooltip' and item.label:find('Right (default)', 1, true) and item.label:find('mirror', 1, true) then tips = tips + 1 end
end
check(tips == 3, 'the label and both buttons explain the choice on hover, naming the default')
cfg.batteryTerminal = 'up'
openSettings()
leftRadio, rightRadio = sides()
check(leftRadio.state == false and rightRadio.state == true, 'an unknown stored value is shown as the Right it draws')
openSettings(leftButton)
check(cfg.batteryTerminal == 'left', 'choosing Left stores the left terminal')
openSettings()
leftRadio, rightRadio = sides()
check(leftRadio.state == true and rightRadio.state == false, 'the stored side is shown')
snapshots[1] = fixture('pro')
render()
check(batteryBody() and near(batteryBody().x, 126) and boxAt('rect', 122, 276, 4, 8), 'the dial draws the stored side on the next frame')
openSettings(rightButton)
check(cfg.batteryTerminal == 'right', 'choosing Right restores the default')
render()
check(batteryBody() and near(batteryBody().x, 122) and boxAt('rect', 214, 276, 4, 8), 'and the dial follows back')
openSettings(leftButton)
cfg.lang = 'zh'
leftButton, rightButton = '左##batteryTerminal', '右##batteryTerminal'
openSettings()
leftRadio, rightRadio = sides()
check(widgetAt('text', '电池接头：') and leftRadio and rightRadio and leftRadio.state == true and rightRadio.state == false,
  'the terminal row is translated')
tips = 0
for _, item in ipairs(widgets) do
  if item.kind == 'tooltip' and item.label:find('右（默认）', 1, true) and item.label:find('镜像', 1, true) then tips = tips + 1 end
end
check(tips == 3, 'the hover text is translated')
openSettings(rightButton)
check(cfg.batteryTerminal == 'right', 'the translated Right button stores the same value')
openSettings(leftButton)
check(cfg.batteryTerminal == 'left', 'the translated Left button stores the same value')
openSettings(rightButton)
-- the rest of the window, including the log-mode readout, still runs
cfg.lang, cfg.showDiagText = 'en', true
snapshots[1].full = true
render()
openSettings()
check(widgetAt('header', 'Diagnostics') and widgetAt('text', 'Source: fixture'), 'the whole settings window runs with the log-mode readout')
cfg.showDiagText = false
print('Settings: terminal side radio buttons, hover text and translation passed')

snapshots[1] = fixture('pro')
snapshots[1].soc, snapshots[1].kw, snapshots[1].strat = 0, 0, 0
snapshots[1].valid = { soc = true, kw = true, strat = true }
render()
check(findText('0%  0.00 / 4 MJ') and batteryDigits('0%') and not batteryFill(), 'invalid raw ESOC cannot override valid zero SOC in Pro energy readouts')
check(findText('+0 kW') and not textContains('cap 350') and not textContains('Deploy 1.25'), 'partial Pro fields show valid zero and suppress invalid cap and lap values')
check(findText('STRAT 0   split --') and findText('PU --'), 'partial Pro strategy retains valid zero and marks missing split/PU')

local latchColors = { [0] = dark, [1] = rgbm(1, 1, 1, 1),
  [2] = rgbm(12 / 255, 96 / 255, 221 / 255, 1), [3] = rgbm(0.95, 0.75, 0.15, 1) }
for latch = 0, 3 do
  snapshots[1] = { kind = 'pro', speed = 150, latch = latch, valid = { latch = true } }
  render()
  check(colorEquals(matchingFill(findText('SM')), latchColors[latch]), 'Pro latch state retains original badge colour: ' .. tostring(latch))
end
snapshots[1].speed = 0
render()
check(colorEquals(matchingFill(findText('SM')), dark), 'stationary Pro does not illuminate the availability/pre-latch indication')
snapshots[1] = { kind = 'vanilla', speed = 150, smAvailable = true, latch = 2,
  wingF = true, wingR = true, valid = { smAvailable = true, latch = true, wingF = true, wingR = true } }
render()
check(colorEquals(matchingFill(findText('SM')), yellow), 'standard SM availability is the in-zone yellow and ignores Pro latch/wing fields')
-- The standard car's SM has three states. Its native availability exists only inside the zone, so it is
-- always the Pro's yellow "available, already in the zone", never the white pre-latch prompt.
local black, dimText = rgbm(0, 0, 0, 1), rgbm(1, 1, 1, 0.35)
local standardSm = {
  { active = false, available = false, fill = dark, ink = dimText },
  { active = false, available = true, fill = yellow, ink = black },
  { active = true, available = true, fill = green, ink = rgbm(1, 1, 1, 1) },
  { active = true, available = false, fill = green, ink = rgbm(1, 1, 1, 1) },
}
for _, case in ipairs(standardSm) do
  for _, speed in ipairs({ 150, 0 }) do
    snapshots[1] = { kind = 'vanilla', speed = speed, smActive = case.active, smAvailable = case.available,
      valid = { smActive = true, smAvailable = true } }
    render()
    local sm, label = findText('SM'), 'active ' .. tostring(case.active) .. ', available ' .. tostring(case.available) .. ', ' .. speed .. ' km/h'
    check(sm and near(sm.x, 122) and near(sm.w, 96), 'standard SM spans the row: ' .. label)
    check(colorEquals(matchingFill(sm), case.fill) and colorEquals(sm.color, case.ink), 'standard SM colours: ' .. label)
    check(not findText('OT'), 'no OT badge in any standard SM state: ' .. label)
  end
end
snapshots[1] = { kind = 'vanilla', speed = 150, smActive = true, smAvailable = true, valid = { smAvailable = true } }
render()
check(colorEquals(matchingFill(findText('SM')), yellow), 'an unverified open flag cannot turn available into open')
snapshots[1].valid = {}
render()
check(colorEquals(matchingFill(findText('SM')), dark), 'unverified standard SM stays dark')

snapshots[2] = fixture('drs')
snapshots[2].drsPresent, snapshots[2].drsActive = false, false
sim.focusedCar = 2
render()
check(findText('DRS') and colorEquals(matchingFill(findText('DRS')), dark), 'vehicle without DRS retains a permanently dark DRS label')
snapshots[2].drsActive, snapshots[2].valid.drsActive = true, false
render()
check(colorEquals(matchingFill(findText('DRS')), dark), 'missing DRS state cannot illuminate using stale raw true')

sim.isReplayActive = true
sim.replayCurrentFrame, sim.replayPlaybackRate = 120, 1
snapshots[2] = fixture('drs')
render()
check(lastReadMode == 'replay' and colorEquals(matchingFill(findText('DRS')), green), 'replay uses the replay snapshot reader')
sim.replayPlaybackRate = 0
snapshots[2].drsActive = false
render()
check(colorEquals(matchingFill(findText('DRS')), dark), 'paused repaint reads the current snapshot without retained active state')
sim.replayCurrentFrame = 20
snapshots[2] = { kind = 'drs', valid = {}, speed = 10, rpm = 1000, gear = 1 }
render()
check(findText('10') and colorEquals(matchingFill(findText('DRS')), dark), 'reverse seek to missing history clears future state')

snapshots[3] = false
sim.focusedCar = 3
render()
check(findText('DRS') and colorEquals(matchingFill(findText('DRS')), dark) and panels() == 0, 'failed car read clears former layout and lamps')
sim.focusedCar, sim.closelyFocusedCar = -1, 2
render()
check(lastReadIndex == 2, 'closely focused car is used when primary camera target is unavailable')
cfg.lockPlayer = true
render()
check(lastReadIndex == 0 and findText('PU RACE'), 'player lock intentionally selects car zero')
cfg.lockPlayer, cfg.followFocused = false, false
render()
check(lastReadIndex == 0, 'follow-focused disabled intentionally selects car zero')
check(recordCalls > cases, 'HUD update continues invoking product replay recording')
check(savedLogWrites == 1, 'UI tests write no probe CSV and no periodic diagnostic output')
print('UI switching, missing/zero/false validity, pause/seek and source routing passed')

-- Pedal arcs and the recovery chip draw the adapter values of the current update without filtering:
-- AC gearbox assists (auto-shifter throttle cut, auto-blip) stay visible by design.
local function fire(event, ...)
  for _, callback in ipairs(callbacks[event]) do callback(...) end
end
local red = rgbm(245 / 255, 45 / 255, 33 / 255, 1)
local function close(a, b) return math.abs(a - b) <= 1e-6 end
local function visibleGas()
  for _, command in ipairs(commands) do
    if command.kind == 'arc' and colorEquals(command.color, green)
      and near(command.r, 119.5) and near(command.a0, math.rad(124)) then
      return (math.deg(command.a1) - 124) / 184
    end
  end
  return 0
end
local function visibleBrake()
  for _, command in ipairs(commands) do
    if command.kind == 'arc' and colorEquals(command.color, red)
      and near(command.r, 119.5) and near(command.a0, math.rad(56)) then
      return (56 - math.deg(command.a1)) / 100
    end
  end
  return 0
end
local function recoveryLit()
  return colorEquals(matchingFill(findText('Recovering')), red)
end

cfg.scale, cfg.lang, cfg.showPanel, cfg.showBattery, cfg.lockPlayer, cfg.followFocused = 1, 'en', true, true, false, true
sim.focusedCar, sim.closelyFocusedCar, sim.isReplayActive, sim.dt = 0, 0, false, 0.015
-- gas, brake, gear, recovering: full throttle, one-frame auto-shift cut and partial frame, braking,
-- auto-blip while the old gear is still shown, engagement and decay, plus single-update recovery pulses.
local sequence = {
  { 1, 0, 5, false }, { 0, 0, 6, true }, { 0.5, 0, 6, false }, { 1, 0, 6, false },
  { 0, 0.8, 6, true }, { 0.94, 0.8, 6, false }, { 0.94, 0.8, 5, false }, { 0.37, 0.8, 5, true },
  { 0, 0.8, 5, true }, { 0, 0.8, 5, false },
}
for _, replay in ipairs({ false, true }) do
  for _, kind in ipairs({ 'vanilla', 'pro', 'drs' }) do
    sim.isReplayActive, sim.replayCurrentFrame, sim.replayFrameMs, sim.replayPlaybackRate = replay, 100, 15, 1
    snapshots[0] = fixture(kind)
    for i, step in ipairs(sequence) do
      snapshots[0].gas, snapshots[0].brake, snapshots[0].gear = step[1], step[2], step[3]
      if kind == 'vanilla' then snapshots[0].recovering = step[4] end
      sim.replayCurrentFrame = sim.replayCurrentFrame + 1
      render()
      local label = kind .. (replay and ' replay' or ' live') .. ' step ' .. i
      check(close(visibleGas(), step[1]) and close(visibleBrake(), step[2]), 'pedal arcs draw the current values without filtering: ' .. label)
      if kind == 'vanilla' then check(recoveryLit() == step[4], 'recovery chip draws the current state without debounce: ' .. label) end
      check(canonicalView.gas == step[1] and canonicalView.brake == step[2], 'canonical pedal values are the drawn values: ' .. label)
    end
  end
end
snapshots[0] = fixture('vanilla')
snapshots[0].gas, snapshots[0].recovering = 1, true
sim.isReplayActive, sim.dt = false, 0.015
render()
sim.dt = 0
snapshots[0].gas, snapshots[0].recovering = 0.2, false
render()
check(close(visibleGas(), 0.2) and not recoveryLit(), 'pause shows the current values; there is no retained display state')
sim.dt = 0.015
check(cfg.hideShiftTransients == nil and cfg.smoothNative == nil, 'no pedal or recovery display filter setting exists')
print('Raw pedal arcs and recovery chip: ' .. tostring(#sequence) .. '-step assist sequence, three adapters, live and replay passed')

-- Replay gap diagnostics (never drawn): short holes in recorded native history are counted.
local logged = {}
ac.log = function(line) logged[#logged + 1] = line end
ac.getCar = function() return nil end
local fakeClock = 1000
local realClock = os.clock
os.clock = function() return fakeClock end
local function lastGapReport()
  cfg.diagnostics, cfg.logDiag = true, true
  fakeClock = fakeClock + 10
  logged = {}
  render()
  cfg.diagnostics, cfg.logDiag = false, false
  for _, line in ipairs(logged) do
    local count, frame = line:match('replayGaps=(%d+)@(%-?%d+)')
    if count then return tonumber(count), tonumber(frame) end
  end
end
local function playFrames(count, available, field)
  for _ = 1, count do
    sim.replayCurrentFrame = sim.replayCurrentFrame + 1
    snapshots[0].valid[field] = available
    render()
  end
end
sim.isReplayActive, sim.replayCurrentFrame, sim.replayFrameMs, sim.replayPlaybackRate, sim.dt = true, 500, 15, 1, 0.015
snapshots[0] = fixture('vanilla')
local baseCount = select(1, lastGapReport()) or 0
fire('replay', 'start')
playFrames(1, false, 'soc')                     -- unrecorded start of a replay is not a gap
playFrames(5, true, 'soc')
local holeFrame = sim.replayCurrentFrame + 1
playFrames(1, false, 'soc')
playFrames(3, true, 'soc')
local count, frame = lastGapReport()
check(count == baseCount + 1 and frame == holeFrame, 'a one-frame hole between recorded frames is counted at its frame')
playFrames(12, false, 'soc')
playFrames(2, true, 'soc')
check(select(1, lastGapReport()) == baseCount + 1, 'a long missing stretch is not reported as a short hole')
playFrames(2, false, 'soc')
fire('replay', 'jump')
playFrames(2, true, 'soc')
check(select(1, lastGapReport()) == baseCount + 1, 'a replay jump restarts gap tracking')
sim.replayCurrentFrame = sim.replayCurrentFrame - 40
playFrames(1, false, 'soc')
playFrames(1, true, 'soc')
check(select(1, lastGapReport()) == baseCount + 1, 'a backward seek restarts gap tracking')
snapshots[0] = fixture('drs')
playFrames(3, true, 'drsActive')
playFrames(2, false, 'drsActive')
playFrames(1, true, 'drsActive')
check(select(1, lastGapReport()) == baseCount + 2, 'conventional-car DRS history holes are counted too')
sim.isReplayActive = false
playFrames(1, false, 'drsActive')
playFrames(1, true, 'drsActive')
check(select(1, lastGapReport()) == baseCount + 2, 'live sessions never count replay gaps')
os.clock = realClock
print('Replay gap diagnostics: hole, long stretch, jump, seek, DRS subset and live checks passed')
print('UI assertions passed: ' .. tostring(checks))
