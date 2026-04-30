-- ============================================
-- QUADCOPTER ABSOLUTE ALTITUDE STABILIZER v6.0
-- Координатное управление высотой (Feed-Forward)
-- ============================================

local SETTINGS = {
    relayStab = "redstone_relay_2",        -- Грубое реле (наклон 30+)
    relayStabFine = "redstone_relay_3",    -- Точное реле (наклон 10+)
    relayAltitude = "redstone_relay_1",    -- Реле высоты (координата Y)
    
    motors = {
        front_left = "Create_RotationSpeedController_3",
        front_right = "Create_RotationSpeedController_1",
        back_left = "Create_RotationSpeedController_2",
        back_right = "Create_RotationSpeedController_0"
    },
    
    -- Стабилизация наклона
    stab_kp = 0.08,
    stab_kd = 0.05,
    
    -- ПИД Высоты (Абсолютные координаты)
    alt_kp = 0.03,   -- Реакция на отклонение от координаты
    alt_ki = 0.002,  -- Устранение "проседания"
    alt_kd = 0.09,   -- Мощный тормоз для исключения раскачки
    
    -- График мощности от высоты (0-320 по реле)
    -- На высоте 320 воздух разрежен, ставим базу выше
    powerCurve = {
        minVal = 0.43, -- Базовый газ для висения на нижних слоях (Y ~ 0)
        maxVal = 0.88  -- Базовый газ для висения в небе (Y ~ 300)
    },
    
    maxStabCorr = 0.35,
    maxAltCorr = 0.25, -- Лимит "суеты" ПИД-а
}

local targetAlt = 50 -- ЦЕЛЬ: Координата 50 по реле
local running = true
local motors = {}
local periphs = {}

local lastErrors = { pitch = 0, roll = 0, alt = 0 }
local integralAlt = 0
local lastTime = os.clock()

function init()
    term.clear()
    term.setCursorPos(1,1)
    print(">>> СИСТЕМА УПРАВЛЕНИЯ ВЫСОТОЙ v6.0")
    
    periphs.rStab = peripheral.wrap(SETTINGS.relayStab)
    periphs.rStabFine = peripheral.wrap(SETTINGS.relayStabFine)
    periphs.rAlt = peripheral.wrap(SETTINGS.relayAltitude)
    
    for name, id in pairs(SETTINGS.motors) do
        local m = peripheral.wrap(id)
        if m then motors[name] = m end
    end
    
    if not (periphs.rStab and periphs.rAlt) then error("Ошибка: Реле не найдены!") end
    print(">>> Целевая координата Y: " .. targetAlt)
end

-- Получение координаты Y напрямую из сигналов реле
function getAbsAltitude()
    local r = periphs.rAlt
    local b, l, f, ri = r.getAnalogInput("back"), r.getAnalogInput("left"), r.getAnalogInput("front"), r.getAnalogInput("right")
    
    -- Склеиваем диапазоны реле в одну прямую линию координат
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

function controlLoop()
    while running do
        local now = os.clock()
        local dt = math.max(now - lastTime, 0.01)
        lastTime = now
        
        -- 1. СТАБИЛИЗАЦИЯ
        local pErr, rErr = getAngles()
        local pCorr = (pErr * SETTINGS.stab_kp) + ((pErr - lastErrors.pitch) / dt * SETTINGS.stab_kd)
        local rCorr = (rErr * SETTINGS.stab_kp) + ((rErr - lastErrors.roll) / dt * SETTINGS.stab_kd)
        lastErrors.pitch, lastErrors.roll = pErr, rErr
        
        -- 2. ВЫСОТА (АБСОЛЮТНАЯ)
        local currentY = getAbsAltitude()
        local altErr = targetAlt - currentY
        
        -- "Умная" база: чем выше цель, тем выше обороты заранее
        local heightRatio = math.max(0, math.min(1, targetAlt / 320))
        local baseThrottle = SETTINGS.powerCurve.minVal + (heightRatio * (SETTINGS.powerCurve.maxVal - SETTINGS.powerCurve.minVal))
        
        -- ПИД коррекция
        integralAlt = math.max(-0.1, math.min(0.1, integralAlt + (altErr * dt)))
        local dAlt = (altErr - lastErrors.alt) / dt
        local altCorr = (altErr * SETTINGS.alt_kp) + (integralAlt * SETTINGS.alt_ki) + (dAlt * SETTINGS.alt_kd)
        
        lastErrors.alt = altErr
        altCorr = math.max(-SETTINGS.maxAltCorr, math.min(SETTINGS.maxAltCorr, altCorr))
        
        -- 3. ИТОГОВЫЙ ГАЗ
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
        
        -- Вывод
        if math.floor(now*4) % 4 == 0 then
            term.setCursorPos(1, 8)
            print(string.format("Y-COORD: %3.1f / %d  ", currentY, targetAlt))
            print(string.format("BASE GAS: %.2f | CORR: %+.2f  ", baseThrottle, altCorr))
        end
        
        sleep(0.05)
    end
end

function inputLoop()
    while running do
        local _, key = os.pullEvent("key")
        if key == keys.up then targetAlt = targetAlt + 5
        elseif key == keys.down then targetAlt = math.max(-60, targetAlt - 5)
        elseif key == keys.x then 
            running = false
            for _, m in pairs(motors) do m.setTargetSpeed(0) end
            print("EMERGENCY OFF")
        end
    end
end

init()
parallel.waitForAny(controlLoop, inputLoop)