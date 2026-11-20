# windower-waypoints

[![tests](https://github.com/TargetedEntropy/windower-waypoints/actions/workflows/tests.yml/badge.svg)](https://github.com/TargetedEntropy/windower-waypoints/actions/workflows/tests.yml)
![Windower 4](https://img.shields.io/badge/Windower-4-blue)
![Lua 5.1](https://img.shields.io/badge/Lua-5.1-2C2D72)
![License: BSD-3-Clause](https://img.shields.io/badge/license-BSD--3--Clause-green)

**waypoints** is a [Windower 4](https://www.windower.net/) addon for Final Fantasy XI. You
record where you walk, and it builds a **graph of walkable routes** for each zone. You name
places on it, and `//wp go <place>` walks you there along the **shortest recorded path** (A*).
It **steers around obstacles**, opens closed doors on the way, and **reroutes** when a path is
blocked.

Windower gives addons no map or collision data, so nothing is guessed: every route the addon
uses is one you walked.

> **Status: 0.5.0, untested in game.** The logic is covered by 180 offline tests (CI runs
> them on every push), but it has not yet been run on a live client. See
> [Verifying in game](#verifying-in-game) before relying on it.

## Contents

- [Features](#features)
- [Install](#install)
- [Quick start](#quick-start)
- [Commands](#commands)
- [How it works](#how-it-works)
- [Pulling](#pulling)
- [Fighting](#fighting)
- [Settings](#settings)
- [Data files](#data-files)
- [Limits](#limits)
- [Safety and terms of service](#safety-and-terms-of-service)
- [Verifying in game](#verifying-in-game)
- [Development](#development)
- [Prior art](#prior-art)
- [License](#license)

## Features

- **Record by walking.** It drops a node every 3 yalms, plus extra nodes at corners. A warp
  never creates a false edge.
- **Routes join themselves.** Walking over or across an earlier route links to it, so routes
  recorded on different days combine into one graph per zone.
- **Named places.** `//wp mark ah`, `//wp mark mog`, `//wp marks`.
- **Shortest-path walking.** A* over the graph, steered with `windower.ffxi.run`.
- **Obstacle avoidance.** When something stops you, it probes headings to either side,
  slides along the obstacle's edge, and rejoins the route once the way is clear.
- **Doors.** It opens closed doors on the path before you reach them, and remembers doors
  you opened by hand while recording.
- **Blocked-path detection.** When avoidance finds no way past, it:
  1. tries to open a nearby door,
  2. then marks that stretch blocked and reroutes over another recorded route,
  3. then stops and tells you where.
- **Pulling.** `//wp pull on` pulls monsters to a camp mark along the recorded routes. It
  picks the mob nearest by the routes, not in a straight line, so it doesn't run at walls.
  See [Pulling](#pulling).
- **Fighting.** With a profile per job, it fights too: melee range and facing,
  weaponskills, opening abilities, buffs, heals, resting, Trust NPCs, food and EXP/CP
  rings. You don't need a separate fight addon. See [Fighting](#fighting).
- **Supervised by design.**
  - Escape or `//wp stop` stops it at any time.
  - It stops by itself when engaged, dead, zoning or off the route.
  - It pauses for cutscenes and menus, and never answers a menu for you.
- **Plain data.** Each zone is a readable Lua table you can diff, share or edit by hand.

## Install

Windower loads an addon from a folder with the same name as its main file. The folder must
be called **`waypoints`**:

```
cd "<Windower>/addons"
git clone https://github.com/TargetedEntropy/windower-waypoints.git waypoints
```

Or download the ZIP from GitHub, extract it, and rename the folder to `waypoints`. Then, in
game:

```
//lua load waypoints
```

To load it automatically, add `lua load waypoints` to `Windower/scripts/init.txt`.

## Quick start

Record a few places in a city, then walk between them:

```
//wp rec                       start recording
//wp mark home point           (standing at the Home Point)
   ...walk to the auction house...
//wp mark ah
   ...walk to the Mog House entrance...
//wp mark mog
//wp stop                      stop recording (saved)

//wp go ah                     walk to the auction house
```

Record more routes any time with `//wp rec`. They join the graph wherever they meet it.
`//wp info` shows the graph's size, and `//wp route <name>` shows a path without moving.

## Commands

`//waypoints` and `//wp` are the same.

| Command | What it does |
|---|---|
| `//wp rec` | Start recording. Walk your routes. |
| `//wp stop` | Stop recording (saves), or stop walking. |
| `//wp undo` | While recording: take back the last step. Repeatable. |
| `//wp mark <name>` | Name the node you're on (while recording), or the nearest node within 5 yalms. |
| `//wp unmark <name>` | Remove a name. |
| `//wp marks` | List names in this zone, with distances. |
| `//wp route <name>` | Show the shortest recorded path's length, without moving. |
| `//wp go <name>` | Walk there. **Escape** or `//wp stop` stops. |
| `//wp pull camp <mark>` | Pull to this mark. |
| `//wp pull add <mob>` / `remove <mob>` / `clear` | Monsters to pull (by name; none listed means any monster). |
| `//wp pull action ra\|provoke\|dia\|melee` | How to pull. `custom <command> <range>` for anything else. |
| `//wp pull radius <yalms>` | How far from camp to pull, measured along the routes (default 40). |
| `//wp pull camp <a>,<b>,...` | Several camps: move on when one has nothing to pull for 30 s. |
| `//wp pull on` / `off` | Start or stop pulling. `//wp pull` shows the state. |
| `//wp pull pause` / `resume` | Finish the current fight, then wait at camp. |
| `//wp fight` | Show this job's fight profile. |
| `//wp fight ws <name> [tp]` / `ws off` | Weaponskill, at 1000 TP unless given. |
| `//wp fight add open\|buff\|heal <use> [HP%]` | Add an opener, a buff to keep up, or a heal (`use`: `ja:Name`, `ma:Name`, `item:Name`). |
| `//wp fight remove open\|buff\|heal <use>` / `clear open\|buffs\|heals\|trusts` | Take them out again. |
| `//wp fight trust add\|remove <name>` | Trust NPCs to call at camp. |
| `//wp fight food <item>` / `ring <item>` | Food, and an EXP/CP ring, kept up between fights (`off` to stop). |
| `//wp fight rest <HP%> [MP%]` | Rest at camp below these. |
| `//wp fight on` / `off` | Fight with the profile, or leave fights to you or another addon. |
| `//wp doors [on\|off]` | Turn door opening on or off (on by default); shows recorded doors. |
| `//wp blocked` | List stretches found blocked while walking (kept 10 minutes). |
| `//wp unblock` | Forget them. |
| `//wp info` | Nodes, edges, dead ends and marks for this zone. |
| `//wp save` / `//wp reload` | Save now / reload this zone from disk. |
| `//wp clear confirm` | Delete every node and mark in this zone. |
| `//wp show` / `//wp hide` | Show or hide the status overlay. |
| `//wp help` | Command summary in the chat log. |

Names are case-insensitive and may contain spaces (`//wp go home point`).

## How it works

The logic lives in seven modules with no Windower dependencies, so it can be tested outside
the game. `waypoints.lua` connects them to Windower.

| File | Role |
|---|---|
| `graph.lua` | Nodes, edges, marks and recorded doors; nearest-node lookup; A* (binary heap) that can skip blocked edges; serialization |
| `recorder.lua` | Turns a stream of positions into nodes and edges |
| `navigator.lua` | Follows a list of points, steering around obstacles; reports arrival, being stuck or leaving the route |
| `doors.lua` | Which entities are doors, whether they're open, and which one is in the way |
| `targets.lua` | Which mob to pull: nearest to camp along the routes |
| `puller.lua` | The pull loop: walk out, pull, run back, fight at camp, repeat; camps, pauses, stops |
| `fighter.lua` | The fight (heals, range, facing, openers, buffs, weaponskill) and camp (food, ring, Trusts, buffs, rest) |
| `waypoints.lua` | Commands, events, steering, door packets, rerouting, storage, overlay |

### Recording

- Your position is sampled 10 times a second.
- A node is dropped every **3 yalms**. When the direction of travel turns by more than **35°**,
  one is dropped after 1.5 yalms, so corners aren't cut.
- Within **2 yalms** of an existing node on the same floor (height within 3), the recorder
  links to that node instead of adding a new one. That is how routes join and junctions form.
  The last few nodes you recorded are excluded, so it never links back to where you just were.
- A jump of more than **20 yalms** between samples (a warp or teleport) starts a new chain
  with no edge across the gap.
- When you open a door by hand while recording, the addon sees the interaction packet and
  remembers that door for the zone.

### Walking

- `//wp go` starts from the recorded node nearest you (within 8 yalms) and runs A* to the mark.
- Each tick it steers with `windower.ffxi.run(dx, dy)` toward the next point. A point is
  reached within 1.5 yalms, or once you've passed it.
- Before it starts, it cancels `/follow`. It won't start while target lock is on.
- It stops when:
  - you press Escape or type `//wp stop`,
  - you are engaged, dead or zoning,
  - you are more than 12 yalms off the route,
  - you are blocked with no way around (see [Obstacles](#obstacles) and
    [Blocked paths](#blocked-paths)).
- Cutscenes, menus, resting and other statuses pause it, and it continues afterwards.

### Obstacles

There's no collision data, so an obstacle is only noticed by its effect. If you move less
than 0.6 yalms in 0.6 seconds while running, you are blocked. The walker then:

1. **Checks for a door.** If a closed door is close by, it opens that instead (see
   [Doors](#doors)).
2. **Probes.** It tries headings turned 45°, 90° and 135° off the direct line, alternating
   sides and starting with the side that worked last. Each gets 0.6 s. The angles are
   measured from the direction at the moment you were blocked, so sliding along the
   obstacle doesn't turn you back into it.
3. **Slides.** As soon as one heading makes progress, it tries the direct line again. If
   that's still blocked, it takes the working heading for another 0.6 s and tries again.
   This follows the obstacle's edge until the way is clear, then rejoins the route.
4. **Switches sides.** Straying more than 8 yalms from the route switches to the other side
   once.
5. **Gives up** as "stuck" when every heading is blocked, when both sides run out of room,
   or after 12 seconds of avoiding on one stretch. The [Blocked paths](#blocked-paths)
   steps then take over.

`nav.avoid = false` turns this off. The walker then waits 3 seconds without progress before
treating the path as blocked.

### Doors

- A door is an entity with `spawn_type` 34. It counts as open while its status is 8
  ("Door Opening"); status 9 is "Door Closing".
- While walking, the addon opens a closed door that is within 6 yalms of you and within
  3 yalms of the next few points of the route, before you reach it.
- It opens the door with the packet the client sends when you click one: outgoing `0x01A`,
  category 0 (NPC interaction). Each door is opened at most once every 7 seconds.
- Doors whose names start with `_`, and `Furniture`, are skipped, as OpenSesame does,
  unless you opened that door yourself while recording.
- Menus are never answered. A door that asks a question pauses the walk until you answer.

### Blocked paths

When obstacle avoidance gives up (or, with avoidance off, after 3 seconds without progress):

1. **Door.** If a closed door is close by, the walker stops, opens it, and waits up to
   4 seconds for it to open. It tries each door twice.
2. **Reroute.** Otherwise it marks the stretch of route it was on as blocked for 10 minutes
   and plans a new route avoiding blocked stretches. The new route starts from the last
   node passed, which is known to be reachable; the nearest node might be on the far side
   of the obstacle.
3. **Give up.** With no other recorded route, or after 3 reroutes, it stops and says where.

`//wp blocked` lists the blocked stretches. They are kept in memory only and are cleared
when you change zones or run `//wp unblock`.

## Pulling

Record the area you hunt in: walk the paths between camp and where the monsters roam, and
mark the camp. Then:

```
//wp pull camp camp
//wp pull add ghost crab        (repeat for each kind; none means any monster)
//wp pull action ra             (or provoke, dia, melee, or custom "/ma \"Stone\"" 20)
//wp pull on
```

Each pull:

1. **Pick.** The candidates are monsters that are alive, unclaimed (or claimed by your
   party), on the list, and within `pull.snap` (10) yalms of a recorded node on their
   floor. The one with the shortest route from camp wins: route length plus the last step
   off the route. A mob behind a wall is close in a straight line but far by the routes,
   so it isn't chosen first. Mobs more than `pull.radius` (40) yalms away by the routes
   are ignored.
2. **Walk out** along the routes to the node nearest the mob, with all the usual avoidance,
   doors and rerouting. If the mob wanders more than 6 yalms, the walk is re-planned. Past
   the end of the routes it closes in in a straight line for up to 8 seconds.
3. **Pull** once in range of the action: it faces the mob and sends the command with the
   mob's id as the target (`/ra 17203241`). If the mob isn't claimed within
   `pull.claim_wait` (4) seconds, it tries once more, then leaves that mob alone for 60
   seconds.
4. **Run back** to camp along the routes; the mob follows. A melee pull disengages first.
5. **Fight at camp.** Once the mob is within `pull.engage_range` (6) yalms it sends
   `/attack`. The fighting is up to you, GearSwap, or a fight addon (Trust in assist mode,
   for example). If the mob doesn't come within 10 seconds, it goes to meet it.
6. When every aggroed mob is dead, it pauses 3 to 6 seconds (loot) and picks again.

Anything that attacks the party is fought first, and nothing new is pulled while it is.
Aggro is tracked from action packets: a monster acting on the party, or the party acting on
a monster.

**Choosing well.**
- **Lone mobs first.** A mob with other monsters within `pull.crowd_radius` (8) yalms
  counts as 20 yalms farther per neighbour, so pulls rarely bring links.
- **Several camps.** `//wp pull camp a,b,c` moves to the next camp when one has had nothing
  to pull for `pull.roam_after` (30) seconds.
- **Failed pulls.** "Unable to see", "too far away", no ammo and the like drop the mob at
  once. Three failed pulls in a row stop pulling, because that usually means the pull action
  itself is wrong.
- **Stolen mobs.** If someone else claims your mob, it lets go, says so, and pulls the next.

**Stopping.**
- **At once:** Escape, `//wp stop`, `//wp pull off`, a tell, death, zoning, a 3-minute
  fight, or not being able to get back to camp.
- **After the current fight,** so you're never left engaged and idle: more than
  `pull.max_aggro` (2) mobs at once, `pull.max_pulls` (50), or `pull.max_minutes` (60).
  Without a fight profile, HP below `pull.min_hp` (40%) is also a stop; with one, it rests
  instead.
- **Summary.** On stopping it reports kills, pulls, time, and EXP/CP per hour. The overlay
  shows the same while it runs.

## Fighting

Each job has a profile in `data/fight/<JOB>.lua`, a plain Lua table. Set it with
`//wp fight` commands, or edit the file:

```lua
return {
    weaponskill = {name = "Raging Axe", tp = 1000},
    open = {"ja:Berserk", "ja:Provoke"},                  -- once per fight
    buffs = {
        {use = "ma:Protect"},                              -- kept up at camp (spells, items)
        {use = "ja:Warcry", when = "fight"},               -- kept up in fights (abilities)
        {use = "ma:Utsusemi: Ni", buff = "Copy Image"},    -- when the buff's name differs
    },
    heals = {{use = "ma:Cure II", hpp = 50}, {use = "item:Hi-Potion", hpp = 35}},
    rest = {hpp = 60, mpp = 30, until_hpp = 95, until_mpp = 90},
    trusts = {"Valaineral", "Kupipi", "Excenmille"},
    food = "Grape Daifuku",
    ring = {name = "Echad Ring", buff = "Dedication"},
    reach = 3.0,
}
```

**In a fight**, each step it does the first of these that applies:
1. **Heal** with the first `heals` entry whose HP% you're under and that's ready (it stands
   still to cast).
2. **Close in** to melee reach (plus half the mob's size) and **face** the mob.
3. **Openers**, once each per fight. Enemy abilities and spells (Provoke, Dia) go at the mob;
   others go on you.
4. **Fight buffs** that are missing.
5. **Weaponskill** at the TP set, but not on a mob under 5% HP.

**At camp**, before each pull:
1. Food, if the Food buff is gone.
2. The EXP/CP ring, if its buff is gone. It equips the ring, waits 8 seconds for the equip
   delay, then uses it.
3. Missing Trust NPCs, while the party has room. A Trust that fails to join twice is left
   for 5 minutes.
4. Camp buffs that are missing.
5. Rest (`/heal`) below `rest.hpp` or `rest.mpp`, until `until_hpp` and `until_mpp`.

"Ready" means known, off recast, enough MP or TP, and not silenced, amnesic, asleep or
stunned, all read from Windower. Nothing is sent while a spell or item is in progress, and
commands are spaced about a second apart. A buff that doesn't appear after use is retried
after 20 seconds. A buff name that the game doesn't have is reported when pulling starts.
`//wp fight off` leaves fights to you or another addon.

## Settings

Windower's config library writes `data/settings.xml` the first time the addon loads. Edit
it while the addon is unloaded, or run `//lua reload waypoints` afterwards.

| Setting | Default | Meaning |
|---|---|---|
| `record.spacing` | 3.0 | Yalms between nodes on a straight walk |
| `record.corner_min` | 1.5 | Shortest segment before a corner node |
| `record.corner_angle` | 35 | Turn (degrees) that counts as a corner |
| `record.merge_radius` | 2.0 | Distance at which a walk joins an existing node |
| `record.max_dz` | 3.0 | Height difference that still counts as the same floor |
| `record.jump` | 20.0 | Distance between samples treated as a warp |
| `nav.tolerance` | 1.5 | Distance at which a point counts as reached |
| `nav.final_tolerance` | 1.0 | The same, for the destination |
| `nav.avoid` | true | Steer around obstacles |
| `nav.blocked_seconds` | 0.6 | Window for noticing an obstacle, and for each probe |
| `nav.blocked_distance` | 0.6 | Movement in that window below which you're blocked |
| `nav.commit_seconds` | 0.6 | How long to keep a working heading before retrying the direct line |
| `nav.avoid_radius` | 8.0 | How far from the route avoidance may go (per side) |
| `nav.avoid_max` | 12.0 | Seconds of avoiding allowed per stretch |
| `nav.stuck_seconds` | 3.0 | Stuck window when avoidance is off |
| `nav.stuck_distance` | 1.0 | Minimum movement in that window |
| `nav.off_route` | 12.0 | Distance from the route that stops the walk |
| `nav.snap_radius` | 8.0 | How far the nearest recorded node may be when starting |
| `nav.block_minutes` | 10 | How long a blocked stretch is avoided |
| `nav.max_reroutes` | 3 | Reroutes allowed per walk |
| `doors.enabled` | true | Open doors while walking |
| `doors.reach` | 6.0 | How close a door must be to be opened |
| `doors.width` | 3.0 | How close to the route a door must be |
| `doors.cooldown` | 7 | Seconds between opening the same door |
| `doors.wait` | 4.0 | Seconds to wait for a door after getting stuck |
| `doors.attempts` | 2 | Tries per door before treating the path as blocked |
| `pull.camp` | | The camp mark |
| `pull.names` | | Monsters to pull, comma-separated (empty: any monster) |
| `pull.action` | ra | `ra`, `provoke`, `dia`, `melee` or `custom` |
| `pull.command`, `pull.range` | /ra, 17 | The command and its range, for `custom` |
| `pull.radius` | 40.0 | How far from camp to pull, along the routes |
| `pull.snap` | 10.0 | How far a mob may be from a recorded node |
| `pull.max_dz` | 4.0 | Height difference between a mob and its node |
| `pull.claim_wait` | 4.0 | Seconds for a pull to claim |
| `pull.engage_range` | 6.0 | Engage at camp once the mob is this close |
| `pull.max_aggro` | 2 | More mobs than this at once stops pulling |
| `pull.min_hp` | 40 | Stop below this HP% |
| `pull.max_pulls` | 50 | Stop after this many pulls |
| `pull.max_minutes` | 60 | Stop after this long |
| `pull.crowd_radius` | 8.0 | Prefer mobs without other monsters this close (0: off) |
| `pull.roam_after` | 30 | With several camps, seconds without a target before moving on |
| `fight.enabled` | true | Fight with the job's profile while pulling |
| `show` | true | Status overlay |

## Data files

Each zone's graph is saved to `data/zones/<zone id>.lua`, a plain Lua table:

```lua
return {
    version = 1,
    zone = 230,
    next_id = 42,
    nodes = { {1, -95.12, 12.40, 0.00}, {2, -92.20, 12.95, 0.00}, ... },  -- id, x, y, z
    edges = { {1, 2}, {2, 3}, ... },                                     -- undirected
    marks = { ["ah"] = 17, ["home point"] = 1 },
    doors = { [17739847] = 71 },                                         -- entity id -> index
}
```

- Files are written through a temporary file, so a crash doesn't leave half a file.
- An unreadable file is left untouched, and saving is disabled for that zone until you fix
  or remove it.
- Zone files hold only positions and names, so they can be shared between characters and
  players.
- `data/` is git-ignored.

## Limits

- **It only knows what you walked.** Elevators, boats, zone lines and one-way drops aren't
  modelled, and routes don't cross zones.
- **Joining can go wrong.**
  - Two corridors less than 2 yalms apart with a wall between them can be joined by a false
    edge. Run `//wp undo` straight away, or lower `record.merge_radius`.
  - Steep stairs and ramps can fall outside the 3-yalm height window. Walk them in one go so
    the nodes connect.
- **Avoidance is reactive, not planned.** It finds obstacles by bumping into them, and it
  explores only within 8 yalms of the route. A big obstacle, a dead-end alcove, or a gap
  narrower than the probe angles can find ends in a reroute or a stop, not a detour.
  Movement in the real game may slide along walls, which helps, but this hasn't been
  measured in game.
- **The fight is a priority list, not a planner.** There are no skillchains, magic bursts,
  enmity management or debuff tracking. It doesn't check how strong a mob is ("Incredibly
  Tough"), so keep the name list to mobs you can solo.
- **Line of sight** isn't known in advance. A pull that can't see the mob is refused by the
  game, and the mob is skipped.
- **Loot** isn't lotted. With Trust NPCs in the party, drops wait in the treasure pool.
- **Doors.** Locked doors and doors that need a key item can't be opened. They become
  blocked stretches. Doors that open a menu wait for you.

## Safety and terms of service

- Third-party tools and automated input can conflict with Final Fantasy XI's terms of
  service. Use this addon for short walks you are watching, not unattended play.
- **Movement** uses Windower's `run` function, the same mechanism follow and assist addons
  use.
- **Doors** are opened with an injected interaction packet. It's the packet a click sends,
  but it's still automated. `//wp doors off` disables it.
- **Pulling** is automated play: it chooses, pulls and engages monsters on its own. That
  is the riskiest part of this addon with respect to the terms of service. Watch it, and
  keep sessions short (`pull.max_minutes`).
- **What it doesn't do:** it doesn't answer menus, warp, change your position directly, or
  move or attack without a `//wp go` or `//wp pull on`.

## Verifying in game

These behaviours come from Windower's documentation and other addons, and haven't yet been
confirmed on a live client:

- `windower.ffxi.run(x, y)` runs along a normalised direction vector. This is the wiki's
  form, and FastFollow and Trust use it the same way.
- Status 5 (chocobo) and 85 (mount) are moving states. 85 comes from Gambit's code.
- Escape arrives in the `keyboard` event as DirectInput code 1.
- Doors have `spawn_type` 34 and status 8 while open (from OpenSesame and Windower's status
  table). Whether the status stays 8 for as long as the door is open hasn't been checked.
- Obstacle-avoidance timings assume running speed of about 5 yalms per second. A 0.6-yalm
  threshold in 0.6 s is 20% of that. Slower movement (weight, Gravity) might count as
  blocked; raise `nav.blocked_seconds` if it does.
- **Pulling:**
  - Commands accept a mob's server id as the target (`/ra 17203241`, `/attack 17203241`),
    as other addons send them.
  - `windower.ffxi.turn(-atan2(dy, dx))` faces the mob (the heading convention Trust uses
    for `run`).
  - `get_player().vitals.hpp` is the player's HP%, and `claim_id` on a mob is the
    claimer's id.
  - The `action` event's `actor_id` and `targets[i].id` identify who acted on whom.
- **Fighting:**
  - `/ja "X" <me>`, `/ma "X" <id>`, `/ws "X" <id>`, `/item "X" <me>`, `/heal on|off`,
    `/attackoff` and `/equip ring1 "X"` behave as typed.
  - `vitals.max_mp` (or `player.max_mp`) is the MP pool, and status 33 is resting.
  - `targets.Enemy` in the ability and spell resources marks enemy-targeted actions.
  - An EXP ring's equip delay is under 8 seconds. Raise `ring.delay` in the profile if the
    use is refused.
  - The pull-refusal texts ("Unable to see", "too far away", ...) are matched in English.
- `os.clock()` measures wall-clock time under Windower, as the Windows C runtime's
  `clock()` does. Other addons use it as a timer.

A first check:
1. Record a short loop in a quiet area and mark both ends.
2. Try `//wp route`, then `//wp go`, with a hand near Escape.
3. Then try a route through a city door: record it with the door open, and walk it with
   the door closed.
4. For avoidance, record a route next to an obstacle, then walk a route that cuts across
   its corner, and watch the overlay show "(avoiding obstacle)".

Please [open an issue](https://github.com/TargetedEntropy/windower-waypoints/issues) with
what you find.

## Development

The tests run on any machine with Lua 5.1. No Windower or game client is needed:

```
lua5.1 tests/run.lua
```

`tests/run.lua` does two things:

- It tests the modules directly, using simulated movement. This includes avoidance
  around a pillar, around an L-shaped wall that is open on only one side, and against an
  endless wall.
- It loads `waypoints.lua` against a fake Windower, a small simulated world with walls and
  doors. It then plays through these sessions:
  - record, walk, reload, and stop when engaged
  - steer around a pillar placed on a recorded route
  - walk through a door that opens when poked
  - try a locked door twice, then reroute over a detour
  - stop at a dead end
  - remember a door opened by hand
  - pull a mob along an L-shaped route, run back, fight it at camp
  - set a fight profile by command, eat before pulling, finish with a weaponskill, stop on
    a tell
- The puller is also tested on its own in a small simulated world: picking by route
  distance, crowded mobs, a pull that never claims or is refused, a wandering mob, a mob
  taken by someone else (before and during the fight), adds, several camps, pausing, and
  each stop.
- The fighter is tested step by step: range and facing, weaponskills, openers, buffs,
  heals, resting, Trusts, food and the ring.

CI ([`.github/workflows/tests.yml`](.github/workflows/tests.yml)) runs the same command on
every push and pull request.

Conventions:
- Keep Windower calls in `waypoints.lua`. The other modules must stay testable.
- New behaviour gets a test.

## Prior art

Existing Windower addons were read before this one was written. What was taken and what was
avoided:

| Project | Approach | Taken / avoided |
|---|---|---|
| [Path](https://github.com/furiex-ffxi/windower-addons/blob/main/path/path.lua) (Cyrite) | Records a point every second; replays the list forward then backward from the nearest point | Taken: start from the nearest point. Avoided: sampling by time, which bunches points when you stand still, and a single linear path |
| [Trust](https://github.com/cyritegamestudios/trust) (`cylibs/actions/runtolocation.lua`, `walk.lua`) | Steers with `run(dx, dy)` every frame; releases target lock and `/follow` first | Taken: steering and pre-checks. This addon refuses to start with target lock on rather than toggling it |
| [Gambit](https://github.com/Kaiconure/Gambit) (`lib/smart-move.lua`) | Stuck detection from average speed; escapes obstacles with a random "jitter" heading 135–225° from the target; detects a passed point with a halfspace test | Taken: speed-based detection and the passed-point test. Changed: avoidance probes in a fixed order (45/90/135°, alternating sides, from a frozen heading) and follows the edge, instead of a random escape |
| [expert-umbrella](https://github.com/sethmccauley/expert-umbrella) (`navigation.lua`) | A node every 4 yalms; nearest-node start filtered by height | Taken: distance-based sampling, height filter |
| [FastFollow](https://github.com/DiscipleOfEris/FastFollow) | Multibox follow with normalised `run(x, y)` | Taken: normalised run vector |
| [OpenSesame](https://github.com/Lygre/addons/blob/live/OpenSesame/OpenSesame.lua) (Arcon) | Opens doors with an outgoing `0x01A`; doors are `spawn_type` 34; skips `_` names and `Furniture`; 7 s cooldown | Taken: door test, packet, cooldown, name filter. Added: only closed doors on the route; recorded doors override the filter |
| [DoorHelper](https://github.com/aragan/my-addons/blob/main/DoorHelper/DoorHelper.lua) | Finds doors by name; answers door menus "Yes" automatically | Avoided: answering menus |
| [FFXI-NavMesh-Builder](https://github.com/LandSandBoat/FFXI-NavMesh-Builder), [ffxi_navmeshes](https://github.com/Omnione/ffxi_navmeshes) | Navigation meshes built from the game's collision data, for private servers | Not used. Querying them needs Detour (C++), which plain Windower Lua can't load |

None of these builds a graph. The ones that record replay a single line. What this addon
adds is joining routes, searching them with A*, following obstacle edges, and rerouting
around blocks.

## License

BSD-3-Clause. See [LICENSE](LICENSE). Final Fantasy XI is a trademark of Square Enix. This
project is not affiliated with Square Enix or the Windower team.
