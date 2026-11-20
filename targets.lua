--[[
    Which mob to pull: the one nearest the camp by the recorded routes, not in a straight
    line. A mob behind a wall is near in a straight line and far by the routes.

    A mob is a candidate when it is:
      - a monster (spawn type 16) that is alive and targetable,
      - unclaimed, or claimed by the party,
      - on the name list (when there is one) and not being skipped,
      - within `snap` yalms of a recorded node on its floor (height within `max_dz`),
      - and within `max_route` yalms of the camp along the routes.

    Pure: the graph, the mob list and the options are passed in (tests/run.lua).
]]

local graph = require('graph')

local targets = {}

targets.MONSTER = 16

-- Shared by the puller: is this mob still worth fighting at all?
function targets.alive(m)
    return m ~= nil and m.valid_target ~= false and (m.hpp or 0) > 0 and m.status ~= 2 and m.status ~= 3
end

-- Claimed by someone outside the party.
function targets.taken(m, party)
    local c = m.claim_id or 0
    return c ~= 0 and not party[c]
end

local function wanted(m, opts, now)
    if m.spawn_type ~= targets.MONSTER or not targets.alive(m) or targets.taken(m, opts.party or {}) then
        return false
    end
    if opts.names and next(opts.names) and not opts.names[(m.name or ''):lower()] then
        return false
    end
    local skip = opts.skip and opts.skip[m.id]
    return not (skip and skip > (now or 0))
end

--[[ Picks the next mob.
     g          the zone graph
     camp       the camp node id
     mobs       an array or map of mob tables (Windower's get_mob_array)
     opts = {names = {['name'] = true}, party = {[id] = true}, skip = {[id] = until},
             snap = 10, max_dz = 4, max_route = 40, blocked = {edge keys}}
     now        for the skip list
   Returns {mob = , node = , route = yalms by the routes from camp to the mob} or nil. ]]
function targets.pick(g, camp, mobs, opts, now)
    if not g.nodes[camp] then
        return nil
    end
    local max_route = opts.max_route or 40
    local dist = g:distances(camp, max_route, opts.blocked)
    local snap, max_dz = opts.snap or 10, opts.max_dz or 4
    local best
    for _, m in pairs(mobs) do
        if type(m) == 'table' and m.x and wanted(m, opts, now) then
            -- The best way in: the reachable node near the mob with the shortest route plus
            -- step off (not simply the nearest node, which may be the long way round).
            for node, d in pairs(dist) do
                local n = g.nodes[node]
                if math.abs(n.z - (m.z or 0)) <= max_dz then
                    local off = graph.dist2d(n, m)
                    if off <= snap and d + off <= max_route and (not best or d + off < best.route) then
                        best = {mob = m, node = node, route = d + off}
                    end
                end
            end
        end
    end
    return best
end

-- The node to walk to for a mob that may have moved: nearest recorded node to it.
function targets.node_for(g, mob, opts)
    return g:nearest(mob, opts.snap or 10, opts.max_dz or 4)
end

targets.dist2d = graph.dist2d

return targets
