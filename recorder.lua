--[[
    Turns a stream of player positions into graph nodes and edges.

    - A node is dropped every `spacing` yalms, or sooner (after `corner_min`) when the
      direction of travel turns by more than `corner_angle` degrees.
    - When the player comes within `merge_radius` of an existing node (same floor: height
      within `max_dz`), the recorder links to that node instead of adding a new one. Walking
      over an earlier route reuses its nodes, and crossing it makes a junction.
    - A jump of more than `jump` yalms between samples (warp, zoning, Home Point) breaks the
      chain, so no edge is drawn across it.

    No Windower dependencies (tests/run.lua drives it with fake positions).
]]

local graph = require('graph')

local recorder = {}
recorder.__index = recorder

local defaults = {
    spacing = 3.0,
    corner_min = 1.5,
    corner_angle = 35,
    merge_radius = 2.0,
    max_dz = 3.0,
    jump = 20.0,
}

function recorder.new(g, opts)
    opts = opts or {}
    local self = setmetatable({graph = g, last = nil, prev = nil, history = {}, added = 0}, recorder)
    for k, v in pairs(defaults) do
        self[k] = opts[k] or v
    end
    self.corner_cos = math.cos(math.rad(self.corner_angle))
    return self
end

-- Ids that must not be snapped to from the current node: itself, its neighbours and the
-- last few steps, so the recorder doesn't link back to where it just came from.
local RECENT = 6

function recorder:_exclude()
    local ex = {}
    for i = math.max(1, #self.history - RECENT + 1), #self.history do
        ex[self.history[i].id] = true
    end
    if self.last then
        ex[self.last] = true
        for nb in pairs(self.graph.edges[self.last] or {}) do
            ex[nb] = true
        end
    end
    return ex
end

-- Moves the chain to node `id`, linking from the previous node. Records the step for undo.
function recorder:_step_to(id, created)
    local from = self.last
    local linked = false
    if from and from ~= id and not self.graph.edges[from][id] then
        linked = self.graph:link(from, id)
    end
    self.history[#self.history + 1] = {id = id, from = from, prev = self.prev, created = created, linked = linked}
    self.prev, self.last = from, id
    if created then self.added = self.added + 1 end
end

-- Starts (or restarts after a break) at `pos`: snaps to a nearby node or creates one.
function recorder:_anchor(pos)
    local near = self.graph:nearest(pos, self.merge_radius, self.max_dz)
    self.last, self.prev = nil, nil
    if near then
        self:_step_to(near, false)
    else
        self:_step_to(self.graph:add_node(pos.x, pos.y, pos.z), true)
    end
end

function recorder:start(pos)
    self:_anchor(pos)
end

-- Feeds one position. Returns "add", "merge", "break" or nil (nothing changed).
function recorder:sample(pos)
    local g = self.graph
    local last = self.last and g.nodes[self.last]
    if not last then
        self:_anchor(pos)
        return 'add'
    end

    local d = graph.dist2d(pos, last)
    if d > self.jump or math.abs(pos.z - last.z) > self.jump then
        self:_anchor(pos)
        return 'break'
    end

    -- Snap to an existing node we've walked onto (other than where we came from).
    local near = g:nearest(pos, self.merge_radius, self.max_dz, self:_exclude())
    if near then
        self:_step_to(near, false)
        return 'merge'
    end

    if d < self.corner_min then
        return nil
    end

    local drop = d >= self.spacing
    if not drop and self.prev and g.nodes[self.prev] then
        -- Corner: compare the last segment's direction with the direction since it.
        local p = g.nodes[self.prev]
        local ax, ay = last.x - p.x, last.y - p.y
        local bx, by = pos.x - last.x, pos.y - last.y
        local la, lb = math.sqrt(ax * ax + ay * ay), math.sqrt(bx * bx + by * by)
        if la > 0 and lb > 0 and (ax * bx + ay * by) / (la * lb) < self.corner_cos then
            drop = true
        end
    end

    if drop then
        self:_step_to(g:add_node(pos.x, pos.y, pos.z), true)
        return 'add'
    end
    return nil
end

-- Reverts the most recent step. Returns false when there's nothing to undo.
function recorder:undo()
    local h = table.remove(self.history)
    if not h then
        return false
    end
    if h.created then
        self.graph:remove_node(h.id)
        self.added = self.added - 1
    elseif h.linked then
        self.graph:unlink(h.from, h.id)
    end
    self.last, self.prev = h.from, h.prev
    return true
end

return recorder
