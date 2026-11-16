--[[
    Follows a list of points by steering: each update returns the direction to run in, or
    tells the caller to stop.

    - A point counts as reached within `tolerance` yalms, or once the player has passed it
      (it lies behind the player along the segment that leads to it).
    - "off route": more than `off_route` yalms from the current segment.
    - "stuck": no way forward was found (see obstacle avoidance below), or, with avoidance
      off, moved less than `stuck_distance` yalms in `stuck_seconds`.

    Obstacle avoidance (`avoid`, on by default). There is no collision data, so obstacles are
    found by their effect: moving less than `blocked_distance` in `blocked_seconds` while
    running. Then:
      1. probe: try headings turned 45, 90 and 135 degrees off the direct line, alternating
         sides, each for `blocked_seconds`, until one makes progress;
      2. retry: try the direct line again;
      3. slide: if it's still blocked, keep the working heading for `commit_seconds` and
         retry again. Together these slide along the obstacle's edge until the way is clear.
    Straying more than `avoid_radius` yalms from the route switches to the other side once.
    It gives up ("stuck") when every heading is blocked, when both sides run out of room, or
    after `avoid_max` seconds of avoiding on one leg.

    No Windower dependencies (tests/run.lua drives it with simulated movement).
]]

local navigator = {}
navigator.__index = navigator

local sqrt, rad, cos, sin = math.sqrt, math.rad, math.cos, math.sin

local defaults = {
    tolerance = 1.5,
    final_tolerance = 1.0,
    stuck_seconds = 3.0,
    stuck_distance = 1.0,
    off_route = 12.0,
    avoid = true,
    blocked_seconds = 0.6,
    blocked_distance = 0.6,
    commit_seconds = 0.6,
    avoid_max = 12.0,
    avoid_radius = 8.0,
}

local PROBE_ANGLES = {45, 90, 135}

-- `points` is a list of {x, y, z} tables; `start` is the player's position. `ids` (optional)
-- are the graph node ids of the points, so a problem can be tied to an edge.
function navigator.new(points, start, opts, ids)
    opts = opts or {}
    local self = setmetatable({points = points, ids = ids or {}, index = 1,
        origin = {x = start.x, y = start.y}, side = 1}, navigator)
    for k, v in pairs(defaults) do
        if opts[k] ~= nil then self[k] = opts[k] else self[k] = v end
    end
    self:reset_window()
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

local function dist(a, b)
    local dx, dy = a.x - b.x, a.y - b.y
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

function navigator:is_avoiding()
    return self.avoiding ~= nil
end

-- Signed probe offsets in degrees, starting on `side` (1 or -1) and alternating.
local function offsets(side)
    local out = {}
    for _, a in ipairs(PROBE_ANGLES) do
        out[#out + 1] = a * side
        out[#out + 1] = -a * side
    end
    return out
end

-- Avoidance state machine. Called once per `blocked_seconds` window with whether the
-- player made progress in it and the direct heading (bx, by). Returns "blocked" when
-- avoidance starts, "stuck" when it gives up, or nil.
--
-- Probe and slide headings are measured from the heading at the moment of the block, not
-- recomputed toward the target: as the player moves along the obstacle the direction to
-- the target turns back into it, and a recomputed 90-degree heading would keep pressing in.
function navigator:_avoid_step(moved, now, bx, by)
    local av = self.avoiding
    if not av then
        if moved then return nil end
        self.avoiding = {list = offsets(self.side), i = 1, mode = 'probe', bx = bx, by = by}
        return 'blocked'
    end
    if av.mode == 'probe' then
        if moved then
            -- The probe window was itself a slide; try the direct line next.
            av.mode = 'retry'
            self.side = av.list[av.i] > 0 and 1 or -1       -- remember the side that worked
        else
            av.i = av.i + 1
            if av.i > #av.list then
                return 'stuck'
            end
        end
    elseif av.mode == 'slide' then
        if not moved then
            av.mode, av.i = 'probe', av.i + 1
            if av.i > #av.list then return 'stuck' end
        elseif now >= av.until_t then
            av.mode = 'retry'
        end
    elseif av.mode == 'retry' then
        if moved then
            self.avoiding = nil                              -- direct line is clear again
            self.avoid_spent = 0
        else
            av.mode, av.until_t = 'slide', now + self.commit_seconds
        end
    end
    return nil
end

-- Stops avoiding (e.g. after opening a door) and restarts every progress window.
function navigator:clear_avoid()
    self.avoiding = nil
    self.avoid_spent = 0
    self:reset_window()
end

-- Returns one of:
--   {run = true, dx = , dy = , distance = , avoiding = bool, event = "blocked"|nil}
--       keep running in (dx, dy), a unit vector; event "blocked" when avoidance starts
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
            self.avoiding, self.avoid_spent = nil, 0
        else
            break
        end
    end

    local target = pts[self.index]
    local off = segment_distance(pos, self:_segment_start(), target)
    if self.avoiding and off > self.avoid_radius then
        -- Out of room on this side: try the other side once, then give up.
        local av = self.avoiding
        if av.flipped then
            return {stop = true, reason = 'stuck'}
        end
        local side = av.list[av.i] > 0 and -1 or 1
        av.list, av.i, av.mode, av.flipped = {90 * side, 45 * side, 135 * side}, 1, 'probe', true
        self.side = side
        self.probe_time, self.probe_pos = now, {x = pos.x, y = pos.y}
    end
    if off > self.off_route then
        return {stop = true, reason = 'off route'}
    end

    local dt = self.last_now and (now - self.last_now) or 0
    self.last_now = now
    if self.avoiding then
        self.avoid_spent = (self.avoid_spent or 0) + dt
        if self.avoid_spent > self.avoid_max then
            return {stop = true, reason = 'stuck'}
        end
    end

    local event
    if self.avoid then
        -- Short progress window drives avoidance.
        if not self.probe_time then
            self.probe_time, self.probe_pos = now, {x = pos.x, y = pos.y}
        elseif now - self.probe_time >= self.blocked_seconds then
            local moved = dist(pos, self.probe_pos) >= self.blocked_distance
            self.probe_time, self.probe_pos = now, {x = pos.x, y = pos.y}
            local tx, ty = target.x - pos.x, target.y - pos.y
            local tl = sqrt(tx * tx + ty * ty)
            local r = self:_avoid_step(moved, now, tl > 0 and tx / tl or 1, tl > 0 and ty / tl or 0)
            if r == 'stuck' then
                return {stop = true, reason = 'stuck'}
            end
            event = r
        end
    else
        -- Plain stuck check over a longer window.
        if not self.window_time then
            self.window_time, self.window_pos = now, {x = pos.x, y = pos.y}
        elseif now - self.window_time >= self.stuck_seconds then
            if dist(pos, self.window_pos) < self.stuck_distance then
                return {stop = true, reason = 'stuck'}
            end
            self.window_time, self.window_pos = now, {x = pos.x, y = pos.y}
        end
    end

    local dx, dy = target.x - pos.x, target.y - pos.y
    local d = sqrt(dx * dx + dy * dy)
    if d == 0 then
        return {run = true, dx = 0, dy = 0, distance = 0}
    end
    dx, dy = dx / d, dy / d
    local av = self.avoiding
    if av and av.mode ~= 'retry' then
        local a = rad(av.list[av.i])
        local c, s = cos(a), sin(a)
        dx, dy = av.bx * c - av.by * s, av.bx * s + av.by * c
    end
    return {run = true, dx = dx, dy = dy, distance = d, avoiding = av ~= nil, event = event}
end

-- Restarts the progress windows (call after a pause, e.g. a cutscene or a door).
function navigator:reset_window()
    self.window_time, self.window_pos = nil, nil
    self.probe_time, self.probe_pos = nil, nil
    self.last_now = nil
end

return navigator
