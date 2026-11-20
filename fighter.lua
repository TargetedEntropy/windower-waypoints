--[[
    The fight and the time between fights, for the puller.

    In a fight (fight(), while engaged on the puller's target), in priority order:
      1. heal: the first `heals` entry whose HP% threshold you're under and that's ready
      2. range: run in to melee reach; face the mob when you're turned away
      3. open: each `open` ability once per fight
      4. buffs marked for fights (job abilities by default), when their buff is missing
      5. weaponskill at `weaponskill.tp`

    At camp (prepare(), before each pull), in order; returns true when ready to pull:
      1. food when the Food buff is gone
      2. EXP/CP ring when its buff is gone: equip, wait out the equip delay, use
      3. Trust NPCs that aren't in the party
      4. buffs for camp (spells and items by default)
      5. rest (/heal) below `rest.hpp` / `rest.mpp`, until `rest.until_hpp` / `until_mpp`

    Nothing is sent while a spell or item is in progress, and commands are spaced like a
    player's. Anything that fails (no claim of the buff after use, a Trust that doesn't
    join) is retried a little later, then left for a while.

    Pure: the world comes in through `view`, everything goes out through `io`:
      io.use(kind, name, target)   kind 'ja' | 'ma' | 'ws' | 'item'; target a mob or 'me'
      io.steer(mob), io.halt(), io.face(mob), io.rest(on), io.equip(slot, name), io.say(text)
    view = {pos, facing, status, hpp, mpp, max_mp, tp, buffs = {['name'] = true},
            can = function(kind, name) -> ok, {cast = seconds}, count = function(item) -> n,
            trust_party = {['trust name'] = true}, party_size = n}
]]

local fighter = {}
fighter.__index = fighter

local sqrt, atan2, abs, pi = math.sqrt, math.atan2, math.abs, math.pi

fighter.KINDS = {ja = true, ma = true, ws = true, item = true}

-- 'ja:Berserk' -> {kind = 'ja', name = 'Berserk'}; a bare name is a spell.
function fighter.parse_use(text)
    if type(text) == 'table' then return text end
    local kind, name = tostring(text):match('^(%a+):(.+)$')
    kind = kind and kind:lower()
    if kind == 'spell' or kind == 'magic' then kind = 'ma' end
    if not (kind and fighter.KINDS[kind]) then kind, name = 'ma', text end
    return {kind = kind, name = name}
end

fighter.default_profile = {
    reach = 3.0,
    weaponskill = nil,          -- {name = 'Raging Axe', tp = 1000, min_mob_hpp = 5}
    open = {},                  -- {'ja:Berserk', ...}: once per fight
    buffs = {},                 -- {{use = 'ma:Protect', buff = 'Protect', when = 'camp'|'fight'|'always'}}
    heals = {},                 -- {{use = 'ma:Cure II', hpp = 50}, {use = 'item:Hi-Potion', hpp = 35}}
    rest = {hpp = 60, mpp = 30, until_hpp = 95, until_mpp = 90},
    trusts = {},                -- {'Valaineral', 'Kupipi'}
    food = nil,                 -- 'Grape Daifuku'
    ring = nil,                 -- {name = 'Echad Ring', buff = 'Dedication', slot = 'ring1', delay = 8}
}

-- Fills in defaults and parses `use` strings. Keeps the caller's table untouched.
function fighter.normalize(profile)
    profile = profile or {}
    local p = {}
    for k, v in pairs(fighter.default_profile) do p[k] = v end
    for k, v in pairs(profile) do p[k] = v end
    local rest = {}
    for k, v in pairs(fighter.default_profile.rest) do rest[k] = v end
    for k, v in pairs(profile.rest or {}) do rest[k] = v end
    p.rest = rest
    p.open_uses = {}
    for i, u in ipairs(p.open or {}) do p.open_uses[i] = fighter.parse_use(u) end
    p.buff_uses = {}
    for i, b in ipairs(p.buffs or {}) do
        local u = fighter.parse_use(b.use)
        -- "Protect II" keeps up the "Protect" buff unless told otherwise.
        local buff = b.buff or u.name:gsub('%s+[IVX]+$', '')
        p.buff_uses[i] = {use = u, buff = buff:lower(),
                          when = b.when or (u.kind == 'ja' and 'fight' or 'camp')}
    end
    p.heal_uses = {}
    for i, h in ipairs(p.heals or {}) do p.heal_uses[i] = {use = fighter.parse_use(h.use), hpp = h.hpp or 50} end
    if type(p.weaponskill) == 'string' then p.weaponskill = {name = p.weaponskill} end
    if p.weaponskill then
        p.weaponskill = {name = p.weaponskill.name, tp = p.weaponskill.tp or 1000,
                         min_mob_hpp = p.weaponskill.min_mob_hpp or 5}
    end
    if type(p.ring) == 'string' then p.ring = {name = p.ring} end
    if p.ring then
        p.ring = {name = p.ring.name, buff = (p.ring.buff or 'Dedication'):lower(), slot = p.ring.slot or 'ring1',
                  delay = p.ring.delay or 8}
    end
    return p
end

function fighter.new(io, profile, rng)
    local self = setmetatable({io = io, rng = rng or math.random, busy_until = 0, next_at = 0,
                               opened = {}, backoff = {}, tries = {}, ring_stage = nil}, fighter)
    self:set_profile(profile)
    return self
end

function fighter:set_profile(profile)
    self.p = fighter.normalize(profile)
end

function fighter:uniform(a, b)
    return a + (b - a) * self.rng()
end

-- A new fight: open abilities fire again.
function fighter:reset_fight()
    self.opened = {}
end

-- The player's own actions (0x028 with the player as actor), to know when a cast or an
-- item is under way and when it ends.
function fighter:on_self_action(category, param, now)
    if category == 8 or category == 9 then          -- casting / item use begins (or is interrupted)
        if param == 28787 then
            self.busy_until = now + 2.0
        else
            self.busy_until = math.max(self.busy_until, now + 12)
        end
    elseif category == 4 or category == 5 then     -- spell / item finished
        self.busy_until = now + 2.5
    elseif category == 3 or category == 6 then     -- weaponskill / job ability
        self.busy_until = math.max(self.busy_until, now + 1.2)
    end
end

function fighter:busy(now)
    return now < self.busy_until or now < self.next_at
end

local function in_backoff(self, key, now)
    local until_t = self.backoff[key]
    return until_t and now < until_t
end

-- Sends one action and holds further ones until it's had time to finish.
function fighter:_use(now, use, target, info, why)
    self.io.use(use.kind, use.name, target)
    local lock = 1.5
    if use.kind == 'ma' then lock = (info and info.cast or 3) + 3
    elseif use.kind == 'item' then lock = 5 end
    self.busy_until = now + lock
    self.next_at = now + lock + self:uniform(0.4, 1.0)
    if why then self.io.say(why) end
end

function fighter:_ready(view, use)
    local ok, info = view.can(use.kind, use.name)
    return ok, info
end

local function dist2d(a, b)
    local dx, dy = a.x - b.x, a.y - b.y
    return sqrt(dx * dx + dy * dy)
end

local function heading_to(from, to)
    return -atan2(to.y - from.y, to.x - from.x)
end

local function angle_diff(a, b)
    local d = (a - b) % (2 * pi)
    if d > pi then d = 2 * pi - d end
    return abs(d)
end

-- One step of a fight against `mob` while engaged. Returns nothing; acts through io.
function fighter:fight(now, view, mob)
    local p = self.p
    if self:busy(now) then return end

    -- 1. Heal: casting stops movement, so stand still for it.
    for _, h in ipairs(p.heal_uses) do
        if (view.hpp or 100) < h.hpp then
            local ok, info = self:_ready(view, h.use)
            if ok then
                self.io.halt()
                self:_use(now, h.use, 'me', info)
                return
            end
        end
    end

    -- 2. Range and facing.
    local d = dist2d(view.pos, mob)
    local reach = p.reach + (mob.model_size or 0) * 0.5
    if d > reach then
        self.io.steer(mob)
        return
    end
    self.io.halt()
    if view.facing and angle_diff(view.facing, heading_to(view.pos, mob)) > 0.35 then
        self.io.face(mob)
    end

    -- 3. Openers, once each per fight.
    for i, u in ipairs(p.open_uses) do
        if not self.opened[i] then
            local ok, info = self:_ready(view, u)
            if ok then
                self.opened[i] = true
                -- Enemy abilities and spells (Provoke, Dia) at the mob; the rest on yourself.
                local enemy = (info and info.enemy ~= nil) and info.enemy or u.kind == 'ma'
                self:_use(now, u, enemy and mob or 'me', info)
                return
            end
        end
    end

    -- 4. Buffs for fights.
    for _, b in ipairs(p.buff_uses) do
        if b.when ~= 'camp' and not (view.buffs or {})[b.buff] and not in_backoff(self, 'buff:' .. b.buff, now) then
            local ok, info = self:_ready(view, b.use)
            if ok then
                -- If the buff never shows (a name that isn't the buff's), don't loop on it.
                self.backoff['buff:' .. b.buff] = now + 20
                self:_use(now, b.use, 'me', info)
                return
            end
        end
    end

    -- 5. Weaponskill.
    local ws = p.weaponskill
    if ws and (view.tp or 0) >= ws.tp and (mob.hpp or 100) >= ws.min_mob_hpp then
        local ok, info = self:_ready(view, {kind = 'ws', name = ws.name})
        if ok then
            self:_use(now, {kind = 'ws', name = ws.name}, mob, info)
        end
    end
end

local function trust_key(name)
    return (name or ''):lower():gsub('%s*%(uc%)$', ''):gsub('%s+ii$', ''):gsub('%s*%[s%]$', '')
end
fighter.trust_key = trust_key

-- Getting ready to pull. Returns true when ready.
function fighter:prepare(now, view)
    local p = self.p
    if self:busy(now) then return false end
    local status = view.status

    -- Resting: get up once recovered (moving or acting would also end it).
    if status == 33 then
        local mp_ok = (view.max_mp or 0) == 0 or (view.mpp or 100) >= p.rest.until_mpp
        if (view.hpp or 100) >= p.rest.until_hpp and mp_ok then
            self.io.rest(false)
            self.next_at = now + self:uniform(1.0, 2.0)
        end
        return false
    end
    if status ~= 0 then return false end

    -- 1. Food.
    local buffs = view.buffs or {}
    if p.food and not buffs['food'] and not in_backoff(self, 'food', now) and view.count(p.food) > 0 then
        self.backoff.food = now + 60       -- if the buff doesn't show, try again in a minute
        self:_use(now, {kind = 'item', name = p.food}, 'me', nil, 'eating ' .. p.food)
        return false
    end

    -- 2. EXP/CP ring: equip, wait for the equip delay, use.
    local r = p.ring
    if r and not buffs[r.buff] and not in_backoff(self, 'ring', now) and view.count(r.name) > 0 then
        if not self.ring_stage then
            self.io.equip(r.slot, r.name)
            self.ring_stage = now + r.delay
            self.next_at = now + 1
            self.io.say(('equipping %s'):format(r.name))
            return false
        elseif now >= self.ring_stage then
            self.ring_stage = nil
            self.backoff.ring = now + 600   -- on recast (or failed): leave it for ten minutes
            self:_use(now, {kind = 'item', name = r.name}, 'me', nil, 'using ' .. r.name)
            return false
        end
        return false
    end
    self.ring_stage = nil

    -- 3. Trust NPCs.
    for _, name in ipairs(p.trusts) do
        local key = trust_key(name)
        if not (view.trust_party or {})[key] and (view.party_size or 1) < 6 and not in_backoff(self, 'trust:' .. key, now) then
            local ok, info = view.can('ma', name)
            if ok then
                local t = (self.tries[key] or 0) + 1
                self.tries[key] = t
                if t >= 2 then self.backoff['trust:' .. key], self.tries[key] = now + 300, 0 end
                self:_use(now, {kind = 'ma', name = name}, 'me', info, 'calling ' .. name)
                return false
            end
        else
            self.tries[key] = 0
        end
    end

    -- 4. Buffs for camp.
    for _, b in ipairs(p.buff_uses) do
        if b.when ~= 'fight' and not buffs[b.buff] and not in_backoff(self, 'buff:' .. b.buff, now) then
            local ok, info = self:_ready(view, b.use)
            if ok then
                self.backoff['buff:' .. b.buff] = now + 20
                self:_use(now, b.use, 'me', info)
                return false
            end
        end
    end

    -- 5. Rest.
    local low_mp = (view.max_mp or 0) > 0 and (view.mpp or 100) < p.rest.mpp
    if (view.hpp or 100) < p.rest.hpp or low_mp then
        self.io.rest(true)
        self.next_at = now + self:uniform(1.5, 2.5)
        return false
    end
    return true
end

return fighter
