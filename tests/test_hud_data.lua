-- Run with tools/test.ps1 (MoonSharp), or provide loadHudData() in another Lua runner.
-- Synthetic values only: no mod source, personal telemetry or replay files.
local D = loadHudData()
local checks = 0
local function check(condition, message)
  checks = checks + 1
  assert(condition, message)
end
local function equal(actual, expected, message)
  check(actual == expected, message .. ': ' .. tostring(actual) .. ' ~= ' .. tostring(expected))
end
-- The recorded deployment share: 14 steps, offset by one so code 0 means nothing was recorded.
local function quantiseShare(v) return math.floor(v * 14 + 0.5) end
check(D.validation.vanillaSM, 'SM evidence gate enabled after observed rear-wing action')
check(D.validation.vanillaRecovery, 'recovery evidence gate enabled after battery/charging comparison')
check(D.validation.vanillaDeploy, 'deployment evidence gate enabled for the native delivery input')
-- Exercise the missing-evidence branch too; later scenarios enable it again.
D.validation.vanillaSM, D.validation.vanillaRecovery, D.validation.vanillaDeploy = false, false, false
local PRO, VAN, FA25 = 'vrc_formula_alpha_2026_csp', 'vrc_formula_alpha_2026', 'vrc_formula_alpha_2025_csp'
local frames, ids, maps, channels, loads, sessions = {}, {}, {}, {}, {}, {}
local sim = { carsCount = 1, isReplayActive = false, replayCurrentFrame = 0 }
local cfg = { recordReplay = true }
local layouts, streams, divisors = {}, {}, {}
local names = { 'LOW', 'MEDIUM', 'HIGH', 'NODEPLOY' }
local si = {}
for name, bytes in pairs({ uint8 = 1, int8 = 1, uint16 = 2 }) do
  local kind, size = name, bytes
  si[name] = function() return { kind = kind, size = size } end
end
si.array = function(element, count) return { element = element, count = count, size = element.size * count } end
local acStub = {
  getCar = setmetatable({}, { __call = function(_, i) return frames[i] end }),
  getCarID = function(i) return ids[i] end,
  getDriverName = function(i) return 'Driver ' .. i end,
  getCarPhysics = function(i) return { scriptControllerInputs = channels[i] } end,
  getMGUKDeliveryName = function(i, p) return names[p + 1] end,
  load = function(key) loads[#loads + 1] = key; return maps[key] end,
  onSessionStart = function(fn) sessions[#sessions + 1] = fn end,
  StructItem = si,
  ReplayStream = function(layout, callback, divisor)
    local result = {}
    for key, field in pairs(layout) do
      result[key] = {}
      for i = 0, field.count - 1 do result[key][i] = 0 end
    end
    layouts[#layouts + 1], streams[#streams + 1], divisors[#divisors + 1] = layout, result, divisor
    return result
  end,
}
local canInputs, canValues = {}, {}
local channelNames = {
  'kersChargeESOC', 'rearMotorPowerKW', 'kersDeployMJ', 'kersRegenMJ', 'kersRegenLimitMJ',
  'mgukMaxPower', 'deploymentSplit', 'puMode', 'drsLatch', 'isOvertakeActive',
  'isOvertakeActivePending', 'isHybridBoostActive', 'isHybridAntiActive', 'isPowerLimited',
  'isPowerLimitedPending', 'drsMode', 'isEngineRunning', 'isPitLimiterActive',
}
for i, name in ipairs(channelNames) do canInputs[name], canValues[i - 1] = { i - 1, false }, 0 end
stringify = { parse = function() return { inputs = canInputs } end }
maps[PRO .. '_CAN'] = 'synthetic channel map'
local function car(i, id)
  ids[i] = id
  frames[i] = { index = i, isConnected = true, physicsAvailable = true,
    speedKmh = 100, rpm = 10000, gear = 4, gas = 1, brake = 0,
    extraH = false, extraI = false, kersPresent = true, kersHasButtonOverride = true,
    kersCharge = 0.4, kersInput = 1, kersButtonPressed = false, kersCharging = true,
    mgukDelivery = 0, mgukDeliveryCount = 4, drsPresent = true, drsAvailable = false, drsActive = false }
  channels[i] = {}
  for key, value in pairs(canValues) do channels[i][key] = value end
  return frames[i]
end
local function cloneStream(r)
  local copy = {}
  for key, array in pairs(r) do copy[key] = {}; for i, value in pairs(array) do copy[key][i] = value end end
  return copy
end
local function restore(r, copy)
  for key, array in pairs(copy) do for i, value in pairs(array) do r[key][i] = value end end
end
local data = D.new(acStub, sim, cfg)
local S = {}

-- Frozen Pro replay layout: all names/types and divisor exactly match v0.9.1.
local contract = { f26soc = 'uint8', f26kw = 'int8', f26deploy = 'uint8', f26regen = 'uint8',
  f26regenLimit = 'uint8', f26esoc = 'uint8', f26cap = 'uint8', f26flags = 'uint16', f26pack = 'uint16' }
local size, count = 0, 0
for name, field in pairs(layouts[1]) do
  equal(field.element.kind, contract[name], 'Pro stream type/name ' .. name)
  equal(field.count, 22, 'Pro slot count'); size = size + field.size; count = count + 1
end
equal(count, 9, 'Pro field count'); equal(size, 242, 'Pro bytes'); equal(divisors[1], 2, 'Pro divisor')
size = 0
for name, field in pairs(layouts[2]) do
  check(field.element.kind == 'uint8' or field.element.kind == 'uint16', 'native stream uses only non-blended integers')
  equal(field.count, 22, 'native slot count'); size = size + field.size
end
equal(size, 132, 'native stream bytes'); equal(size, data.NATIVE_BYTES, 'reported native size')
equal(divisors[2], 1, 'native stream records every frame')

for id, kind in pairs({ [PRO] = 'pro', [VAN] = 'vanilla', [FA25] = 'drs',
  vrc_formula_alpha_2026_csp_fake = 'drs', vrc_formula_alpha_2026_other = 'drs', no_system = 'drs' }) do
  equal(data.classify(id), kind, 'exact classification ' .. id)
end
equal(data.classify(nil), 'drs', 'missing ID')
local c = car(0, FA25); c.extraH, c.extraI, c.drsActive = true, true, true
data.readLive(S, 0)
equal(S.kind, 'drs', 'FA25 layout'); equal(S.wingF, nil, 'FA25 H is not SM')
equal(S.wingR, nil, 'FA25 I is not SM'); equal(S.drsActive, true, 'native DRS active')
equal(#loads, 0, 'legacy never connects Pro CAN')
c.drsPresent = false; data.readLive(S, 0)
equal(S.drsActive, false, 'no DRS stays off even with contradictory active flag')
equal(S.valid.drsActive, true, 'no DRS is a known off')
c.physicsAvailable = false; data.readLive(S, 0)
equal(S.drsActive, nil, 'unavailable physics cannot report known DRS off')
equal(S.valid.drsActive, false, 'missing DRS has invalid bit')
c = car(0, VAN); c.extraH = true
data.readLive(S, 0)
equal(#loads, 0, 'vanilla never connects Pro CAN'); equal(S.full, false, 'vanilla is not full Pro')
equal(S.soc, 0.4, 'native SoC'); equal(S.boost, false, 'automatic deployment is not manual BOOST')
equal(S.valid.boost, true, 'native manual false is valid'); equal(S.strategyName, 'LOW', 'native strategy name')
equal(S.strategy, 0, 'LOW index zero is valid'); equal(S.smActive, nil, 'unvalidated SM absent')
equal(S.smAvailable, nil, 'unvalidated SM availability absent'); equal(S.recovering, nil, 'unvalidated recovery absent')
equal(S.candidate.recovering, true, 'candidate recovery retained'); equal(S.wingF, nil, 'vanilla ignores H')
equal(S.otActive, false, 'vanilla OT stays dark'); equal(S.supported.otActive, false, 'OT unsupported')
equal(S.valid.otActive, false, 'unsupported OT is not historical false')
equal(S.deployInput, nil, 'ungated deployment input absent')
equal(S.valid.deployInput, false, 'ungated deployment input invalid')

-- Native delivery input: a requested share, validated like every other native number.
D.validation.vanillaDeploy = true
data.readLive(S, 0); equal(S.deployInput, 1, 'native deployment input read')
c.kersInput = 0.45; data.readLive(S, 0); equal(S.deployInput, 0.45, 'partial deployment share')
c.kersInput = 0; data.readLive(S, 0)
equal(S.deployInput, 0, 'a real zero share is kept'); equal(S.valid.deployInput, true, 'zero share is valid')
c.kersInput = 1.5; data.readLive(S, 0); equal(S.valid.deployInput, false, 'share above one rejected')
c.kersInput = -0.2; data.readLive(S, 0); equal(S.valid.deployInput, false, 'negative share rejected')
c.kersInput = 0 / 0; data.readLive(S, 0); equal(S.valid.deployInput, false, 'NaN share rejected')
c.kersInput = nil; data.readLive(S, 0); equal(S.deployInput, nil, 'missing share is not zero')
c.kersInput = 0.45; c.kersPresent = false; data.readLive(S, 0)
equal(S.valid.deployInput, false, 'no KERS, no deployment share')
c.kersPresent = true; c.kersInput = 1
c.physicsAvailable = false; data.readLive(S, 0)
equal(S.deployInput, nil, 'remote physics exposes no deployment share')
c.physicsAvailable = true
D.validation.vanillaDeploy = false
data.readLive(S, 0); equal(S.valid.deployInput, false, 'the gate closes the field again')
c.kersCharge, c.kersButtonPressed, c.mgukDelivery = 0, true, 3
data.readLive(S, 0)
equal(S.soc, 0, 'real zero SoC retained'); equal(S.valid.soc, true, 'real zero SoC valid')
equal(S.boost, true, 'manual BOOST'); equal(S.strategyName, 'NODEPLOY', 'fourth strategy')
c.kersCharge, c.kersButtonPressed, c.mgukDelivery = nil, nil, nil
data.readLive(S, 0)
equal(S.soc, nil, 'missing SoC is not zero'); equal(S.boost, nil, 'missing button is not false')
equal(S.strategyName, nil, 'missing strategy is not LOW')
c.kersCharge = 0 / 0; data.readLive(S, 0); equal(S.valid.soc, false, 'NaN invalid')
c.kersCharge = 1.1; data.readLive(S, 0); equal(S.valid.soc, false, 'out-of-range SoC invalid')
c.kersCharge, c.kersButtonPressed, c.mgukDelivery = 0.7, false, 1
c.physicsAvailable = false; data.readLive(S, 0)
equal(S.soc, nil, 'remote physics missing'); equal(S.boost, nil, 'remote cannot borrow player button')
equal(S.strategyName, nil, 'remote cannot borrow player strategy')
c.physicsAvailable = true
setmetatable(c, { __index = function(_, key) if key == 'kersCharging' then error('missing API') end end })
c.kersCharging = nil; check(data.readLive(S, 0), 'throwing native property is contained')

-- Old ordinary replay stays missing despite native default false/zero/LOW.
sim.isReplayActive = true
c.kersCharge, c.kersButtonPressed, c.mgukDelivery = 0, false, 0
data.readReplay(S, 0)
equal(S.soc, nil, 'old native SoC unknown'); equal(S.boost, nil, 'old native button unknown')
equal(S.strategyName, nil, 'old native strategy unknown'); equal(S.drsActive, nil, 'old native DRS unknown')
sim.isReplayActive = false; c = car(0, VAN)
equal(data.recordAll(), 1, 'record vanilla')
local vanillaOff = cloneStream(data.VRS)
equal(data.VRS.f26n1owner[0], 0xA601, 'vanilla car/slot association')
sim.isReplayActive = true; c.kersCharge, c.kersButtonPressed = 0, true
data.readReplay(S, 0)
equal(S.soc, 0.4, 'recorded SoC outranks native default'); equal(S.boost, false, 'recorded false outranks native true')
equal(S.strategyName, 'LOW', 'recorded strategy'); equal(S.smActive, nil, 'recorded unverified SM absent')
equal(data.recordAll(), 0, 'replay does not record')
equal(data.VRS.f26n1owner[0], 0xA601, 'replay buffers never cleared by recordAll')

-- A short future-validation scenario: typed manual/recovery/DRS values record independently.
D.validation.vanillaSM, D.validation.vanillaRecovery, D.validation.vanillaDeploy = true, true, true
sim.isReplayActive = false; c = car(0, VAN)
c.kersButtonPressed, c.drsAvailable, c.drsActive, c.mgukDelivery = true, true, true, 3
c.kersInput = 0.6
data.recordAll(); local vanillaOn = cloneStream(data.VRS)
sim.isReplayActive = true; c.drsActive, c.kersCharging = false, false
data.readReplay(S, 0)
equal(S.boost, true, 'recorded manual true'); equal(S.recovering, true, 'recorded recovery')
equal(S.smActive, true, 'validated SM from record'); equal(S.smAvailable, true, 'validated SM available')
equal(S.strategyName, 'NODEPLOY', 'recorded discrete strategy')

-- One byte carries both: the strategy index in bits 0-3, the deployment share and its own
-- validity in bits 4-7. Every schema-1 validity bit and the 132-byte layout stay untouched.
equal(data.VRS.f26n1strategy[0], 3 + (quantiseShare(0.6) + 1) * 16, 'strategy and deployment share in one byte')
equal(data.VRS.f26n1valid[0], 127, 'the share needs no validity bit of its own')
equal(data.NATIVE_BYTES, 132, 'the share needs no extra stream byte')
equal(S.deployInput, quantiseShare(0.6) / 14, 'recorded deployment share restored')
sim.isReplayActive = false; c.kersInput = 1
data.recordAll(); local vanillaFull = cloneStream(data.VRS)
sim.isReplayActive = true
data.readReplay(S, 0); equal(S.deployInput, 1, 'a full share survives quantisation')
equal(S.strategyName, 'NODEPLOY', 'a full share leaves the strategy nibble intact')
equal(data.VRS.f26n1strategy[0], 3 + 15 * 16, 'a full share is the highest code')
sim.isReplayActive = false; c.kersInput = 0
data.recordAll(); data.readReplay(S, 0)
equal(S.deployInput, 0, 'a recorded zero share is a valid zero, not a missing field')
equal(data.VRS.f26n1strategy[0], 3 + 16, 'a zero share is the lowest recorded code')
c.kersInput = nil; data.recordAll()
equal(data.VRS.f26n1strategy[0], 3, 'an unavailable share leaves the nibble empty')
data.readReplay(S, 0); equal(S.deployInput, nil, 'an empty nibble reports no share')
sim.isReplayActive = true
restore(data.VRS, vanillaOn)
D.validation.vanillaDeploy = false; data.readReplay(S, 0)
equal(S.deployInput, nil, 'ungated playback drops the recorded share')
equal(S.strategyName, 'NODEPLOY', 'the gate does not disturb the strategy in the same byte')
D.validation.vanillaDeploy = true
-- Recordings made before the nibble existed: no share, and their strategy still reads.
data.VRS.f26n1strategy[0] = 3
data.readReplay(S, 0)
equal(S.deployInput, nil, 'an older recording reports no share')
equal(S.strategyName, 'NODEPLOY', 'an older recording keeps its strategy')
restore(data.VRS, vanillaOn); data.VRS.f26n1strategy[0] = 7 + 10 * 16
data.readReplay(S, 0)
equal(S.strategyName, nil, 'a strategy index outside the four-name contract is rejected')
equal(S.deployInput, 9 / 14, 'the share survives an unusable strategy nibble')
restore(data.VRS, vanillaFull); data.readReplay(S, 0)
equal(S.deployInput, 1, 'restored full-share frame')
restore(data.VRS, vanillaOn); data.readReplay(S, 0)
c.kersInput = 0.6
local onState = data.VRS.f26n1state[0]
sim.replayCurrentFrame = 500; data.readReplay(S, 0); data.readReplay(S, 0)
equal(data.VRS.f26n1state[0], onState, 'paused reads do not mutate stream')
restore(data.VRS, vanillaOff); sim.replayCurrentFrame = 20; data.readReplay(S, 0)
equal(S.boost, false, 'backward seek immediately reads earlier false'); equal(S.strategyName, 'LOW', 'seek strategy')
equal(S.recovering, nil, 'missing bit does not reuse later recovery')
restore(data.VRS, vanillaOn)
local onStateBits = data.VRS.f26n1state[0]
data.VRS.f26n1valid[0] = 2; data.readReplay(S, 0)
equal(S.boost, true, 'partial valid button'); equal(S.soc, nil, 'partial invalid SoC')
equal(S.strategyName, nil, 'partial invalid strategy'); equal(S.smActive, nil, 'partial invalid SM')
equal(S.deployInput, 8 / 14, 'the share does not depend on the strategy validity bit')
-- A recording from a later version: bits this version does not know are ignored, never a reason
-- to drop the slot.
data.VRS.f26n1valid[0] = 127 + 128; data.VRS.f26n1state[0] = onStateBits + 32
data.readReplay(S, 0)
equal(S.boost, true, 'an unknown validity bit does not discard the slot')
equal(S.strategyName, 'NODEPLOY', 'an unknown state bit does not discard the slot')
restore(data.VRS, vanillaOn); data.VRS.f26n1valid[0] = 2
data.VRS.f26n1owner[0] = 0; data.readReplay(S, 0)
equal(S.boost, nil, 'unrecorded frame clears button')
restore(data.VRS, vanillaOn); data.VRS.f26n1owner[0] = 0xA602; data.readReplay(S, 0)
equal(S.soc, nil, 'wrong slot association rejected')
restore(data.VRS, vanillaOn); ids[0] = FA25; data.readReplay(S, 0)
equal(S.drsActive, nil, 'wrong vehicle family association rejected'); equal(S.soc, nil, 'FA25 cannot read vanilla SoC')
D.validation.vanillaSM, D.validation.vanillaRecovery, D.validation.vanillaDeploy = false, false, false

-- Only exact FA25 receives the evidence-required minimal DRS supplement.
sim.isReplayActive = false; c = car(0, FA25); c.drsActive, c.drsAvailable = true, true
equal(data.recordAll(), 1, 'record exact FA25'); equal(data.recordedDRS, 1, 'FA25 count')
equal(data.VRS.f26n1owner[0], 0xA501, 'FA25 car/slot association')
D.validation.vanillaDeploy = true
equal(data.recordAll(), 1, 'record exact FA25 with the deployment gate open')
equal(data.VRS.f26n1strategy[0], 0, 'another family records neither strategy nor deployment share')
check(data.VRS.f26n1valid[0] <= 127, 'the validity mask stays inside schema 1')
D.validation.vanillaDeploy = false
sim.isReplayActive = true; c.drsActive = false; data.readReplay(S, 0)
equal(S.drsActive, true, 'new FA25 replay restored'); equal(S.soc, nil, 'FA25 never receives hybrid panel')
data.VRS.f26n1owner[0] = 0; data.readReplay(S, 0)
equal(S.drsActive, nil, 'old FA25 native false is unknown'); equal(S.valid.drsActive, false, 'old FA25 invalid')

-- Since 0.9.39 every other car with a native DRS component records the DRS subset under the generic
-- family (0xA000 + slot + 1): CSP playback reports no DRS history of its own for any sampled car.
local OTHER = 'another_drs_car'
sim.isReplayActive = false; c = car(0, OTHER); c.drsAvailable, c.drsActive = true, true
D.validation.vanillaSM, D.validation.vanillaRecovery, D.validation.vanillaDeploy = true, true, true
equal(data.recordAll(), 1, 'a conventional DRS car is recorded'); equal(data.recordedDRS, 1, 'and counted as a DRS car')
equal(data.recordedVanilla, 0, 'never as a standard FA26')
equal(data.VRS.f26n1owner[0], 0xA001, 'generic family car/slot association')
equal(data.VRS.f26n1valid[0], 16 + 32 + 64, 'only the DRS subset is valid, whatever the other gates say')
equal(data.VRS.f26n1state[0], 4 + 8 + 16, 'present, available and open recorded')
equal(data.VRS.f26n1soc[0], 0, 'a generic car records no battery')
equal(data.VRS.f26n1strategy[0], 0, 'nor a strategy or deployment share')
local genericOpen = cloneStream(data.VRS)
sim.isReplayActive = true; c.drsActive, c.drsAvailable = false, false; data.readReplay(S, 0)
equal(S.kind, 'drs', 'a generic car keeps the conventional layout in replay')
equal(S.drsActive, true, 'generic replay restores the open wing'); equal(S.drsAvailable, true, 'and its availability')
equal(S.drsPresent, true, 'and the component'); equal(S.supported.drsActive, true, 'so the badge is supported')
equal(S.soc, nil, 'a generic car never receives a battery'); equal(S.boost, nil, 'nor a manual button')
equal(S.recovering, nil, 'nor a recovery state'); equal(S.strategyName, nil, 'nor a strategy')
equal(S.source, 'replay: native app stream, car 0', 'the source names the app stream')
sim.isReplayActive = false; c.drsActive, c.drsAvailable = false, true; data.recordAll()
equal(data.VRS.f26n1state[0], 4 + 8, 'available and closed recorded')
sim.isReplayActive = true; c.drsActive = true; data.readReplay(S, 0)
equal(S.drsActive, false, 'a recorded closed wing outranks the native playback value')
equal(S.valid.drsActive, true, 'and is a valid false')
restore(data.VRS, genericOpen); data.VRS.f26n1owner[0] = 0xA002; data.readReplay(S, 0)
equal(S.drsActive, nil, 'a generic record for another slot is rejected')
equal(S.source, 'replay: DRS history unavailable', 'and the source says so')
restore(data.VRS, genericOpen); data.VRS.f26n1owner[0] = 0
data.readReplay(S, 0); equal(S.drsActive, nil, 'an unrecorded frame stays unknown, not closed')
restore(data.VRS, genericOpen); ids[0] = VAN; data.readReplay(S, 0)
equal(S.drsActive, nil, 'a generic record is never read for a standard FA26')
equal(S.smActive, nil, 'so its SM stays unknown'); equal(S.soc, nil, 'and no battery appears')
ids[0] = FA25; data.readReplay(S, 0)
equal(S.drsActive, nil, 'nor for the exact FA25, which has its own family')
ids[0] = OTHER; restore(data.VRS, genericOpen); data.readReplay(S, 0)
equal(S.drsActive, true, 'the matching generic car still reads it')
restore(data.VRS, vanillaOn); data.VRS.f26n1owner[0] = 0xA001; ids[0] = OTHER; data.readReplay(S, 0)
equal(S.soc, nil, 'standard-FA26 bits under a generic owner never become a battery')
equal(S.boost, nil, 'nor a manual button'); equal(S.recovering, nil, 'nor a recovery state')
equal(S.strategyName, nil, 'nor a strategy'); equal(S.deployInput, nil, 'nor a deployment share')
equal(S.drsActive, true, 'only the DRS subset of such a slot is read')
-- No component, nothing to keep: no record and no counted gap. A remote car without physics is a gap.
sim.isReplayActive = false; c = car(0, 'car_without_drs'); c.drsPresent = false
local gapsBefore = data.recordingGaps.totalNativeEmpty
equal(data.recordAll(), 0, 'a car without DRS is not recorded')
equal(data.VRS.f26n1owner[0], 0, 'its slot stays empty')
equal(data.recordingGaps.totalNativeEmpty, gapsBefore, 'and its empty slot is not a gap')
c = car(0, OTHER); c.drsActive = true; data.recordAll()
equal(data.VRS.f26n1owner[0], 0xA001, 'the generic slot is filled again')
c.drsPresent = false; data.recordAll()
equal(data.VRS.f26n1owner[0], 0, 'a car that stops reporting DRS clears its slot')
equal(data.recordingGaps.totalNativeEmpty, gapsBefore, 'without a counted gap')
c.drsPresent, c.physicsAvailable = true, false
equal(data.recordAll(), 0, 'a generic car without physics cannot be recorded')
equal(data.recordingGaps.totalNativeEmpty, gapsBefore + 1, 'and its missing record is a counted gap')
equal(data.recordingGaps.lastNativeReason, 'physics unavailable', 'with the reason')
c.drsPresent = false; data.recordAll()
equal(data.recordingGaps.totalNativeEmpty, gapsBefore + 1, 'a remote car reporting no DRS is not a gap')
c.drsPresent, c.isConnected = true, false; data.recordAll()
equal(data.recordingGaps.totalNativeEmpty, gapsBefore + 1, 'nor is a generic car that cannot be read at all')
c.isConnected = true
c.physicsAvailable, c.drsPresent = true, true; data.recordAll()
equal(data.VRS.f26n1owner[0], 0xA001, 'physics back, record back')
ids[0] = ''; data.recordAll()
equal(data.VRS.f26n1owner[0], 0, 'a car without an ID is never recorded')
equal(data.recordingGaps.totalNativeEmpty, gapsBefore + 1, 'nor counted as a gap')
ids[0] = OTHER
D.validation.vanillaSM, D.validation.vanillaRecovery, D.validation.vanillaDeploy = false, false, false

-- Pro: exact bus scope, complete old round-trip and partial validity.
c = car(0, PRO)
local function channel(name, value) channels[0][canInputs[name][1]] = value end
channel('kersChargeESOC', 5.6); channel('rearMotorPowerKW', 150); channel('kersDeployMJ', 2.5)
channel('kersRegenMJ', 1); channel('kersRegenLimitMJ', 8.5); channel('mgukMaxPower', 350)
channel('deploymentSplit', 2); channel('puMode', 1); channel('drsLatch', 3)
channel('isHybridBoostActive', 1); channel('isEngineRunning', 1)
data.readLive(S, 0)
equal(S.full, true, 'Pro CAN path'); equal(S.kw, 150, 'Pro power'); equal(S.boost, true, 'Pro button')
equal(S.valid.charge, true, 'Pro CAN false is valid'); equal(S.charge, false, 'Pro CAN false retained')
equal(loads[#loads], PRO .. '_CAN', 'only exact Pro bus key')
equal(data.recordAll(), 1, 'complete Pro record'); equal(data.recordedPro, 1, 'Pro count')
local proFrame = cloneStream(data.RS)
sim.isReplayActive = true; c.extraH, c.extraI = true, true; data.readReplay(S, 0)
equal(S.kw, 150, 'old Pro power round-trip'); equal(S.deploy, 2.5, 'old Pro deploy round-trip')
equal(S.regenLimit, 8.5, 'old Pro regen limit'); equal(S.cap, 350, 'old Pro cap')
equal(S.strat, 1, 'old Pro strat'); equal(S.split, 2, 'old Pro split'); equal(S.puMode, 1, 'old Pro PU')
equal(S.latch, 3, 'old Pro latch'); equal(S.boost, true, 'old Pro boost')
equal(S.wingF, false, 'recorded false wins over native H'); equal(S.wingR, false, 'recorded false wins over native I')
-- Straight Mode engaged reports latch 4: it must record, and bits 6-7 plus bit 13 must carry it
-- without disturbing any other flag.
sim.isReplayActive = false; channel('drsLatch', 4); data.readLive(S, 0)
equal(S.latch, 4, 'engaged Straight Mode latch read')
equal(data.recordAll(), 1, 'an engaged latch still records the frame')
equal(data.recordingGaps.totalProEmpty, 0, 'and is not counted as a skipped frame')
local engagedFlags = data.RS.f26flags[0]
equal(math.floor(engagedFlags / 8192) % 2, 1, 'the third latch bit is bit 13')
equal(math.floor(engagedFlags / 64) % 4, 0, 'its low bits stay in 6-7')
equal(math.floor(engagedFlags / 256) % 2, math.floor(proFrame.f26flags[0] / 256) % 2, 'SM active bit untouched')
equal(engagedFlags % 64, proFrame.f26flags[0] % 64, 'the low flag bits are untouched')
sim.isReplayActive = true; data.readReplay(S, 0)
equal(S.latch, 4, 'engaged latch round-trip')
equal(math.floor(engagedFlags / 64) % 4, 0, 'a reader without bit 13 sees latch 0, never a wrong state')
for _, value in ipairs({ 0, 1, 2, 3, 5, 7 }) do
  sim.isReplayActive = false; channel('drsLatch', value); data.readLive(S, 0)
  equal(S.latch, value, 'latch ' .. value .. ' read')
  equal(data.recordAll(), 1, 'latch ' .. value .. ' records')
  sim.isReplayActive = true; data.readReplay(S, 0)
  equal(S.latch, value, 'latch ' .. value .. ' round-trip')
end
sim.isReplayActive = false; channel('drsLatch', 8); data.readLive(S, 0)
equal(S.valid.latch, false, 'a latch outside 0-7 is still rejected')
equal(data.recordAll(), 0, 'and the frame is skipped')
equal(data.recordingGaps.lastProReason, 'latch', 'the skipped frame names the field that caused it')
equal(data.recordingGaps.lastProIndex, 0, 'and the car it happened on')
equal(data.recordingGaps.totalProEmpty, 1, 'skipped Pro frames are counted')
channel('drsLatch', 3); data.readLive(S, 0); data.recordAll()
sim.isReplayActive = true; restore(data.RS, proFrame)
data.RS.f26flags[0] = 0; data.readReplay(S, 0)
equal(S.full, false, 'unrecorded Pro not full'); equal(S.soc, nil, 'unrecorded Pro no battery')
equal(S.wingF, true, 'old Pro native H fallback'); equal(S.wingR, true, 'old Pro native I fallback')
restore(data.RS, proFrame); ids[0] = FA25; data.readReplay(S, 0)
equal(S.full, false, 'FA25 rejects old Pro stream'); equal(S.wingF, nil, 'FA25 rejects Pro H mapping')
sim.isReplayActive = false; ids[0] = PRO; channel('rearMotorPowerKW', nil); data.readLive(S, 0)
equal(S.kw, nil, 'missing Pro channel is not zero'); equal(S.valid.kw, false, 'missing channel invalid')
equal(S.boost, true, 'partial Pro fields remain usable'); equal(data.recordAll(), 0, 'old stream cannot encode partial truth')
equal(data.RS.f26flags[0], 0, 'partial Pro clears old slot')
equal(data.VRS.f26n1owner[0], 0, 'a partial Pro never falls back to a native slot')
c.physicsAvailable = false; local gapsPro = data.recordingGaps.totalNativeEmpty
equal(data.recordAll(), 0, 'nor does a Pro without physics')
equal(data.VRS.f26n1owner[0], 0, 'its native slot stays empty')
equal(data.recordingGaps.totalNativeEmpty, gapsPro, 'and a Pro is never a native gap')
c.physicsAvailable = true

-- State reset, shrinking grids, recording toggle and failures are independent of UI clearing.
sim.carsCount = 3; c = car(0, VAN); car(1, FA25).drsActive = true; car(2, 'another_drs_car')
equal(data.recordAll(), 3, 'mixed native grid')
equal(data.recordedVanilla, 1, 'one standard FA26'); equal(data.recordedDRS, 2, 'FA25 and the generic car')
equal(data.VRS.f26n1owner[1], 0xA502, 'FA25 keeps its family in slot 1')
equal(data.VRS.f26n1owner[2], 0xA003, 'the generic car takes its family in slot 2')
sim.carsCount = 1; frames[1], frames[2] = nil, nil; data.recordAll()
equal(data.VRS.f26n1owner[1], 0, 'departed slot cleared')
equal(data.VRS.f26n1owner[2], 0, 'departed generic slot cleared')
cfg.recordReplay = false; data.recordAll()
for _, r in ipairs({ data.RS, data.VRS }) do
  for _, array in pairs(r) do for _, value in pairs(array) do equal(value, 0, 'recording off clears every stored value') end end
end
cfg.recordReplay = true; sim.carsCount = 23; car(22, VAN); data.readLive(S, 22)
equal(S.kind, 'vanilla', 'slot 22 still displays live')
sim.isReplayActive = true; data.readReplay(S, 22); equal(S.soc, nil, 'slot 22 outside replay contract')
frames[0] = nil; check(not data.readReplay(S, 0), 'no car returns false'); equal(S.boost, nil, 'no car clears snapshot')
equal(S.valid.boost, false, 'no car validity cleared')
car(0, FA25).index = 1; check(not data.readLive(S, 0), 'index mismatch rejected')
car(0, FA25).isConnected = false; check(not data.readLive(S, 0), 'disconnected car rejected')
acStub.ReplayStream = function() error('stream unavailable') end
local failed = D.new(acStub, sim, cfg)
check(failed.RS == nil and failed.VRS == nil and failed.rsErr ~= nil and failed.vrsErr ~= nil, 'stream initialization failure contained')
sim.isReplayActive = false; car(0, VAN); check(failed.readLive(S, 0), 'live independent of replay initialization')

-- Observe every shared-buffer assignment, including writes between native API calls.
-- This catches placeholder zero publication which end-of-update round-trip tests miss.
local observeWrite, observeNativeRead
acStub.ReplayStream = function(layout)
  local result = {}
  for name, field in pairs(layout) do
    local key, backing = name, {}
    for i = 0, field.count - 1 do backing[i] = 0 end
    result[key] = setmetatable({}, {
      __index = backing,
      __newindex = function(_, index, value)
        backing[index] = value
        if observeWrite then observeWrite(result, key, index, value) end
      end,
    })
  end
  return result
end
acStub.getMGUKDeliveryName = function(_, p)
  if observeNativeRead then observeNativeRead() end
  return names[p + 1]
end
D.validation.vanillaSM, D.validation.vanillaRecovery, D.validation.vanillaDeploy = true, true, true
local observed = D.new(acStub, sim, cfg)
sim.carsCount = 2; c = car(0, VAN); car(1, FA25)
equal(observed.recordAll(), 2, 'prime observed native buffers')
equal(observed.VRS.f26n1owner[0], 0xA601, 'observed proxy stores initial native owner')
local watchedWrites, watchedReads = 0, 0
observeWrite = function(r, key, i)
  if r == observed.VRS and i == 0 then
    watchedWrites = watchedWrites + 1
    equal(r.f26n1owner[0], 0xA601, 'valid refresh never publishes empty native owner')
    equal(r.f26n1valid[0], 127, 'valid refresh never publishes placeholder invalid mask')
  end
end
observeNativeRead = function()
  watchedReads = watchedReads + 1
  equal(observed.VRS.f26n1owner[0], 0xA601, 'previous committed sample remains during API read')
  equal(observed.VRS.f26n1valid[0], 127, 'API read is not inside an invalidation window')
end
c.kersCharge, c.kersButtonPressed, c.mgukDelivery = 0.2, true, 3
equal(observed.recordAll(), 2, 'publish valid native update')
check(watchedWrites >= 5 and watchedReads > 0, 'observer actually sampled publication and native read')
equal(observed.VRS.f26n1soc[0], 50, 'new SoC published instead of holding old sample')
equal(observed.VRS.f26n1strategy[0], 3 + 15 * 16, 'new strategy and full deployment share published')
observeWrite, observeNativeRead = nil, nil

local sawFamilyRevocation = false
local function watchRevocation(r, key, i)
  if r == observed.VRS and i == 0 then
    if key == 'f26n1valid' and r.f26n1valid[0] == 0 then sawFamilyRevocation = true end
    if key == 'f26n1soc' then check(sawFamilyRevocation, 'old family validity revoked before new payload') end
  end
end
observeWrite = watchRevocation
car(0, FA25); observed.recordAll(); observeWrite = nil
check(sawFamilyRevocation, 'family switch performs explicit revocation')
equal(observed.VRS.f26n1owner[0], 0xA501, 'family switch publishes FA25 owner last')
sawFamilyRevocation, observeWrite = false, watchRevocation
car(0, 'another_drs_car'); observed.recordAll(); observeWrite = nil
check(sawFamilyRevocation, 'a switch to the generic family revokes the old validity first')
equal(observed.VRS.f26n1owner[0], 0xA001, 'and publishes the generic owner last')
sawFamilyRevocation, observeWrite = false, watchRevocation
c = car(0, VAN); observed.recordAll(); observeWrite = nil
check(sawFamilyRevocation, 'and back from the generic family too')
equal(observed.VRS.f26n1owner[0], 0xA601, 'standard FA26 owner restored')

-- A truly missing field must lose validity and payload immediately, without stale data.
c.kersCharge = nil; observed.recordAll()
equal(observed.VRS.f26n1valid[0] % 2, 0, 'missing SoC validity revoked')
equal(observed.VRS.f26n1soc[0], 0, 'invalid SoC payload cleared')
sim.isReplayActive = true; observed.readReplay(S, 0)
equal(S.soc, nil, 'no hold-last SoC on real missing field')
sim.isReplayActive = false; c.physicsAvailable = false
observed.recordAll()
equal(observed.VRS.f26n1owner[0], 0, 'actual native data loss clears slot')
equal(observed.recordingGaps.totalNativeEmpty, 1, 'actual data loss counted')
equal(observed.recordingGaps.lastNativeReason, 'physics unavailable', 'gap diagnosis')
c.physicsAvailable, c.kersCharge = true, 0.3; observed.recordAll()
sim.carsCount = 1; frames[1] = nil; observed.recordAll()
equal(observed.VRS.f26n1owner[1], 0, 'departed slot still cleared with publication fix')
cfg.recordReplay = false; observed.recordAll()
equal(observed.VRS.f26n1owner[0], 0, 'recording off still clears committed slot')
equal(observed.recordingGaps.totalNativeEmpty, 1, 'intentional recording-off is not a data failure')
sessions[#sessions]()
equal(observed.recordingGaps.totalNativeEmpty, 0, 'session resets recording gap count')
equal(observed.recordingGaps.lastNativeReason, 'none', 'session resets gap reason')

-- Pro valid-to-valid publication keeps its frozen recorded marker too.
cfg.recordReplay = true; c = car(0, PRO)
equal(observed.recordAll(), 1, 'prime observed Pro buffer')
observeWrite = function(r, _, i)
  if r == observed.RS and i == 0 then check(r.f26flags[0] >= 0x8000, 'valid Pro refresh never clears recorded marker') end
end
c.kersCharge = 0.8; observed.recordAll()
observeWrite = nil
local proClearStarted = false
observeWrite = function(r, key, i)
  if r == observed.RS and i == 0 then
    if not proClearStarted then equal(key, 'f26flags', 'Pro invalidation revokes flags before numeric payload'); proClearStarted = true end
    equal(r.f26flags[0], 0, 'Pro invalid payload is never advertised as recorded')
  end
end
channel('rearMotorPowerKW', nil); observed.recordAll(); observeWrite = nil
equal(observed.RS.f26flags[0], 0, 'real partial Pro snapshot still clears old stream slot')

-- Native hybrids (RSS FHX 2026, SP Mod 2026): exact-ID profiles over the standard FA26's native fields.
local RSS, SF = 'rss_formula_hybrid_x_2026', 'f1_2026_sf26'
local SP_IDS = { 'f1_2026_amr26', 'f1_2026_mac26', 'f1_2026_mcl40', 'f1_2026_r26', 'f1_2026_rb22', 'f1_2026_sf26',
  'f1_2026_w17' }
local RSS_MAPS = { 'No deploy', 'Low', 'Balanced', 'High', 'Qualy', 'Override' }
local SP_MAPS = { 'Charging', 'Balanced low', 'Balanced high', 'Linear', 'Overtake', 'Top Speed', 'Hotlap' }
check(D.validation.hybridAero and D.validation.hybridRecovery and D.validation.hybridDeploy
  and D.validation.hybridLapEnergy, 'hybrid evidence gates open for the in-game check')
-- Exercise the missing-evidence branch first; later scenarios open the gates again.
D.validation.hybridAero, D.validation.hybridRecovery, D.validation.hybridDeploy, D.validation.hybridLapEnergy = false, false, false, false
equal(data.classify(RSS), 'hybrid', 'RSS FHX 2026 is a native hybrid')
for _, id in ipairs(SP_IDS) do equal(data.classify(id), 'hybrid', 'SP Mod car is a native hybrid: ' .. id) end
for _, id in ipairs({ 'rss_formula_hybrid_x', 'rss_formula_hybrid_x_evo', 'rss_formula_hybrid_2021', 'f1_2026_w18',
  'f1_2026_sf26_v2', 'F1_2026_SF26', 'rss_formula_hybrid_x_2026 ', '' }) do
  equal(data.classify(id), 'drs', 'only exact profile IDs are hybrids: ' .. id)
end
equal(D.HYBRIDS[RSS].aero, 'sm', 'RSS moves both wings'); equal(D.HYBRIDS[SF].aero, 'drs', 'SP Mod moves the rear flap')
for k, name in ipairs(RSS_MAPS) do equal(D.HYBRIDS[RSS].maps[k], name, 'RSS program ' .. k) end
for _, id in ipairs(SP_IDS) do
  for k, name in ipairs(SP_MAPS) do equal(D.HYBRIDS[id].maps[k], name, id .. ' program ' .. k) end
  equal(#D.HYBRIDS[id].maps, 7, id .. ' has seven programs')
end
equal(#D.HYBRIDS[RSS].maps, 6, 'RSS has six programs')

acStub.getMGUKDeliveryName = function(i, p)
  if observeNativeRead then observeNativeRead() end
  local profile = D.HYBRIDS[ids[i]]
  if profile then return profile.maps[p + 1] end
  return names[p + 1]
end
local function hybridCar(i, id)
  local h = car(i, id)
  h.mgukDeliveryCount, h.mgukDelivery = #D.HYBRIDS[id].maps, 2
  h.kersMaxKJ, h.kersCurrentKJ, h.kersInput, h.kersCharging = 9000, 3210.5, 0.285, false
  return h
end
cfg.recordReplay, sim.isReplayActive, sim.carsCount = true, false, 1
local H = D.new(acStub, sim, cfg)
-- H's buffers are the observing proxies above, whose values live behind __index: copy them slot by slot.
local function cloneSlots(r)
  local copy = {}
  for key, array in pairs(r) do copy[key] = {}; for i = 0, 21 do copy[key][i] = array[i] end end
  return copy
end
local loadsBefore = #loads
c = hybridCar(0, RSS)
check(H.readLive(S, 0), 'hybrid live read')
equal(S.kind, 'hybrid', 'hybrid layout'); equal(S.aero, 'sm', 'the profile names the aero mode')
equal(#loads, loadsBefore, 'a hybrid never connects the Pro bus'); equal(S.full, false, 'a hybrid is not a full Pro')
equal(S.soc, 0.4, 'hybrid battery'); equal(S.boost, false, 'hybrid manual button'); equal(S.valid.boost, true, 'a valid false button')
equal(S.strategyName, 'Balanced', 'RSS program name'); equal(S.strat, 3, 'program number is 1-based')
equal(S.deployInput, nil, 'closed deploy gate'); equal(S.recovering, nil, 'closed recovery gate')
equal(S.lapUsedKJ, nil, 'closed lap-energy gate'); equal(S.smActive, nil, 'closed aero gate')
equal(S.candidate.recovering, false, 'recovery candidate kept'); equal(S.candidate.kersPresent, true, 'KERS candidate kept')
equal(S.otActive, false, 'no Overtake Mode'); equal(S.supported.otActive, false, 'OT unsupported')
equal(S.valid.otActive, false, 'unsupported OT is not a recorded false')
equal(S.drsActive, false, 'native DRS read'); equal(S.valid.drsActive, true, 'native DRS valid')
equal(S.source, 'live: native hybrid', 'hybrid source'); equal(S.wingF, nil, 'a hybrid ignores extra switch H')
-- the standard FA26's gates never open a hybrid field
D.validation.vanillaSM, D.validation.vanillaRecovery, D.validation.vanillaDeploy = true, true, true
c.drsAvailable, c.drsActive, c.kersCharging = true, true, true
H.readLive(S, 0)
equal(S.smActive, nil, 'vanilla SM gate does not open hybrid SM'); equal(S.recovering, nil, 'nor recovery')
equal(S.deployInput, nil, 'nor deployment')
D.validation.vanillaSM, D.validation.vanillaRecovery, D.validation.vanillaDeploy = false, false, false
D.validation.hybridAero, D.validation.hybridRecovery, D.validation.hybridDeploy, D.validation.hybridLapEnergy = true, true, true, true
H.readLive(S, 0)
equal(S.smActive, true, 'both-wing DRS open = SM open'); equal(S.smAvailable, true, 'and available')
equal(S.recovering, true, 'hybrid recovery'); equal(S.deployInput, 0.285, 'hybrid deployment share')
equal(S.lapUsedKJ, 3210.5, 'energy deployed this lap'); equal(S.lapCapKJ, 9000, 'per-lap limit')
-- per-lap limit: only a real limit, and a real count
c.kersMaxKJ = 99999; H.readLive(S, 0)
equal(S.valid.lapCapKJ, false, 'a declared 99999 kJ is no limit'); equal(S.valid.lapUsedKJ, false, 'so no lap row')
c.kersMaxKJ = 0; H.readLive(S, 0); equal(S.valid.lapCapKJ, false, 'a zero limit is not a limit')
c.kersMaxKJ, c.kersCurrentKJ = 4000, -1; H.readLive(S, 0); equal(S.valid.lapUsedKJ, false, 'a negative count is rejected')
c.kersCurrentKJ = 0 / 0; H.readLive(S, 0); equal(S.valid.lapCapKJ, false, 'NaN count rejects the pair')
c.kersCurrentKJ = nil; H.readLive(S, 0); equal(S.lapUsedKJ, nil, 'a missing count is not zero')
c.kersCurrentKJ = 0; H.readLive(S, 0); equal(S.lapUsedKJ, 0, 'a real zero at the line'); equal(S.valid.lapUsedKJ, true, 'is valid')
c.kersCurrentKJ = 4100; H.readLive(S, 0); equal(S.lapUsedKJ, 4100, 'a count past the limit is kept as reported')
c.kersCurrentKJ, c.kersMaxKJ = 3210.5, 9000
-- delivery request: the car's own closed-throttle offset reads as no request, nothing else is reinterpreted
c.kersInput = -1e-12; H.readLive(S, 0); equal(S.deployInput, 0, 'float noise below zero is a zero request')
c.kersInput = -0.004; H.readLive(S, 0); equal(S.valid.deployInput, false, 'RSS tables never go negative: rejected')
c.kersInput = 1; H.readLive(S, 0); equal(S.deployInput, 1, 'a full request')
c.kersInput = 1.01; H.readLive(S, 0); equal(S.valid.deployInput, false, 'above one rejected')
c.kersInput = nil; H.readLive(S, 0); equal(S.deployInput, nil, 'a missing request is not zero')
c = hybridCar(0, SF)
c.kersInput = -0.004; H.readLive(S, 0)
equal(S.deployInput, 0, 'SP closed-throttle offset is no request'); equal(S.valid.deployInput, true, 'and a valid zero')
c.kersInput = -0.01; H.readLive(S, 0); equal(S.deployInput, 0, 'down to the profile floor')
c.kersInput = -0.02; H.readLive(S, 0); equal(S.valid.deployInput, false, 'below the floor rejected')
c.kersInput = 0.5; H.readLive(S, 0); equal(S.deployInput, 0.5, 'SP share')
-- rear-flap profile: DRS stays DRS, whatever the aero gate says
c.drsAvailable, c.drsActive = true, true; H.readLive(S, 0)
equal(S.aero, 'drs', 'SP aero'); equal(S.smActive, nil, 'a rear flap is never Straight Mode')
equal(S.valid.smAvailable, false, 'no SM availability either'); equal(S.drsActive, true, 'its DRS is read')
equal(S.strategyName, 'Balanced high', 'SP program name at index 2')
c.mgukDelivery = 7; H.readLive(S, 0); equal(S.strategyName, nil, 'an index past the program count is rejected')
c.mgukDelivery, c.mgukDeliveryCount = 0, nil; H.readLive(S, 0); equal(S.strategyName, nil, 'no count, no program')
c.mgukDeliveryCount = 7
c.physicsAvailable = false; H.readLive(S, 0)
equal(S.soc, nil, 'remote hybrid: no battery'); equal(S.boost, nil, 'no borrowed button'); equal(S.lapUsedKJ, nil, 'no lap row')
equal(S.source, 'live: native hybrid, physics unavailable', 'the source says why')
c.physicsAvailable = true

-- Recording: the generic family, now with the energy fields.
c = hybridCar(0, RSS)
c.kersButtonPressed, c.kersCharging, c.drsAvailable, c.drsActive, c.mgukDelivery, c.kersInput = true, true, true, false, 5, 1
equal(H.recordAll(), 1, 'a hybrid is recorded'); equal(H.recordedHybrid, 1, 'and counted as a hybrid')
equal(H.recordedDRS, 0, 'not as a conventional car'); equal(H.recordedVanilla, 0, 'nor as a standard FA26')
equal(H.VRS.f26n1owner[0], 0xA001, 'a hybrid keeps the generic family')
equal(H.VRS.f26n1valid[0], 127, 'all seven native fields valid')
equal(H.VRS.f26n1state[0], 1 + 2 + 4 + 8, 'Boost, recovery, DRS present and available; closed')
equal(H.VRS.f26n1soc[0], 100, 'battery x 250')
equal(H.VRS.f26n1strategy[0], 5 + 15 * 16, 'program index and full share in one byte')
local hybridRecord = cloneSlots(H.VRS)
equal(hybridRecord.f26n1owner[0], 0xA001, 'the saved record really holds the slot')
sim.isReplayActive = true
c.kersCharge, c.kersButtonPressed, c.kersCharging, c.drsAvailable, c.mgukDelivery = 0.9, false, false, false, 0
H.readReplay(S, 0)
equal(S.kind, 'hybrid', 'hybrid replay layout'); equal(S.soc, 0.4, 'recorded battery outranks playback')
equal(S.boost, true, 'recorded button'); equal(S.recovering, true, 'recorded recovery')
equal(S.strategyName, 'Override', 'recorded index named from the profile'); equal(S.strat, 6, 'program number')
equal(S.deployInput, 1, 'recorded share'); equal(S.drsAvailable, true, 'recorded availability'); equal(S.drsActive, false, 'recorded closed')
equal(S.smAvailable, true, 'SM from the record'); equal(S.smActive, false, 'a recorded closed wing')
equal(S.lapUsedKJ, nil, 'the lap row is live only'); equal(S.supported.soc, true, 'battery supported in replay')
equal(S.source, 'replay: native app stream, car 0', 'hybrid replay source')
D.validation.hybridAero, D.validation.hybridRecovery, D.validation.hybridDeploy = false, false, false
H.readReplay(S, 0)
equal(S.smActive, nil, 'closed aero gate in replay'); equal(S.recovering, nil, 'closed recovery gate in replay')
equal(S.deployInput, nil, 'closed deploy gate in replay'); equal(S.strategyName, 'Override', 'the program is not gated')
equal(S.soc, 0.4, 'nor the battery')
D.validation.hybridAero, D.validation.hybridRecovery, D.validation.hybridDeploy = true, true, true
-- What a 0.9.39 reader sees: its generic-car path takes only the DRS subset of the same slot.
ids[0] = 'another_drs_car'; H.readReplay(S, 0)
equal(S.kind, 'drs', 'a conventional reader of the slot'); equal(S.drsAvailable, true, 'still gets the DRS')
equal(S.soc, nil, 'but never a battery'); equal(S.boost, nil, 'nor a button'); equal(S.recovering, nil, 'nor recovery')
equal(S.strategyName, nil, 'nor a program'); equal(S.deployInput, nil, 'nor a share')
ids[0] = VAN; H.readReplay(S, 0); equal(S.soc, nil, 'a standard FA26 never reads a generic slot')
ids[0] = SF; H.readReplay(S, 0)
equal(S.strategyName, 'Top Speed', 'the same index names the SP profile program')
H.VRS.f26n1strategy[0] = 9 + 15 * 16; H.readReplay(S, 0)
equal(S.strategyName, nil, 'an index past the SP programs is rejected'); equal(S.deployInput, 1, 'the share survives')
ids[0] = RSS; H.VRS.f26n1strategy[0] = 6 + 3 * 16; H.readReplay(S, 0)
equal(S.strategyName, nil, 'RSS has no seventh program'); equal(S.deployInput, 2 / 14, 'the share still reads')
restore(H.VRS, hybridRecord); H.VRS.f26n1owner[0] = 0xA002; H.readReplay(S, 0)
equal(S.soc, nil, 'a hybrid record for another slot is rejected')
equal(S.source, 'replay: native hybrid history unavailable', 'and the source says so')
restore(H.VRS, hybridRecord); H.VRS.f26n1owner[0] = 0; H.readReplay(S, 0)
equal(S.drsActive, nil, 'an unrecorded frame stays unknown'); equal(S.soc, nil, 'battery unknown')
restore(H.VRS, hybridRecord); H.VRS.f26n1valid[0] = 16 + 32 + 64; H.readReplay(S, 0)
equal(S.drsAvailable, true, 'a DRS-only hybrid record (0.9.39 writer) still reads its DRS')
equal(S.soc, nil, 'and leaves the battery unknown'); equal(S.strategyName, nil, 'and the program')
sim.isReplayActive = false
-- A program name the profile does not know shows live but is never recorded.
acStub.getMGUKDeliveryName = function(i, p) return (p == 5 and 'Override*') or D.HYBRIDS[RSS].maps[p + 1] end
c = hybridCar(0, RSS); c.mgukDelivery = 5
H.readLive(S, 0); equal(S.strategyName, 'Override*', 'a renamed program still displays live')
H.recordAll(); equal(H.VRS.f26n1valid[0] % 8 >= 4, false, 'but is not recorded under the profile contract')
acStub.getMGUKDeliveryName = function(i, p)
  local profile = D.HYBRIDS[ids[i]]
  if profile then return profile.maps[p + 1] end
  return names[p + 1]
end
-- A hybrid without a DRS component still records its energy system; physics loss is a counted gap.
c = hybridCar(0, SF); c.drsPresent = false
local hybridGaps = H.recordingGaps.totalNativeEmpty
equal(H.recordAll(), 1, 'a hybrid without DRS is recorded')
equal(H.VRS.f26n1valid[0] % 16, 15, 'battery, button, program and recovery')
equal(math.floor(H.VRS.f26n1state[0] / 4) % 8, 0, 'no DRS state bits')
c.physicsAvailable = false
equal(H.recordAll(), 0, 'no physics, no record')
equal(H.recordingGaps.totalNativeEmpty, hybridGaps + 1, 'a hybrid without physics is a counted gap')
equal(H.recordingGaps.lastNativeReason, 'physics unavailable', 'with the reason')
c.kersPresent, c.drsPresent = false, false
H.readLive(S, 0); equal(S.candidate.kersPresent, false, 'candidate reflects the missing KERS')
H.recordAll(); equal(H.recordingGaps.totalNativeEmpty, hybridGaps + 1, 'a hybrid reporting neither system is not a gap')
-- Mixed grid counting.
sim.carsCount = 5
car(0, VAN); hybridCar(1, RSS); hybridCar(2, SF); car(3, FA25); car(4, 'another_drs_car')
equal(H.recordAll(), 5, 'mixed grid with hybrids')
equal(H.recordedVanilla, 1, 'one standard FA26'); equal(H.recordedHybrid, 2, 'two hybrids'); equal(H.recordedDRS, 2, 'FA25 and a generic car')
equal(H.VRS.f26n1owner[1], 0xA002, 'RSS in slot 1'); equal(H.VRS.f26n1owner[2], 0xA003, 'SP in slot 2')
equal(H.VRS.f26n1valid[4], 16 + 32 + 64, 'the conventional generic car still records only DRS')
sim.carsCount = 1; for k = 1, 4 do frames[k] = nil end; H.recordAll()

-- Family switches through the shared generic owner: a hybrid handing its slot to a conventional car
-- revokes the energy fields before their payload is cleared; the other way round needs no revocation.
local HO = D.new(acStub, sim, cfg)
c = hybridCar(0, RSS)
equal(HO.recordAll(), 1, 'prime the observed hybrid slot')
local sawHybridRevocation = false
observeWrite = function(r, key, i)
  if r == HO.VRS and i == 0 then
    if key == 'f26n1valid' and r.f26n1valid[0] == 16 + 32 + 64 then sawHybridRevocation = true end
    if key == 'f26n1soc' then check(sawHybridRevocation, 'energy validity revoked before the battery payload') end
  end
end
car(0, 'another_drs_car'); HO.recordAll(); observeWrite = nil
check(sawHybridRevocation, 'hybrid to conventional revokes first')
equal(HO.VRS.f26n1valid[0], 16 + 32 + 64, 'the conventional car keeps only DRS'); equal(HO.VRS.f26n1soc[0], 0, 'battery payload cleared')
observeWrite = function(r, key, i)
  if r == HO.VRS and i == 0 then
    check(r.f26n1owner[0] == 0xA001, 'conventional to hybrid never publishes an empty owner')
    local v = r.f26n1valid[0]
    check(v == 16 + 32 + 64 or v == 127, 'and only ever shows the old DRS subset or the new full mask')
  end
end
c = hybridCar(0, SF); HO.recordAll(); observeWrite = nil
equal(HO.VRS.f26n1valid[0], 127, 'the hybrid adds its energy fields')
D.validation.hybridAero, D.validation.hybridRecovery, D.validation.hybridDeploy, D.validation.hybridLapEnergy = true, true, true, true
local result = 'PASS: hud_data (' .. checks .. ' checks; synthetic adapter/replay contracts, not in-game validation)'
print(result)
return result
