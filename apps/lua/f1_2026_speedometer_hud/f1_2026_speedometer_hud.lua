-- F1 2026 Speedometer HUD
-- Broadcast-style speedometer with exact FA26 Pro/native and conventional DRS adapters.
-- The original dial is shared; energy and state fields depend on the viewed vehicle.
-- Keeps the Pro energy stream and records verified native fields separately for slots 0-21.
-- Read-only with respect to car and track files (league-safe).
-- Source: https://github.com/Zhaoyi-Fan/f1-2026-speedometer-hud
-- Data contract (CAN channel names, replay layout): docs/DATA-CONTRACT.md in the repository.

local VERSION = '0.9.25'
local TAG = '[F1-2026-HUD]'
local MAX_CARS = 22          -- replay stream slots: 11 bytes per car -> 242 bytes per frame (limit 256)
local SPEED_MAX = 360        -- arc full scale; the numeric readout can exceed this
local KW_MAX = 350           -- MGU-K bar full scale (2026 MGU-K)
local ES_USABLE_MJ = 4       -- 2026 energy store usable window
local ES_FLOOR_MJ = 4        -- VRC: usable window sits on top of a 4 MJ floor (ESOC 4..8 MJ)

-- side bars flanking the dial (design units): left = usable battery, right = lap regen vs limit
local DIAL_W = 340
local BAR_MARGIN, BAR_W, BAR_GAP, BAR_LABEL_W = 13, 22, 14, 48
local BAR_TOP, BAR_H = 20, 280
local DIAL_INSET = BAR_MARGIN + BAR_W + BAR_GAP            -- 49: dial x offset when bars are shown
local RIGHT_BAR_X = DIAL_INSET + DIAL_W + BAR_GAP          -- 403
local BARS_TOTAL_W = RIGHT_BAR_X + BAR_W + BAR_MARGIN      -- 438
local PANEL_GAP, PANEL_W = 12, 308
local REPLAY_DIVISOR = 2     -- record every 2nd replay frame

local sim = ac.getSim()

local cfg = ac.storage({
  scale = 1.0,
  showPanel = true,
  showBars = true,
  followFocused = true,
  lockPlayer = false,
  recordReplay = true,
  diagnostics = true,
  logDiag = true,
  showDiagText = false,
  fontName = 'Bahnschrift',
  fontZh = 'Microsoft YaHei UI',
  lang = 'en',
}, 'f1_2026_hud')

-- Colours sampled from the original MultiViewer textures (disc = black 50 %, tracks = black 75 %,
-- speed #0C60DD, throttle #31AC33, brake #F52D21, labels #A0A0A0).
local C = {
  disc = rgbm(0, 0, 0, 0.5),
  track = rgbm(0.09, 0.09, 0.09, 1),   -- opaque: translucent tracks showed dark blobs where the round caps overlap (v0.1)
  blue = rgbm(12 / 255, 96 / 255, 221 / 255, 1),
  green = rgbm(49 / 255, 172 / 255, 51 / 255, 1),
  red = rgbm(245 / 255, 45 / 255, 33 / 255, 1),
  white = rgbm(1, 1, 1, 1),
  black = rgbm(0, 0, 0, 1),
  grey = rgbm(160 / 255, 160 / 255, 160 / 255, 1),
  dim = rgbm(1, 1, 1, 0.35),
  yellow = rgbm(0.95, 0.75, 0.15, 1),
  purple = rgbm(0.65, 0.55, 1, 1),
  orange = rgbm(1, 0.45, 0.1, 1),
  cyan = rgbm(0.2, 0.75, 1, 1),
  boost = rgbm(0.92, 0.2, 0.58, 1),   -- Boost button (dial pill + panel chip): magenta, used nowhere else so it never merges with SM / OT green
  panel = rgbm(0, 0, 0, 0.62),
  barTrack = rgbm(1, 1, 1, 0.12),
}

-- 1-based, same table the car's own dash uses (display\styles\style_0\pages.lua puModes); 11 = SLO is the yellow one
local PU_MODE_NAMES = { 'RACE', 'AD1', 'AD2', 'FS', 'FW', 'IN', 'ES', 'Q', 'K2', 'K2+', 'SLO', 'SC', 'T4', 'RS' }

-- UI strings. Broadcast abbreviations (SM, OT, Boost, PL, PLP, STRAT, PU, MGU-K, KMH, RPM, GEAR) stay
-- untranslated on purpose, like the on-air graphics on Chinese F1 broadcasts. Reviewed 2026-09-10.
local STR = {
  battery = { en = 'Battery', zh = '电池' },
  harvest = { en = 'harvest', zh = '回收' },
  recovering = { en = 'Recovering', zh = '正在回收' },
  cap = { en = 'cap %s kW', zh = '上限 %s kW' },
  clip = { en = 'clip %s kW', zh = '强制回收 %s kW' },
  lapEnergy = { en = 'Lap energy', zh = '本圈能量' },
  deploy = { en = 'Deploy %.2f MJ', zh = '部署 %.2f MJ' },
  regenLim = { en = 'Regen %.2f / %.1f MJ', zh = '回收 %.2f / %.1f MJ' },
  regen = { en = 'Regen %.2f MJ', zh = '回收 %.2f MJ' },
  strategy = { en = 'Strategy', zh = '策略' },
  stratSplit = { en = 'STRAT %s   split %s', zh = 'STRAT %s   分段 %s' },
  status = { en = 'Status', zh = '状态' },
  sm_off = { en = 'SM', zh = 'SM' },
  sm_avail = { en = 'SM avail', zh = 'SM 可用' },
  sm_pre = { en = 'SM pre-latch', zh = 'SM 已预锁' },
  sm_late = { en = 'SM late', zh = 'SM 区内可用' },
  sm_on = { en = 'SM ON', zh = 'SM 开启' },
  ot_active = { en = 'OT active', zh = 'OT 激活' },
  ot_pending = { en = 'OT pending', zh = 'OT 待激活' },
  boost = { en = 'Boost', zh = 'Boost' },
  charge = { en = 'Charge', zh = '充电模式' },
  pitLimiter = { en = 'Pit limiter', zh = '维修区限速' },
  language = { en = 'Language', zh = '语言' },
  display = { en = 'Display', zh = '显示' },
  scale = { en = 'Scale: %.2f', zh = '缩放：%.2f' },
  showPanel = { en = 'Show energy panel', zh = '显示能量面板' },
  showBars = { en = 'Show battery / regen bars beside the dial', zh = '表盘两侧显示电量和回收竖条' },
  follow = { en = 'Follow camera-focused car', zh = '跟随镜头聚焦的车' },
  lock = { en = 'Lock to player car', zh = '锁定玩家车' },
  font = { en = 'Font', zh = '字体' },
  fontZh = { en = 'Chinese label font', zh = '中文字体' },
  bindings = { en = 'Bindings', zh = '按键绑定' },
  togglePanel = { en = 'Toggle energy panel', zh = '切换能量面板' },
  replay = { en = 'Replay', zh = '回放' },
  record = { en = 'Record supported car states into replays', zh = '将已支持车辆的状态录进回放' },
  streamOk = { en = 'Stream: ok, %d car slots, every %d%s frame, %d bytes per frame', zh = '回放流：正常，%d 个车位，每 %d%s 帧记录一次，每帧 %d 字节' },
  streamErr = { en = 'Stream: unavailable: %s', zh = '回放流：不可用：%s' },
  recorded = { en = 'Cars recorded this frame: %d', zh = '本帧记录车辆数：%d' },
  diagnostics = { en = 'Diagnostics', zh = '诊断' },
  diagPanel = { en = 'Show data source and enable diagnostics', zh = '显示数据来源并启用诊断' },
  diagLog = { en = 'Write diagnostics to the CSP log every 5 s', zh = '每 5 秒把诊断写入 CSP 日志' },
  diagText = { en = 'Show technical readout (log mode)', zh = '显示技术读数（日志模式）' },
  version = { en = 'Version %s  |  replay mode: %s', zh = '版本 %s  |  回放模式：%s' },
  target = { en = 'Target car: %s (%s)  |  %s', zh = '目标车：%s (%s)  |  %s' },
  source = { en = 'Source: %s', zh = '数据来源：%s' },
  canReplay = { en = 'CAN map: not used in replays (data comes from the app stream)', zh = 'CAN 通道表：回放中不使用（数据来自应用回放流）' },
  canOk = { en = 'CAN map: %d channels (%s)', zh = 'CAN 通道表：%d 个通道 (%s)' },
  canNone = { en = 'CAN map: none (%s)', zh = 'CAN 通道表：无 (%s)' },
  diagFile = { en = 'Diag file: %s', zh = '诊断文件：%s' },
  aiProbe = { en = 'AI probe: %s', zh = 'AI 探针：%s' },
  replayNative = { en = 'Replay native: %s', zh = '回放原生值：%s' },
}

local function L(key)
  local e = STR[key]
  if not e then return key end
  if cfg.lang == 'zh' and e.zh then return e.zh end
  return e.en
end

-- ---------------------------------------------------------------------------------------------
-- helpers
-- ---------------------------------------------------------------------------------------------

local function clamp(v, a, b)
  if v < a then return a end
  if v > b then return b end
  return v
end

local function fmtInt(v) return string.format('%d', math.floor((v or 0) + 0.5)) end

local function valid(S, field)
  return S.valid and S.valid[field] == true
end

local function validAll(S, ...)
  for i = 1, select('#', ...) do
    if not valid(S, select(i, ...)) then return false end
  end
  return true
end

-- returns: numbers bold, numbers regular, label bold, label regular, dial label medium. Panel labels switch to the Chinese font
-- in zh mode (Bahnschrift has no CJK glyphs); digits and the dial stay on the main font.
local fontCache = { key = nil, bold = nil, regular = nil, labelBold = nil, labelRegular = nil, medium = nil }
local function getFonts()
  local name = cfg.fontName
  if name == nil or name == '' then name = 'Segoe UI' end
  local zhName = cfg.fontZh
  if zhName == nil or zhName == '' then zhName = 'Microsoft YaHei UI' end
  local labelName = (cfg.lang == 'zh') and zhName or name
  local key = name .. '|' .. labelName
  if fontCache.key ~= key then
    fontCache.key = key
    fontCache.bold = ui.DWriteFont(name):weight(ui.DWriteFont.Weight.Bold)
    fontCache.regular = ui.DWriteFont(name)
    fontCache.medium = ui.DWriteFont(name):weight(ui.DWriteFont.Weight.Medium)
    if labelName == name then
      fontCache.labelBold, fontCache.labelRegular = fontCache.bold, fontCache.regular
    else
      fontCache.labelBold = ui.DWriteFont(labelName):weight(ui.DWriteFont.Weight.Bold)
      fontCache.labelRegular = ui.DWriteFont(labelName)
    end
  end
  return fontCache.bold, fontCache.regular, fontCache.labelBold, fontCache.labelRegular, fontCache.medium
end

-- ---------------------------------------------------------------------------------------------
-- Model-specific telemetry and replay contracts live in a separate, independently tested module.
-- ---------------------------------------------------------------------------------------------
local data = require('hud_data').new(ac, sim, cfg)
local can, RS, rsErr = data.can, data.RS, data.rsErr
local readLive, readReplay = data.readLive, data.readReplay
local recordedCars = 0
local function clearSnap(S) for k in pairs(S) do S[k] = nil end end

-- ---------------------------------------------------------------------------------------------
-- target car + per-frame state
-- ---------------------------------------------------------------------------------------------

local view = {}
local diag = { aiProbe = 'n/a', nativeSocReplay = 'n/a', lastLog = -10, lastProbe = -10 }
-- Persistent diagnostics file: the CSP log is overwritten on every launch, this one accumulates
-- (Documents\Assetto Corsa\logs\f1_2026_speedometer_hud_diag.log, trimmed to the last DIAG_MAX_LINES).
local DIAG_MAX_LINES = 600
local diagPath = ac.getFolder(ac.FolderID.Logs) .. '\\f1_2026_speedometer_hud_diag.log'
local diagLines = {}
local diagDirty = false
do
  local ok, existing = pcall(io.load, diagPath, '')
  if ok and type(existing) == 'string' and existing ~= '' then
    for line in existing:gmatch('[^\r\n]+') do diagLines[#diagLines + 1] = line end
  end
end

local function diagStamp()
  local ok, d = pcall(os.date, '%Y-%m-%d %H:%M:%S')
  if ok and type(d) == 'string' then return d end
  return string.format('t+%.0fs', os.clock())
end

local function diagFileAppend(line)
  diagLines[#diagLines + 1] = diagStamp() .. ' ' .. line
  diagDirty = true
end

local function diagFileFlush()
  if not diagDirty then return end
  diagDirty = false
  if #diagLines > DIAG_MAX_LINES then
    local trimmed = {}
    for i = #diagLines - DIAG_MAX_LINES + 1, #diagLines do trimmed[#trimmed + 1] = diagLines[i] end
    diagLines = trimmed
  end
  pcall(io.save, diagPath, table.concat(diagLines, '\n') .. '\n', true)
end

local function targetCar()
  if cfg.lockPlayer or not cfg.followFocused then return 0 end
  local f = sim.focusedCar
  if f == nil or f < 0 then f = sim.closelyFocusedCar end
  if f == nil or f < 0 or f >= sim.carsCount then f = 0 end
  return f
end

local function refreshView()
  clearSnap(view)
  local idx = targetCar()
  local ok
  if sim.isReplayActive then ok = readReplay(view, idx) else ok = readLive(view, idx) end
  if not ok then
    view.kind, view.valid = 'drs', {}
    view.source = 'no car'
    view.speed, view.rpm, view.gear, view.gas, view.brake = 0, 0, 0, 0, 0
  end
end

-- Diagnostics only, never used for drawing: counts short holes in recorded native history during
-- forward playback (available, missing for at most REPLAY_GAP_MAX_FRAMES frames, available again).
-- Recordings made with the current writer should report 0.
local REPLAY_GAP_MAX_FRAMES, REPLAY_STEP_MAX_FRAMES = 10, 8
local replayGaps = { count = 0, lastFrame = -1 }
local function resetReplayGapTracking()
  replayGaps.seen, replayGaps.missingFrom, replayGaps.frame = false, nil, nil
end
if type(ac.onReplay) == 'function' then pcall(ac.onReplay, resetReplayGapTracking) end

local function trackReplayGaps()
  local g, frame = replayGaps, sim.replayCurrentFrame
  if not sim.isReplayActive or type(frame) ~= 'number' or (view.kind ~= 'vanilla' and view.kind ~= 'drs') then
    resetReplayGapTracking()
    return
  end
  if g.index ~= view.index or g.carID ~= view.carID
      or (g.frame ~= nil and (frame < g.frame or frame - g.frame > REPLAY_STEP_MAX_FRAMES)) then
    resetReplayGapTracking()
  end
  g.index, g.carID, g.frame = view.index, view.carID, frame
  if valid(view, 'soc') or valid(view, 'drsActive') then
    if g.seen and g.missingFrom ~= nil and frame - g.missingFrom <= REPLAY_GAP_MAX_FRAMES then
      g.count, g.lastFrame = g.count + 1, g.missingFrom
    end
    g.seen, g.missingFrom = true, nil
  elseif g.seen and g.missingFrom == nil then
    g.missingFrom = frame
  end
end

local function runDiagnostics()
  local now = os.clock()
  if now - diag.lastProbe > 2 then
    diag.lastProbe = now
    -- Read the other car through its own adapter; never interpret a mixed grid as Pro CAN.
    diag.aiProbe, diag.nativeSocReplay = 'n/a', 'n/a'
    if not sim.isReplayActive and sim.carsCount > 1 then
      local other = {}
      if readLive(other, 1) then
        diag.aiProbe = string.format('car 1 %s: %s, soc=%s kW=%s',
          tostring(other.name), tostring(other.source), tostring(other.soc), tostring(other.kw))
      end
    elseif sim.isReplayActive then
      local car = ac.getCar(targetCar())
      if car then
        diag.nativeSocReplay = string.format('car %d native kersCharge %.3f, kersInput %.3f, extraH %s, extraI %s',
          car.index, car.kersCharge or -1, car.kersInput or -1, tostring(car.extraH), tostring(car.extraI))
      end
    end
  end
  if cfg.logDiag and now - diag.lastLog > 5 then
    diag.lastLog = now
    local canState
    if sim.isReplayActive then canState = 'n/a (replay)'
    elseif can.inputs then canState = string.format('ok (%d ch)', can.count)
    else canState = 'none: ' .. tostring(can.err) end
    local l1 = string.format('%s src=%s | car=%s (%s) | CAN=%s | session=%s replay=%s stream=%s recorded=%d | replayGaps=%d@%s | %s | %s',
      TAG, tostring(view.source), tostring(view.index), tostring(view.name), canState,
      tostring(sim.raceSessionType), tostring(sim.isReplayActive), RS and 'ok' or ('ERR ' .. tostring(rsErr)), recordedCars,
      replayGaps.count, tostring(replayGaps.lastFrame), diag.aiProbe, diag.nativeSocReplay)
    ac.log(l1)
    diagFileAppend(l1)
    if view.full then
      local l2 = string.format('%s soc=%.3f esoc=%s kW=%.1f cap=%.0f dep=%.2f reg=%.2f/%.2f strat=%s split=%s pu=%s ot=%s/%s boost=%s chg=%s pl=%s/%s latch=%s smAct=%s wings=%s/%s spd=%.0f gear=%s gas=%.2f',
        TAG, view.soc or -1, tostring(view.esoc), view.kw or 0, view.cap or 0, view.deploy or 0, view.regen or 0, view.regenLimit or 0,
        tostring(view.strat), tostring(view.split), tostring(view.puMode), tostring(view.otActive), tostring(view.otPending),
        tostring(view.boost), tostring(view.charge), tostring(view.pl), tostring(view.plp), tostring(view.latch), tostring(view.smActive),
        tostring(view.wingF), tostring(view.wingR), view.speed or 0, tostring(view.gear), view.gas or 0)
      ac.log(l2)
      diagFileAppend(l2)
    elseif view.kind == 'vanilla' or view.kind == 'drs' then
      local gaps = data.recordingGaps or {}
      local l2 = string.format('%s native kind=%s soc=%s boost=%s strategy=%s recovering=%s drs=%s/%s/%s sm=%s/%s valid=%s/%s/%s/%s/%s nativeStream=%s recordedNative=%d/%d emptyNative=%d lastEmpty=%s:%s',
        TAG, tostring(view.kind), tostring(view.soc), tostring(view.boost), tostring(view.strategyName),
        tostring(view.recovering), tostring(view.drsPresent), tostring(view.drsAvailable), tostring(view.drsActive),
        tostring(view.smAvailable), tostring(view.smActive), tostring(valid(view, 'soc')), tostring(valid(view, 'boost')),
        tostring(valid(view, 'strategy')), tostring(valid(view, 'recovering')), tostring(valid(view, 'drsActive')),
        data.VRS and 'ok' or tostring(data.vrsErr), data.recordedVanilla or 0, data.recordedDRS or 0,
        gaps.totalNativeEmpty or 0, tostring(gaps.lastNativeIndex or -1), tostring(gaps.lastNativeReason or 'none'))
      ac.log(l2)
      diagFileAppend(l2)
    end
    diagFileFlush()
  end
end

-- ---------------------------------------------------------------------------------------------
-- control buttons (bind in this app's settings window or in CSP controls)
-- ---------------------------------------------------------------------------------------------

local btnPanel = ac.ControlButton('f1_2026_speedometer_hud/Toggle energy panel')
local btnLock = ac.ControlButton('f1_2026_speedometer_hud/Lock to player car')

do
  local hello = string.format('%s v%s loaded, CSP build %s, replay stream %s, track %s, car0 %s, replay mode %s',
    TAG, VERSION, tostring(ac.getPatchVersionCode()), RS and 'ok' or ('unavailable: ' .. tostring(rsErr)),
    tostring(ac.getTrackFullID and ac.getTrackFullID('/') or ac.getTrackID()), tostring(ac.getCarID(0)), tostring(sim.isReplayActive))
  ac.log(hello)
  diagFileAppend('---- launch ----')
  diagFileAppend(hello)
  diagFileFlush()
end

function script.update(dt)
  if btnPanel:pressed() then cfg.showPanel = not cfg.showPanel end
  if btnLock:pressed() then cfg.lockPlayer = not cfg.lockPlayer end
  recordedCars = data.recordAll()
  refreshView()
  trackReplayGaps()
  if cfg.diagnostics then runDiagnostics() end
end

-- ---------------------------------------------------------------------------------------------
-- drawing primitives (design units: 340 x 340 dial, scaled by s)
-- ---------------------------------------------------------------------------------------------

local function arc(center, r, a0deg, a1deg, width, color)
  if a0deg == a1deg then return end
  local a0, a1 = math.rad(a0deg), math.rad(a1deg)
  local segs = math.max(6, math.floor(math.abs(a1deg - a0deg) / 3))
  ui.pathClear()
  ui.pathArcTo(center, r, a0, a1, segs)
  ui.pathStroke(color, false, width)
  local cr = width * 0.5
  ui.drawCircleFilled(vec2(center.x + r * math.cos(a0), center.y + r * math.sin(a0)), cr, color, 24)
  ui.drawCircleFilled(vec2(center.x + r * math.cos(a1), center.y + r * math.sin(a1)), cr, color, 24)
end

local function text(font, str, size, x, y, w, h, color, hAlign)
  ui.pushDWriteFont(font)
  ui.setCursor(vec2(x, y))
  ui.dwriteTextAligned(str, size, hAlign or ui.Alignment.Center, ui.Alignment.Center, vec2(w, h), false, color or C.white)
  ui.popDWriteFont()
end

-- The scale and the blue fill must use the same speed-to-angle mapping.
local function speedAngle(speed)
  return 124 + 292 * clamp(speed, 0, SPEED_MAX) / SPEED_MAX
end

local function arcText(font, str, size, center, radius, angle)
  local a = math.rad(angle)
  local p = vec2(center.x + radius * math.cos(a), center.y + radius * math.sin(a))
  local w, h = size * 3.5, size * 1.6
  ui.beginRotation()
  text(font, str, size, p.x - w * 0.5, p.y - h * 0.5, w, h, C.white)
  -- CSP uses 90 degrees for unrotated text; -angle follows the clockwise tangent.
  ui.endPivotRotation(-angle, p)
end

-- Measure at design size once per font change. Proportional spacing keeps the curved words
-- balanced, while scaling the cached advances with the dial preserves their proportions.
local arcLabelCache = { font = nil, size = nil, labels = {} }
local function curvedLabel(font, str, size, center, radius, angle, s)
  if arcLabelCache.font ~= font or arcLabelCache.size ~= size then
    arcLabelCache = { font = font, size = size, labels = {} }
  end
  local label = arcLabelCache.labels[str]
  if not label then
    label = { width = 0, glyphs = {} }
    ui.pushDWriteFont(font)
    for i = 1, #str do
      local ch = str:sub(i, i)
      local width = ui.measureDWriteText(ch, size).x
      label.glyphs[i] = { ch = ch, advance = label.width + width * 0.5 }
      label.width = label.width + width + 0.7
    end
    ui.popDWriteFont()
    label.width = label.width - 0.7
    arcLabelCache.labels[str] = label
  end
  for i = 1, #label.glyphs do
    local glyph = label.glyphs[i]
    local offset = math.deg((glyph.advance - label.width * 0.5) / radius)
    arcText(font, glyph.ch, size * s, center, radius * s, angle + offset)
  end
end

local function pill(font, x, y, w, h, fill, border, label, size, txtColor, rounding, thickness)
  local p1, p2 = vec2(x, y), vec2(x + w, y + h)
  if fill then ui.drawRectFilled(p1, p2, fill, rounding) end
  if border then ui.drawRect(p1, p2, border, rounding, nil, thickness) end
  text(font, label, size, x, y, w, h, txtColor)
end

local function smState(S)
  if S.kind == 'vanilla' then
    if valid(S, 'smActive') and S.smActive then return 'on' end
    if valid(S, 'smAvailable') and S.smAvailable then return 'avail' end
    return 'off'
  end
  if S.kind ~= 'pro' then return 'off' end
  if (valid(S, 'wingF') and S.wingF) or (valid(S, 'wingR') and S.wingR)
    or (valid(S, 'smActive') and S.smActive) then return 'on' end
  if not valid(S, 'latch') or (S.speed or 0) < 1 then return 'off' end
  if S.latch == 2 then return 'pre' end
  if S.latch == 1 then return 'avail' end
  if S.latch == 3 then return 'late' end
  return 'off'
end

local SM_STYLE = {
  off = { fill = C.track, txt = C.dim, label = 'SM' },
  avail = { fill = C.white, txt = C.black, label = 'SM' },       -- LEDs white: available, push to pre-latch
  pre = { fill = C.blue, txt = C.white, label = 'SM' },          -- LEDs blue: pre-latched, engages in the zone
  late = { fill = C.yellow, txt = C.black, label = 'SM' },       -- LEDs yellow: available but already in the zone
  on = { fill = C.green, txt = C.white, label = 'SM' },          -- wings in Straight Mode position
}
local SM_CHIP_KEY = { off = 'sm_off', avail = 'sm_avail', pre = 'sm_pre', late = 'sm_late', on = 'sm_on' }

local function drawDial(S, ox, oy, s, fontB, fontR, fontM)
  local c = vec2(ox + 170 * s, oy + 170 * s)
  ui.drawCircleFilled(c, 169 * s, C.disc, 96)
  arc(c, 154 * s, 124, 416, 27 * s, C.track)
  arc(c, 119.5 * s, 124, 308, 27 * s, C.track)
  arc(c, 119.5 * s, -44, 56, 27 * s, C.track)

  local spd = math.max(S.speed or 0, 0)
  if spd > 0.5 then arc(c, 154 * s, 124, speedAngle(spd), 27 * s, C.blue) end
  local gas = clamp(S.gas or 0, 0, 1)
  if gas > 0.01 then arc(c, 119.5 * s, 124, 124 + 184 * gas, 27 * s, C.green) end
  local brk = clamp(S.brake or 0, 0, 1)
  if brk > 0.01 then arc(c, 119.5 * s, 56, 56 - 100 * brk, 27 * s, C.red) end

  -- Fixed labels sit above both the empty tracks and the active fills.
  for speed = 0, SPEED_MAX, 60 do
    arcText(fontM, tostring(speed), 14 * s, c, 154 * s, speedAngle(speed))
  end
  curvedLabel(fontM, 'THROTTLE', 14, c, 119.5, 180, s)
  curvedLabel(fontM, 'BRAKE', 14, c, 119.5, 360, s)

  -- vertical layout (design units, v0.8): the digit stack sits 8-12 higher than the MultiViewer original
  -- to make room for the Boost button under the SM / OT badges; GEAR moves 3 down. Text boxes are centred.
  text(fontB, fmtInt(spd), 56 * s, ox + 70 * s, oy + 78 * s, 200 * s, 62 * s, C.white)
  text(fontM, 'KMH', 16 * s, ox + 120 * s, oy + 143 * s, 100 * s, 22 * s, C.grey)
  text(fontB, fmtInt(S.rpm), 27 * s, ox + 95 * s, oy + 175 * s, 150 * s, 34 * s, C.white)
  text(fontM, 'RPM', 16 * s, ox + 120 * s, oy + 212 * s, 100 * s, 20 * s, C.grey)

  -- badge cluster where the DRS badge used to be: SM | OT on top, the Boost button spanning both below.
  -- Width budget (v0.9): the throttle / brake track start caps (r 13.5 at (103.2, 269.1) and (236.8, 269.1))
  -- narrow the free channel to x 116.7-223.3 at y 269, so the cluster is 96 wide (x 122-218) to clear
  -- both caps by >= 5 units on every row; v0.8's 120-wide cluster overlapped them (seen in-game).
  if S.kind ~= 'pro' and S.kind ~= 'vanilla' then
    local on = valid(S, 'drsActive') and S.drsActive == true
    pill(fontB, ox + 122 * s, oy + 251 * s, 96 * s, 28 * s,
      on and C.green or C.track, nil, 'DRS', 16 * s, on and C.white or C.dim, 6 * s)
  else
    local st = SM_STYLE[smState(S)]
    pill(fontB, ox + 122 * s, oy + 240 * s, 45 * s, 24 * s, st.fill, nil, st.label, 15 * s, st.txt, 6 * s)
    local otFill, otBorder, otTxt = C.track, nil, C.dim
    if valid(S, 'otActive') and S.otActive then otFill, otTxt = C.green, C.white
    elseif valid(S, 'otPending') and S.otPending then otFill, otBorder, otTxt = nil, C.white, C.white end
    pill(fontB, ox + 173 * s, oy + 240 * s, 45 * s, 24 * s, otFill, otBorder, 'OT', 15 * s, otTxt, 6 * s, 2 * s)
    -- Both adapters expose only the manual command, never automatic deployment or estimated power.
    local boostOn = valid(S, 'boost') and S.boost
    pill(fontB, ox + 122 * s, oy + 270 * s, 96 * s, 20 * s, boostOn and C.boost or C.track, nil,
      'BOOST', 13 * s, boostOn and C.white or C.dim, 6 * s)
  end

  local g = S.gear or 0
  local gearStr = g == 0 and 'N' or (g < 0 and 'R' or tostring(g))
  ui.pushDWriteFont(fontM)
  local gearLabelW = ui.measureDWriteText('GEAR', 14 * s).x
  ui.popDWriteFont()
  ui.pushDWriteFont(fontB)
  local gearValueW = ui.measureDWriteText(gearStr, 27 * s).x
  ui.popDWriteFont()
  local gearGap = 7 * s
  local gearX = c.x - (gearLabelW + gearGap + gearValueW) * 0.5
  text(fontM, 'GEAR', 14 * s, gearX, oy + 299 * s, gearLabelW, 30 * s, C.grey, ui.Alignment.Start)
  text(fontB, gearStr, 27 * s, gearX + gearLabelW + gearGap, oy + 297 * s, gearValueW, 34 * s, C.white, ui.Alignment.Start)
end

local function socColor(soc)
  if soc > 0.5 then return C.green end
  if soc > 0.25 then return C.yellow end
  return C.red
end

local function vbar(x, y, w, h, frac, color, s)
  ui.drawRectFilled(vec2(x, y), vec2(x + w, y + h), C.track, 4 * s)
  if frac and frac > 0.005 then
    local fh = h * clamp(frac, 0, 1)
    ui.drawRectFilled(vec2(x, y + h - fh), vec2(x + w, y + h), color, 4 * s)
  end
  for i = 1, 3 do
    local ty = y + h * i / 4
    ui.drawRectFilled(vec2(x, ty - 0.6 * s), vec2(x + w, ty + 0.6 * s), rgbm(0, 0, 0, 0.55))
  end
end

-- two vertical bars beside the dial (the VRC dash idiom): left = usable battery, right = lap regen vs limit
local function drawSideBars(S, ox, oy, s, fontB, fontR)
  local by, bh = oy + BAR_TOP * s, BAR_H * s
  local lx = ox + BAR_MARGIN * s
  local rx = ox + RIGHT_BAR_X * s
  local llab = lx + (BAR_W * 0.5 - BAR_LABEL_W * 0.5) * s
  local rlab = rx + (BAR_W * 0.5 - BAR_LABEL_W * 0.5) * s
  local ty1, ty2 = oy + (BAR_TOP + BAR_H + 4) * s, oy + (BAR_TOP + BAR_H + 20) * s

  if valid(S, 'soc') then
    local soc = clamp(S.soc, 0, 1)
    local col = socColor(soc)
    vbar(lx, by, BAR_W * s, bh, soc, col, s)
    text(fontB, fmtInt(soc * 100) .. '%', 14 * s, llab, ty1, BAR_LABEL_W * s, 16 * s, col)
    if S.kind == 'pro' then
      local usable = valid(S, 'esoc') and math.max(S.esoc - ES_FLOOR_MJ, 0) or (soc * ES_USABLE_MJ)
      text(fontR, string.format('%.2f MJ', usable), 11 * s, llab, ty2, BAR_LABEL_W * s, 14 * s, C.grey)
    end
  else
    vbar(lx, by, BAR_W * s, bh, 0, C.green, s)
    text(fontB, '--', 14 * s, llab, ty1, BAR_LABEL_W * s, 16 * s, C.dim)
  end

  if S.kind ~= 'pro' then return end
  if validAll(S, 'regen', 'regenLimit') then
    local lim = S.regenLimit
    local regen = S.regen or 0
    vbar(rx, by, BAR_W * s, bh, lim > 0.05 and regen / lim or 0, C.purple, s)
    text(fontB, string.format('%.1f', regen), 14 * s, rlab, ty1, BAR_LABEL_W * s, 16 * s, C.purple)
    text(fontR, lim > 0.05 and string.format('/%.1f MJ', lim) or 'MJ', 11 * s, rlab, ty2, BAR_LABEL_W * s, 14 * s, C.grey)
  else
    vbar(rx, by, BAR_W * s, bh, 0, C.purple, s)
    text(fontB, '--', 14 * s, rlab, ty1, BAR_LABEL_W * s, 16 * s, C.dim)
  end
end

local function chip(font, x, y, w, h, active, activeFill, label, s, activeTxt)
  pill(font, x, y, w, h, active and activeFill or C.track, nil, label, 12 * s, active and (activeTxt or C.white) or C.dim, 5 * s)
end

local function drawPanel(S, panelX, oy, s, fontB, fontR, fontLB, fontLR)
  local px, py, pw, ph = panelX, oy + 10 * s, PANEL_W * s, 320 * s
  ui.drawRectFilled(vec2(px, py), vec2(px + pw, py + ph), C.panel, 10 * s)
  local lx = px + 14 * s
  local cw = pw - 28 * s
  local function label(str, y) text(fontLR, str, 12 * s, lx, py + y * s, cw, 16 * s, C.grey, ui.Alignment.Start) end
  local function valueRight(str, y, col, size) text(fontB, str, (size or 15) * s, lx, py + y * s, cw, 20 * s, col or C.white, ui.Alignment.End) end

  -- battery
  label(L('battery'), 8)
  local bx, by, bw, bh = lx, py + 28 * s, 180 * s, 14 * s
  ui.drawRectFilled(vec2(bx, by), vec2(bx + bw, by + bh), C.barTrack, 3 * s)
  if valid(S, 'soc') then
    local soc = clamp(S.soc, 0, 1)
    local col = soc > 0.5 and C.green or (soc > 0.25 and C.yellow or C.red)
    if soc > 0.002 then ui.drawRectFilled(vec2(bx, by), vec2(bx + bw * soc, by + bh), col, 3 * s) end
    -- usable energy: the 2026 ES has a 4 MJ usable window; VRC models it as the top 4 MJ of an 8 MJ store
    -- (kersChargeESOC = 4 + 4 x kersCharge, verified from the 2026-09-10 logs). Raw ESOC stays in diagnostics.
    local usable = valid(S, 'esoc') and math.max(S.esoc - ES_FLOOR_MJ, 0) or (soc * ES_USABLE_MJ)
    valueRight(string.format('%s%%  %.2f / %.0f MJ', fmtInt(soc * 100), usable, ES_USABLE_MJ), 25)
  else
    valueRight('--', 25, C.dim)
  end

  -- MGU-K
  label('MGU-K', 54)
  local mx, my, mw, mh = lx, py + 74 * s, 180 * s, 14 * s
  local mid = mx + mw * 0.5
  ui.drawRectFilled(vec2(mx, my), vec2(mx + mw, my + mh), C.barTrack, 3 * s)
  if valid(S, 'kw') then
    local kw = S.kw
    if kw > 1 then
      ui.drawRectFilled(vec2(mid, my), vec2(mid + mw * 0.5 * clamp(kw / KW_MAX, 0, 1), my + mh), C.green)
    elseif kw < -1 then
      ui.drawRectFilled(vec2(mid - mw * 0.5 * clamp(-kw / KW_MAX, 0, 1), my), vec2(mid, my + mh), C.red)
    end
    -- live MGU-K cap: >0 = allowed deploy power (zone / regulation / speed curve), 0 = deployment
    -- blocked, <0 = super-clipping (forced harvest at full throttle); observed live: 250/200/150/100/0/-350
    local cap = S.cap or 0
    local capColor = cap > 0 and C.yellow or C.orange
    local tx = mid + mw * 0.5 * clamp(cap / KW_MAX, -1, 1)
    if valid(S, 'cap') then
      ui.drawRectFilled(vec2(tx - 1.5 * s, my - 3 * s), vec2(tx + 1.5 * s, my + mh + 3 * s), capColor)
    end
    ui.drawRectFilled(vec2(mid - 1 * s, my - 2 * s), vec2(mid + 1 * s, my + mh + 2 * s), C.white)
    valueRight(string.format('%+d kW', math.floor(kw + 0.5)), 71)
    text(fontLR, L('harvest'), 11 * s, mx, my + 17 * s, 90 * s, 14 * s, C.dim, ui.Alignment.Start)
    local capLabel = valid(S, 'cap') and string.format(cap < 0 and L('clip') or L('cap'), fmtInt(cap)) or '--'
    text(fontLR, capLabel, 11 * s, mx + mw - 110 * s, my + 17 * s, 110 * s, 14 * s, capColor, ui.Alignment.End)
  else
    valueRight('--', 71, C.dim)
  end

  -- lap energy
  label(L('lapEnergy'), 112)
  if valid(S, 'deploy') or valid(S, 'regen') then
    text(fontLB, valid(S, 'deploy') and string.format(L('deploy'), S.deploy) or '--', 14 * s, lx, py + 130 * s, 130 * s, 18 * s, C.white, ui.Alignment.Start)
    local lim = S.regenLimit or 0
    local regenStr = valid(S, 'regen') and (valid(S, 'regenLimit') and lim > 0.05
      and string.format(L('regenLim'), S.regen, lim) or string.format(L('regen'), S.regen)) or '--'
    text(fontLB, regenStr, 14 * s, lx + 136 * s, py + 130 * s, cw - 136 * s, 18 * s, C.white, ui.Alignment.Start)
    local rx, ry, rw, rh = lx + 136 * s, py + 150 * s, cw - 136 * s, 6 * s
    ui.drawRectFilled(vec2(rx, ry), vec2(rx + rw, ry + rh), C.barTrack, 2 * s)
    if validAll(S, 'regen', 'regenLimit') and lim > 0.05 then
      local fr = clamp((S.regen or 0) / lim, 0, 1)
      if fr > 0.005 then ui.drawRectFilled(vec2(rx, ry), vec2(rx + rw * fr, ry + rh), C.purple, 2 * s) end
    end
  else
    text(fontB, '--', 14 * s, lx, py + 130 * s, cw, 18 * s, C.dim, ui.Alignment.Start)
  end

  -- strategy
  label(L('strategy'), 170)
  if valid(S, 'strat') or valid(S, 'split') or valid(S, 'puMode') then
    local pm = math.floor((S.puMode or 0) + 0.5)
    local pmName = valid(S, 'puMode') and (PU_MODE_NAMES[pm] or ('#' .. fmtInt(pm))) or '--'
    text(fontLB, string.format(L('stratSplit'), valid(S, 'strat') and fmtInt(S.strat) or '--', valid(S, 'split') and fmtInt(S.split) or '--'), 14 * s, lx, py + 188 * s, 150 * s, 18 * s, C.white, ui.Alignment.Start)
    text(fontB, 'PU ' .. pmName, 14 * s, lx + 156 * s, py + 188 * s, cw - 156 * s, 18 * s, pm == 11 and C.yellow or C.white, ui.Alignment.Start)
  else
    text(fontB, '--', 14 * s, lx, py + 188 * s, cw, 18 * s, C.dim, ui.Alignment.Start)
  end

  -- status chips
  label(L('status'), 220)
  local sm = smState(S)
  local st = SM_STYLE[sm]
  local y1, y2, h = py + 240 * s, py + 268 * s, 22 * s
  pill(fontLB, lx, y1, 100 * s, h, sm ~= 'off' and st.fill or C.track, nil, L(SM_CHIP_KEY[sm]), 12 * s, sm ~= 'off' and st.txt or C.dim, 5 * s)
  local otLabel = (valid(S, 'otActive') and S.otActive) and L('ot_active') or ((valid(S, 'otPending') and S.otPending) and L('ot_pending') or 'OT')
  chip(fontLB, lx + 108 * s, y1, 84 * s, h, ((valid(S, 'otActive') and S.otActive) or (valid(S, 'otPending') and S.otPending)), S.otActive and C.green or C.cyan, otLabel, s, S.otActive and C.white or C.black)
  chip(fontLB, lx + 200 * s, y1, 60 * s, h, valid(S, 'boost') and S.boost, C.boost, L('boost'), s)
  chip(fontLB, lx, y2, 64 * s, h, valid(S, 'charge') and S.charge, C.blue, L('charge'), s)
  chip(fontLB, lx + 72 * s, y2, 40 * s, h, valid(S, 'pl') and S.pl, C.orange, 'PL', s)
  chip(fontLB, lx + 120 * s, y2, 44 * s, h, valid(S, 'plp') and S.plp, C.yellow, 'PLP', s, C.black)
  chip(fontLB, lx + 172 * s, y2, 88 * s, h, valid(S, 'pitLimiter') and S.pitLimiter, C.white, L('pitLimiter'), s, C.black)

  if cfg.diagnostics then
    text(fontR, string.format('%s  |  %s', tostring(S.name), tostring(S.source)), 11 * s, lx, py + 298 * s, cw, 16 * s, C.dim, ui.Alignment.Start)
  end
end

local VANILLA_PANEL_W = 248
local function drawVanillaPanel(S, panelX, oy, s, fontB, fontR, fontLB, fontLR)
  local px, py, pw, ph = panelX, oy + 65 * s, VANILLA_PANEL_W * s, 210 * s
  local lx, cw = px + 14 * s, pw - 28 * s
  ui.drawRectFilled(vec2(px, py), vec2(px + pw, py + ph), C.panel, 10 * s)
  text(fontLR, L('battery'), 12 * s, lx, py + 12 * s, cw, 16 * s, C.grey, ui.Alignment.Start)
  local soc = valid(S, 'soc') and clamp(S.soc, 0, 1) or nil
  local col = soc and socColor(soc) or C.dim
  text(fontB, soc and (fmtInt(soc * 100) .. '%') or '--', 18 * s, lx, py + 8 * s, cw, 24 * s, col, ui.Alignment.End)
  local by, bh = py + 39 * s, 14 * s
  ui.drawRectFilled(vec2(lx, by), vec2(lx + cw, by + bh), C.barTrack, 3 * s)
  if soc and soc > 0.002 then ui.drawRectFilled(vec2(lx, by), vec2(lx + cw * soc, by + bh), col, 3 * s) end
  text(fontLR, L('strategy'), 12 * s, lx, py + 72 * s, cw, 16 * s, C.grey, ui.Alignment.Start)
  text(fontB, valid(S, 'strategy') and S.strategyName or '--', 20 * s, lx, py + 91 * s, cw, 28 * s, C.white, ui.Alignment.Start)
  local recoveryKnown = valid(S, 'recovering')
  local recovering = recoveryKnown and S.recovering
  chip(fontLB, lx, py + 144 * s, cw, 28 * s, recovering, C.purple,
    recoveryKnown and L('recovering') or (L('recovering') .. ' --'), s)
  if cfg.diagnostics then
    text(fontR, tostring(S.source), 10 * s, lx, py + 185 * s, cw, 16 * s, C.dim, ui.Alignment.Start)
  end
end

function script.windowMain(dt)
  local s = clamp(cfg.scale, 0.3, 2.5)
  local fontB, fontR, fontLB, fontLR, fontM = getFonts()
  local o = ui.getCursor()
  local ox, oy = o.x, o.y
  local pro, vanilla = view.kind == 'pro', view.kind == 'vanilla'
  local bars = cfg.showBars and (pro or vanilla)
  local panel = cfg.showPanel and (pro or vanilla)
  local leftW = bars and (pro and BARS_TOTAL_W or (DIAL_INSET + DIAL_W + BAR_MARGIN)) or DIAL_W
  local panelW = vanilla and VANILLA_PANEL_W or PANEL_W
  local dialOx = ox + (bars and DIAL_INSET or 0) * s
  drawDial(view, dialOx, oy, s, fontB, fontR, fontM)
  if bars then drawSideBars(view, ox, oy, s, fontB, fontR) end
  if panel then
    local draw = vanilla and drawVanillaPanel or drawPanel
    draw(view, ox + (leftW + PANEL_GAP) * s, oy, s, fontB, fontR, fontLB, fontLR)
  end
  ui.setCursor(o)
  ui.dummy(vec2((leftW + (panel and (PANEL_GAP + panelW) or 0)) * s, 340 * s))
end

function script.windowSettings(dt)
  ui.header(L('language'))
  if ui.radioButton('English', cfg.lang ~= 'zh') then cfg.lang = 'en' end
  ui.sameLine(0, 16)
  if ui.radioButton('简体中文', cfg.lang == 'zh') then cfg.lang = 'zh' end

  ui.header(L('display'))
  cfg.scale = ui.slider('##scale', cfg.scale, 0.5, 2.5, L('scale'))
  if ui.checkbox(L('showPanel'), cfg.showPanel) then cfg.showPanel = not cfg.showPanel end
  if ui.checkbox(L('showBars'), cfg.showBars) then cfg.showBars = not cfg.showBars end
  if ui.checkbox(L('follow'), cfg.followFocused) then cfg.followFocused = not cfg.followFocused end
  if ui.checkbox(L('lock'), cfg.lockPlayer) then cfg.lockPlayer = not cfg.lockPlayer end
  local fontName, fontChanged = ui.inputText(L('font'), cfg.fontName)
  if fontChanged then cfg.fontName = fontName end
  local fontZh, fontZhChanged = ui.inputText(L('fontZh'), cfg.fontZh)
  if fontZhChanged then cfg.fontZh = fontZh end

  ui.header(L('bindings'))
  ui.text(L('togglePanel'))
  ui.sameLine(200)
  btnPanel:control(vec2(200, 0))
  ui.text(L('lock'))
  ui.sameLine(200)
  btnLock:control(vec2(200, 0))

  ui.header(L('replay'))
  if ui.checkbox(L('record'), cfg.recordReplay) then cfg.recordReplay = not cfg.recordReplay end
  local ordinal = (cfg.lang == 'zh') and '' or (REPLAY_DIVISOR == 2 and 'nd' or 'th')
  ui.text(RS and string.format(L('streamOk'), MAX_CARS, REPLAY_DIVISOR, ordinal, MAX_CARS * 11)
    or string.format(L('streamErr'), tostring(rsErr)))
  ui.text(string.format(L('recorded'), recordedCars))
  ui.text(data.VRS and (cfg.lang == 'zh' and '原生状态回放流：正常' or 'Native-state replay stream: ready')
    or ((cfg.lang == 'zh' and '原生状态回放流：' or 'Native-state replay stream: ') .. tostring(data.vrsErr)))

  ui.header(L('diagnostics'))
  if ui.checkbox(L('diagPanel'), cfg.diagnostics) then cfg.diagnostics = not cfg.diagnostics end
  if ui.checkbox(L('diagLog'), cfg.logDiag) then cfg.logDiag = not cfg.logDiag end
  if ui.checkbox(L('diagText'), cfg.showDiagText) then cfg.showDiagText = not cfg.showDiagText end
  ui.text(string.format(L('version'), VERSION, tostring(sim.isReplayActive)))
  if not cfg.showDiagText then return end
  ui.text(string.format(L('target'), tostring(view.index), tostring(view.name), tostring(view.carID)))
  ui.text(string.format(L('source'), tostring(view.source)))
  if sim.isReplayActive then
    ui.text(L('canReplay'))
  else
    ui.text(can.inputs and string.format(L('canOk'), can.count, tostring(can.carID)) or string.format(L('canNone'), tostring(can.err)))
  end
  ui.text(string.format(L('diagFile'), diagPath))
  ui.text(string.format(L('aiProbe'), tostring(diag.aiProbe)))
  ui.text(string.format(L('replayNative'), tostring(diag.nativeSocReplay)))
  if view.full then
    ui.text(string.format('SoC %.3f  ESOC %s  kW %.1f  cap %.0f', view.soc or -1, tostring(view.esoc), view.kw or 0, view.cap or 0))
    ui.text(string.format('deploy %.2f  regen %.2f / %.2f  strat %s  split %s  PU %s', view.deploy or 0, view.regen or 0, view.regenLimit or 0, tostring(view.strat), tostring(view.split), tostring(view.puMode)))
    ui.text(string.format('OT %s/%s  boost %s  charge %s  PL %s/%s  latch %s  SM %s  wings %s/%s', tostring(view.otActive), tostring(view.otPending), tostring(view.boost), tostring(view.charge), tostring(view.pl), tostring(view.plp), tostring(view.latch), tostring(view.smActive), tostring(view.wingF), tostring(view.wingR)))
  end
end
