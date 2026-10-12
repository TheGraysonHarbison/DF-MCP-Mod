-- Date, time of day, season, weather, pause state.
--@ module = true

TICKS_PER_DAY = 1200
DAYS_PER_MONTH = 28
MONTHS_PER_YEAR = 12

MONTH_NAMES = {
    'Granite', 'Slate', 'Felsite',
    'Hematite', 'Malachite', 'Galena',
    'Limestone', 'Sandstone', 'Timber',
    'Moonstone', 'Opal', 'Obsidian',
}

SEASON_NAMES = {'spring', 'summer', 'autumn', 'winter'}

local function safe(fn, ...)
    local ok, value = pcall(fn, ...)
    if ok then return value end
    return nil
end

local function fort_name()
    return safe(function()
        local site = dfhack.world.getCurrentSite()
        return site and dfhack.TranslateName(site.name, true) or nil
    end)
end

local function weather_name()
    local weather = safe(dfhack.maps.getCurrentWeather)
    if weather == nil then return nil end
    return df.weather_type[weather] or tostring(weather)
end

local function now(args)
    local year = df.global.cur_year
    local year_tick = df.global.cur_year_tick
    local month_index = math.floor(year_tick / (TICKS_PER_DAY * DAYS_PER_MONTH)) -- 0-11
    local day_of_year = math.floor(year_tick / TICKS_PER_DAY)                      -- 0-335
    local day = day_of_year % DAYS_PER_MONTH + 1                                   -- 1-28
    local day_tick = year_tick % TICKS_PER_DAY
    local minutes_of_day = math.floor(day_tick * 24 * 60 / TICKS_PER_DAY)
    local season_index = math.floor(month_index / 3)                              -- 0-3

    return {
        year = year,
        month = month_index + 1,
        month_name = MONTH_NAMES[month_index + 1],
        day = day,
        day_of_year = day_of_year + 1,
        season = SEASON_NAMES[season_index + 1],
        season_day = day_of_year - season_index * 3 * DAYS_PER_MONTH + 1,
        hour = math.floor(minutes_of_day / 60),
        minute = minutes_of_day % 60,
        year_tick = year_tick,
        frame = df.global.world.frame_counter,
        paused = dfhack.world.ReadPauseState(),
        weather = weather_name(),
        fort_name = fort_name(),
        unsaved_seconds = safe(dfhack.persistent.getUnsavedSeconds),
        date_string = ('%d-%02d-%02d %02d:%02d (%s %d, %d, %s)'):format(
            year, month_index + 1, day,
            math.floor(minutes_of_day / 60), minutes_of_day % 60,
            MONTH_NAMES[month_index + 1], day, year, SEASON_NAMES[season_index + 1]),
    }
end

function ops()
    return {
        ['time.now'] = {namespace = 'time', handler = now, needs_map = true},
    }
end
