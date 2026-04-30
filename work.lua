-- ============================================
-- STABILIZATOR KVADROKOPTERA S REGULIROVKOY VYSOTY
-- Versiya 4.2 - IS PRAVLENY ZNAKI PITCH
-- ============================================

local SETTINGS = {
    relayStab = "redstone_relay_2",
    relayAltitude = "redstone_relay_1",
    
    motors = {
        front_left = "Create_RotationSpeedController_3",
        front_right = "Create_RotationSpeedController_1",
        back_left = "Create_RotationSpeedController_2",
        back_right = "Create_RotationSpeedController_0"
    },
    
    stab_kp = 0.05,
    stab_kd = 0.02,
    
    alt_kp = 0.02,
    alt_kd = 0.03,
    
    baseThrottle = 0.45,
    
    deadzone_stab = 0.5,
    deadzone_alt = 0.5,
    maxStabCorrection = 0.3,
    maxAltCorrection = 0.12,
}

local targetAltitude = 10
local running = true
local relayStab = nil
local relayAlt = nil
local motors = {}

local lastPitchError = 0
local lastRollError = 0
local lastAltError = 0
local lastTime = os.clock()

function getAltitudeFromRelay()
    if not relayAlt then return 0 end
    local back = relayAlt.getAnalogInput("back") or 0
    local left = relayAlt.getAnalogInput("left") or 0
    local front = relayAlt.getAnalogInput("front") or 0
    local right = relayAlt.getAnalogInput("right") or 0
    if back > 0 then return -64 + (back / 15) * 128
    elseif left > 0 then return 64 + (left / 15) * 100
    elseif front > 0 then return 164 + (front / 15) * 100
    elseif right > 0 then return 264 + (right / 15) * 56
    end
    return 0
end

function findDevices()
    print("Poisk ustroystv...")
    relayStab = peripheral.wrap(SETTINGS.relayStab)
    if not relayStab then
        local devices = peripheral.find("redstone_relay")
        if devices and #devices > 0 then
            relayStab = devices[1]
            print("Relay stab: " .. peripheral.getName(relayStab))
        else error("Relay stabilizacii ne nayden!") end
    end
    relayAlt = peripheral.wrap(SETTINGS.relayAltitude)
    if not relayAlt then
        local devices = peripheral.find("redstone_relay")
        if devices and #devices > 1 then
            relayAlt = devices[2]
            print("Relay alt: " .. peripheral.getName(relayAlt))
        else error("Relay vysoty ne nayden!") end
    end
    for name, id in pairs(SETTINGS.motors) do
        local motor = peripheral.wrap(id)
        if motor then motors[name] = motor; print("Motor: " .. name .. " OK") end
    end
    print("Gotovo! Naydeno motorov: " .. #motors)
end

function setMotor(name, throttle)
    local motor = motors[name]
    if not motor then return end
    throttle = math.max(0, math.min(1, throttle))
    motor.setTargetSpeed(throttle * 256)
end

function readStabilization()
    if not relayStab then return 0,0,0,0 end
    return relayStab.getAnalogInput("front") or 0,
           relayStab.getAnalogInput("back") or 0,
           relayStab.getAnalogInput("left") or 0,
           relayStab.getAnalogInput("right") or 0
end

function pidCalc(error, lastError, dt, kp, kd)
    if dt < 0.001 then dt = 0.001 end
    local p = kp * error
    local d = kd * (error - lastError) / dt
    return p + d, error
end

function handleKeyboard()
    local eventData = {os.pullEvent()}
    local event = eventData[1]
    if event == "key" then
        local key = eventData[2]
        if key == keys.up then targetAltitude = targetAltitude + 1; print(">> Target altitude: " .. targetAltitude .. " m")
        elseif key == keys.down then targetAltitude = math.max(0, targetAltitude - 1); print(">> Target altitude: " .. targetAltitude .. " m")
        elseif key == keys.home then targetAltitude = 5; print(">> Target altitude: 5 m")
        elseif key == keys.pageUp then targetAltitude = targetAltitude + 5; print(">> Target altitude: " .. targetAltitude .. " m")
        elseif key == keys.pageDown then targetAltitude = math.max(0, targetAltitude - 5); print(">> Target altitude: " .. targetAltitude .. " m")
        elseif key == keys.x then print(">> EMERGENCY STOP!"); running = false end
    end
end

function mainLoop()
    print("\n=======================================")
    print("   KVADROKOPTER STABILIZATOR v4.2")
    print("=======================================")
    print("Upravlenie: UP/DOWN +-1 m, PGUP/PGDN +-5 m, HOME=5 m, X - stop")
    print("Target altitude: " .. targetAltitude .. " m")
    print("Bazovyy gaz: " .. SETTINGS.baseThrottle)
    print("=======================================\n")
    
    local lastPrint = os.clock()
    local lastTime = os.clock()
    
    local function keyboardHandler()
        while running do handleKeyboard() end
    end
    
    local function stabilizerLoop()
        while running do
            local currentTime = os.clock()
            local dt = currentTime - lastTime
            if dt > 0.1 then dt = 0.1 end
            if dt < 0.001 then dt = 0.001 end
            
            local front, back, left, right = readStabilization()
            
            local pitchError = (front - back) / 15
            local rollError = (left - right) / 15
            
            if math.abs(pitchError) < SETTINGS.deadzone_stab / 15 then pitchError = 0 end
            if math.abs(rollError) < SETTINGS.deadzone_stab / 15 then rollError = 0 end
            
            local pitchCorr, _ = pidCalc(pitchError, lastPitchError, dt, SETTINGS.stab_kp, SETTINGS.stab_kd)
            local rollCorr, _ = pidCalc(rollError, lastRollError, dt, SETTINGS.stab_kp, SETTINGS.stab_kd)
            
            lastPitchError = math.abs(pitchCorr) > 0.001 and pitchError or 0
            lastRollError = math.abs(rollCorr) > 0.001 and rollError or 0
            
            pitchCorr = math.max(-SETTINGS.maxStabCorrection, math.min(SETTINGS.maxStabCorrection, pitchCorr))
            rollCorr = math.max(-SETTINGS.maxStabCorrection, math.min(SETTINGS.maxStabCorrection, rollCorr))
            
            local altitude = getAltitudeFromRelay()
            local altError = targetAltitude - altitude
            if math.abs(altError) < SETTINGS.deadzone_alt then altError = 0 end
            local altCorrection, _ = pidCalc(altError, lastAltError, dt, SETTINGS.alt_kp, SETTINGS.alt_kd)
            lastAltError = altError
            altCorrection = math.max(-SETTINGS.maxAltCorrection, math.min(SETTINGS.maxAltCorrection, altCorrection))
            
            local totalThrottle = SETTINGS.baseThrottle + altCorrection
            totalThrottle = math.max(0.1, math.min(0.9, totalThrottle))
            
            -- ** ISPRAVLENNAYa X-SHEMA **
            -- Pri naklone vpered (pitchError > 0) nado uvelichivat perednie motory
            local fl = totalThrottle + rollCorr + pitchCorr   -- peredniy levyy
            local fr = totalThrottle - rollCorr + pitchCorr   -- peredniy pravyy
            local bl = totalThrottle + rollCorr - pitchCorr   -- zadniy levyy
            local br = totalThrottle - rollCorr - pitchCorr   -- zadniy pravyy
            
            setMotor("front_left", fl)
            setMotor("front_right", fr)
            setMotor("back_left", bl)
            setMotor("back_right", br)
            
            if os.clock() - lastPrint >= 0.5 then
                local pitchDeg = (front - back)
                local rollDeg = (left - right)
                print(string.format(
                    "Alt: %3.0f / %3.0f m | CorrH: %+0.3f | Ang: P=%+3d° R=%+3d° | Gas: FL=%0.2f FR=%0.2f BL=%0.2f BR=%0.2f",
                    altitude, targetAltitude, altCorrection,
                    pitchDeg, rollDeg,
                    fl, fr, bl, br
                ))
                lastPrint = os.clock()
            end
            
            lastTime = currentTime
            sleep(0.05)
        end
    end
    
    parallel.waitForAny(keyboardHandler, stabilizerLoop)
    
    print("\n!!! EMERGENCY STOP !!!")
    setMotor("front_left", 0)
    setMotor("front_right", 0)
    setMotor("back_left", 0)
    setMotor("back_right", 0)
end

print("=======================================")
print("   ZAPUSK STABILIZATORA v4.2")
print("=======================================")

local ok, err = pcall(findDevices)
if not ok then
    print("\nERROR: " .. tostring(err))
    return
end

if #motors < 4 then
    print("\nPREDUPREZhDENIE: Naydeno tolko " .. #motors .. " motorov iz 4!")
end

mainLoop()