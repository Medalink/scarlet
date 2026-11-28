local _, ns = ...

local date, time, format, floor, max = date, time, string.format, math.floor, math.max

local MONTHS = { "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" }
local WEEKDAYS = { "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat" }
local JUST_NOW, MINUTE, HOUR, DAY, RELATIVE_DAYS = 10, 60, 3600, 86400, 7

local function Parts(t, utc)
    if type(t) ~= "number" or t ~= t or t <= 0 or t > 4e9 then return end
    return date(utc and "!*t" or "*t", t)
end

local function Count(n, unit)
    return format("%d %s%s", n, unit, n == 1 and "" or "s")
end

local function DaysApart(now, t)
    local a, b = Parts(now), Parts(t)
    if not a or not b then return 0 end
    local midA = now - (a.hour * HOUR + a.min * MINUTE + a.sec)
    local midB = t - (b.hour * HOUR + b.min * MINUTE + b.sec)
    return floor((midA - midB) / DAY + 0.5)
end

--- A day as "Nov 22", "Sat Nov 22" with weekday, and "Nov 22 2025" when it is not this year. utc reads a day key
--- stored as a UTC midnight, so it names the day the data was written for in any timezone.
function ns.Day(t, weekday, utc)
    local p = Parts(t, utc)
    if not p then return "" end
    local text = format("%s %d", MONTHS[p.month], p.day)
    if weekday then text = WEEKDAYS[p.wday] .. " " .. text end
    local this = Parts(time())
    if this and this.year ~= p.year then text = text .. " " .. p.year end
    return text
end

local function Hour12(hour)
    return hour % 12 == 0 and 12 or hour % 12, hour < 12 and "AM" or "PM"
end

--- The local clock as "8:19 PM", or "8:19:47 PM" with seconds.
function ns.Clock(t, seconds)
    local p = Parts(t)
    if not p then return "" end
    local hour, half = Hour12(p.hour)
    if seconds then return format("%d:%02d:%02d %s", hour, p.min, p.sec, half) end
    return format("%d:%02d %s", hour, p.min, half)
end

--- A chart axis label: "8 PM" on the hour, the clock for any other minute.
function ns.Hour(t)
    local p = Parts(t)
    if not p then return "" end
    if p.min ~= 0 then return ns.Clock(t) end
    local hour, half = Hour12(p.hour)
    return format("%d %s", hour, half)
end

--- A day and time: "8:19 PM" for today, "Nov 22 8:19 PM" for any other day.
function ns.DayTime(t)
    if not Parts(t) then return "" end
    if DaysApart(time(), t) == 0 then return ns.Clock(t) end
    return ns.Day(t) .. " " .. ns.Clock(t)
end

--- A moment as text that is worked out again at each call: "just now", "5 minutes ago", "3 hours ago", "yesterday",
--- "4 days ago", then the short day. A time ahead of now reads "in 5 minutes" the same way. now is optional.
function ns.Ago(t, now)
    if not Parts(t) then return "" end
    now = now or time()
    local s = now - t
    if s > -JUST_NOW and s < JUST_NOW then return "just now" end
    local ahead = s < 0
    if ahead then s = -s end
    local text
    if s < MINUTE then
        text = Count(floor(s), "second")
    elseif s < HOUR then
        text = Count(floor(s / MINUTE), "minute")
    elseif s < DAY then
        text = Count(floor(s / HOUR), "hour")
    else
        local days = ahead and -DaysApart(now, t) or DaysApart(now, t)
        if days >= RELATIVE_DAYS then return ns.Day(t) end
        if not ahead and days <= 1 then return "yesterday" end
        text = Count(max(days, 1), "day")
    end
    if ahead then return "in " .. text end
    return text .. " ago"
end

--- The full value for a tooltip: "Sat Nov 22 2025 8:19:47 PM". A UTC day has no clock and reads "Sat Nov 22 2025 UTC".
function ns.Exact(t, utc)
    local p = Parts(t, utc)
    if not p then return "" end
    local text = format("%s %s %d %d", WEEKDAYS[p.wday], MONTHS[p.month], p.day, p.year)
    if utc then return text .. " UTC" end
    return text .. " " .. ns.Clock(t, true)
end

--- Fills the game tooltip next to owner with the exact value of t. The caller hides it on leave.
function ns.ShowExact(owner, t, utc, anchor)
    if type(t) ~= "number" or t <= 0 then return end
    GameTooltip:SetOwner(owner, anchor or "ANCHOR_RIGHT")
    GameTooltip:AddLine(ns.Exact(t, utc), 1, 1, 1)
    GameTooltip:Show()
end
