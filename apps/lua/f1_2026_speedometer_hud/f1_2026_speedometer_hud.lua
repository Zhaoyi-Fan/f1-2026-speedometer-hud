-- F1 2026 Speedometer HUD
-- Broadcast-style speedometer with exact FA26 Pro/native and conventional DRS adapters.
-- The original dial is shared; energy and state fields depend on the viewed vehicle.
-- Keeps the Pro energy stream and records verified native fields separately for slots 0-21.
-- Read-only with respect to car and track files (league-safe).
-- Source: https://github.com/Zhaoyi-Fan/f1-2026-speedometer-hud
-- Data contract (CAN channel names, replay layout): docs/DATA-CONTRACT.md in the repository.

local VERSION = '0.9.38'
local TAG = '[F1-2026-HUD]'
local MAX_CARS = 22          -- replay stream slots: 11 bytes per car -> 242 bytes per frame (limit 256)
local SPEED_MAX = 360        -- arc full scale; the numeric readout can exceed this
local KW_MAX = 350           -- MGU-K bar full scale (2026 MGU-K)
local ES_USABLE_MJ = 4       -- 2026 energy store usable window
local ES_FLOOR_MJ = 4        -- VRC: usable window sits on top of a 4 MJ floor (ESOC 4..8 MJ)

local DIAL_W = 340
local PANEL_GAP, PANEL_W = 12, 308
local REPLAY_DIVISOR = 2     -- record every 2nd replay frame

-- Battery glyph in the dial (design units, v0.9.3). It takes the 96 x 20 slot of the former BOOST pill at
-- (122, 270), the one row whose clearance from the throttle / brake track start caps was verified in game
-- (see drawDial). The terminal side is a setting (`batteryTerminal`). By default (since 0.9.38) the terminal
-- nub is on the RIGHT and the charge fill is anchored to the LEFT wall, like a common battery icon, so the
-- fill drains to the left. With the terminal on the LEFT (the only layout of 0.9.3-0.9.37) the fill is
-- anchored to the RIGHT wall: deploying moves its edge to the right and harvesting to the left, the same
-- directions as the panel's MGU-K bar. The two layouts are mirror images about the dial's vertical axis
-- (x = 170), where the slot and both track caps are symmetric, so both keep the same clearances. Text is
-- placed as the mirror but never reversed.
-- The body colour follows the Boost button (the pill's own rule); the ring, nub and bolt follow the
-- MGU-K flow of the current update: the Pro's signed power, or the standard car's recovery status
-- and the deployment share its delivery controller requests.
local BAT = { x = 122, y = 270, w = 96, h = 20, nubW = 4, nubH = 8, r = 5, inset = 2.5, ring = 2,
  halo = { 1.5, 3 }, haloA = { 0.30, 0.14 }, boltX = 6, boltY = 4, boltW = 8, digits = 13,
  lowSoc = 0.10, boostSoc = 9, vanillaI = 0.6, vanillaDeadband = 0.02, smoothing = 0.12 }
local KW_DEADBAND = 5        -- |kW| at or below this is idle; also swallows the replay stream's 3 kW quantum
-- lightning bolt, 8 x 12, as two convex quads sharing a diagonal (ui.pathFillConvex cannot fill a concave shape)
-- (vertices clockwise on screen: ImGui's anti-aliased fill puts the fringe outside only for clockwise polygons)
local BAT_BOLT = { { { 5, 0 }, { 5, 4.8 }, { 3.2, 7.2 }, { 0, 7 } }, { { 4.8, 5 }, { 8, 5 }, { 2.4, 12 }, { 3, 7 } } }
local OUTLINE_OFS = { { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 } }

local sim = ac.getSim()

local cfg = ac.storage({
  scale = 1.0,
  showPanel = true,
  showBattery = true,
  batteryTerminal = 'right',  -- 'right' or 'left'; any other value draws the default right one
  batterySmoothing = true,
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
  batFill = rgbm(0.91, 0.92, 0.93, 0.92),   -- charge fill: neutral, so red only ever means harvesting
  batIdle = rgbm(1, 1, 1, 0.30),            -- battery ring while no energy flows, or the flow is unknown
  batBolt = rgbm(1, 1, 1, 0.70),            -- bolt and nub at rest
  outline = rgbm(0, 0, 0, 0.85),            -- outline behind the digits drawn over the light fill
}

-- 1-based, same table the car's own dash uses (display\styles\style_0\pages.lua puModes); 11 = SLO is the yellow one
local PU_MODE_NAMES = { 'RACE', 'AD1', 'AD2', 'FS', 'FW', 'IN', 'ES', 'Q', 'K2', 'K2+', 'SLO', 'SC', 'T4', 'RS' }

-- UI strings. Broadcast abbreviations (SM, OT, Boost, PL, PLP, STRAT, PU, MGU-K, KMH, RPM, GEAR) stay
-- untranslated on purpose, like the on-air graphics on Chinese F1 broadcasts. Reviewed 2026-09-10.
local STR = {
  battery = { en = 'Battery', zh = '电池' },
  harvest = { en = 'harvest', zh = '回收' },
  recovering = { en = 'Recovering', zh = '正在回收' },
  deploying = { en = 'Deploying', zh = '正在部署' },
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
  showBattery = { en = 'Battery glyph in the dial (off: BOOST badge)', zh = '表盘内显示电池图标（关闭 = BOOST 徽章）' },
  batteryTerminal = { en = 'Battery terminal:', zh = '电池接头：' },
  terminalLeft = { en = 'Left', zh = '左' },
  terminalRight = { en = 'Right', zh = '右' },
  terminalTip = {
    en = 'Right (default): the usual battery icon; the fill drains to the left.\nLeft: deploying moves the fill edge to the right, like the MGU-K bar.\nSwitching mirrors the whole glyph; the text keeps its reading direction.',
    zh = '右（默认）：常见的电池图标，电量向左减少。\n左：部署时填充边缘向右退，与 MGU-K 条方向一致。\n切换时整个图标左右镜像，文字方向不变。',
  },
  batterySmooth = { en = 'Ease the battery ring brightness (120 ms, decorative)', zh = '电池环亮度平滑（120 ms，仅视觉）' },
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

-- Diagnostics only: keeps a missing or non-numeric native property out of string.format.
local function numOr(v) return type(v) == 'number' and v or -1 end

-- The displayed whole percentage, and the low-charge rule applied to that same figure, so '10%' is
-- never drawn in two colours.
local function socPercent(soc) return math.floor(soc * 100 + 0.5) end
local function socLow(soc) return socPercent(soc) <= BAT.lowSoc * 100 end

local function valid(S, field)
  return S.valid and S.valid[field] == true
end

local function validAll(S, ...)
  for i = 1, select('#', ...) do
    if not valid(S, select(i, ...)) then return false end
  end
  return true
end

-- Battery ring state from the current update only, in the data contract's order: no hysteresis, no hold.
-- Returns the state ('harvest', 'deploy', 'boost' or 'idle') and the raw intensity 0..1 (nil when no flow is known).
local function batteryFlow(S)
  if S.kind == 'vanilla' then
    -- The native car reports no power. Deployment is the share its delivery controller requests
    -- (`deployInput`, throttle x speed map), drawn like a Pro deployment but with the requested share
    -- as the brightness; recovery is a status flag drawn at a declared fixed intensity. Deployment is
    -- tested first: it is a live input, while recovery is a state the car can hold off throttle.
    if valid(S, 'deployInput') and S.deployInput > BAT.vanillaDeadband then
      return (valid(S, 'boost') and S.boost) and 'boost' or 'deploy', clamp(S.deployInput, 0, 1)
    end
    if valid(S, 'recovering') and S.recovering then return 'harvest', BAT.vanillaI end
    return 'idle', nil
  end
  if S.kind ~= 'pro' or not valid(S, 'kw') then return 'idle', nil end
  local kw = S.kw
  if kw > KW_DEADBAND then
    return (valid(S, 'boost') and S.boost) and 'boost' or 'deploy', clamp(kw / KW_MAX, 0, 1)
  elseif kw < -KW_DEADBAND then
    return 'harvest', clamp(-kw / KW_MAX, 0, 1)
  end
  return 'idle', nil
end

-- Decorative easing of the ring BRIGHTNESS only (a setting): the state and hue above are never eased. It
-- advances with sim.dt (following replay speed); while paused sim.dt is 0 and the shown frame's raw value
-- is drawn. It is evaluated on every drawn update, idle frames easing it down to 0, and restarts from the
-- raw value on a car change or after any update that did not draw the glyph, so a new flow never inherits
-- a brightness from an earlier stretch.
local updateCount = 0
local batEase = { value = 0, index = nil, stamp = -1 }
local function batteryIntensity(S, raw)
  local dt = sim.dt
  local continuous = batEase.index == S.index and batEase.stamp == updateCount - 1
  batEase.index, batEase.stamp = S.index, updateCount
  if not cfg.batterySmoothing or type(dt) ~= 'number' or dt <= 0 or not continuous then
    batEase.value = raw
    return raw
  end
  local k = 1 - math.exp(-math.min(dt, 0.1) / BAT.smoothing)
  batEase.value = batEase.value + (raw - batEase.value) * k
  return batEase.value
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
    local gaps = data.recordingGaps or {}
    local l1 = string.format('%s src=%s | car=%s (%s) | CAN=%s | session=%s replay=%s stream=%s recorded=%d proSkip=%d:%s@%s | replayGaps=%d@%s | %s | %s',
      TAG, tostring(view.source), tostring(view.index), tostring(view.name), canState,
      tostring(sim.raceSessionType), tostring(sim.isReplayActive), RS and 'ok' or ('ERR ' .. tostring(rsErr)), recordedCars,
      gaps.totalProEmpty or 0, tostring(gaps.lastProReason or 'none'), tostring(gaps.lastProIndex or -1),
      replayGaps.count, tostring(replayGaps.lastFrame), diag.aiProbe, diag.nativeSocReplay)
    ac.log(l1)
    diagFileAppend(l1)
    if view.full then
      local batState, batRaw = batteryFlow(view)
      local l2 = string.format('%s soc=%.3f esoc=%s kW=%.1f cap=%.0f dep=%.2f reg=%.2f/%.2f strat=%s split=%s pu=%s ot=%s/%s boost=%s chg=%s pl=%s/%s latch=%s smAct=%s wings=%s/%s spd=%.0f gear=%s gas=%.2f bat=%s/%.2f',
        TAG, view.soc or -1, tostring(view.esoc), view.kw or 0, view.cap or 0, view.deploy or 0, view.regen or 0, view.regenLimit or 0,
        tostring(view.strat), tostring(view.split), tostring(view.puMode), tostring(view.otActive), tostring(view.otPending),
        tostring(view.boost), tostring(view.charge), tostring(view.pl), tostring(view.plp), tostring(view.latch), tostring(view.smActive),
        tostring(view.wingF), tostring(view.wingR), view.speed or 0, tostring(view.gear), view.gas or 0, batState, batRaw or 0)
      ac.log(l2)
      diagFileAppend(l2)
    elseif view.kind == 'vanilla' or view.kind == 'drs' then
      local batState, batRaw = batteryFlow(view)
      -- Native KERS properties of the selected live car, so the shown deployment can be compared
      -- with the car's own input, load and store contents in a single lap.
      local probe = ''
      if view.kind == 'vanilla' and not sim.isReplayActive and view.index then
        local car = ac.getCar(view.index)
        if car then
          probe = string.format(' | probe kersInput=%.3f kersLoad=%.3f kJ=%.1f/%.1f charging=%s gas=%.2f speed=%.0f',
            numOr(car.kersInput), numOr(car.kersLoad), numOr(car.kersCurrentKJ), numOr(car.kersMaxKJ),
            tostring(car.kersCharging), numOr(car.gas), numOr(car.speedKmh))
        end
      end
      local l2 = string.format('%s native kind=%s soc=%s boost=%s strategy=%s recovering=%s deploy=%s/%s drs=%s/%s/%s sm=%s/%s valid=%s/%s/%s/%s/%s nativeStream=%s recordedNative=%d/%d emptyNative=%d lastEmpty=%s:%s | bat=%s/%.2f%s',
        TAG, tostring(view.kind), tostring(view.soc), tostring(view.boost), tostring(view.strategyName),
        tostring(view.recovering), tostring(view.deployInput), tostring(valid(view, 'deployInput')),
        tostring(view.drsPresent), tostring(view.drsAvailable), tostring(view.drsActive),
        tostring(view.smAvailable), tostring(view.smActive), tostring(valid(view, 'soc')), tostring(valid(view, 'boost')),
        tostring(valid(view, 'strategy')), tostring(valid(view, 'recovering')), tostring(valid(view, 'drsActive')),
        data.VRS and 'ok' or tostring(data.vrsErr), data.recordedVanilla or 0, data.recordedDRS or 0,
        gaps.totalNativeEmpty or 0, tostring(gaps.lastNativeIndex or -1), tostring(gaps.lastNativeReason or 'none'),
        batState, batRaw or 0, probe)
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
  updateCount = updateCount + 1
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

local function textOutlined(font, str, size, x, y, w, h, color, s, hAlign)
  for _, d in ipairs(OUTLINE_OFS) do text(font, str, size, x + d[1] * s, y + d[2] * s, w, h, C.outline, hAlign) end
  text(font, str, size, x, y, w, h, color, hAlign)
end

local function bolt(x, y, s, color, shift)
  for _, quad in ipairs(BAT_BOLT) do
    local p = {}
    for k = 1, 4 do p[k] = vec2(x + quad[k][1] * s + shift, y + quad[k][2] * s + shift) end
    ui.drawQuadFilled(p[1], p[2], p[3], p[4], color)
  end
end

local BAT_HUE = { harvest = C.red, deploy = C.green, boost = C.boost }

-- Every element is a function of the current snapshot: body = Boost button (and the word BOOST inside it while
-- it is held), fill length and digits = state of charge, ring / nub / bolt hue = flow direction, ring
-- brightness / width and halo = the intensity of that flow
-- (Pro: |kW| / 350; standard car: the requested deployment share, or the declared fixed recovery value),
-- optionally eased. Only the placement depends on a setting, the terminal side (see BAT).
local function drawBattery(S, ox, oy, s, fontB)
  local state, raw = batteryFlow(S)
  local hue = BAT_HUE[state]
  local i
  if S.kind == 'pro' and not valid(S, 'kw') then
    -- unknown flow clears the easing at once; nothing is carried into the next valid update
    batEase.value, batEase.index, batEase.stamp, i = 0, S.index, updateCount, 0
  else
    i = batteryIntensity(S, raw or 0)   -- idle frames ease the brightness down to 0
  end
  -- Body box, beside the nub. Positions below are written for the left terminal; the right terminal (the
  -- default, and whatever an unrecognised stored value falls back to) takes their mirror image about the
  -- dial's vertical axis.
  local right = cfg.batteryTerminal ~= 'left'
  local x0, y0 = ox + (right and BAT.x or BAT.x + BAT.nubW) * s, oy + BAT.y * s
  local w, h = (BAT.w - BAT.nubW) * s, BAT.h * s
  local p1, p2 = vec2(x0, y0), vec2(x0 + w, y0 + h)
  if hue then
    for k = #BAT.halo, 1, -1 do
      local pad = BAT.halo[k] * s
      ui.drawRect(vec2(x0 - pad, y0 - pad), vec2(x0 + w + pad, y0 + h + pad),
        rgbm(hue.r, hue.g, hue.b, i * i * BAT.haloA[k]), (BAT.r + BAT.halo[k]) * s, ui.CornerFlags.All, 2 * s)
    end
  end
  -- The body follows the manual command of both adapters; automatic deployment never colours it.
  local boostOn = valid(S, 'boost') and S.boost
  ui.drawRectFilled(p1, p2, boostOn and C.boost or C.track, BAT.r * s, ui.CornerFlags.All)
  local socOk = valid(S, 'soc')
  local soc = socOk and clamp(S.soc, 0, 1) or 0
  local low = socOk and socLow(soc)
  if socOk and soc > 0.005 then
    -- anchored to the wall opposite the terminal
    local lx1, lx2 = x0 + BAT.inset * s, x0 + w - BAT.inset * s
    local fw = (lx2 - lx1) * soc
    local fx1, fx2, anchor = lx2 - fw, lx2, ui.CornerFlags.Right
    if right then fx1, fx2, anchor = lx1, lx1 + fw, ui.CornerFlags.Left end
    ui.drawRectFilled(vec2(fx1, y0 + BAT.inset * s), vec2(fx2, y0 + h - BAT.inset * s),
      low and C.yellow or C.batFill, math.min(3 * s, fw * 0.5), soc > 0.97 and ui.CornerFlags.All or anchor)
  end
  -- The bolt sits beside the terminal, at the end the fill leaves first. Only its position is mirrored:
  -- the symbol and its down-right shadow keep their usual orientation.
  local boltX = right and x0 + w - (BAT.boltX + BAT.boltW) * s or x0 + BAT.boltX * s
  if socOk then
    -- on a magenta (Boost) body the bolt is white so it stays visible; the ring still carries the flow hue
    local boltCol = boostOn and C.white or (hue and rgbm(hue.r, hue.g, hue.b, 0.45 + 0.55 * i) or C.batBolt)
    bolt(boltX, y0 + BAT.boltY * s, s, C.outline, 0.7 * s)
    bolt(boltX, y0 + BAT.boltY * s, s, boltCol, 0)
  end
  local ringCol = hue and rgbm(hue.r, hue.g, hue.b, 0.35 + 0.65 * i) or C.batIdle
  ui.drawRect(p1, p2, ringCol, BAT.r * s, ui.CornerFlags.All, (BAT.ring + i) * s)
  local ny = y0 + (BAT.h - BAT.nubH) * 0.5 * s
  local nx1, nx2, nubCorners = ox + BAT.x * s, x0, ui.CornerFlags.Left
  if right then nx1, nx2, nubCorners = x0 + w, ox + (BAT.x + BAT.w) * s, ui.CornerFlags.Right end
  ui.drawRectFilled(vec2(nx1, ny), vec2(nx2, ny + BAT.nubH * s), hue and ringCol or C.batBolt, 1.5 * s, nubCorners)
  -- While the Boost command is held the body reads BOOST, exactly as the badge this glyph replaced;
  -- the fill still shows the level. The number returns beside the word once the displayed charge is
  -- down to a single digit, where it is the reading that matters, and is then always the amber one.
  -- The number sits at the anchored end, clear of the bolt: left-aligned with the terminal on the right,
  -- right-aligned with it on the left.
  local dx, dw, align = x0 + 16 * s, w - 20 * s, ui.Alignment.End
  if right then dx, align = x0 + 4 * s, ui.Alignment.Start end
  local digits = socOk and (socPercent(soc) .. '%') or nil
  local digitsWithBoost = digits ~= nil and socPercent(soc) <= BAT.boostSoc
  if digits and (not boostOn or digitsWithBoost) then
    textOutlined(fontB, digits, BAT.digits * s, dx, y0, dw, h, low and C.yellow or C.white, s, align)
  elseif not socOk and not boostOn then
    text(fontB, '--', BAT.digits * s, dx, y0, dw, h, C.dim, align)
  end
  if boostOn then
    local wx, ww = x0, w                      -- centred on the body, the badge's own placement
    if digitsWithBoost then
      ui.pushDWriteFont(fontB)
      local numberW = ui.measureDWriteText(digits, BAT.digits * s).x
      ui.popDWriteFont()
      -- between the bolt and the number it now shares the body with
      local boltEdge = (BAT.boltX + BAT.boltW) * s
      if right then
        wx = x0 + 4 * s + numberW
        ww = x0 + w - boltEdge - wx
      else
        wx = x0 + boltEdge
        ww = x0 + w - 4 * s - numberW - wx
      end
    end
    textOutlined(fontB, 'BOOST', BAT.digits * s, wx, y0, ww, h, C.white, s)
  end
end

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
    if cfg.showBattery then
      drawBattery(S, ox, oy, s, fontB)   -- the glyph's body carries the Boost button, its ring the energy flow
    else
      -- The badge is the manual command of both adapters; in this mode there is no ring, so
      -- automatic deployment and recovery are not shown at all.
      local boostOn = valid(S, 'boost') and S.boost
      pill(fontB, ox + 122 * s, oy + 270 * s, 96 * s, 20 * s, boostOn and C.boost or C.track, nil,
        'BOOST', 13 * s, boostOn and C.white or C.dim, 6 * s)
    end
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
    local col = socLow(soc) and C.yellow or C.batFill   -- same level rule as the dial glyph
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
  local low = soc and socLow(soc)
  text(fontB, soc and (socPercent(soc) .. '%') or '--', 18 * s, lx, py + 8 * s, cw, 24 * s, soc and (low and C.yellow or C.white) or C.dim, ui.Alignment.End)
  local by, bh = py + 39 * s, 14 * s
  ui.drawRectFilled(vec2(lx, by), vec2(lx + cw, by + bh), C.barTrack, 3 * s)
  if soc and soc > 0.002 then ui.drawRectFilled(vec2(lx, by), vec2(lx + cw * soc, by + bh), low and C.yellow or C.batFill, 3 * s) end
  text(fontLR, L('strategy'), 12 * s, lx, py + 72 * s, cw, 16 * s, C.grey, ui.Alignment.Start)
  text(fontB, valid(S, 'strategy') and S.strategyName or '--', 20 * s, lx, py + 91 * s, cw, 28 * s, C.white, ui.Alignment.Start)
  -- The two flow states the native car reports, in the dial glyph's colours: the deployment share
  -- its delivery controller requests, and its recovery status.
  local deployKnown = valid(S, 'deployInput')
  local deploying = deployKnown and S.deployInput > BAT.vanillaDeadband
  local cellW = (cw - 12 * s) * 0.5
  chip(fontLB, lx, py + 144 * s, cellW, 28 * s, deploying, C.green,
    deployKnown and L('deploying') or (L('deploying') .. ' --'), s)
  local recoveryKnown = valid(S, 'recovering')
  local recovering = recoveryKnown and S.recovering
  chip(fontLB, lx + cellW + 12 * s, py + 144 * s, cellW, 28 * s, recovering, C.red,   -- same red as the dial's harvest ring
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
  local panel = cfg.showPanel and (pro or vanilla)
  local panelW = vanilla and VANILLA_PANEL_W or PANEL_W
  drawDial(view, ox, oy, s, fontB, fontR, fontM)
  if panel then
    local draw = vanilla and drawVanillaPanel or drawPanel
    draw(view, ox + (DIAL_W + PANEL_GAP) * s, oy, s, fontB, fontR, fontLB, fontLR)
  end
  ui.setCursor(o)
  ui.dummy(vec2((DIAL_W + (panel and (PANEL_GAP + panelW) or 0)) * s, 340 * s))
end

local function hoverTip(key)
  if ui.itemHovered() then ui.setTooltip(L(key)) end
end

function script.windowSettings(dt)
  ui.header(L('language'))
  if ui.radioButton('English', cfg.lang ~= 'zh') then cfg.lang = 'en' end
  ui.sameLine(0, 16)
  if ui.radioButton('简体中文', cfg.lang == 'zh') then cfg.lang = 'zh' end

  ui.header(L('display'))
  cfg.scale = ui.slider('##scale', cfg.scale, 0.5, 2.5, L('scale'))
  if ui.checkbox(L('showPanel'), cfg.showPanel) then cfg.showPanel = not cfg.showPanel end
  if ui.checkbox(L('showBattery'), cfg.showBattery) then cfg.showBattery = not cfg.showBattery end
  ui.alignTextToFramePadding()
  ui.text(L('batteryTerminal'))
  hoverTip('terminalTip')
  ui.sameLine(0, 12)
  if ui.radioButton(L('terminalLeft') .. '##batteryTerminal', cfg.batteryTerminal == 'left') then cfg.batteryTerminal = 'left' end
  hoverTip('terminalTip')
  ui.sameLine(0, 16)
  if ui.radioButton(L('terminalRight') .. '##batteryTerminal', cfg.batteryTerminal ~= 'left') then cfg.batteryTerminal = 'right' end
  hoverTip('terminalTip')
  if ui.checkbox(L('batterySmooth'), cfg.batterySmoothing) then cfg.batterySmoothing = not cfg.batterySmoothing end
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
