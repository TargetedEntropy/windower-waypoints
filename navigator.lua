--[[
    Follows a list of points by steering: each update returns the direction to run in, or
    tells the caller to stop.

    - A point counts as reached within `tolerance` yalms, or once the player has passed it
      (it lies behind the player along the segment that leads to it).
    - "stuck": moved less than `stuck_distance` yalms in `stuck_seconds`.
    - "off route": more than `off_route` yalms from the current segment.

    No Windower dependencies (tests/run.lua drives it with simulated movement).
]]

local navigator = {}
navigator.__index = navigator

local sqrt = math.sqrt

local defaults = {
    tolerance = 1.5,
    final_tolerance = 1.0,
    stuck_seconds = 3.0,
    stuck_distance = 1.0,
    off_route = 12.0,
}

-- `points` is a list of {x, y, z} tables; `start` is the player's position. `ids` (optional)
-- are the graph node ids of the points, so a problem can be tied to an edge.
function navigator.new(points, start, opts, ids)
    opts = opts or {}
    local self = setmetatable({points = points, ids = ids or {}, index = 1,
        origin = {x = start.x, y = start.y}}, navigator)
    for k, v in pairs(defaults) do
        self[k] = opts[k] or v
    end
    self.window_time, self.window_pos = nil, nil
    return self
end

-- Distance from p to the segment a-b (2D).
local function segment_distance(p, a, b)
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

function navigator:_segment_start()
    return self.index > 1 and self.points[self.index - 1] or self.origin
end

-- The edge being walked as (from id, to id); from is nil while heading to the first point.
function navigator:current_edge()
    return self.ids[self.index - 1], self.ids[self.index]
end

-- Up to `n` points from the current target on.
function navigator:ahead(n)
    local out = {}
    for i = self.index, math.min(#self.points, self.index + n - 1) do
        out[#out + 1] = self.points[i]
    end
    return out
end

function navigator:remaining()
    return #self.points - self.index + 1
end

-- Returns one of:
--   {run = true, dx = , dy = , distance = }  keep running in (dx, dy), a unit vector
--   {done = true}                            arrived; stop
--   {stop = true, reason = "stuck" | "off route"}
function navigator:update(pos, now)
    local pts = self.points
    local last = #pts

    -- Advance past every point already reached or passed.
    while self.index <= last do
        local target = pts[self.index]
        local dx, dy = target.x - pos.x, target.y - pos.y
        local d = sqrt(dx * dx + dy * dy)
        if self.index == last then
            if d <= self.final_tolerance then
                return {done = true}
            end
            break
        end
        local a = self:_segment_start()
        local passed = d < 4 and ((target.x - a.x) * dx + (target.y - a.y) * dy) < 0
        if d <= self.tolerance or passed then
            self.index = self.index + 1
        else
            break
        end
    end

    local target = pts[self.index]
    if segment_distance(pos, self:_segment_start(), target) > self.off_route then
        return {stop = true, reason = 'off route'}
    end

    -- Stuck check over a sliding window.
    if not self.window_time then
        self.window_time, self.window_pos = now, {x = pos.x, y = pos.y}
    elseif now - self.window_time >= self.stuck_seconds then
        local mx, my = pos.x - self.window_pos.x, pos.y - self.window_pos.y
        if sqrt(mx * mx + my * my) < self.stuck_distance then
            return {stop = true, reason = 'stuck'}
        end
        self.window_time, self.window_pos = now, {x = pos.x, y = pos.y}
    end

    local dx, dy = target.x - pos.x, target.y - pos.y
    local d = sqrt(dx * dx + dy * dy)
    if d == 0 then
        return {run = true, dx = 0, dy = 0, distance = 0}
    end
    return {run = true, dx = dx / d, dy = dy / d, distance = d}
end

-- Restarts the stuck window (call after a pause, e.g. a cutscene or being engaged).
function navigator:reset_window()
    self.window_time, self.window_pos = nil, nil
end

return navigator
