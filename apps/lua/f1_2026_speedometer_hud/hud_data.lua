-- Vehicle-specific, read-only telemetry and replay adapters.
-- The v0.9.1 Pro stream is an immutable compatibility contract. See DATA-CONTRACT.md.
local M = {}
local PRO_ID, VANILLA_ID = 'vrc_formula_alpha_2026_csp', 'vrc_formula_alpha_2026'
local FA25_ID = 'vrc_formula_alpha_2025_csp'
local MAX_CARS, PRO_DIVISOR, NATIVE_DIVISOR = 22, 2, 1
local STRATEGIES = { 'LOW', 'MEDIUM', 'HIGH', 'NODEPLOY' }
local VALID_FIELDS = { 'soc', 'boost', 'strategy', 'strategyName', 'strat', 'recovering',
  'deployInput', 'drsPresent', 'drsAvailable', 'drsActive', 'smActive', 'smAvailable',
  'wingF', 'wingR', 'esoc', 'kw', 'deploy', 'regen', 'regenLimit', 'cap', 'split', 'puMode',
  'latch', 'otActive', 'otPending', 'charge', 'pl', 'plp', 'engineRunning', 'pitLimiter',
  'speed', 'rpm', 'gear', 'gas', 'brake' }
local BASIC_FIELDS = { speed = 'speedKmh', rpm = 'rpm', gear = 'gear', gas = 'gas', brake = 'brake' }
local DRS_FIELDS = { 'drsPresent', 'drsAvailable', 'drsActive' }
local PRO_FLAG_MASKS = { otActive = 1, otPending = 2, boost = 4, charge = 8, pl = 16,
  plp = 32, smActive = 256, wingF = 512, wingR = 1024, engineRunning = 2048, pitLimiter = 4096 }
local LATCH_HIGH = 8192   -- bit 13, free since v0.9.1: the Straight Mode latch's third bit

-- Evidence gates, not user settings. Enable only after an observed action/state comparison.
-- Native FA25 replay flags are constant in the available samples and are NOT verified history.
-- Vanilla SM: native live transitions plus the rear wing observed opening after DRS in game,
-- 2026-09-13. This establishes drag reduction, not independent Pro front/rear actuators.
-- Recovery: observed battery rise under braking and positive SoC changes in sustained native
-- kersCharging samples. It is a recovery status, not a guarantee of positive net battery flow.
-- Deployment: the native ERS input (kersInput), the value this car's four delivery controllers
-- produce from throttle and speed. It is a requested share of the car's deployment, never a
-- measured power, and only values inside 0..1 are accepted. The diagnostics line reports it
-- beside the battery level so live samples can be compared against the charge they consume.
M.validation = { vanillaSM = true, vanillaRecovery = true, vanillaDeploy = true,
  legacyReplayDRS = false }

local function finite(v)
  return type(v) == 'number' and v == v and v > -math.huge and v < math.huge
end
local function number(v, lo, hi)
  if finite(v) and (not lo or v >= lo) and (not hi or v <= hi) then return v end
  return nil
end
local function integer(v, lo, hi)
  if number(v, lo, hi) and v == math.floor(v) then return v end
  return nil
end
local function boolean(v)
  if type(v) == 'boolean' then return v end
  return nil
end
local function get(obj, key)
  if obj == nil then return nil end
  local ok, value = pcall(function() return obj[key] end)
  if ok then return value end
  return nil
end
local function invoke(fn, ...) return fn(...) end
local function call(fn, ...)
  -- ac.getCar is a callable table in CSP (it also provides .ordered/.leaderboard).
  -- Let pcall handle __call and failures instead of rejecting non-function callables.
  if fn == nil then return nil end
  local ok, value = pcall(invoke, fn, ...)
  if ok then return value end
  return nil
end
local function quantize(v, lo, hi)
  return math.floor(math.max(lo, math.min(hi, v)) + 0.5)
end
local function has(v, mask) return math.floor(v / mask) % 2 == 1 end
local function put(S, field, value)
  S[field], S.valid[field] = value, value ~= nil
end
local function clear(S)
  local valid, supported, candidate = S.valid or {}, S.supported or {}, S.candidate or {}
  for key in pairs(S) do S[key] = nil end
  for key in pairs(valid) do valid[key] = nil end
  for key in pairs(supported) do supported[key] = nil end
  for key in pairs(candidate) do candidate[key] = nil end
  S.valid, S.supported, S.candidate, S.full = valid, supported, candidate, false
  for _, field in ipairs(VALID_FIELDS) do valid[field] = false end
end
local function classify(id)
  if id == PRO_ID then return 'pro' end
  if id == VANILLA_ID then return 'vanilla' end
  return 'drs'
end
M.classify = classify

local PRO_NUMBERS = {
  esoc = 'kersChargeESOC', kw = 'rearMotorPowerKW', deploy = 'kersDeployMJ',
  regen = 'kersRegenMJ', regenLimit = 'kersRegenLimitMJ', cap = 'mgukMaxPower',
  split = 'deploymentSplit', puMode = 'puMode', latch = 'drsLatch',
}
local PRO_BOOLEANS = {
  otActive = 'isOvertakeActive', otPending = 'isOvertakeActivePending',
  boost = 'isHybridBoostActive', charge = 'isHybridAntiActive', pl = 'isPowerLimited',
  plp = 'isPowerLimitedPending', smActive = 'drsMode', engineRunning = 'isEngineRunning',
  pitLimiter = 'isPitLimiterActive',
}
local PRO_REQUIRED = { 'soc', 'esoc', 'kw', 'deploy', 'regen', 'regenLimit', 'cap',
  'strat', 'split', 'puMode', 'latch', 'otActive', 'otPending', 'boost', 'charge', 'pl',
  'plp', 'smActive', 'engineRunning', 'pitLimiter', 'wingF', 'wingR' }
-- Invalidation order only; the frozen ReplayStream layout below is unchanged.
local PRO_STREAM_FIELDS = { 'f26flags', 'f26soc', 'f26kw', 'f26deploy', 'f26regen', 'f26regenLimit',
  'f26esoc', 'f26cap', 'f26pack' }
local NATIVE_FIELDS = { 'f26n1owner', 'f26n1valid', 'f26n1state', 'f26n1soc', 'f26n1strategy' }
local NATIVE_BITS = { soc = 1, boost = 2, strategy = 4, recovering = 8,
  drsPresent = 16, drsAvailable = 32, drsActive = 64 }
-- 0.9.35 carries the native deployment share in the free high nibble of the strategy byte, and its
-- own validity with it: 0 = nothing recorded, 1-15 = share x 14 + 1. The array layout, the slot
-- count and every validity bit stay exactly as in schema 1, so recordings in both directions keep
-- the fields a reader knows: earlier versions validate this byte as 0-3 and simply lose the
-- strategy of a frame that carries a share, never the slot.
local DEPLOY_STEPS = 14
local NATIVE_STATE_BITS = { boost = 1, recovering = 2, drsPresent = 4,
  drsAvailable = 8, drsActive = 16 }
-- v1 schema and exact-car family; low byte is car slot + 1. Other cars are never recorded.
local function ownerBase(id)
  if id == VANILLA_ID then return 0xA600 end
  if id == FA25_ID then return 0xA500 end
end

function M.new(ac, sim, cfg)
  local data = { classify = classify, MAX_CARS = MAX_CARS, REPLAY_DIVISOR = PRO_DIVISOR,
    NATIVE_DIVISOR = NATIVE_DIVISOR, NATIVE_BYTES = MAX_CARS * 6,
    validation = M.validation, recordedPro = 0, recordedVanilla = 0, recordedDRS = 0,
    recordingGaps = { totalNativeEmpty = 0, lastNativeReason = 'none', lastNativeIndex = -1,
      totalProEmpty = 0, lastProReason = 'none', lastProIndex = -1 } }
  local can = { inputs = nil, carID = nil, count = 0, lastTry = -10, err = nil }
  data.can = can
  local function resetCAN()
    can.inputs, can.carID, can.count, can.lastTry, can.err = nil, nil, 0, -10, nil
  end
  if type(ac.onSessionStart) == 'function' then
    pcall(ac.onSessionStart, function()
      resetCAN()
      data.recordingGaps.totalNativeEmpty, data.recordingGaps.totalProEmpty = 0, 0
      data.recordingGaps.lastNativeReason, data.recordingGaps.lastNativeIndex = 'none', -1
      data.recordingGaps.lastProReason, data.recordingGaps.lastProIndex = 'none', -1
    end)
  end

  local function connectCAN(id)
    if id ~= PRO_ID then return false end
    if can.carID ~= id then resetCAN(); can.carID = id end
    if can.inputs then return true end
    local now = os.clock()
    if now >= can.lastTry and now - can.lastTry < 1 then return false end
    can.lastTry = now
    local raw = call(ac.load, id .. '_CAN')
    if type(raw) ~= 'string' or raw == '' then can.err = 'CAN map unavailable'; return false end
    local parsed = stringify and call(stringify.parse, raw)
    local st = type(parsed) == 'table' and (parsed.inputs and parsed or parsed[1])
    if type(st) ~= 'table' or type(st.inputs) ~= 'table' then
      can.err = 'CAN map has no valid inputs table'; return false
    end
    local inputs, count = {}, 0
    for name, field in pairs(st.inputs) do
      if type(name) == 'string' and type(field) == 'table' and integer(field[1], 0, 65535) then
        inputs[name], count = field, count + 1
      end
    end
    if count == 0 then can.err = 'CAN map has no valid channels'; return false end
    can.inputs, can.count, can.err = inputs, count, nil
    return true
  end
  local function rd(physics, field)
    local entry = can.inputs and can.inputs[field]
    if not entry then return nil end
    return number(get(get(physics, 'scriptControllerInputs'), entry[1]))
  end
  data.rd = rd -- Diagnostic access; caller must use only the exact Pro car and live physics.

  local function base(S, idx)
    clear(S)
    if not integer(idx, 0) then S.source = 'no car'; return nil end
    local car = call(ac.getCar, idx)
    if not car or get(car, 'isConnected') == false then S.source = 'no car'; return nil end
    local actualIndex = get(car, 'index')
    if actualIndex ~= nil and actualIndex ~= idx then S.source = 'car index mismatch'; return nil end
    S.index, S.carID = idx, call(ac.getCarID, idx)
    S.kind, S.fa26 = classify(S.carID), S.carID == PRO_ID or S.carID == VANILLA_ID
    S.name = call(ac.getDriverName, idx) or ''
    for key, native in pairs(BASIC_FIELDS) do put(S, key, number(get(car, native))) end
    S.physicsAvailable = boolean(get(car, 'physicsAvailable'))
    if S.kind == 'pro' then
      put(S, 'wingF', boolean(get(car, 'extraH')))
      put(S, 'wingR', boolean(get(car, 'extraI')))
    end
    return car
  end

  local function nativeDRS(S, car, trusted)
    for _, field in ipairs(DRS_FIELDS) do
      S.candidate[field] = boolean(get(car, field))
      if trusted then put(S, field, S.candidate[field]) end
    end
    if trusted then
      S.supported.drsActive = S.drsPresent
      if S.drsPresent == false then
        put(S, 'drsAvailable', false); put(S, 'drsActive', false)
      elseif S.drsPresent ~= true then
        put(S, 'drsAvailable', nil); put(S, 'drsActive', nil)
      end
    end
  end
  local function vanillaSemantics(S)
    S.supported.otActive, S.supported.otPending = false, false
    S.otActive, S.otPending = false, false
    if M.validation.vanillaSM then
      put(S, 'smActive', S.drsActive)
      put(S, 'smAvailable', S.drsAvailable)
    end
  end

  function data.readLive(S, idx)
    local car = base(S, idx)
    if not car then return false end
    if S.kind == 'drs' then
      nativeDRS(S, car, S.physicsAvailable == true)
      S.source = S.valid.drsActive and 'live: native DRS' or 'live: DRS unavailable'
      return true
    end
    if S.kind == 'vanilla' then
      nativeDRS(S, car, S.physicsAvailable == true)
      S.candidate.recovering = boolean(get(car, 'kersCharging'))
      if S.physicsAvailable == true then
        S.supported.soc = boolean(get(car, 'kersPresent'))
        S.supported.boost = boolean(get(car, 'kersHasButtonOverride'))
        if S.supported.soc == true then
          put(S, 'soc', number(get(car, 'kersCharge'), 0, 1))
          if M.validation.vanillaRecovery then put(S, 'recovering', S.candidate.recovering) end
          -- Deployment share requested by the car's delivery controller, not a measured power.
          if M.validation.vanillaDeploy then
            put(S, 'deployInput', number(get(car, 'kersInput'), 0, 1))
          end
        end
        if S.supported.soc == true and S.supported.boost == true then
          put(S, 'boost', boolean(get(car, 'kersButtonPressed')))
        end
        local count = integer(get(car, 'mgukDeliveryCount'), 1, 256)
        local strategy = integer(get(car, 'mgukDelivery'), 0, count and count - 1 or -1)
        if strategy ~= nil then
          local name = call(ac.getMGUKDeliveryName, idx, strategy)
          if type(name) == 'string' and name ~= '' then
            put(S, 'strat', strategy + 1); put(S, 'strategy', strategy)
            put(S, 'strategyName', name)
          end
        end
      end
      vanillaSemantics(S)
      S.source = 'live: native FA26'
      return true
    end
    S.source = 'live: waiting for Pro CAN'
    if S.physicsAvailable ~= true or not connectCAN(S.carID) then return true end
    local physics = call(ac.getCarPhysics, idx)
    if not physics then S.source = 'live: Pro physics unavailable'; return true end
    put(S, 'soc', number(get(car, 'kersCharge'), 0, 1))
    local strategy = integer(get(car, 'mgukDelivery'), 0, 15)
    put(S, 'strat', strategy and strategy + 1)
    for key, channel in pairs(PRO_NUMBERS) do put(S, key, rd(physics, channel)) end
    -- 0 off, 1 available, 2 pre-latched, 3 available inside the zone, 4 Straight Mode engaged
    -- (the car's own audio script reads 4 as SLM). Values 0-7 are carried; 4 and above need the
    -- flag word's third latch bit, added in 0.9.37.
    put(S, 'latch', integer(S.latch, 0, 7))
    put(S, 'split', integer(S.split, 0, 31))
    put(S, 'puMode', integer(S.puMode, 0, 15))
    for key, channel in pairs(PRO_BOOLEANS) do
      local value = rd(physics, channel)
      if value ~= nil then put(S, key, value > 0.5) end
    end
    S.full, S.source = true, 'live: Pro CAN, car ' .. idx
    return true
  end

  -- Do not change these field names, types, arrays or divisor: v0.9.1 stream identity.
  do
    local ok, result = pcall(function()
      return ac.ReplayStream({
        f26soc = ac.StructItem.array(ac.StructItem.uint8(), MAX_CARS),
        f26kw = ac.StructItem.array(ac.StructItem.int8(), MAX_CARS),
        f26deploy = ac.StructItem.array(ac.StructItem.uint8(), MAX_CARS),
        f26regen = ac.StructItem.array(ac.StructItem.uint8(), MAX_CARS),
        f26regenLimit = ac.StructItem.array(ac.StructItem.uint8(), MAX_CARS),
        f26esoc = ac.StructItem.array(ac.StructItem.uint8(), MAX_CARS),
        f26cap = ac.StructItem.array(ac.StructItem.uint8(), MAX_CARS),
        f26flags = ac.StructItem.array(ac.StructItem.uint16(), MAX_CARS),
        f26pack = ac.StructItem.array(ac.StructItem.uint16(), MAX_CARS),
      }, nil, PRO_DIVISOR)
    end)
    if ok then data.RS = result else data.rsErr = tostring(result) end
    if not data.RS and not data.rsErr then data.rsErr = 'stream absent' end
  end
  -- Raw integer StructItems have no replayType in CSP's official struct builder: they
  -- are excluded from its interpolation map. Do not replace with float/unorm fields.
  do
    local ok, result = pcall(function()
      return ac.ReplayStream({
        f26n1owner = ac.StructItem.array(ac.StructItem.uint16(), MAX_CARS),
        f26n1valid = ac.StructItem.array(ac.StructItem.uint8(), MAX_CARS),
        f26n1state = ac.StructItem.array(ac.StructItem.uint8(), MAX_CARS),
        f26n1soc = ac.StructItem.array(ac.StructItem.uint8(), MAX_CARS),
        f26n1strategy = ac.StructItem.array(ac.StructItem.uint8(), MAX_CARS),
      }, nil, NATIVE_DIVISOR)
    end)
    if ok then data.VRS = result else data.vrsErr = tostring(result) end
    if not data.VRS and not data.vrsErr then data.vrsErr = 'stream absent' end
  end

  local function clearSlot(stream, fields, i)
    if stream then for _, field in ipairs(fields) do stream[field][i] = 0 end end
  end
  local function clearStreams()
    for i = 0, MAX_CARS - 1 do
      clearSlot(data.RS, PRO_STREAM_FIELDS, i)
      clearSlot(data.VRS, NATIVE_FIELDS, i)
    end
  end
  -- Latch bits 0-1 stay in bits 6-7 where v0.9.1 put them; bit 2 goes to the free bit 13, so a
  -- reader older than 0.9.37 sees 4-7 as 0-3 and every other field of the frame still restores.
  local function packPro(S)
    local f = 0x8000 + (S.latch % 4) * 64 + (S.latch >= 4 and LATCH_HIGH or 0)
    for field, mask in pairs(PRO_FLAG_MASKS) do if S[field] then f = f + mask end end
    return f
  end
  local function recordPro(S, i)
    -- The old stream has no per-field validity, so one missing field costs the whole frame. Name it:
    -- a silently skipped frame is invisible in the replay until someone watches that stretch.
    for _, field in ipairs(PRO_REQUIRED) do
      if not S.valid[field] then
        local gaps = data.recordingGaps
        gaps.totalProEmpty, gaps.lastProReason, gaps.lastProIndex = gaps.totalProEmpty + 1, field, i
        return false
      end
    end
    local r = data.RS
    r.f26soc[i] = quantize(S.soc * 250, 0, 255)
    r.f26kw[i] = quantize(S.kw / 3, -128, 127)
    r.f26deploy[i] = quantize(S.deploy * 20, 0, 255)
    r.f26regen[i] = quantize(S.regen * 20, 0, 255)
    r.f26regenLimit[i] = quantize(S.regenLimit * 20, 0, 255)
    r.f26esoc[i] = quantize(S.esoc * 10, 0, 255)
    r.f26cap[i] = quantize(S.cap / 2, 0, 255)
    r.f26pack[i] = S.strat - 1 + S.split * 16 + S.puMode * 512
    r.f26flags[i] = packPro(S)
    return true
  end
  local function recordNative(S, i)
    local r, valid, state = data.VRS, 0, 0
    for field, mask in pairs(NATIVE_BITS) do
      local trusted = S.valid[field] == true
      if S.kind == 'vanilla' and (field == 'drsActive' or field == 'drsAvailable')
          and not M.validation.vanillaSM then trusted = false end
      if field == 'strategy' then
        -- Index alone is not a stable meaning; record only the verified four-name contract.
        trusted = trusted and STRATEGIES[S.strategy + 1] == S.strategyName
      end
      if trusted then
        valid = valid + mask
        if NATIVE_STATE_BITS[field] and S[field] then state = state + NATIVE_STATE_BITS[field] end
      end
    end
    if valid == 0 then return false end
    local owner = ownerBase(S.carID) + i + 1
    -- Construct this sample before touching the shared replay buffer. A valid-to-valid
    -- refresh must not publish a temporary empty slot while native APIs are being read.
    local soc = has(valid, NATIVE_BITS.soc) and quantize(S.soc * 250, 0, 250) or 0
    local strategy = has(valid, NATIVE_BITS.strategy) and S.strategy or 0
    -- Only the native FA26 has a delivery controller; no other family writes this nibble.
    local deploy = (S.kind == 'vanilla' and S.valid.deployInput == true)
      and (quantize(S.deployInput * DEPLOY_STEPS, 0, DEPLOY_STEPS) + 1) or 0
    local previousValid = r.f26n1owner[i] == owner and r.f26n1valid[i] or 0
    local retainedValid = 0
    for _, mask in pairs(NATIVE_BITS) do
      if has(valid, mask) and has(previousValid, mask) then retainedValid = retainedValid + mask end
    end
    -- Revoke fields that have genuinely become invalid before clearing their payload.
    -- The full-valid path keeps its valid mask throughout publication.
    if r.f26n1owner[i] ~= owner or retainedValid ~= previousValid then r.f26n1valid[i] = retainedValid end
    r.f26n1soc[i] = soc
    r.f26n1strategy[i] = strategy + deploy * 16
    r.f26n1state[i] = state
    r.f26n1valid[i] = valid
    r.f26n1owner[i] = owner
    return true
  end
  local recordSnap = {}
  function data.recordAll()
    data.recordedPro, data.recordedVanilla, data.recordedDRS = 0, 0, 0
    -- During replay these are CSP-owned read buffers: never clear or write them.
    if sim.isReplayActive then return 0 end
    if not cfg.recordReplay then clearStreams(); return 0 end
    local count = integer(sim.carsCount, 0) or 0
    for i = 0, MAX_CARS - 1 do
      local wrotePro, wroteNative = false, false
      local readable = i < count and data.readLive(recordSnap, i)
      if readable then
        if recordSnap.kind == 'pro' and data.RS and recordSnap.full and recordPro(recordSnap, i) then
          data.recordedPro, wrotePro = data.recordedPro + 1, true
        elseif ownerBase(recordSnap.carID) and data.VRS and recordNative(recordSnap, i) then
          wroteNative = true
          if recordSnap.kind == 'vanilla' then data.recordedVanilla = data.recordedVanilla + 1
          else data.recordedDRS = data.recordedDRS + 1 end
        end
      end
      -- Only genuinely absent/invalid/inapplicable slots are cleared. This is not a
      -- hold-last-value fallback: an invalid current snapshot is discarded this update.
      if not wrotePro then clearSlot(data.RS, PRO_STREAM_FIELDS, i) end
      if not wroteNative then clearSlot(data.VRS, NATIVE_FIELDS, i) end
      if i < count and not wroteNative then
        local id = recordSnap.carID or call(ac.getCarID, i)
        if ownerBase(id) then
          local gaps = data.recordingGaps
          gaps.totalNativeEmpty, gaps.lastNativeIndex = gaps.totalNativeEmpty + 1, i
          if not data.VRS then gaps.lastNativeReason = 'native stream unavailable'
          elseif not readable then gaps.lastNativeReason = recordSnap.source or 'car unavailable'
          elseif recordSnap.physicsAvailable ~= true then gaps.lastNativeReason = 'physics unavailable'
          else gaps.lastNativeReason = 'no valid native fields' end
        end
      end
    end
    return data.recordedPro + data.recordedVanilla + data.recordedDRS
  end

  local function replayPro(S, idx)
    local r = data.RS
    if not r or idx >= MAX_CARS then return false end
    local f = integer(r.f26flags[idx], 0, 65535)
    if not f or not has(f, 0x8000) then return false end
    local p = integer(r.f26pack[idx], 0, 65535)
    if not p then return false end
    local numbers = { soc = { 'f26soc', 1 / 250 }, kw = { 'f26kw', 3 },
      deploy = { 'f26deploy', 1 / 20 }, regen = { 'f26regen', 1 / 20 },
      regenLimit = { 'f26regenLimit', 1 / 20 }, esoc = { 'f26esoc', 1 / 10 }, cap = { 'f26cap', 2 } }
    for field, encoding in pairs(numbers) do
      local value = number(r[encoding[1]][idx])
      put(S, field, value and value * encoding[2])
    end
    put(S, 'strat', p % 16 + 1); put(S, 'split', math.floor(p / 16) % 32)
    put(S, 'puMode', math.floor(p / 512) % 16)
    put(S, 'latch', math.floor(f / 64) % 4 + (has(f, LATCH_HIGH) and 4 or 0))
    -- Recorded false is authoritative: never OR it with a possibly stale native switch.
    for field, mask in pairs(PRO_FLAG_MASKS) do put(S, field, has(f, mask)) end
    S.full, S.source = true, 'replay: Pro app stream, car ' .. idx
    return true
  end
  local function replayNative(S, idx)
    local r = data.VRS
    local owner = ownerBase(S.carID)
    if not r or not owner or idx >= MAX_CARS or r.f26n1owner[idx] ~= owner + idx + 1 then return false end
    -- Whole-byte ranges: a bit this version does not know is ignored, never a reason to drop a slot.
    local valid = integer(r.f26n1valid[idx], 0, 255)
    local state = integer(r.f26n1state[idx], 0, 255)
    if not valid or not state then return false end
    for field, mask in pairs(NATIVE_STATE_BITS) do
      if (S.kind == 'vanilla' or field == 'drsPresent' or field == 'drsAvailable' or field == 'drsActive')
          and has(valid, NATIVE_BITS[field]) then put(S, field, has(state, mask)) end
    end
    if not M.validation.vanillaRecovery then put(S, 'recovering', nil) end
    if S.kind == 'vanilla' and has(valid, NATIVE_BITS.soc) then
      local soc = integer(r.f26n1soc[idx], 0, 250)
      put(S, 'soc', soc and soc / 250)
    end
    if S.kind == 'vanilla' then
      -- One byte, two fields: the strategy index in bits 0-3, the deployment share in bits 4-7.
      local packed = integer(r.f26n1strategy[idx], 0, 255)
      local deploy = packed and math.floor(packed / 16)
      if deploy and deploy > 0 and M.validation.vanillaDeploy then
        put(S, 'deployInput', (deploy - 1) / DEPLOY_STEPS)
      end
      if packed and has(valid, NATIVE_BITS.strategy) then
        local strategy = packed % 16
        if strategy <= 3 then
          put(S, 'strategy', strategy); put(S, 'strat', strategy + 1)
          put(S, 'strategyName', STRATEGIES[strategy + 1])
        end
      end
    end
    if S.kind == 'vanilla' then S.supported.soc, S.supported.boost = true, true end
    S.supported.drsActive = S.drsPresent
    S.source = 'replay: native app stream, car ' .. idx
    return true
  end
  function data.readReplay(S, idx)
    local car = base(S, idx)
    if not car then return false end
    if S.kind == 'pro' then
      if not replayPro(S, idx) then S.source = 'replay: Pro native wings only; no app data' end
    elseif S.kind == 'vanilla' then
      nativeDRS(S, car, false)
      S.candidate.recovering = boolean(get(car, 'kersCharging'))
      if not replayNative(S, idx) then S.source = 'replay: native FA26 history unavailable' end
      vanillaSemantics(S)
    else
      nativeDRS(S, car, M.validation.legacyReplayDRS and S.physicsAvailable == true)
      if not replayNative(S, idx) then
        S.source = S.valid.drsActive and 'replay: native DRS' or 'replay: DRS history unavailable'
      end
    end
    return true
  end
  return data
end

return M
