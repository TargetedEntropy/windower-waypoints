# windower-waypoints

[![tests](https://github.com/TargetedEntropy/windower-waypoints/actions/workflows/tests.yml/badge.svg)](https://github.com/TargetedEntropy/windower-waypoints/actions/workflows/tests.yml)
![Windower 4](https://img.shields.io/badge/Windower-4-blue)
![Lua 5.1](https://img.shields.io/badge/Lua-5.1-2C2D72)
![License: BSD-3-Clause](https://img.shields.io/badge/license-BSD--3--Clause-green)

**waypoints** is a [Windower 4](https://www.windower.net/) addon for Final Fantasy XI. You
record where you walk, and it builds a **graph of walkable routes** for each zone. You name
places on it, and `//wp go <place>` walks you there along the **shortest recorded path** (A*).
It opens closed doors on the way and **routes around blocked paths**.

Windower gives addons no map or collision data, so nothing is guessed: every route the addon
uses is one you walked.

> **Status: 0.2.0, untested in game.** The logic is covered by 62 offline tests (CI runs
> them on every push), but it has not yet been run on a live client. See
> [Verifying in game](#verifying-in-game) before relying on it.

## Contents

- [Features](#features)
- [Install](#install)
- [Quick start](#quick-start)
- [Commands](#commands)
- [How it works](#how-it-works)
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
- **Doors.** It opens closed doors on the path before you reach them, and remembers doors
  you opened by hand while recording.
- **Blocked-path detection.** When the walk stops making progress, it:
  1. tries to open a nearby door,
  2. then marks that stretch blocked and reroutes over another recorded route,
  3. then stops and tells you where.
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

The logic lives in four modules with no Windower dependencies, so it can be tested outside
the game. `waypoints.lua` connects them to Windower.

| File | Role |
|---|---|
| `graph.lua` | Nodes, edges, marks and recorded doors; nearest-node lookup; A* (binary heap) that can skip blocked edges; serialization |
| `recorder.lua` | Turns a stream of positions into nodes and edges |
| `navigator.lua` | Follows a list of points; reports arrival, being stuck or leaving the route |
| `doors.lua` | Which entities are doors, whether they're open, and which one is in the way |
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
  - you are blocked with no way around (below).
- Cutscenes, menus, resting and other statuses pause it, and it continues afterwards.

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

When you move less than 1 yalm in 3 seconds:

1. **Door.** If a closed door is close by, the walker stops, opens it, and waits up to
   4 seconds for it to open. It tries each door twice.
2. **Reroute.** Otherwise it marks the stretch of route it was on as blocked for 10 minutes
   and plans a new route from where you are, avoiding blocked stretches.
3. **Give up.** With no other recorded route, or after 3 reroutes, it stops and says where.

`//wp blocked` lists the blocked stretches. They are kept in memory only and are cleared
when you change zones or run `//wp unblock`.

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
| `nav.stuck_seconds` | 3.0 | Window for the stuck check |
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
- **Blocked means reroute, not steer.** Being stuck is detected after 3 seconds without
  progress. The answer is a different recorded route, not walking around the obstacle.
- **Doors.** Locked doors and doors that need a key item can't be opened. They become
  blocked stretches. Doors that open a menu wait for you.

## Safety and terms of service

- Third-party tools and automated input can conflict with Final Fantasy XI's terms of
  service. Use this addon for short walks you are watching, not unattended play.
- **Movement** uses Windower's `run` function, the same mechanism follow and assist addons
  use.
- **Doors** are opened with an injected interaction packet. It's the packet a click sends,
  but it's still automated. `//wp doors off` disables it.
- **What it doesn't do:** it doesn't answer menus, attack, warp, change your position
  directly, or move you without a `//wp go`.

## Verifying in game

These behaviours come from Windower's documentation and other addons, and haven't yet been
confirmed on a live client:

- `windower.ffxi.run(x, y)` runs along a normalised direction vector. This is the wiki's
  form, and FastFollow and Trust use it the same way.
- Status 5 (chocobo) and 85 (mount) are moving states. 85 comes from Gambit's code.
- Escape arrives in the `keyboard` event as DirectInput code 1.
- Doors have `spawn_type` 34 and status 8 while open (from OpenSesame and Windower's status
  table). Whether the status stays 8 for as long as the door is open hasn't been checked.
- `os.clock()` measures wall-clock time under Windower, as the Windows C runtime's
  `clock()` does. Other addons use it as a timer.

A first check:
1. Record a short loop in a quiet area and mark both ends.
2. Try `//wp route`, then `//wp go`, with a hand near Escape.
3. Then try a route through a city door: record it with the door open, and walk it with
   the door closed.

Please [open an issue](https://github.com/TargetedEntropy/windower-waypoints/issues) with
what you find.

## Development

The tests run on any machine with Lua 5.1. No Windower or game client is needed:

```
lua5.1 tests/run.lua
```

`tests/run.lua` does two things:

- It tests the four modules directly, using simulated movement.
- It loads `waypoints.lua` against a fake Windower, a small simulated world with walls and
  doors. It then plays through these sessions:
  - record, walk, reload, and stop when engaged
  - walk through a door that opens when poked
  - try a locked door twice, then reroute over a detour
  - stop at a dead end
  - remember a door opened by hand

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
| [Gambit](https://github.com/Kaiconure/Gambit) (`lib/smart-move.lua`) | Stuck detection from average speed; random "jitter" escape; detects a passed point with a halfspace test | Taken: stuck detection and the passed-point test. Avoided: random jitter. A supervised walker should stop and say why |
| [expert-umbrella](https://github.com/sethmccauley/expert-umbrella) (`navigation.lua`) | A node every 4 yalms; nearest-node start filtered by height | Taken: distance-based sampling, height filter |
| [FastFollow](https://github.com/DiscipleOfEris/FastFollow) | Multibox follow with normalised `run(x, y)` | Taken: normalised run vector |
| [OpenSesame](https://github.com/Lygre/addons/blob/live/OpenSesame/OpenSesame.lua) (Arcon) | Opens doors with an outgoing `0x01A`; doors are `spawn_type` 34; skips `_` names and `Furniture`; 7 s cooldown | Taken: door test, packet, cooldown, name filter. Added: only closed doors on the route; recorded doors override the filter |
| [DoorHelper](https://github.com/aragan/my-addons/blob/main/DoorHelper/DoorHelper.lua) | Finds doors by name; answers door menus "Yes" automatically | Avoided: answering menus |
| [FFXI-NavMesh-Builder](https://github.com/LandSandBoat/FFXI-NavMesh-Builder), [ffxi_navmeshes](https://github.com/Omnione/ffxi_navmeshes) | Navigation meshes built from the game's collision data, for private servers | Not used. Querying them needs Detour (C++), which plain Windower Lua can't load |

None of these builds a graph. The ones that record replay a single line. Joining routes,
searching them with A*, and rerouting around blocks is what this addon adds.

## License

BSD-3-Clause. See [LICENSE](LICENSE). Final Fantasy XI is a trademark of Square Enix. This
project is not affiliated with Square Enix or the Windower team.
