--[[
    Waypoint graph for one zone: nodes (x, y, z), undirected edges, named marks,
    nearest-node lookup, A* search and a plain-Lua serializer.

    No Windower dependencies, so it can be tested outside the game (tests/run.lua).

    Coordinates follow Windower's mob tables: x and y are the ground plane, z is height.
]]

local graph = {}
graph.__index = graph

local sqrt, huge, floor = math.sqrt, math.huge, math.floor

function graph.new(zone)
    return setmetatable({
        zone = zone,
        nodes = {},     -- id -> {x = , y = , z = }
        edges = {},     -- id -> {[neighbour id] = true}
        marks = {},     -- name -> id
        doors = {},     -- door entity id -> entity index (doors opened while recording)
        next_id = 1,
        count = 0,
    }, graph)
end

local function dist2d(a, b)
    local dx, dy = a.x - b.x, a.y - b.y
    return sqrt(dx * dx + dy * dy)
end

local function dist3d(a, b)
    local dx, dy, dz = a.x - b.x, a.y - b.y, a.z - b.z
    return sqrt(dx * dx + dy * dy + dz * dz)
end

graph.dist2d = dist2d
graph.dist3d = dist3d

local function round(v)
    return floor(v * 100 + 0.5) / 100
end

-- Nodes and edges ---------------------------------------------------------------------------

function graph:add_node(x, y, z)
    local id = self.next_id
    self.next_id = id + 1
    self.nodes[id] = {x = round(x), y = round(y), z = round(z)}
    self.edges[id] = {}
    self.count = self.count + 1
    return id
end

function graph:link(a, b)
    if a == b or not self.nodes[a] or not self.nodes[b] then
        return false
    end
    self.edges[a][b] = true
    self.edges[b][a] = true
    return true
end

function graph:unlink(a, b)
    if self.edges[a] then self.edges[a][b] = nil end
    if self.edges[b] then self.edges[b][a] = nil end
end

function graph:remove_node(id)
    if not self.nodes[id] then
        return false
    end
    for n in pairs(self.edges[id]) do
        self.edges[n][id] = nil
    end
    self.nodes[id] = nil
    self.edges[id] = nil
    self.count = self.count - 1
    for name, mid in pairs(self.marks) do
        if mid == id then
            self.marks[name] = nil
        end
    end
    return true
end

function graph:degree(id)
    local n = 0
    for _ in pairs(self.edges[id] or {}) do
        n = n + 1
    end
    return n
end

function graph:edge_count()
    local n = 0
    for _, e in pairs(self.edges) do
        for _ in pairs(e) do
            n = n + 1
        end
    end
    return n / 2
end

-- Nearest node to a position within `radius` (2D) whose height differs by at most
-- `max_dz`. `exclude` is an optional set of ids to skip. Returns id, distance.
function graph:nearest(pos, radius, max_dz, exclude)
    local best, best_d = nil, radius or huge
    max_dz = max_dz or huge
    for id, n in pairs(self.nodes) do
        if not (exclude and exclude[id]) and math.abs(n.z - pos.z) <= max_dz then
            local d = dist2d(n, pos)
            if d < best_d then
                best, best_d = id, d
            end
        end
    end
    return best, best and best_d or nil
end

-- A* ----------------------------------------------------------------------------------------

-- Minimal binary heap keyed on f-score.
local function heap_push(h, id, f)
    h.n = h.n + 1
    local i = h.n
    h.ids[i], h.f[i] = id, f
    while i > 1 do
        local p = floor(i / 2)
        if h.f[p] <= h.f[i] then break end
        h.ids[p], h.ids[i] = h.ids[i], h.ids[p]
        h.f[p], h.f[i] = h.f[i], h.f[p]
        i = p
    end
end

local function heap_pop(h)
    if h.n == 0 then return nil end
    local top = h.ids[1]
    h.ids[1], h.f[1] = h.ids[h.n], h.f[h.n]
    h.ids[h.n], h.f[h.n] = nil, nil
    h.n = h.n - 1
    local i = 1
    while true do
        local l, r, s = i * 2, i * 2 + 1, i
        if l <= h.n and h.f[l] < h.f[s] then s = l end
        if r <= h.n and h.f[r] < h.f[s] then s = r end
        if s == i then break end
        h.ids[s], h.ids[i] = h.ids[i], h.ids[s]
        h.f[s], h.f[i] = h.f[i], h.f[s]
        i = s
    end
    return top
end

-- Key for an undirected edge, used in `blocked` sets.
function graph.edge_key(a, b)
    if a > b then a, b = b, a end
    return a .. ':' .. b
end

-- Shortest path between two node ids. Returns a list of ids (start..goal) and its length,
-- or nil when the goal can't be reached. `blocked` is an optional set of edge keys to avoid.
function graph:find_path(start, goal, blocked)
    local nodes, edges = self.nodes, self.edges
    if not nodes[start] or not nodes[goal] then
        return nil
    end
    local goal_node = nodes[goal]
    local g, came, closed = {[start] = 0}, {}, {}
    local open = {ids = {}, f = {}, n = 0}
    heap_push(open, start, dist3d(nodes[start], goal_node))

    while open.n > 0 do
        local current = heap_pop(open)
        if current == goal then
            local path = {goal}
            while came[path[1]] do
                table.insert(path, 1, came[path[1]])
            end
            return path, g[goal]
        end
        if not closed[current] then
            closed[current] = true
            local cn = nodes[current]
            for nb in pairs(edges[current]) do
                if not closed[nb] and not (blocked and blocked[graph.edge_key(current, nb)]) then
                    local tentative = g[current] + dist3d(cn, nodes[nb])
                    if tentative < (g[nb] or huge) then
                        g[nb] = tentative
                        came[nb] = current
                        heap_push(open, nb, tentative + dist3d(nodes[nb], goal_node))
                    end
                end
            end
        end
    end
    return nil
end

-- Route distance from `start` to every node within `max_len` (Dijkstra, stopping at
-- `max_len`). Returns id -> distance. Used to measure "how far by the routes" for many
-- places at once (the puller's candidate mobs). `blocked` as in find_path.
function graph:distances(start, max_len, blocked)
    local nodes, edges = self.nodes, self.edges
    if not nodes[start] then
        return {}
    end
    max_len = max_len or huge
    local dist, done = {[start] = 0}, {}
    local open = {ids = {}, f = {}, n = 0}
    heap_push(open, start, 0)
    while open.n > 0 do
        local current = heap_pop(open)
        if not done[current] then
            done[current] = true
            local cn = nodes[current]
            for nb in pairs(edges[current]) do
                if not done[nb] and not (blocked and blocked[graph.edge_key(current, nb)]) then
                    local d = dist[current] + dist3d(cn, nodes[nb])
                    if d <= max_len and d < (dist[nb] or huge) then
                        dist[nb] = d
                        heap_push(open, nb, d)
                    end
                end
            end
        end
    end
    return dist
end

-- Serialization -----------------------------------------------------------------------------

local function fmt(v)
    return string.format('%.2f', v)
end

-- A Lua chunk that returns a plain table; readable and diffable.
function graph:serialize()
    local out = {'-- waypoints graph, zone ' .. tostring(self.zone) .. '\nreturn {\n'}
    out[#out + 1] = '    version = 1,\n    zone = ' .. tostring(self.zone) .. ',\n'
    out[#out + 1] = '    next_id = ' .. self.next_id .. ',\n    nodes = {\n'
    local ids = {}
    for id in pairs(self.nodes) do ids[#ids + 1] = id end
    table.sort(ids)
    for _, id in ipairs(ids) do
        local n = self.nodes[id]
        out[#out + 1] = string.format('        {%d, %s, %s, %s},\n', id, fmt(n.x), fmt(n.y), fmt(n.z))
    end
    out[#out + 1] = '    },\n    edges = {\n'
    for _, id in ipairs(ids) do
        local nbs = {}
        for nb in pairs(self.edges[id]) do
            if nb > id then nbs[#nbs + 1] = nb end
        end
        table.sort(nbs)
        for _, nb in ipairs(nbs) do
            out[#out + 1] = string.format('        {%d, %d},\n', id, nb)
        end
    end
    out[#out + 1] = '    },\n    marks = {\n'
    local names = {}
    for name in pairs(self.marks) do names[#names + 1] = name end
    table.sort(names)
    for _, name in ipairs(names) do
        out[#out + 1] = string.format('        [%q] = %d,\n', name, self.marks[name])
    end
    out[#out + 1] = '    },\n    doors = {\n'
    local door_ids = {}
    for id in pairs(self.doors) do door_ids[#door_ids + 1] = id end
    table.sort(door_ids)
    for _, id in ipairs(door_ids) do
        out[#out + 1] = string.format('        [%d] = %d,\n', id, self.doors[id])
    end
    out[#out + 1] = '    },\n}\n'
    return table.concat(out)
end

-- Builds a graph from the table a serialized chunk returns. Bad entries are skipped.
function graph.from_table(t, zone)
    local g = graph.new(t.zone or zone)
    local max_id = 0
    for _, n in ipairs(t.nodes or {}) do
        local id, x, y, z = n[1], n[2], n[3], n[4]
        if type(id) == 'number' and type(x) == 'number' and type(y) == 'number' and type(z) == 'number' then
            g.nodes[id] = {x = x, y = y, z = z}
            g.edges[id] = {}
            g.count = g.count + 1
            if id > max_id then max_id = id end
        end
    end
    for _, e in ipairs(t.edges or {}) do
        g:link(e[1], e[2])
    end
    for name, id in pairs(t.marks or {}) do
        if g.nodes[id] then g.marks[name] = id end
    end
    for id, index in pairs(t.doors or {}) do
        if type(id) == 'number' and type(index) == 'number' then g.doors[id] = index end
    end
    g.next_id = math.max(t.next_id or 1, max_id + 1)
    return g
end

return graph
