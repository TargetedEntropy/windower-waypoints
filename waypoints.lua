--[[
    waypoints: record walkable routes as a per-zone graph, name places on it, and walk to a
    named place along the shortest recorded path (A*).

    Record by walking: //wp rec, walk, //wp stop. Routes recorded at different times join
    where they cross. Mark places with //wp mark <name>; walk there with //wp go <name>.
    Obstacles are steered around; closed doors on the way are opened; a blocked path is
    routed around when another recorded route exists.

    Pulling (//wp pull on) pulls monsters to a camp mark along the routes and fights them
    there (puller.lua, targets.lua).

    Movement is supervised: //wp stop or Escape stops it, and it stops on its own when stuck
    with no way around, off the route, engaged, dead or zoning. Automated movement can
    conflict with FFXI's terms of service; keep it to short, attended use.

    Graphs are saved per zone in data/zones/<zone id>.lua (plain Lua tables).

    Copyright (c) 2026, TargetedEntropy. BSD-3-Clause; see LICENSE.
]]

_addon.name = 'waypoints'
_addon.author = 'TargetedEntropy'
_addon.version = '0.4.0'
_addon.commands = {'waypoints', 'wp'}

package.path = windower.addon_path .. '?.lua;' .. package.path

local config = require('config')
local texts = require('texts')
local graph = require('graph')
local recorder = require('recorder')
local navigator = require('navigator')
local doors = require('doors')
local puller = require('puller')
local packets = require('packets')

local defaults = {
    record = {spacing = 3.0, corner_min = 1.5, corner_angle = 35, merge_radius = 2.0, max_dz = 3.0, jump = 20.0},
    nav = {tolerance = 1.5, final_tolerance = 1.0, stuck_seconds = 3.0, stuck_distance = 1.0, off_route = 12.0,
           snap_radius = 8.0, block_minutes = 10, max_reroutes = 3,
           avoid = true, blocked_seconds = 0.6, blocked_distance = 0.6, commit_seconds = 0.6,
           avoid_max = 12.0, avoid_radius = 8.0},
    doors = {enabled = true, reach = 6.0, width = 3.0, cooldown = 7, wait = 4.0, attempts = 2},
    -- Pulling (//wp pull): camp is a mark; names is a comma-separated list (empty: any
    -- monster); action is one of PULL_ACTIONS or 'custom' (command + range).
    pull = {camp = '', names = '', action = 'ra', command = '/ra', range = 17.0, radius = 40.0,
            snap = 10.0, max_dz = 4.0, claim_wait = 4.0, engage_range = 6.0, max_aggro = 2, min_hp = 40,
            max_pulls = 50, max_minutes = 60},
    show = true,
    display = {pos = {x = 20, y = 300}, text = {size = 10, font = 'Consolas'}, bg = {alpha = 160}},
}

local settings = config.load(defaults)
local overlay = texts.new('', settings.display)

local CHAT_COLOR = 207
local TICK = 0.1                                  -- seconds between updates (os.clock is wall time on Windows)
local NAV_STATUSES = {[0] = true, [5] = true, [85] = true}  -- idle, chocobo, mount
local DIK_ESCAPE = 1

-- Pull actions: the command (sent with the mob's id as its target) and its range.
local PULL_ACTIONS = {
    ra = {command = '/ra', range = 17.0},
    provoke = {command = '/ja "Provoke"', range = 17.0},
    dia = {command = '/ma "Dia"', range = 19.0},
    melee = {command = '/attack', range = 3.0, engages = true},
}

local state = {
    zone = nil,
    graph = nil,
    dirty = false,
    rec = nil,          -- recorder while recording
    nav = nil,          -- navigator while walking
    nav_goal = nil,     -- what the walk is to, for messages ("ah", "camp", a mob's name)
    nav_goal_id = nil,  -- its node
    pull = nil,         -- puller while pulling
    pull_walk = false,  -- the current walk is the puller's
    nav_paused = false,
    nav_reroutes = 0,
    door_wait = nil,    -- {id = , index = , until_t = } while waiting for a door to open
    door_tries = {},    -- door id -> attempts during this walk
    door_last = {},     -- door id -> os.clock() of the last poke
    blocked = {},       -- edge key -> os.time() when the block expires
    last_tick = 0,
}

-- Helpers -----------------------------------------------------------------------------------

local function say(fmt, ...)
    windower.add_to_chat(CHAT_COLOR, 'waypoints: ' .. string.format(fmt, ...))
end

local function me()
    local m = windower.ffxi.get_mob_by_target('me')
    if m and m.x and m.y and m.z then
        return {x = m.x, y = m.y, z = m.z}
    end
end

local function zone_name(id)
    local ok, res = pcall(require, 'resources')
    local z = ok and res.zones and res.zones[id]
    return z and z.name or ('zone ' .. tostring(id))
end

local function data_path(zone)
    return windower.addon_path .. 'data/zones/' .. tostring(zone) .. '.lua'
end

local function ensure_dirs()
    for _, d in ipairs({'data/', 'data/zones/'}) do
        local p = windower.addon_path .. d
        if not windower.dir_exists(p) then
            windower.create_dir(p)
        end
    end
end

-- Storage -----------------------------------------------------------------------------------

local function load_zone(zone)
    local path = data_path(zone)
    if not windower.file_exists(path) then
        return graph.new(zone)
    end
    local chunk, err = loadfile(path)
    if not chunk then
        say('could not read %s: %s (starting empty; the file is left as is)', path, tostring(err))
        return graph.new(zone), true
    end
    setfenv(chunk, {})
    local ok, t = pcall(chunk)
    if not ok or type(t) ~= 'table' then
        say('could not load %s (starting empty; the file is left as is)', path)
        return graph.new(zone), true
    end
    return graph.from_table(t, zone)
end

local function save()
    local g = state.graph
    if not g or not state.dirty or state.read_only then
        return
    end
    ensure_dirs()
    local path = data_path(g.zone)
    local tmp = path .. '.tmp'
    local f, err = io.open(tmp, 'w')
    if not f then
        say('save failed: %s', tostring(err))
        return
    end
    f:write(g:serialize())
    f:close()
    os.remove(path)
    local ok, rerr = os.rename(tmp, path)
    if not ok then
        say('save failed: %s', tostring(rerr))
        return
    end
    state.dirty = false
end

local function enter_zone(zone)
    state.zone = zone
    state.graph, state.read_only = load_zone(zone)
    state.dirty = false
    if state.read_only then
        say('this zone\'s file is unreadable; changes here will not be saved until it is fixed or removed')
    end
end

-- Recording and navigation ------------------------------------------------------------------

local function stop_nav(reason)
    if state.nav then
        windower.ffxi.run(false)
        if state.pull_walk and state.pull then
            -- The puller decides what a failed walk means; it says so itself.
            state.pull:on_walk(reason and 'failed' or 'arrived', reason, os.clock())
        elseif reason then
            say('stopped: %s', reason)
        end
    end
    state.pull_walk = false
    state.nav, state.nav_goal, state.nav_goal_id, state.nav_paused = nil, nil, nil, false
    state.door_wait, state.door_tries, state.nav_reroutes = nil, {}, 0
end

-- Blocked edges -----------------------------------------------------------------------------

-- The set of edges blocked right now (expired ones are dropped).
local function active_blocks()
    local now, out = os.time(), {}
    for key, expires in pairs(state.blocked) do
        if expires > now then
            out[key] = true
        else
            state.blocked[key] = nil
        end
    end
    return out
end

local function block_edge(a, b)
    state.blocked[graph.edge_key(a, b)] = os.time() + settings.nav.block_minutes * 60
end

-- Doors -------------------------------------------------------------------------------------

local function poke_door(mob)
    packets.inject(packets.new('outgoing', 0x01A, {
        ['Target'] = mob.id,
        ['Target Index'] = mob.index,
        ['Category'] = 0,   -- NPC interaction, as when you click the door
        ['Param'] = 0,
    }))
    state.door_last[mob.id] = os.clock()
end

local function door_ahead(pos, opts)
    if not settings.doors.enabled or not state.nav then
        return nil
    end
    local mobs = windower.ffxi.get_mob_array() or {}
    return doors.blocking(mobs, pos, state.nav:ahead(3), opts, state.graph.doors)
end

local function door_ready(mob)
    local last = state.door_last[mob.id]
    return not last or os.clock() - last >= settings.doors.cooldown
end

local function stop_recording()
    local rec = state.rec
    if not rec then
        return
    end
    state.rec = nil
    save()
    say('recording stopped: %d new nodes; %s has %d nodes, %d edges',
        rec.added, zone_name(state.zone), state.graph.count, state.graph:edge_count())
end

local function start_recording()
    if state.rec then
        say('already recording')
        return
    end
    if state.nav then
        say('stop walking first (//wp stop)')
        return
    end
    local pos = me()
    if not pos or not state.graph then
        say('no position yet')
        return
    end
    state.rec = recorder.new(state.graph, settings.record)
    state.rec:start(pos)
    state.dirty = true
    say('recording in %s; walk your routes, then //wp stop', zone_name(state.zone))
end

local function resolve_goal(name)
    local g = state.graph
    local id = g and g.marks[name]
    if not id then
        say('no mark "%s" in %s (//wp marks lists them)', name, zone_name(state.zone))
    end
    return id
end

-- Plans from the player's position to a node, avoiding blocked edges. `label` names it in
-- messages. `avoid` is an optional set of node ids not to start from (a start node that
-- couldn't be reached); `from` forces the start node (a rerouted walk starts from the node it
-- last passed). On failure returns nil and the reason (`quiet` keeps it out of chat).
local function plan_to(goal, label, avoid, from, quiet)
    local function fail(fmt, ...)
        local msg = string.format(fmt, ...)
        if not quiet then say('%s', msg) end
        return nil, msg
    end
    local pos = me()
    if not pos then
        return fail('no position yet')
    end
    local g = state.graph
    local start, d
    if from and g.nodes[from] then
        start, d = from, graph.dist2d(pos, g.nodes[from])
    else
        start, d = g:nearest(pos, settings.nav.snap_radius, settings.record.max_dz + 2, avoid)
    end
    if not start then
        return fail('no recorded node within %.0f yalms; walk closer to a recorded route', settings.nav.snap_radius)
    end
    local blocked = active_blocks()
    local path, length = g:find_path(start, goal, blocked)
    if not path then
        if next(blocked) and g:find_path(start, goal) then
            return fail('every recorded route to "%s" is blocked right now (//wp unblock to retry them)', label)
        end
        return fail('"%s" is not connected to the route you are on', label)
    end
    return path, length + d, pos
end

local function plan(name, avoid, from)
    local goal = resolve_goal(name)
    if not goal then
        return nil
    end
    return plan_to(goal, name, avoid, from)
end

local function begin_walk(name, path, pos)
    local points = {}
    for i, id in ipairs(path) do
        points[i] = state.graph.nodes[id]
    end
    state.nav = navigator.new(points, pos, settings.nav, path)
    state.nav_goal, state.nav_goal_id = name, path[#path]
    state.door_wait = nil
    return #points
end

local function go(name)
    if state.rec then
        say('stop recording first (//wp stop)')
        return
    end
    if state.pull then
        say('stop pulling first (//wp pull off)')
        return
    end
    local player = windower.ffxi.get_player()
    if not player or not NAV_STATUSES[player.status] then
        say('can only walk while idle or mounted')
        return
    end
    if player.target_locked then
        say('target lock is on; release it first')
        return
    end
    local path, length, pos = plan(name)
    if not path then
        return
    end
    stop_nav()
    windower.ffxi.follow()     -- cancel any /follow so it doesn't fight the steering
    local count = begin_walk(name, path, pos)
    say('walking to "%s": %.0f yalms, %d points (//wp stop or Escape to stop)', name, length, count)
end

-- When movement is blocked, a closed door close by is the likeliest cause: stop, open it and
-- wait for it (each door is tried `doors.attempts` times per walk). Returns true if it did.
local function try_door(pos)
    local d = settings.doors
    local door = door_ahead(pos, {reach = d.reach + 2, width = d.width + 1, max_dz = settings.record.max_dz + 1})
    if not door or (state.door_tries[door.id] or 0) >= d.attempts then
        return false
    end
    state.door_tries[door.id] = (state.door_tries[door.id] or 0) + 1
    windower.ffxi.run(false)
    poke_door(door)
    state.door_wait = {id = door.id, index = door.index, until_t = os.clock() + d.wait}
    state.nav:clear_avoid()
    say('opening %s', door.name ~= '' and door.name or 'a door')
    return true
end

-- Called when the walker reports being stuck (avoidance found no way past). Tries, in
-- order: open a door in the way, route around the blocked edge, give up.
local function handle_stuck(pos)
    local nav = state.nav
    local where = string.format(' near point %d/%d', nav.index, #nav.points)

    -- 1. A closed door close by.
    if try_door(pos) then
        return
    end

    -- 2. Block the edge and look for another recorded route.
    local a, b = nav:current_edge()
    local avoid
    if a and b then
        block_edge(a, b)
    elseif b then
        avoid = {[b] = true}    -- couldn't reach the first point: start somewhere else
    end
    if state.nav_reroutes >= settings.nav.max_reroutes then
        stop_nav('blocked' .. where .. string.format(' after %d reroutes', state.nav_reroutes))
        return
    end
    local goal, goal_id = state.nav_goal, state.nav_goal_id
    -- Restart from the node last passed: it's behind us, so known to be reachable, whereas
    -- the nearest node may be on the far side of whatever blocked us.
    local path, length, here = plan_to(goal_id, goal, avoid, a, state.pull_walk)
    if not path then
        stop_nav('blocked' .. where)
        return
    end
    state.nav_reroutes = state.nav_reroutes + 1
    local pull_walk = state.pull_walk
    begin_walk(goal, path, here)
    state.pull_walk = pull_walk
    say('path blocked%s; rerouting (%.0f yalms)', where, length)
end

local function update_overlay()
    if not settings.show then
        overlay:hide()
        return
    end
    local lines
    if state.rec then
        local g = state.graph
        lines = string.format('waypoints  REC  %s\nnodes %d  edges %d  new %d',
            zone_name(state.zone), g.count, g:edge_count(), state.rec.added)
    elseif state.pull then
        local p = state.pull
        local t = p.target and p.target.name or ''
        lines = string.format('waypoints  PULL  %s %s\npulls %d  aggro %d%s', p.state, t, p.pulls,
            p:aggro_count(), state.nav and string.format('  point %d/%d', state.nav.index, #state.nav.points) or '')
    elseif state.nav then
        local n = state.nav
        local target = n.points[n.index]
        local pos = me()
        local d = (pos and target) and graph.dist2d(pos, target) or 0
        local note = state.nav_paused and '  (paused)' or state.door_wait and '  (opening door)'
            or n:is_avoiding() and '  (avoiding obstacle)' or ''
        lines = string.format('waypoints  GO  "%s"%s\npoint %d/%d  next %.1f%s',
            state.nav_goal, note, n.index, #n.points, d,
            state.nav_reroutes > 0 and string.format('  rerouted %d', state.nav_reroutes) or '')
    end
    if lines then
        overlay:text(lines)
        overlay:show()
    else
        overlay:hide()
    end
end

-- Pulling ---------------------------------------------------------------------------------

-- The party's ids (players and their pets), as a set.
local function party_ids()
    local ids = {}
    local ok, party = pcall(windower.ffxi.get_party)
    if ok and party then
        for _, k in ipairs({'p0', 'p1', 'p2', 'p3', 'p4', 'p5'}) do
            local m = party[k] and party[k].mob
            if m and m.id then
                ids[m.id] = true
                if m.pet_index then
                    local pet = windower.ffxi.get_mob_by_index(m.pet_index)
                    if pet and pet.id then ids[pet.id] = true end
                end
            end
        end
    end
    local me_ = windower.ffxi.get_player()
    if me_ and me_.id then ids[me_.id] = true end
    return ids
end

local function pull_action()
    local p = settings.pull
    if p.action == 'custom' then
        return {command = p.command, range = p.range, engages = p.command:find('^/attack') ~= nil}
    end
    return PULL_ACTIONS[p.action] or PULL_ACTIONS.ra
end

local function pull_names()
    local names, any = {}, false
    for n in (settings.pull.names or ''):gmatch('[^,]+') do
        n = n:gsub('^%s+', ''):gsub('%s+$', ''):lower()
        if n ~= '' then names[n], any = true, true end
    end
    return any and names or nil
end

local function face(mob)
    local pos = me()
    if pos then
        windower.ffxi.turn(-math.atan2(mob.y - pos.y, mob.x - pos.x))
    end
end

local function send_input(text)
    windower.send_command('input ' .. text)
end

-- What the puller does in the world.
local pull_io = {
    walk = function(node)
        local label = node == state.pull.camp and 'camp' or (state.pull.target and state.pull.target.name or 'target')
        local path, length, pos = plan_to(node, label, nil, nil, true)
        if not path then
            return false, length
        end
        state.pull_walk = false
        stop_nav()
        windower.ffxi.follow()
        begin_walk(label, path, pos)
        state.pull_walk = true
        return true
    end,
    halt = function()
        -- Only stop movement the puller started: in a fight something else may be moving you.
        state.pull_walk = false
        if state.nav then
            stop_nav()
        elseif state.pull_steering then
            windower.ffxi.run(false)
        end
        state.pull_steering = false
    end,
    steer = function(mob)
        local pos = me()
        if not pos then return end
        local dx, dy = mob.x - pos.x, mob.y - pos.y
        local d = math.sqrt(dx * dx + dy * dy)
        if d > 0.1 then
            if state.nav then
                state.pull_walk = false
                stop_nav()
            end
            windower.ffxi.run(dx / d, dy / d)
            state.pull_steering = true
        end
    end,
    pull = function(mob)
        face(mob)
        send_input(string.format('%s %d', pull_action().command, mob.id))
    end,
    engage = function(mob)
        face(mob)
        send_input(string.format('/attack %d', mob.id))
    end,
    disengage = function()
        send_input('/attackoff')
    end,
    say = function(text)
        say('%s', text)
    end,
}

local function stop_pulling(reason)
    if state.pull then
        state.pull:stop()
        state.pull = nil
        state.pull_walk, state.pull_steering = false, false
        if reason then
            say('pulling stopped: %s', reason)
        end
    end
end

local function pull_tick(pos)
    local player = windower.ffxi.get_player()
    if not player then
        return
    end
    local mob_me = windower.ffxi.get_mob_by_target('me')
    local r = state.pull:tick(os.clock(), {
        g = state.graph, pos = pos, status = player.status,
        hpp = player.vitals and player.vitals.hpp or (mob_me and mob_me.hpp) or 100,
        me = player.id, party = party_ids(), mobs = windower.ffxi.get_mob_array() or {},
        blocked = active_blocks(),
    })
    if r and r.stop then
        stop_pulling(r.stop)
    end
end

local function tick()
    local pos = me()
    if not pos then
        return
    end

    if state.rec then
        local r = state.rec:sample(pos)
        if r then
            state.dirty = true
        end
    end

    if state.pull then
        pull_tick(pos)
    end

    if state.nav then
        local player = windower.ffxi.get_player()
        if not player then
            return
        end
        if player.status == 1 or player.status == 2 or player.status == 3 then
            stop_nav(player.status == 1 and 'engaged' or 'dead')
            return
        end
        if not NAV_STATUSES[player.status] then
            -- Cutscene, resting, etc.: hold still and resume afterwards.
            if not state.nav_paused then
                windower.ffxi.run(false)
                state.nav_paused = true
            end
            return
        end
        if state.nav_paused then
            state.nav_paused = false
            state.nav:reset_window()
        end

        -- Waiting for a door we poked after getting stuck.
        local wait = state.door_wait
        if wait then
            local mob = windower.ffxi.get_mob_by_index(wait.index)
            local open = mob and mob.id == wait.id and doors.is_open(mob)
            if not open and os.clock() < wait.until_t then
                return
            end
            state.door_wait = nil
            state.nav:clear_avoid()
        end

        -- Open a closed door on the path ahead before reaching it.
        local door = door_ahead(pos, settings.doors)
        if door and door_ready(door) then
            poke_door(door)
        end

        local step = state.nav:update(pos, os.clock())
        if step.done then
            windower.ffxi.run(false)
            if not state.pull_walk then
                say('arrived at "%s"', state.nav_goal)
            end
            stop_nav()
        elseif step.stop and step.reason == 'stuck' then
            handle_stuck(pos)
        elseif step.stop then
            stop_nav(step.reason .. string.format(' near point %d/%d', state.nav.index, #state.nav.points))
        elseif step.event == 'blocked' and try_door(pos) then
            return      -- a door was in the way; wait for it instead of steering around it
        elseif step.dx ~= 0 or step.dy ~= 0 then
            windower.ffxi.run(step.dx, step.dy)
        end
    end
end

-- Commands ----------------------------------------------------------------------------------

local function sorted_marks()
    local names = {}
    for name in pairs(state.graph and state.graph.marks or {}) do
        names[#names + 1] = name
    end
    table.sort(names)
    return names
end

local commands = {}

commands.rec = start_recording
commands.record = start_recording

function commands.stop()
    if state.rec then
        stop_recording()
    elseif state.pull then
        stop_pulling('by request')
    elseif state.nav then
        stop_nav('by request')
    else
        say('nothing to stop')
    end
end

function commands.undo()
    if not state.rec then
        say('undo works while recording')
        return
    end
    if state.rec:undo() then
        state.dirty = true
        say('undid one step (%d nodes)', state.graph.count)
    else
        say('nothing to undo')
    end
end

function commands.mark(...)
    local name = table.concat({...}, ' '):lower()
    if name == '' then
        say('usage: //wp mark <name>')
        return
    end
    local pos = me()
    if not pos then
        return
    end
    local g = state.graph
    local id = state.rec and state.rec.last
    if not id then
        id = g:nearest(pos, 5, settings.record.max_dz)
    end
    if not id then
        say('no recorded node within 5 yalms; record here first (//wp rec)')
        return
    end
    g.marks[name] = id
    state.dirty = true
    if not state.rec then save() end
    say('marked "%s" at node %d', name, id)
end

function commands.unmark(...)
    local name = table.concat({...}, ' '):lower()
    if not state.graph.marks[name] then
        say('no mark "%s"', name)
        return
    end
    state.graph.marks[name] = nil
    state.dirty = true
    if not state.rec then save() end
    say('removed "%s"', name)
end

function commands.marks()
    local names = sorted_marks()
    if #names == 0 then
        say('no marks in %s', zone_name(state.zone))
        return
    end
    local pos = me()
    for _, name in ipairs(names) do
        local n = state.graph.nodes[state.graph.marks[name]]
        say('  %-20s %s', name, pos and string.format('%.0f yalms away', graph.dist2d(pos, n)) or '')
    end
end

function commands.route(...)
    local name = table.concat({...}, ' '):lower()
    local path, length = plan(name)
    if path then
        say('"%s": %.0f yalms over %d points', name, length, #path)
    end
end

function commands.go(...)
    local name = table.concat({...}, ' '):lower()
    if name == '' then
        say('usage: //wp go <mark>')
        return
    end
    go(name)
end

function commands.pull(sub, ...)
    sub = (sub or ''):lower()
    local rest = table.concat({...}, ' ')
    local p = settings.pull
    if sub == 'on' then
        if state.rec then
            say('stop recording first (//wp stop)')
            return
        end
        local camp = state.graph.marks[(p.camp or ''):lower()]
        if not camp then
            say('set a camp first: //wp pull camp <mark>')
            return
        end
        local player = windower.ffxi.get_player()
        if not player or player.status ~= 0 then
            say('can only start pulling while idle')
            return
        end
        stop_nav()
        local a = pull_action()
        state.pull = puller.new(pull_io, {
            range = a.range, engages = a.engages, snap = p.snap, max_dz = p.max_dz, max_route = p.radius,
            claim_wait = p.claim_wait, engage_range = p.engage_range, max_aggro = p.max_aggro,
            min_hp = p.min_hp, max_pulls = p.max_pulls, max_minutes = p.max_minutes,
            camp_radius = settings.nav.tolerance * 2,
        })
        state.pull:start(camp, pull_names(), os.clock())
        say('pulling from "%s": %s within %.0f yalms by the routes, with %s (//wp pull off or Escape stops)',
            p.camp, p.names ~= '' and p.names or 'any monster', p.radius, a.command)
    elseif sub == 'off' then
        if state.pull then stop_pulling('by request') else say('not pulling') end
    elseif sub == 'camp' then
        local name = rest:lower()
        if name == '' or not state.graph.marks[name] then
            say('usage: //wp pull camp <mark> (//wp marks lists them)')
            return
        end
        p.camp = name
        config.save(settings)
        say('camp: "%s"', name)
    elseif sub == 'add' or sub == 'remove' then
        local name = rest:lower()
        if name == '' then
            say('usage: //wp pull %s <mob name>', sub)
            return
        end
        local names, list = pull_names() or {}, {}
        names[name] = sub == 'add' or nil
        for n in pairs(names) do list[#list + 1] = n end
        table.sort(list)
        p.names = table.concat(list, ',')
        config.save(settings)
        say('pull targets: %s', p.names ~= '' and p.names or 'any monster')
    elseif sub == 'clear' then
        p.names = ''
        config.save(settings)
        say('pull targets: any monster')
    elseif sub == 'action' then
        local which = (...)
        which = which and which:lower()
        if PULL_ACTIONS[which] then
            p.action = which
        elseif which == 'custom' and select(2, ...) then
            local args = {...}
            local range = tonumber(args[#args])
            if not range then
                say('usage: //wp pull action custom <command> <range>')
                return
            end
            p.action, p.range = 'custom', range
            p.command = table.concat(args, ' ', 2, #args - 1)
        else
            say('usage: //wp pull action ra|provoke|dia|melee, or custom <command> <range>')
            return
        end
        config.save(settings)
        local a = pull_action()
        say('pull action: %s (range %.1f)', a.command, a.range)
    elseif sub == 'radius' then
        local n = tonumber(rest)
        if not n or n <= 0 then
            say('usage: //wp pull radius <yalms>')
            return
        end
        p.radius = n
        config.save(settings)
        say('pull radius: %.0f yalms by the routes', n)
    else
        local a = pull_action()
        say('pull: %s; camp "%s"; targets %s; %s (range %.1f); radius %.0f', state.pull and state.pull.state or 'off',
            p.camp, p.names ~= '' and p.names or 'any monster', a.command, a.range, p.radius)
    end
end

function commands.info()
    local g = state.graph
    if not g then
        return
    end
    local ends = 0
    for id in pairs(g.nodes) do
        if g:degree(id) <= 1 then ends = ends + 1 end
    end
    say('%s (%d): %d nodes, %d edges, %d dead ends, %d marks%s', zone_name(g.zone), g.zone,
        g.count, g:edge_count(), ends, #sorted_marks(), state.dirty and ' (unsaved)' or '')
end

function commands.save()
    if state.read_only then
        say('not saved: this zone\'s file is unreadable (fix or remove it, then //wp reload)')
        return
    end
    state.dirty = true
    save()
    if not state.dirty then
        say('saved')
    end
end

function commands.reload()
    if state.rec or state.nav then
        say('stop first (//wp stop)')
        return
    end
    enter_zone(state.zone)
    say('reloaded %s', zone_name(state.zone))
end

function commands.clear(confirm)
    if confirm ~= 'confirm' then
        say('this deletes every node and mark in %s; type //wp clear confirm', zone_name(state.zone))
        return
    end
    if state.rec or state.nav then
        say('stop first (//wp stop)')
        return
    end
    state.graph = graph.new(state.zone)
    state.dirty = true
    save()
    say('cleared %s', zone_name(state.zone))
end

function commands.doors(arg)
    if arg == 'on' or arg == 'off' then
        settings.doors.enabled = arg == 'on'
        config.save(settings)
    end
    local n = 0
    for _ in pairs(state.graph.doors) do n = n + 1 end
    say('door opening while walking: %s; %d recorded doors in this zone',
        settings.doors.enabled and 'on' or 'off', n)
end

function commands.blocked()
    local blocks, n = active_blocks(), 0
    for key in pairs(blocks) do
        n = n + 1
        local a, b = key:match('(%d+):(%d+)')
        say('  blocked: points %s-%s for %d more minutes', a, b,
            math.ceil((state.blocked[key] - os.time()) / 60))
    end
    if n == 0 then
        say('no blocked paths')
    end
end

function commands.unblock()
    state.blocked = {}
    say('cleared blocked paths')
end

function commands.show()
    settings.show = true
    config.save(settings)
end

function commands.hide()
    settings.show = false
    config.save(settings)
    overlay:hide()
end

function commands.help()
    for _, line in ipairs({
        '//wp rec | stop | undo         record by walking; undo the last step',
        '//wp mark <name> | unmark <name> | marks',
        '//wp route <name>              show the shortest recorded path',
        '//wp go <name>                 walk there (//wp stop or Escape stops)',
        '//wp doors [on|off]            open closed doors on the way',
        '//wp pull camp <mark> | add <mob> | remove <mob> | clear | radius <yalms>',
        '//wp pull action ra|provoke|dia|melee | custom <command> <range>',
        '//wp pull on | off             pull to the camp along the routes',
        '//wp blocked | unblock         paths found blocked while walking (kept 10 min)',
        '//wp info | save | reload | clear confirm | show | hide',
    }) do
        say(line)
    end
end

-- Events ------------------------------------------------------------------------------------

windower.register_event('addon command', function(cmd, ...)
    cmd = (cmd or 'help'):lower()
    if not state.graph and cmd ~= 'help' then
        say('not logged in')
        return
    end
    local f = commands[cmd]
    if f then
        f(...)
    else
        say('unknown command "%s" (//wp help)', cmd)
    end
end)

windower.register_event('prerender', function()
    local now = os.clock()
    if now - state.last_tick < TICK then
        return
    end
    state.last_tick = now
    if state.graph then
        tick()
    end
    update_overlay()
end)

windower.register_event('zone change', function(new_id)
    if state.rec then
        stop_recording()
    end
    stop_pulling(state.pull and 'zoned' or nil)
    stop_nav(state.nav and 'zoned' or nil)
    state.blocked, state.door_last = {}, {}
    save()
    -- Also fires on login and logout; only load a graph for a real zone.
    if new_id and new_id ~= 0 and windower.ffxi.get_info().logged_in then
        enter_zone(new_id)
    else
        state.graph, state.zone = nil, nil
    end
end)

-- Aggro for the puller: a monster acting on the party, or the party acting on a monster.
windower.register_event('action', function(act)
    if not state.pull or not act or not act.actor_id then
        return
    end
    local ids = {}
    for _, t in ipairs(act.targets or {}) do
        ids[#ids + 1] = t.id
    end
    local function monster(id)
        local m = windower.ffxi.get_mob_by_id(id)
        return m ~= nil and m.spawn_type == 16
    end
    state.pull:on_action(act.actor_id, ids, monster(act.actor_id), party_ids(), monster)
end)

-- While recording, a door you open by hand is remembered for this zone, so it is opened
-- when walking even if its name would otherwise be skipped.
windower.register_event('outgoing chunk', function(id, original, modified, injected)
    if id ~= 0x01A or injected or not state.rec then
        return
    end
    local p = packets.parse('outgoing', original)
    if not p or p['Category'] ~= 0 then
        return
    end
    local mob = windower.ffxi.get_mob_by_index(p['Target Index'])
    if mob and mob.id == p['Target'] and mob.spawn_type == doors.SPAWN_TYPE
        and not state.graph.doors[mob.id] then
        state.graph.doors[mob.id] = mob.index
        state.dirty = true
        say('recorded door: %s', mob.name ~= '' and mob.name or ('#' .. mob.index))
    end
end)

windower.register_event('keyboard', function(dik, pressed)
    if pressed and dik == DIK_ESCAPE then
        if state.pull then
            stop_pulling('Escape')
        elseif state.nav then
            stop_nav('Escape')
        end
    end
end)

windower.register_event('logout', function()
    stop_pulling()
    if state.rec then stop_recording() end
    stop_nav()
    save()
    state.graph, state.zone = nil, nil
end)

windower.register_event('login', function()
    local info = windower.ffxi.get_info()
    if info and info.zone then
        enter_zone(info.zone)
    end
end)

windower.register_event('load', function()
    local info = windower.ffxi.get_info()
    if info and info.logged_in then
        enter_zone(info.zone)
    end
end)

windower.register_event('unload', function()
    stop_pulling()
    if state.nav then
        windower.ffxi.run(false)
    end
    if state.rec then stop_recording() end
    save()
end)
