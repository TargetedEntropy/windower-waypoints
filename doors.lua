--[[
    Door detection: which nearby entities are doors, whether they're open, and which one is
    in the way of the segment being walked.

    Facts this relies on:
    - Doors are entities with spawn_type 34 (OpenSesame, Windower addon by Arcon).
    - Status 8 is "Door Opening" and 9 "Door Closing" (Windower/Resources statuses.lua). A door
      counts as open only while its status is 8.
    - Names starting with "_" and "Furniture" are skipped unless the door was recorded (opened
      by hand while recording), as OpenSesame skips them.

    No Windower dependencies; `mobs` is any table of mob tables (get_mob_array's shape).
]]

local doors = {}

doors.SPAWN_TYPE = 34
doors.STATUS_OPEN = 8

local sqrt = math.sqrt

function doors.is_door(mob, known)
    if not mob or mob.spawn_type ~= doors.SPAWN_TYPE or not mob.x then
        return false
    end
    if known and known[mob.id] then
        return true
    end
    local name = mob.name or ''
    return name ~= '' and name:byte() ~= 95 and name ~= 'Furniture'
end

function doors.is_open(mob)
    return mob.status == doors.STATUS_OPEN
end

local function seg_dist(p, a, b)
    local abx, aby = b.x - a.x, b.y - a.y
    local len2 = abx * abx + aby * aby
    local t = 0
    if len2 > 0 then
        t = ((p.x - a.x) * abx + (p.y - a.y) * aby) / len2
        if t < 0 then t = 0 elseif t > 1 then t = 1 end
    end
    local dx, dy = p.x - (a.x + t * abx), p.y - (a.y + t * aby)
    return sqrt(dx * dx + dy * dy)
end

-- The closest closed door within `reach` of `pos` that lies within `width` of the path
-- `pos -> ahead[1] -> ahead[2] ...` and on the same floor (height within `max_dz`).
-- Returns the mob table or nil.
function doors.blocking(mobs, pos, ahead, opts, known)
    local reach, width, max_dz = opts.reach or 6, opts.width or 3, opts.max_dz or 4
    local best, best_d
    for _, mob in pairs(mobs) do
        if type(mob) == 'table' and doors.is_door(mob, known) and not doors.is_open(mob)
            and math.abs((mob.z or pos.z) - pos.z) <= max_dz then
            local dx, dy = mob.x - pos.x, mob.y - pos.y
            local d = sqrt(dx * dx + dy * dy)
            if d <= reach and (not best_d or d < best_d) then
                local a, near = pos, false
                for _, b in ipairs(ahead) do
                    if seg_dist(mob, a, b) <= width then
                        near = true
                        break
                    end
                    a = b
                end
                if near then
                    best, best_d = mob, d
                end
            end
        end
    end
    return best
end

return doors
