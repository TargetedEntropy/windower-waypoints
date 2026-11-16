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

-- addon sessions ------------------------------------------------------------------------------

-- Loads waypoints.lua into a fake Windower. `world.blocked(x0, y0, x1, y1)` says whether a
-- move is blocked; `world.mobs` are the entities; a poked door opens after `door_delay` s.
local function session(world)
    local tmp = os.tmpname()
    os.remove(tmp)
    local env = {dir = tmp .. '_wp/', chat = {}, ran = {}, events = {}, injected = {}, clock = 0,
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
        register_event = function(name, f) env.events[name] = f end,
        file_exists = function(p) local f = io.open(p) if f then f:close() return true end return false end,
        dir_exists = function(p) return os.execute('test -d "' .. p .. '"') == 0 end,
        create_dir = function(p) return os.execute('mkdir "' .. p .. '"') == 0 end,
        ffxi = {
            get_mob_by_target = function() return {x = env.player.x, y = env.player.y, z = env.player.z} end,
            get_player = function() return {status = env.player.status, target_locked = false} end,
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
    world.blocked = function(x0, y0, x1, y1) return math.abs(y0) < 3 and x0 < 10 and x1 >= 9.5 end
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

os.clock = real_clock

print(string.format('%d passed, %d failed', passed, failed))
os.exit(failed == 0 and 0 or 1)
