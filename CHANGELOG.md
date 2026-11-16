# Changelog

## 0.3.0 (2026-11-16)

- **Obstacle avoidance.** A block is noticed within 0.6 s.
  - The walker probes headings 45°, 90° and 135° off the direct line, alternating sides and
    measured from the heading at the moment of the block.
  - It slides along the obstacle's edge, retrying the direct line every 0.6 s, and switches
    sides once if it runs out of room.
  - It gives up after 12 s or 8 yalms off the route on both sides. A closed door is opened
    instead of steered around.
  - `nav.avoid = false` restores the 3-second stuck check.
- **Rerouting** now starts from the last node passed instead of the nearest node, which
  could be on the far side of the obstacle.
- Tests: 74 offline checks, including a pillar, an L-shaped wall and an endless wall.

## 0.2.0 (2026-11-16)

- **Doors**
  - Closed doors on the path ahead are opened while walking.
  - Doors opened by hand while recording are remembered for the zone, and are opened even
    when their name would otherwise be skipped.
  - New command: `//wp doors [on|off]`.
- **Blocked paths**
  - When the walk stops making progress, it tries a nearby door first. If that fails, it marks
    the stretch blocked for 10 minutes and reroutes over another recorded route (up to 3
    times), then stops and says where.
  - New commands: `//wp blocked`, `//wp unblock`.
- Zone files now also store recorded doors. Files from 0.1.0 still load.
- Tests: 62 offline checks, including whole addon sessions in a simulated world with walls
  and doors.

## 0.1.0 (2026-11-16)

- First version: record routes into a per-zone graph, name places, and walk to them along
  the shortest recorded path (A*).
- Stops on Escape, `//wp stop`, being stuck, leaving the route, being engaged, dying or
  zoning; pauses during cutscenes.
