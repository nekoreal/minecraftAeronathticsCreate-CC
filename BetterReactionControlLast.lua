-- ============================================
-- QUADCOPTER CONTROL SYSTEM v7.0 (GUI Edition)
-- ============================================

local SETTINGS = {
    monitorName = "monitor_1",
    relayStab = "redstone_relay_5",
    relayStabFine = "redstone_relay_4",
    relayAltitude = "redstone_relay_6",
    
    motors = {
        front_left = "Create_RotationSpeedController_7",
        front_right = "Create_RotationSpeedController_5",
        back_left = "Create_RotationSpeedController_6",
        back_right = "Create_RotationSpeedController_4"
    },
    
    stab_kp = 0.08,
    stab_kd = 0.2,
    
    alt_kp = 0.03,
    alt_ki = 0.002,
    alt_kd = 0.09,
    
    powerCurve = {
        minVal = 0.43,
        maxVal = 0.88 
    },
    
    maxStabCorr = 0.35,
    maxAltCorr = 0.25,
}

local targetAlt = 50
local altStep = 5
local running = true
local motors = {}
local periphs = {}

local lastErrors = { pitch = 0, roll = 0, alt = 0 }
local integralAlt = 0
local lastTime = os.clock()

-- Инициализация
function init()
    term.clear()
    periphs.mon = peripheral.wrap(SETTINGS.monitorName)
    if not periphs.mon then error("Монитор " .. SETTINGS.monitorName .. " не найден!") end
    periphs.mon.setTextScale(1)
    
    periphs.rStab = peripheral.wrap(SETTINGS.relayStab)
    periphs.rStabFine = peripheral.wrap(SETTINGS.relayStabFine)
    periphs.rAlt = peripheral.wrap(SETTINGS.relayAltitude)
    
    for name, id in pairs(SETTINGS.motors) do
        local m = peripheral.wrap(id)
        if m then motors[name] = m end
    end
end

-- Расчет высоты
function getAbsAltitude()
    local r = periphs.rAlt
    local b = r.getAnalogInput("back")
    local l = r.getAnalogInput("left")
    local f = r.getAnalogInput("front")
    local ri = r.getAnalogInput("right")
    
    if ri > 0 then return 264 + (ri / 15) * 56
    elseif f > 0 then return 164 + (f / 15) * 100
    elseif l > 0 then return 64 + (l / 15) * 100
    elseif b > 0 then return -64 + (b / 15) * 128
    end
    return 0
end

-- Углы наклона
function getAngles()
    local rs, rf = periphs.rStab, periphs.rStabFine
    local p = (rs.getAnalogInput("front") - rs.getAnalogInput("back")) + 
              ((rf.getAnalogInput("front") - rf.getAnalogInput("back")) * 0.4)
    local r = (rs.getAnalogInput("left") - rs.getAnalogInput("right")) + 
              ((rf.getAnalogInput("left") - rf.getAnalogInput("right")) * 0.4)
    return p / 15, r / 15
end

-- Отрисовка интерфейса
function drawGUI(curY, p, r, throttle)
    local mon = periphs.mon
    mon.setBackgroundColor(colors.black)
    mon.clear()
    
    -- Заголовок
    mon.setCursorPos(1,1)
    mon.setTextColor(colors.yellow)
    mon.write("--- DRONE OS v7.0 ---")

    -- Данные
    mon.setTextColor(colors.white)
    mon.setCursorPos(1,3)
    mon.write(string.format("ALT: %5.1f / %-3d", curY, targetAlt))
    mon.setCursorPos(1,4)
    mon.write(string.format("P: %+.2f | R: %+.2f", p, r))
    mon.setCursorPos(1,5)
    mon.write(string.format("PWR: %d%% | STEP: %d", math.floor(throttle * 100), altStep))

    -- Кнопки Высоты
    mon.setCursorPos(1,7)
    mon.setBackgroundColor(colors.blue)
    mon.write(" [ ALT + ] ")
    mon.setCursorPos(13,7)
    mon.write(" [ ALT - ] ")

    -- Кнопки Шага
    mon.setCursorPos(1,9)
    mon.setBackgroundColor(colors.gray)
    mon.write(" [ STP + ] ")
    mon.setCursorPos(13,9)
    mon.write(" [ STP - ] ")
end

-- Основной цикл управления
function controlLoop()
    while running do
        local now = os.clock()
        local dt = math.max(now - lastTime, 0.01)
        lastTime = now
        
        local pErr, rErr = getAngles()
        local pCorr = (pErr * SETTINGS.stab_kp) + ((pErr - lastErrors.pitch) / dt * SETTINGS.stab_kd)
        local rCorr = (rErr * SETTINGS.stab_kp) + ((rErr - lastErrors.roll) / dt * SETTINGS.stab_kd)
        lastErrors.pitch, lastErrors.roll = pErr, rErr
        
        local currentY = getAbsAltitude()
        local altErr = targetAlt - currentY
        
        local heightRatio = math.max(0, math.min(1, targetAlt / 320))
        local baseThrottle = SETTINGS.powerCurve.minVal + (heightRatio * (SETTINGS.powerCurve.maxVal - SETTINGS.powerCurve.minVal))
        
        integralAlt = math.max(-0.1, math.min(0.1, integralAlt + (altErr * dt)))
        local dAlt = (altErr - lastErrors.alt) / dt
        local altCorr = (altErr * SETTINGS.alt_kp) + (integralAlt * SETTINGS.alt_ki) + (dAlt * SETTINGS.alt_kd)
        
        lastErrors.alt = altErr
        altCorr = math.max(-SETTINGS.maxAltCorr, math.min(SETTINGS.maxAltCorr, altCorr))
        
        local throttle = baseThrottle + altCorr
        
        local speeds = {
            fl = throttle + rCorr + pCorr,
            fr = throttle - rCorr + pCorr,
            bl = throttle + rCorr - pCorr,
            br = throttle - rCorr - pCorr
        }
        
        for name, key in pairs({front_left="fl", front_right="fr", back_left="bl", back_right="br"}) do
            if motors[name] then
                motors[name].setTargetSpeed(math.max(0, math.min(1, speeds[key])) * 256)
            end
        end
        
        if math.floor(now*2) % 2 == 0 then
            drawGUI(currentY, pErr, rErr, throttle)
        end
        
        sleep(0.05)
    end
end

-- Обработка нажатий на монитор
function touchLoop()
    while running do
        local _, side, x, y = os.pullEvent("monitor_touch")
        
        -- Логика кнопок (координаты зависят от размера монитора)
        if y == 7 then
            if x >= 1 and x <= 11 then targetAlt = targetAlt + altStep
            elseif x >= 13 and x <= 23 then targetAlt = targetAlt - altStep
            end
        elseif y == 9 then
            if x >= 1 and x <= 11 then altStep = math.min(50, altStep + 1)
            elseif x >= 13 and x <= 23 then altStep = math.max(1, altStep - 1)
            end
        end
    end
end

init()
parallel.waitForAny(controlLoop, touchLoop)