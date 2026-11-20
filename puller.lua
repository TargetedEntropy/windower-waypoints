--[[
    Pulling from a camp along the recorded routes.

      camp ──pick──▶ approach ──in range──▶ pulling ──claimed──▶ returning ──at camp──▶ fighting
        ▲                │ mob moved: re-plan     │ no claim: retry, then skip      │
        └────────────────┴── lost / taken / dead ─┴──────── no more mobs + loot pause ┘

    - The target is the mob nearest the camp by the routes (targets.lua). The walk out
      follows the routes to the node nearest the mob, then closes in in a straight line.
    - Anything that aggroes the party is fought first, and nothing new is pulled while it is.
    - The fight itself is left to the player (or GearSwap, Trust in assist mode, ...): the
      puller engages at camp and waits until every aggroed mob is dead.
    - It stops on death, low HP, too many mobs, time or pull limits, or when it can't get
      back to camp.

    Pure: the world comes in through tick(now, view), and everything goes out through `io`:
      io.walk(node) -> ok, why     walk the routes to a node; report with on_walk()
      io.halt()                    stop walking and steering
      io.steer(mob)                one step straight toward a mob (off the routes)
      io.pull(mob)                 face it and use the pull action
      io.engage(mob), io.disengage()
      io.say(text)
    view = {g = graph, pos = {x, y, z}, status = n, hpp = n, me = id, party = {[id] = true},
            mobs = get_mob_array()}
]]

local targets = require('targets')

local puller = {}
puller.__index = puller

local dist2d = targets.dist2d

puller.defaults = {
    range = 17.0,        -- pull action range (yalms)
    engages = false,     -- the pull action engages (melee): disengage before running back
    snap = 10.0,         -- a mob must be this close to a recorded node
    max_dz = 4.0,
    max_route = 40.0,    -- how far from camp to pull, along the routes
    replan = 6.0,        -- re-plan the walk when the mob moves this far
    steer_max = 8.0,     -- seconds to close in off the routes before giving up on a mob
    approach_max = 60.0, -- seconds from leaving camp to pulling
    claim_wait = 4.0,    -- seconds for a pull to claim
    pull_tries = 2,
    skip_seconds = 60,   -- a mob that couldn't be pulled is left alone this long
    camp_radius = 3.0,   -- "at camp"
    engage_range = 6.0,  -- engage once the mob is this close at camp
    fetch_after = 10.0,  -- seconds to wait at camp for it before going to meet it
    fight_max = 180.0,
    max_aggro = 2,       -- more than this many at once: stop
    min_hp = 40,         -- stop below this HP%
    max_pulls = 50,
    max_minutes = 60,
    loot_pause = {3.0, 6.0},
    pick_every = 3.0,
}

function puller.new(io, opts, rng)
    local self = setmetatable({io = io, rng = rng or math.random, state = 'off', aggro = {}, skip = {},
                               pulls = 0, kills = 0}, puller)
    self.o = {}
    for k, v in pairs(puller.defaults) do self.o[k] = v end
    for k, v in pairs(opts or {}) do self.o[k] = v end
    return self
end

function puller:uniform(a, b)
    return a + (b - a) * self.rng()
end

function puller:running()
    return self.state ~= 'off'
end

-- names: {['mob name'] = true} or nil for any monster.
function puller:start(camp, names, now)
    self.camp, self.names, self.started = camp, names, now
    self.pulls, self.kills, self.aggro, self.skip = 0, 0, {}, {}
    self.target, self.walking, self.said_none = nil, false, false
    self:_to('returning', now)       -- go to camp first (a no-op if already there)
end

function puller:stop()
    if self.state ~= 'off' then
        self.io.halt()
    end
    self.state, self.target, self.walking = 'off', nil, false
end

function puller:_to(state, now)
    self.state, self.since, self.sent, self.due = state, now, nil, nil
    self.steer_since, self.engage_at, self.disengaged = nil, nil, nil
end

-- The host reports the end of a walk: 'arrived', or 'failed' with a reason.
function puller:on_walk(result, reason, now)
    self.walking = false
    self.walk_result, self.walk_reason = result, reason
end

-- A 0x028 action: a monster acting on the party, or the party acting on a monster, means
-- that monster is in the fight.
function puller:on_action(actor, target_ids, actor_is_monster, party, monster)
    if self.state == 'off' then return end
    if actor_is_monster then
        for _, t in ipairs(target_ids) do
            if party[t] then self.aggro[actor] = true return end
        end
    elseif party[actor] then
        for _, t in ipairs(target_ids) do
            if monster(t) then self.aggro[t] = true end
        end
    end
end

function puller:aggro_count()
    local n = 0
    for _ in pairs(self.aggro) do n = n + 1 end
    return n
end

local function index_mobs(mobs)
    local by_id = {}
    for _, m in pairs(mobs or {}) do
        if type(m) == 'table' and m.id then by_id[m.id] = m end
    end
    return by_id
end

function puller:_walk(node, now)
    local ok, why = self.io.walk(node)
    self.walking, self.walk_result = ok and true or false, nil
    self.walk_node = node
    return ok, why
end

function puller:_skip(mob, now, why)
    self.skip[mob.id] = now + self.o.skip_seconds
    self.io.say(('skipping %s for %ds: %s'):format(mob.name or '?', self.o.skip_seconds, why))
end

-- Back to camp, forgetting the target.
function puller:_give_up(now)
    self.io.halt()
    self.target, self.walking = nil, false
    self:_to('returning', now)
end

-- The nearest living aggroed mob (or the pulled one while it's still ours).
function puller:_fight_target(view, by_id)
    local t = self.target and by_id[self.target.id]
    if t and targets.alive(t) and not targets.taken(t, view.party) then return t end
    local best, bd
    for id in pairs(self.aggro) do
        local m = by_id[id]
        if m and targets.alive(m) then
            local d = dist2d(view.pos, m)
            if not bd or d < bd then best, bd = m, d end
        end
    end
    return best
end

function puller:tick(now, view)
    if self.state == 'off' then return nil end
    local o, g = self.o, view.g
    local by_id = index_mobs(view.mobs)

    -- Forget dead or vanished aggro.
    for id in pairs(self.aggro) do
        local m = by_id[id]
        if not m or not targets.alive(m) then
            self.aggro[id] = nil
            if self.target and self.target.id == id and m then self.kills = self.kills + 1 end
        end
    end

    -- Stops that apply everywhere.
    local why
    if view.status == 2 or view.status == 3 then why = 'you died'
    elseif (view.hpp or 100) < o.min_hp then why = ('HP %d%% (below %d%%)'):format(view.hpp, o.min_hp)
    elseif self:aggro_count() > o.max_aggro then why = ('%d mobs on you'):format(self:aggro_count())
    elseif (now - self.started) / 60 >= o.max_minutes then why = 'time limit reached'
    end
    if why then
        self:stop()
        return {stop = why}
    end

    local camp = g.nodes[self.camp]
    if not camp then
        self:stop()
        return {stop = 'the camp mark is gone'}
    end
    local at_camp = dist2d(view.pos, camp) <= o.camp_radius
    local s = self.state

    if s == 'camp' then
        if next(self.aggro) then self:_to('fighting', now) return nil end
        if not at_camp then self:_to('returning', now) return nil end
        if self.pulls >= o.max_pulls then
            self:stop()
            return {stop = ('%d pulls done'):format(self.pulls)}
        end
        if now < (self.due or 0) then return nil end
        local pick = targets.pick(g, self.camp, view.mobs, {names = self.names, party = view.party,
            skip = self.skip, snap = o.snap, max_dz = o.max_dz, max_route = o.max_route, blocked = view.blocked}, now)
        if not pick then
            if not self.said_none then
                self.io.say('nothing to pull right now; checking again')
                self.said_none = true
            end
            self.due = now + o.pick_every
            return nil
        end
        self.said_none = false
        self.target = {id = pick.mob.id, name = pick.mob.name, node = pick.node, at = {x = pick.mob.x, y = pick.mob.y}}
        self.walk_result = nil
        self.io.say(('pulling %s (%.0f yalms by the routes)'):format(pick.mob.name or '?', pick.route))
        self:_to('approach', now)
        if dist2d(view.pos, pick.mob) > o.range then
            local ok, err = self:_walk(pick.node, now)
            if not ok then
                self:_skip(pick.mob, now, err or 'no route')
                self:_give_up(now)
            end
        end
        return nil

    elseif s == 'approach' then
        local m = by_id[self.target.id]
        if not m or not targets.alive(m) or targets.taken(m, view.party) then
            self.io.say(('%s is gone or taken'):format(self.target.name or '?'))
            self:_give_up(now)
            return nil
        end
        if next(self.aggro) then
            -- Something found us on the way (maybe the target itself): fight it.
            self.io.halt()
            self.walking = false
            self:_to('returning', now)
            return nil
        end
        if now - self.since > o.approach_max then
            self:_skip(m, now, 'took too long to reach')
            self:_give_up(now)
            return nil
        end
        local d = dist2d(view.pos, m)
        if d <= o.range and math.abs((m.z or 0) - (view.pos.z or 0)) <= o.max_dz then
            self.io.halt()
            self.walking = false
            self:_to('pulling', now)
            self.due = now + self:uniform(0.3, 0.9)
            return nil
        end
        if self.walking then
            -- Follow a wandering mob: re-plan when it has moved well away from where it was.
            if dist2d(m, self.target.at) > o.replan then
                self.target.at = {x = m.x, y = m.y}
                local node = targets.node_for(g, m, o)
                if node and node ~= self.target.node then
                    self.target.node = node
                    local ok = self:_walk(node, now)
                    if not ok then
                        self:_skip(m, now, 'no route to it')
                        self:_give_up(now)
                    end
                end
            end
            return nil
        end
        if self.walk_result == 'failed' then
            self:_skip(m, now, self.walk_reason or 'walk failed')
            self:_give_up(now)
            return nil
        end
        -- Off the end of the routes: straight at it, briefly.
        self.steer_since = self.steer_since or now
        if now - self.steer_since > o.steer_max then
            self:_skip(m, now, 'could not get in range')
            self:_give_up(now)
            return nil
        end
        self.io.steer(m)
        return nil

    elseif s == 'pulling' then
        local m = by_id[self.target.id]
        if not m or not targets.alive(m) or targets.taken(m, view.party) then
            self.io.say(('%s is gone or taken'):format(self.target.name or '?'))
            self:_give_up(now)
            return nil
        end
        local c = m.claim_id or 0
        if (c ~= 0 and view.party[c]) or self.aggro[m.id] then
            self.aggro[m.id] = true
            self.pulls = self.pulls + 1
            self:_to('returning', now)
            return nil
        end
        if not self.sent then
            if now >= self.due then
                self.io.pull(m)
                self.sent, self.tries = now, (self.tries or 0) + 1
            end
        elseif now - self.sent > o.claim_wait then
            if self.tries < o.pull_tries then
                self.sent, self.due = nil, now + self:uniform(0.3, 0.8)
            else
                self.tries = nil
                self:_skip(m, now, 'the pull did not claim it')
                self:_give_up(now)
            end
        end
        return nil

    elseif s == 'returning' then
        if view.status == 1 then
            -- A melee pull engages: let go so the walk can run (the mob follows).
            if o.engages and not self.disengaged then
                self.io.disengage()
                self.disengaged = now
            elseif not o.engages or now - self.disengaged > 5 then
                self:_to('fighting', now)        -- engaged by something else: fight here
            end
            return nil
        end
        if at_camp then
            self.io.halt()
            self.walking = false
            if next(self.aggro) or self:_fight_target(view, by_id) then
                self:_to('fighting', now)
            else
                self:_to('camp', now)
                self.due = now + self:uniform(1.0, 2.5)
            end
            return nil
        end
        if self.walking then return nil end
        if self.walk_result == 'failed' then
            if next(self.aggro) then self:_to('fighting', now) return nil end
            local r = self.walk_reason
            self:stop()
            return {stop = 'could not get back to camp' .. (r and (': ' .. r) or '')}
        end
        if self.walk_result == 'arrived' and self.walk_node == self.camp then
            -- Arrived but outside camp_radius (the route ends a little off): close enough.
            self.walk_result = nil
            self:_to('camp', now)
            return nil
        end
        local ok, err = self:_walk(self.camp, now)
        if not ok then
            self:stop()
            return {stop = 'no route back to camp' .. (err and (': ' .. err) or '')}
        end
        return nil

    elseif s == 'fighting' then
        local m = self:_fight_target(view, by_id)
        if not m then
            if self.target then
                self.io.say(('%s defeated (%d pulls)'):format(self.target.name or 'target', self.pulls))
            end
            self.target = nil
            self:_to(at_camp and 'camp' or 'returning', now)
            self.due = now + self:uniform(o.loot_pause[1], o.loot_pause[2])
            return nil
        end
        if now - self.since > o.fight_max then
            self:stop()
            return {stop = ('fight with %s went over %ds'):format(m.name or '?', o.fight_max)}
        end
        if view.status == 1 then
            self.io.halt()
            self.steer_since = nil
            return nil
        end
        local d = dist2d(view.pos, m)
        if d <= o.engage_range then
            self.io.halt()
            if not self.engage_at or now - self.engage_at > 3 then
                self.io.engage(m)
                self.engage_at = now
            end
        elseif now - self.since > o.fetch_after then
            self.io.steer(m)             -- it isn't coming: go and meet it
        end
        return nil
    end
    return nil
end

return puller
