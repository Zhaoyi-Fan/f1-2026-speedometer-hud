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
  drawRectFilled = function(a, b, color)
    emit({ kind = 'rect', x = a.x, y = a.y, w = b.x - a.x, h = b.y - a.y, color = color })
  end,
  drawRect = function(a, b, color)
    emit({ kind = 'border', x = a.x, y = a.y, w = b.x - a.x, h = b.y - a.y, color = color })
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
    result.strategy, result.otActive, result.otPending = 3, false, false
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
-- Battery glyph geometry at scale 1: body (126, 270) 92 x 20, digits box (142, 270) 72 x 20, nub (122, 276) 4 x 8.
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
local function batteryBody(scale) scale = scale or 1; return boxAt('rect', 126 * scale, 270 * scale, 92 * scale, 20 * scale) end
local function batteryRing(scale) scale = scale or 1; return boxAt('border', 126 * scale, 270 * scale, 92 * scale, 20 * scale) end
local function batteryDigits(value, scale) scale = scale or 1; return findTextAt(value, 142 * scale, 270 * scale) end
local function sameHue(a, b) return a and b and near(a.r, b.r) and near(a.g, b.g) and near(a.b, b.b) end
for _, kind in ipairs({ 'pro', 'vanilla', 'drs' }) do
  for _, lang in ipairs({ 'en', 'zh' }) do
    for _, scale in ipairs({ 0.5, 1, 2.5 }) do
      for _, showBattery in ipairs({ false, true }) do
        for _, showPanel in ipairs({ false, true }) do
          cases = cases + 1
          cfg.lang, cfg.scale, cfg.showBattery, cfg.showPanel = lang, scale, showBattery, showPanel
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
            check(findText('SM') and findText('OT') and not findText('DRS'), '2026 badge cluster retained')
            if showBattery then
              check(not findText('BOOST') and batteryBody(scale) and batteryRing(scale), 'battery glyph replaces the BOOST badge')
              check(batteryDigits(kind == 'pro' and '75%' or '50%', scale), 'battery digits sit inside the glyph')
              check(colorEquals(batteryBody(scale).color, boostColor) and quads() == 4, 'Boost button colours the battery body; bolt drawn')
            else
              check(findText('BOOST') and not batteryBody(scale) and quads() == 0, 'BOOST badge returns when the glyph is off')
              check(colorEquals(matchingFill(findText('BOOST')), boostColor), 'BOOST badge shows the button')
            end
            if kind == 'pro' then
              check(colorEquals(matchingFill(findText('OT')), green), 'Pro OT retains its active indication')
              if panel then check(findText('MGU-K') and textContains('MJ') and findText('PU RACE'), 'Pro panel keeps energy and PU fields') end
            else
              check(not textContains('MJ') and not textContains('kW') and not textContains('PU ') and not findText('MGU-K'), 'ordinary layout excludes Pro-only quantities')
              check(colorEquals(matchingFill(findText('OT')), dark), 'ordinary OT remains dark')
              if panel then
                check(findText('NODEPLOY') and findText('50%'), 'ordinary strategy and battery percentage shown')
                local label = findText(lang == 'zh' and '电池' or 'Battery')
                check(label and label.font == (lang == 'zh' and 'Microsoft YaHei UI' or 'Bahnschrift'), 'localized label uses expected font family')
              end
            end
          end
          assertBounds(kind .. '/' .. lang .. '/' .. tostring(scale))
        end
      end
    end
  end
end
print('UI matrix: ' .. tostring(cases) .. ' vehicle/language/scale/panel/battery combinations passed')

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

-- Battery glyph: state and hue from the current update, body from the Boost button, fill anchored to the
-- right wall, easing of the ring brightness only.
cfg.batterySmoothing = false
local redHue = rgbm(245 / 255, 45 / 255, 33 / 255, 1)
local function batteryFill()
  for _, command in ipairs(commands) do
    if command.kind == 'rect' and (colorEquals(command.color, batteryColor) or colorEquals(command.color, yellow))
      and command.y > 270 and command.y < 290 and command.x > 126 then return command end
  end
end
snapshots[1] = fixture('pro')                                   -- kw 175, boost true
render()
check(sameHue(batteryRing().color, boostColor) and near(batteryRing().color.m, 0.35 + 0.65 * 0.5), 'Boost while deploying: magenta ring at |kW| / 350 brightness')
check(colorEquals(batteryBody().color, boostColor), 'Boost button colours the body')
snapshots[1].boost, snapshots[1].kw = false, 200
render()
check(sameHue(batteryRing().color, green) and colorEquals(batteryBody().color, dark), 'deploying without Boost: green ring, dark body')
local fill = batteryFill()
check(fill and near(fill.x + fill.w, 215.5) and near(fill.w, 87 * 0.75), 'charge fill is anchored to the right wall and scaled by SoC')
snapshots[1].kw = -200
render()
check(sameHue(batteryRing().color, redHue) and near(batteryRing().color.m, 0.35 + 0.65 * 200 / 350), 'harvesting: red ring')
local function boltColors()
  local colors = {}
  for _, command in ipairs(commands) do
    if command.kind == 'quad' and not colorEquals(command.color, rgbm(0, 0, 0, 0.85)) then colors[#colors + 1] = command.color end
  end
  return colors
end
check(#boltColors() == 2 and sameHue(boltColors()[1], redHue), 'the bolt takes the flow hue')
snapshots[1].boost = true
render()
check(sameHue(batteryRing().color, redHue) and colorEquals(batteryBody().color, boostColor), 'Boost held while harvesting: magenta body, red ring')
check(#boltColors() == 2 and colorEquals(boltColors()[1], rgbm(1, 1, 1, 1)) and colorEquals(boltColors()[2], rgbm(1, 1, 1, 1)), 'the bolt is white on the magenta Boost body')
snapshots[1].boost, snapshots[1].kw = false, 3
render()
check(colorEquals(batteryRing().color, batteryIdle) and quads() == 4, 'inside the 5 kW deadband the ring is idle and the bolt stays')
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
snapshots[1] = fixture('vanilla')                                -- recovering true, boost true
render()
check(sameHue(batteryRing().color, redHue) and near(batteryRing().color.m, 0.35 + 0.65 * 0.6), 'native recovery: red ring at the declared fixed intensity')
check(colorEquals(batteryBody().color, boostColor), 'native Boost button colours the body only')
snapshots[1].recovering = false
render()
check(colorEquals(batteryRing().color, batteryIdle), 'native car without recovery: idle ring, never green')
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
print('Battery glyph: flow states, Boost body, right-anchored fill, low charge, native and conventional cars, easing passed')

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
check(colorEquals(matchingFill(findText('SM')), rgbm(1, 1, 1, 1)), 'ordinary SM uses native availability and ignores Pro latch/wing fields')

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
