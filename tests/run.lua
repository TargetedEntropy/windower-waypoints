--[[
    Offline tests. From the addon folder:  lua5.1 tests/run.lua
    Covers graph, recorder and navigator directly, then loads waypoints.lua against a fake
    `windower` and drives a record -> mark -> go -> save -> reload session.
]]

local root = arg[0]:match('^(.*)[/\\]tests[/\\]') or '.'
package.path = root .. '/?.lua;' .. package.path

local graph = require('graph')
local recorder = require('recorder')
local navigator = require('navigator')

local passed, failed = 0, 0
local function check(name, cond, detail)
    if cond then
        passed = passed + 1
    else
        failed = failed + 1
        print('FAIL ' .. name .. (detail and (': ' .. tostring(detail)) or ''))
    end
end

local function P(x, y, z) return {x = x, y = y, z = z or 0} end

-- graph ---------------------------------------------------------------------------------------

do
    -- A 5x5 grid with spacing 4, minus a wall at x == 2 for y in 0..3 (so the gap is y == 4).
    local g = graph.new(100)
    local id = {}
    for i = 0, 4 do
        id[i] = {}
        for j = 0, 4 do
            id[i][j] = g:add_node(i * 4, j * 4, 0)
        end
    end
    local wall = function(i, j) return i == 2 and j < 4 end
    for i = 0, 4 do
        for j = 0, 4 do
            if not wall(i, j) then
                if i < 4 and not wall(i + 1, j) then g:link(id[i][j], id[i + 1][j]) end
                if j < 4 and not wall(i, j + 1) then g:link(id[i][j], id[i][j + 1]) end
            end
        end
    end
    local path, len = g:find_path(id[0][0], id[4][0])
    check('astar finds a path around the wall', path ~= nil)
    check('astar path length', path and math.abs(len - 4 * 12) < 1e-6, len)
    check('astar path goes through the gap', path and (function()
        for _, p in ipairs(path) do if p == id[2][4] then return true end end
    end)())

    local isolated = g:add_node(100, 100, 0)
    check('astar unreachable returns nil', g:find_path(id[0][0], isolated) == nil)

    local n, d = g:nearest(P(4.5, 0.2), 2, 3)
    check('nearest finds the closest node', n == id[1][0], n)
    check('nearest distance', d and d < 0.6, d)
    check('nearest respects radius', g:nearest(P(50, 50), 2, 3) == nil)
    check('nearest respects height', g:nearest(P(4, 0, 10), 2, 3) == nil)

    g.marks['corner'] = id[4][4]
    local s = g:serialize()
    local t = setfenv(assert(loadstring(s)), {})()
    local g2 = graph.from_table(t, 100)
    check('roundtrip node count', g2.count == g.count, g2.count)
    check('roundtrip edge count', g2:edge_count() == g:edge_count(), g2:edge_count())
    check('roundtrip mark', g2.marks['corner'] == id[4][4])
    check('roundtrip next id', g2.next_id == g.next_id)
    local _, len2 = g2:find_path(id[0][0], id[4][0])
    check('roundtrip path length', len2 and math.abs(len2 - len) < 1e-6)

    g:remove_node(id[4][4])
    check('remove node drops its mark', g.marks['corner'] == nil)
end

-- recorder ------------------------------------------------------------------------------------

do
    -- Straight walk east 30 yalms in 0.5 steps: a node every ~3 yalms.
    local g = graph.new(1)
    local r = recorder.new(g)
    r:start(P(0, 0))
    for x = 0.5, 30, 0.5 do r:sample(P(x, 0)) end
    check('straight walk node count', g.count >= 10 and g.count <= 11, g.count)
    check('straight walk is a chain', g:edge_count() == g.count - 1, g:edge_count())

    -- Turn north: a corner node close to the turn.
    for y = 0.5, 6, 0.5 do r:sample(P(30, y)) end
    local corner = g:nearest(P(30, 1.5), 1.6, 3)
    check('corner dropped near the turn', corner ~= nil)

    -- A second walk south along x = 15 crosses the first route: it must join it.
    r = recorder.new(g)
    r:start(P(15, 12))
    for y = 11.5, -12, -0.5 do r:sample(P(15, y)) end
    local west = g:nearest(P(0, 0), 0.5, 3)
    local south_end = g:nearest(P(15, -12), 3.1, 3)
    check('crossing walk forms a junction', west and south_end and g:find_path(west, south_end) ~= nil)

    -- A warp breaks the chain.
    local before = g:edge_count()
    local r2 = recorder.new(g)
    r2:start(P(200, 200))
    local res = r2:sample(P(400, 400))
    check('jump reports a break', res == 'break', res)
    check('no edge across the jump', g:nearest(P(200, 200), 0.1, 3) and
        g:degree(g:nearest(P(200, 200), 0.1, 3)) == 0)
    check('jump added no edges', g:edge_count() == before)

    -- Undo removes the nodes it created.
    local g3 = graph.new(2)
    local r3 = recorder.new(g3)
    r3:start(P(0, 0))
    for x = 1, 9 do r3:sample(P(x, 0)) end
    local count = g3.count
    check('undo succeeds', r3:undo())
    check('undo removed a node', g3.count == count - 1, g3.count)
    while r3:undo() do end
    check('undo all empties the graph', g3.count == 0, g3.count)

    -- Different floor (height) is not merged.
    local g4 = graph.new(3)
    local r4 = recorder.new(g4)
    r4:start(P(0, 0, 0))
    for x = 1, 12 do r4:sample(P(x, 0, 0)) end
    local n_before = g4.count
    r4 = recorder.new(g4)
    r4:start(P(0, 0.5, 10))
    for x = 1, 12 do r4:sample(P(x, 0.5, 10)) end
    check('upper floor gets its own nodes', g4.count >= n_before * 2 - 1, g4.count)
end

-- navigator -----------------------------------------------------------------------------------

local function simulate(nav, pos, speed, steps, dt, block)
    local t = 0
    for _ = 1, steps do
        t = t + dt
        local step = nav:update(pos, t)
        if step.done or step.stop then return step, pos, t end
        local nx, ny = pos.x + step.dx * speed * dt, pos.y + step.dy * speed * dt
        if not (block and block(nx, ny)) then
            pos = P(nx, ny, pos.z)
        end
    end
    return nil, pos, t
end

do
    local pts = {P(0, 0), P(10, 0), P(10, 10), P(20, 10)}
    local nav = navigator.new(pts, P(-1, 0))
    local step, pos = simulate(nav, P(-1, 0), 5, 400, 0.1)
    check('navigator arrives', step and step.done, step and step.reason)
    check('navigator ends near the goal', graph.dist2d(pos, pts[4]) <= 1.0)

    -- A wall at x = 5 that the route ignores: the player stops making progress.
    nav = navigator.new({P(10, 0)}, P(0, 0))
    step = simulate(nav, P(0, 0), 5, 200, 0.1, function(x) return x > 5 end)
    check('navigator detects stuck', step and step.reason == 'stuck', step and (step.reason or 'done'))

    -- Pushed far from the route.
    nav = navigator.new({P(0, 0), P(10, 0)}, P(0, 0))
    step = nav:update(P(5, 30), 0)
    check('navigator detects off route', step.stop and step.reason == 'off route')

    -- Overshooting a point still advances (it's behind us).
    nav = navigator.new({P(10, 0), P(20, 0)}, P(0, 0))
    nav:update(P(12, 0.5), 0)
    check('navigator advances past an overshot point', nav.index == 2, nav.index)
end

-- obstacle avoidance -------------------------------------------------------------------------

local function in_box(x, y, b) return x > b[1] and x < b[3] and y > b[2] and y < b[4] end

do
    -- A 4x4 pillar on a straight route.
    local pillar = {8, -2, 12, 2}
    local blocked = function(x, y) return in_box(x, y, pillar) end
    local nav = navigator.new({P(20, 0)}, P(0, 0))
    local events, max_off = 0, 0
    local pos, t = P(0, 0), 0
    local step
    for _ = 1, 400 do
        t = t + 0.1
        step = nav:update(pos, t)
        if step.done or step.stop then break end
        if step.event == 'blocked' then events = events + 1 end
        local nx, ny = pos.x + step.dx * 0.5, pos.y + step.dy * 0.5
        if not blocked(nx, ny) then pos = P(nx, ny) end
        max_off = math.max(max_off, math.abs(pos.y))
    end
    check('avoid: gets around a pillar', step and step.done, step and (step.reason or 'running'))
    check('avoid: reported the obstacle once', events == 1, events)
    check('avoid: stays close to the route', max_off <= 8, max_off)
    check('avoid: never entered the pillar', not in_box(pos.x, pos.y, pillar))

    -- An L-shaped wall: blocked straight ahead and on one side; must find the other side.
    local wall = {8, 1, 9, 12}             -- vertical wall reaching north; open below y = 1
    local wall2 = {7, 11, 14, 12}          -- and a cap along the top
    blocked = function(x, y) return in_box(x, y, wall) or in_box(x, y, wall2) end
    nav = navigator.new({P(20, 5)}, P(0, 5))
    pos, t = P(0, 5), 0
    for _ = 1, 600 do
        t = t + 0.1
        step = nav:update(pos, t)
        if step.done or step.stop then break end
        local nx, ny = pos.x + step.dx * 0.5, pos.y + step.dy * 0.5
        if not blocked(nx, ny) then pos = P(nx, ny) end
    end
    check('avoid: finds the open side of a corner', step and step.done, step and (step.reason or 'running'))

    -- A wall with no way past within avoid_radius: gives up as stuck.
    nav = navigator.new({P(20, 0)}, P(0, 0))
    step = simulate(nav, P(0, 0), 5, 600, 0.1, function(x) return x > 10 end)
    check('avoid: endless wall ends as stuck', step and step.stop and step.reason == 'stuck',
        step and (step.reason or 'done'))

    -- Avoidance off: the plain 3-second stuck check.
    nav = navigator.new({P(20, 0)}, P(0, 0), {avoid = false})
    local s2, _, t2 = simulate(nav, P(0, 0), 5, 600, 0.1, function(x, y) return in_box(x, y, pillar) end)
    check('avoid off: pillar means stuck', s2 and s2.reason == 'stuck', s2 and (s2.reason or 'done'))
    check('avoid off: within two 3-second windows', t2 and t2 <= 6.5, t2)

    -- clear_avoid resets the state machine.
    nav = navigator.new({P(20, 0)}, P(0, 0))
    nav.avoiding = {list = {45}, i = 1, mode = 'probe'}
    nav:clear_avoid()
    check('avoid: clear_avoid stops avoiding', not nav:is_avoiding())
end

-- doors ---------------------------------------------------------------------------------------

do
    local doors = require('doors')
    local door = {id = 1, index = 10, name = 'Door', spawn_type = 34, status = 9, x = 5, y = 0, z = 0}
    local hidden = {id = 2, index = 11, name = '_6s1', spawn_type = 34, status = 9, x = 5, y = 0.5, z = 0}
    local npc = {id = 3, index = 12, name = 'Door', spawn_type = 2, status = 0, x = 5, y = 0, z = 0}
    check('door is a door', doors.is_door(door))
    check('hidden-name door skipped', not doors.is_door(hidden))
    check('hidden-name door allowed when recorded', doors.is_door(hidden, {[2] = 11}))
    check('npc is not a door', not doors.is_door(npc))
    local opts = {reach = 6, width = 3}
    check('closed door on the path is found', doors.blocking({door, npc}, P(0, 0), {P(10, 0)}, opts) == door)
    check('door off to the side is ignored', doors.blocking({door}, P(0, 10), {P(10, 10)}, opts) == nil)
    check('door out of reach is ignored', doors.blocking({door}, P(-10, 0), {P(10, 0)}, opts) == nil)
    door.status = 8
    check('open door is ignored', doors.blocking({door}, P(0, 0), {P(10, 0)}, opts) == nil)

    local g = graph.new(1)
    local a, b, c, d = g:add_node(0, 0, 0), g:add_node(10, 0, 0), g:add_node(0, 10, 0), g:add_node(10, 10, 0)
    g:link(a, b) g:link(a, c) g:link(c, d) g:link(d, b)
    local path = g:find_path(a, b, {[graph.edge_key(a, b)] = true})
    check('blocked edge is avoided', path and #path == 4, path and #path)
    check('everything blocked returns nil', g:find_path(a, b, {[graph.edge_key(a, b)] = true,
        [graph.edge_key(a, c)] = true}) == nil)
    g.doors[1234] = 56
    local g2 = graph.from_table(setfenv(assert(loadstring(g:serialize())), {})(), 1)
    check('doors survive a roundtrip', g2.doors[1234] == 56)
end

-- pulling: targets and the puller --------------------------------------------------------------

local targets = require('targets')
local puller = require('puller')

-- A U-shaped route: camp at (0, 0), east to (20, 0), north to (20, 20), west to (0, 20).
-- A wall runs between the two arms, so (2, 20) is 20 yalms from camp in a straight line but
-- 60 by the routes.
local function u_graph()
    local g = graph.new(100)
    local prev, ids = nil, {}
    local pts = {}
    for x = 0, 20, 4 do pts[#pts + 1] = P(x, 0) end
    for y = 4, 20, 4 do pts[#pts + 1] = P(20, y) end
    for x = 16, 0, -4 do pts[#pts + 1] = P(x, 20) end
    for i, p in ipairs(pts) do
        ids[i] = g:add_node(p.x, p.y, p.z)
        if prev then g:link(prev, ids[i]) end
        prev = ids[i]
    end
    g.marks.camp = ids[1]
    return g, ids
end

local function M(id, name, x, y, extra)
    local m = {id = id, index = id - 1000, name = name, x = x, y = y, z = 0, hpp = 100, spawn_type = 16,
               status = 0, claim_id = 0, valid_target = true}
    for k, v in pairs(extra or {}) do m[k] = v end
    return m
end

do
    local g, ids = u_graph()
    local d = g:distances(ids[1], 30)
    check('distances: along the route', math.abs(d[ids[6]] - 20) < 0.01 and math.abs(d[ids[8]] - 28) < 0.01, d[ids[8]])
    check('distances: stops at the limit', d[ids[9]] == nil and d[ids[16]] == nil)
    local blocked = {[graph.edge_key(ids[3], ids[4])] = true}
    check('distances: blocked edges', g:distances(ids[1], 100, blocked)[ids[5]] == nil)

    local near_by_air = M(1001, 'Crab', 2, 20)       -- other arm: 20 in a line, 60 by the routes
    local near_by_route = M(1002, 'Crab', 20, -6)    -- 21 in a line, 26 by the routes
    local mobs = {near_by_air, near_by_route}
    local pick = targets.pick(g, ids[1], mobs, {max_route = 80, party = {}})
    check('targets: nearest by the routes, not in a line', pick and pick.mob.id == 1002, pick and pick.mob.id)
    -- 12 along the route to (12, 0), then 10 straight to the mob (within `snap`).
    check('targets: route length includes the step off', pick and math.abs(pick.route - 22) < 0.01, pick and pick.route)
    pick = targets.pick(g, ids[1], {near_by_air}, {max_route = 40, party = {}})
    check('targets: too far by the routes', pick == nil)
    pick = targets.pick(g, ids[1], {near_by_air}, {max_route = 80, party = {}})
    check('targets: within the radius by the routes', pick and pick.mob.id == 1001 and math.abs(pick.route - 58) < 0.01,
        pick and pick.route)

    local function only(m) return targets.pick(g, ids[1], {m}, {max_route = 80, party = {[7] = true}}, 0) end
    check('targets: claimed by others', only(M(1003, 'Crab', 20, 2, {claim_id = 99})) == nil)
    check('targets: claimed by the party', only(M(1004, 'Crab', 20, 2, {claim_id = 7})) ~= nil)
    check('targets: dead', only(M(1005, 'Crab', 20, 2, {hpp = 0})) == nil)
    check('targets: not a monster', only(M(1006, 'Crab', 20, 2, {spawn_type = 2})) == nil)
    check('targets: off the routes', only(M(1007, 'Crab', 10, 10)) == nil)
    check('targets: another floor', only(M(1008, 'Crab', 20, 2, {z = 12})) == nil)
    check('targets: names', targets.pick(g, ids[1], {M(1009, 'Bat', 20, 2)}, {max_route = 80, party = {},
        names = {crab = true}}) == nil)
    check('targets: skipped', targets.pick(g, ids[1], {M(1010, 'Crab', 20, 2)}, {max_route = 80, party = {},
        skip = {[1010] = 30}}, 10) == nil)
end

-- A small world for the puller: the player walks the routes at 5 yalms/s (straight between
-- nodes is enough here), pulls claim after `claim_delay`, claimed mobs follow at 4 yalms/s,
-- and an engaged mob dies after `fight` seconds.
local function pull_world(opts)
    opts = opts or {}
    local g, ids = u_graph()
    local w = {g = g, ids = ids, t = 0, pos = P(0, 0), status = 0, hpp = 100, me = 7, said = {}, pulls = 0,
               mobs = opts.mobs or {}, path = nil, steer = nil, engaged = nil, walks = 0}
    local io = {}
    function io.walk(node)
        local here = g:nearest(w.pos, 8, 4)
        local path = here and g:find_path(here, node)
        if not path then return false, 'no route' end
        w.path, w.walks = {}, w.walks + 1
        for i, id in ipairs(path) do w.path[i] = g.nodes[id] end
        return true
    end
    function io.halt() w.path, w.steer = nil, nil end
    function io.steer(m) w.path, w.steer = nil, m end
    function io.pull(m)
        w.pulls = w.pulls + 1
        if not (opts.unpullable and opts.unpullable[m.id]) then
            m.claim_at = w.t + (opts.claim_delay or 1)
        end
    end
    function io.engage(m) w.status, w.engaged, w.engaged_at = 1, m, w.t end
    function io.disengage() w.status = 0 end
    function io.say(text) w.said[#w.said + 1] = text end
    w.p = puller.new(io, opts.puller or {}, function() return 0.5 end)
    w.p:start(ids[1], opts.names, 0)

    local function move(from, to, dist)
        local dx, dy = to.x - from.x, to.y - from.y
        local d = math.sqrt(dx * dx + dy * dy)
        if d <= dist then return P(to.x, to.y), true end
        return P(from.x + dx / d * dist, from.y + dy / d * dist), false
    end
    function w.said_like(pat)
        for _, s in ipairs(w.said) do if s:find(pat) then return true end end
        return false
    end
    function w.run(seconds)
        local stop_at = w.t + seconds
        while w.t < stop_at do
            local dt = 0.1
            w.t = w.t + dt
            if w.path then
                local reached
                w.pos, reached = move(w.pos, w.path[1], 5 * dt)
                if reached then
                    table.remove(w.path, 1)
                    if #w.path == 0 then w.path = nil w.p:on_walk('arrived', nil, w.t) end
                end
            elseif w.steer then
                w.pos = move(w.pos, w.steer, 5 * dt)
                w.steer = nil
            end
            for _, m in ipairs(w.mobs) do
                if m.claim_at and w.t >= m.claim_at then m.claim_id, m.claim_at, m.status = w.me, nil, 1 end
                if m.claim_id == w.me and m.hpp > 0 then
                    local np = move(m, w.pos, 4 * dt)
                    if graph.dist2d(np, w.pos) >= 1.5 then m.x, m.y = np.x, np.y end
                    w.p:on_action(m.id, {w.me}, true, {[w.me] = true})
                end
                if opts.wander and m.wander and w.t >= m.wander.at and not m.wandered then
                    m.x, m.y, m.wandered = m.wander.x, m.wander.y, true
                end
            end
            if w.engaged and w.t - w.engaged_at >= (opts.fight or 5) then
                w.engaged.hpp, w.engaged.status, w.engaged = 0, 2, nil
                w.status = 0
            end
            local r = w.p:tick(w.t, {g = g, pos = w.pos, status = w.status, hpp = w.hpp, me = w.me,
                                     party = {[w.me] = true}, mobs = w.mobs})
            if r and r.stop then w.stopped = r.stop return r end
        end
    end
    return w
end

do
    -- One full pull: walk out by the routes, pull, run back, fight at camp, pull the next.
    local crab = M(1002, 'Crab', 20, -6)
    local crab2 = M(1003, 'Crab', 20, 8)
    local w = pull_world({mobs = {crab, crab2}, puller = {range = 10}})
    w.run(3)
    check('puller: walks out by the routes', w.p.state == 'approach' and w.walks == 1 and w.pos.y == 0, w.p.state)
    for _ = 1, 100 do
        if w.pulls > 0 then break end
        w.run(0.1)
    end
    check('puller: pulls in range', w.pulls == 1 and graph.dist2d(w.pos, crab) <= 10, graph.dist2d(w.pos, crab))
    w.run(1.5)
    check('puller: claimed, then back to camp', crab.claim_id == 7 and w.p.state == 'returning', w.p.state)
    w.run(25)
    check('puller: fought at camp', crab.hpp == 0 and graph.dist2d(w.pos, P(0, 0)) <= 3.5, w.p.state)
    check('puller: says the kill', w.said_like('Crab defeated'))
    w.run(40)
    check('puller: pulls the next one', crab2.hpp == 0 and w.p.pulls == 2, w.p.pulls)
    w.run(10)
    check('puller: nothing left, waits', w.said_like('nothing to pull') and w.p.state == 'camp' and not w.stopped)
end

do
    -- A pull that never claims: tried twice, then skipped and back to camp.
    local crab = M(1002, 'Crab', 20, -6)
    local w = pull_world({mobs = {crab}, unpullable = {[1002] = true}, puller = {range = 10}})
    w.run(40)
    check('puller: retries the pull once', w.pulls == 2, w.pulls)
    check('puller: then skips it', w.said_like('skipping Crab') and w.p.skip[1002])
    check('puller: and goes back to camp', w.p.state == 'camp' and graph.dist2d(w.pos, P(0, 0)) <= 3.5, w.p.state)
end

do
    -- The mob wanders while we walk out: the walk is re-planned to its new spot.
    local crab = M(1002, 'Crab', 20, -6, {wander = {at = 2, x = 18, y = 22}})
    local w = pull_world({mobs = {crab}, wander = true, puller = {range = 6}})
    w.run(6)
    check('puller: re-plans for a wandering mob', w.walks == 2, w.walks)
    w.run(20)
    check('puller: still pulls it', w.pulls >= 1 and crab.claim_id == 7)
end

do
    -- Taken by someone else on the way: give up and go back.
    local crab = M(1002, 'Crab', 20, -6)
    local w = pull_world({mobs = {crab}, puller = {range = 6}})
    w.run(4)
    crab.claim_id = 99
    w.run(0.2)
    check('puller: gives up a taken mob', w.said_like('gone or taken') and w.p.state == 'returning', w.p.state)
    w.run(10)
    check('puller: and goes back to camp', w.p.state == 'camp' and graph.dist2d(w.pos, P(0, 0)) <= 3.5, w.p.state)
end

do
    -- Stops: too many mobs, low HP, death.
    local a, b, c = M(1002, 'Crab', 1, 1), M(1003, 'Crab', 1, 2), M(1004, 'Crab', 2, 1)
    local w = pull_world({mobs = {a, b, c}})
    for _, m in ipairs({a, b, c}) do w.p:on_action(m.id, {7}, true, {[7] = true}) end
    w.run(0.2)
    check('puller: stops with too many mobs', w.stopped == '3 mobs on you' and not w.p:running(), w.stopped)

    w = pull_world({mobs = {}})
    w.hpp = 30
    w.run(0.2)
    check('puller: stops on low HP', w.stopped and w.stopped:find('HP 30%%'), w.stopped)
    w = pull_world({mobs = {}})
    w.status = 2
    w.run(0.2)
    check('puller: stops on death', w.stopped == 'you died', w.stopped)
end

do
    -- Something aggroes us on the way out: it is fought first, back at camp.
    local crab = M(1002, 'Crab', 20, -6)
    local bat = M(1005, 'Bat', 8, 2)
    local w = pull_world({mobs = {crab, bat}, names = {crab = true}, puller = {range = 6}})
    w.run(1.5)
    bat.claim_id = 7
    w.p:on_action(bat.id, {7}, true, {[7] = true})
    w.run(15)
    check('puller: fights the add first', bat.hpp == 0 and crab.hpp == 100 and crab.claim_id == 0)
    w.run(30)
    check('puller: then goes back to pulling', crab.hpp == 0)
end

-- addon sessions ------------------------------------------------------------------------------

-- Loads waypoints.lua into a fake Windower. `world.blocked(x0, y0, x1, y1)` says whether a
-- move is blocked; `world.mobs` are the entities; a poked door opens after `door_delay` s.
local function session(world)
    local tmp = os.tmpname()
    os.remove(tmp)
    local env = {dir = tmp .. '_wp/', chat = {}, ran = {}, events = {}, injected = {}, clock = 0, sent = {},
                 player = {x = 0, y = 0, z = 0, status = 0}, world = world}
    os.execute('mkdir -p "' .. env.dir .. '"')

    for _, m in ipairs({'config', 'texts', 'resources', 'packets', 'waypoints'}) do
        package.loaded[m] = nil
    end
    package.preload['config'] = function()
        return {load = function(d) return d end, save = function() end}
    end
    package.preload['texts'] = function()
        return {new = function()
            return {text = function() end, show = function() end, hide = function() end}
        end}
    end
    package.preload['resources'] = function()
        return {zones = {[230] = {name = 'Southern San d\'Oria'}}}
    end
    package.preload['packets'] = function()
        return {
            new = function(dir, id, fields) local p = {dir = dir, id = id} for k, v in pairs(fields) do p[k] = v end return p end,
            inject = function(p)
                env.injected[#env.injected + 1] = p
                for _, m in ipairs(world.mobs or {}) do
                    if m.id == p['Target'] and m.spawn_type == 34 then
                        m.opens_at = env.clock + (world.door_delay or 0.5)
                    end
                end
            end,
            parse = function(_, data) return data end,
        }
    end

    local function mob_by_index(i)
        for _, m in ipairs(world.mobs or {}) do if m.index == i then return m end end
    end

    _addon = {}
    windower = {
        addon_path = env.dir,
        add_to_chat = function(_, msg) env.chat[#env.chat + 1] = msg end,
        send_command = function(c) env.sent[#env.sent + 1] = c if world.command then world.command(env, c) end end,
        register_event = function(name, f) env.events[name] = f end,
        file_exists = function(p) local f = io.open(p) if f then f:close() return true end return false end,
        dir_exists = function(p) return os.execute('test -d "' .. p .. '"') == 0 end,
        create_dir = function(p) return os.execute('mkdir "' .. p .. '"') == 0 end,
        ffxi = {
            get_mob_by_target = function() return {x = env.player.x, y = env.player.y, z = env.player.z} end,
            get_player = function() return {id = 1, status = env.player.status, target_locked = false,
                                            vitals = {hpp = env.player.hpp or 100}} end,
            get_party = function() return {p0 = {mob = {id = 1}}} end,
            get_mob_by_id = function(id)
                for _, m in ipairs(world.mobs or {}) do if m.id == id then return m end end
            end,
            turn = function(h) env.facing = h end,
            get_info = function() return {zone = 230, logged_in = true} end,
            get_mob_array = function() return world.mobs or {} end,
            get_mob_by_index = mob_by_index,
            run = function(a, b) env.ran[#env.ran + 1] = {a, b} end,
            follow = function() end,
        },
    }
    os.clock = function() return env.clock end
    dofile(root .. '/waypoints.lua')
    env.events['load']()

    function env.frame(dt)
        env.clock = env.clock + (dt or 0.1)
        for _, m in ipairs(world.mobs or {}) do
            if m.opens_at and env.clock >= m.opens_at then m.status, m.opens_at = 8, nil end
        end
        if world.tick then world.tick(env) end
        env.events['prerender']()
    end
    function env.cmd(...) env.events['addon command'](...) end
    function env.said(pattern)
        for i = #env.chat, 1, -1 do if env.chat[i]:find(pattern) then return true end end
        return false
    end
    function env.walk_to(x, y)       -- record-mode movement in 0.5 steps
        local p = env.player
        while math.abs(p.x - x) > 0.25 or math.abs(p.y - y) > 0.25 do
            local dx, dy = x - p.x, y - p.y
            local d = math.sqrt(dx * dx + dy * dy)
            local s = math.min(0.5, d)
            p.x, p.y = p.x + dx / d * s, p.y + dy / d * s
            env.frame()
        end
    end
    -- Follow run() commands (5 yalms/s) until `pattern` appears in chat or `frames` pass.
    function env.drive(pattern, frames)
        for _ = 1, frames or 800 do
            local r = env.ran[#env.ran]
            if r and type(r[1]) == 'number' then
                local nx, ny = env.player.x + r[1] * 0.5, env.player.y + r[2] * 0.5
                if not (world.blocked and world.blocked(env.player.x, env.player.y, nx, ny)) then
                    env.player.x, env.player.y = nx, ny
                end
            end
            env.frame()
            if env.said(pattern) then return true end
        end
        return false
    end
    function env.close()
        os.execute('rm -rf "' .. env.dir .. '"')
    end
    return env
end

local real_clock = os.clock

-- Record, mark, walk, reload, engage.
do
    local s = session({})
    s.cmd('rec')
    s.cmd('mark', 'Gate')
    s.walk_to(20, 0)
    s.walk_to(20, 20)
    s.cmd('mark', 'Auction', 'House')
    s.cmd('stop')
    check('addon recorded', s.said('recording stopped'), s.chat[#s.chat])
    check('addon saved a zone file', windower.file_exists(s.dir .. 'data/zones/230.lua'))

    s.cmd('go', 'gate')
    check('addon started walking', s.said('walking to "gate"'), s.chat[#s.chat])
    check('addon arrived', s.drive('arrived'), s.chat[#s.chat])
    check('addon ends at the gate', math.abs(s.player.x) <= 1.5 and math.abs(s.player.y) <= 1.5,
        s.player.x .. ',' .. s.player.y)
    check('addon stopped running', s.ran[#s.ran][1] == false)

    s.cmd('reload')
    s.cmd('route', 'auction', 'house')
    check('addon routes after reload', s.said('"auction house": %d+ yalms'), s.chat[#s.chat])

    s.cmd('go', 'auction', 'house')
    s.frame()
    s.player.status = 1
    s.frame()
    check('addon stops when engaged', s.said('stopped: engaged'), s.chat[#s.chat])
    s.close()
end

-- A closed door across the corridor at x = 10: opened on the way, no stop.
do
    local door = {id = 0x0100F00A, index = 10, name = 'Door', spawn_type = 34, status = 9, x = 10, y = 0, z = 0}
    local world = {mobs = {door}, door_delay = 0.5}
    world.blocked = function(x0, _, x1) return door.status ~= 8 and x0 < 10 and x1 >= 9.5 end
    local s = session(world)
    s.cmd('rec')
    s.cmd('mark', 'start')
    door.status = 8                   -- open while recording
    s.walk_to(20, 0)
    s.cmd('mark', 'end')
    s.cmd('stop')
    s.player.x, s.player.y = 0, 0
    door.status = 9
    s.cmd('go', 'end')
    check('door: arrives through the door', s.drive('arrived'), s.chat[#s.chat])
    check('door: poked with an interaction packet', #s.injected >= 1 and s.injected[1].id == 0x01A
        and s.injected[1]['Target'] == door.id and s.injected[1]['Category'] == 0)
    check('door: no reroute needed', not s.said('rerouting'))
    s.close()
end

-- A locked door (never opens): stuck, door retried, then the edge is blocked and a second
-- recorded route (north loop) is taken.
do
    local door = {id = 0x0100F00B, index = 11, name = 'Door', spawn_type = 34, status = 9, x = 10, y = 0, z = 0}
    local world = {mobs = {door}, door_delay = 1e9}
    world.blocked = function(x0, y0, x1, y1) return math.abs(y1) < 15 and x0 < 10 and x1 >= 9.5 end
    local s = session(world)
    s.cmd('rec')
    s.cmd('mark', 'start')
    s.walk_to(20, 0)                  -- recorded while the door was open (blocked() ignores status here)
    s.cmd('mark', 'end')
    s.walk_to(20, 20)                 -- detour: north, west, back down to the start
    s.walk_to(0, 20)
    s.walk_to(0, 0)
    s.cmd('stop')
    s.player.x, s.player.y = 0, 0
    s.cmd('go', 'end')
    check('blocked: reroutes around the locked door', s.drive('arrived', 2000), s.chat[#s.chat])
    check('blocked: tried the door first', s.said('opening Door'))
    check('blocked: announced the reroute', s.said('rerouting'))
    check('blocked: ends at the goal', math.abs(s.player.x - 20) <= 1.5 and math.abs(s.player.y) <= 1.5,
        s.player.x .. ',' .. s.player.y)
    s.cmd('blocked')
    check('blocked: lists the blocked edge', s.said('blocked: points'))
    s.cmd('unblock')
    s.cmd('blocked')
    check('blocked: unblock clears it', s.said('no blocked paths'))
    s.close()
end

-- A pillar on the recorded route (placed after recording): steered around, no reroute.
do
    local world = {mobs = {}}
    local s = session(world)
    s.cmd('rec')
    s.cmd('mark', 'start')
    s.walk_to(30, 0)
    s.cmd('mark', 'end')
    s.cmd('stop')
    world.blocked = function(_, _, x1, y1) return x1 > 13 and x1 < 17 and y1 > -2 and y1 < 2 end
    s.player.x, s.player.y = 0, 0
    s.cmd('go', 'end')
    check('obstacle: arrives around the pillar', s.drive('arrived'), s.chat[#s.chat])
    check('obstacle: no reroute needed', not s.said('rerouting'))
    check('obstacle: no stop', not s.said('^waypoints: stopped:'))
    s.close()
end

-- Blocked with no alternative: stops and says so.
do
    local world = {mobs = {}}
    world.blocked = function(x0, _, x1) return x0 < 10 and x1 >= 10 end
    local s = session(world)
    s.cmd('rec')
    s.cmd('mark', 'start')
    s.walk_to(20, 0)
    s.cmd('mark', 'end')
    s.cmd('stop')
    s.player.x, s.player.y = 0, 0
    s.cmd('go', 'end')
    check('dead end: stops as blocked', s.drive('stopped: blocked'), s.chat[#s.chat])
    check('dead end: stopped running', s.ran[#s.ran][1] == false)
    s.close()
end

-- A door opened by hand while recording is remembered, even with a hidden name.
do
    local door = {id = 0x0100F00C, index = 12, name = '_6s1', spawn_type = 34, status = 9, x = 5, y = 0, z = 0}
    local s = session({mobs = {door}})
    s.cmd('rec')
    s.events['outgoing chunk'](0x01A, {['Category'] = 0, ['Target'] = door.id, ['Target Index'] = door.index},
        nil, false)
    s.cmd('stop')
    check('record: door remembered', s.said('recorded door: _6s1'), s.chat[#s.chat])
    s.cmd('reload')
    s.cmd('doors')
    check('record: door saved', s.said('1 recorded doors'), s.chat[#s.chat])
    s.close()
end

-- Pulling in a whole session: camp at (0, 0), a crab off the far end of an L-shaped route.
-- /ra claims it and it follows; /attack kills it 3 s later.
do
    local crab = {id = 1002, index = 2, name = 'Ghost Crab', x = 24, y = 18, z = 0, hpp = 100, spawn_type = 16,
                  status = 0, claim_id = 0, valid_target = true}
    local world = {mobs = {crab}}
    function world.command(env, c)
        if c == 'input /ra 1002' then crab.claim_id, crab.status = 1, 1 end
        if c == 'input /attack 1002' then env.player.status, env.attack_at = 1, env.clock end
    end
    function world.tick(env)
        local p = env.player
        if crab.claim_id == 1 and crab.hpp > 0 then
            local dx, dy = p.x - crab.x, p.y - crab.y
            local d = math.sqrt(dx * dx + dy * dy)
            if d > 1.5 then crab.x, crab.y = crab.x + dx / d * 0.4, crab.y + dy / d * 0.4 end
            if env.events['action'] then env.events['action']({actor_id = 1002, targets = {{id = 1}}}) end
        end
        if env.attack_at and env.clock - env.attack_at >= 3 then
            crab.hpp, crab.status, p.status, env.attack_at = 0, 2, 0, nil
        end
    end
    local s = session(world)
    s.cmd('rec')
    s.cmd('mark', 'camp')
    s.walk_to(20, 0)
    s.walk_to(20, 20)
    s.cmd('stop')
    s.walk_to(0, 0)
    s.cmd('pull', 'on')
    check('pull: needs a camp', s.said('set a camp first'), s.chat[#s.chat])
    s.cmd('pull', 'camp', 'camp')
    s.cmd('pull', 'add', 'Ghost', 'Crab')
    s.cmd('pull', 'action', 'ra')
    s.cmd('pull', 'on')
    check('pull: started', s.said('pulling from "camp": ghost crab within 40 yalms'), s.chat[#s.chat])
    check('pull: picks the crab', s.drive('pulling Ghost Crab', 100), s.chat[#s.chat])
    local sent_ra = false
    for _ = 1, 400 do
        s.drive('$^', 1)
        for _, c in ipairs(s.sent) do if c == 'input /ra 1002' then sent_ra = true end end
        if sent_ra then break end
    end
    check('pull: walked the routes out and used /ra on it', sent_ra and s.player.x > 15, s.player.x .. ',' .. s.player.y)
    check('pull: faced it', s.facing ~= nil)
    check('pull: fights it at camp', s.drive('Ghost Crab defeated', 600), s.chat[#s.chat])
    check('pull: engaged it near camp', math.abs(s.player.x) <= 4 and math.abs(s.player.y) <= 4,
        s.player.x .. ',' .. s.player.y)
    check('pull: /attack sent', s.sent[#s.sent] == 'input /attack 1002', s.sent[#s.sent])
    check('pull: nothing left', s.drive('nothing to pull', 100))
    s.cmd('go', 'camp')
    check('pull: //wp go waits', s.said('stop pulling first'))
    s.cmd('stop')
    check('pull: //wp stop stops it', s.said('pulling stopped: by request'), s.chat[#s.chat])
    s.close()
end

os.clock = real_clock

print(string.format('%d passed, %d failed', passed, failed))
os.exit(failed == 0 and 0 or 1)
