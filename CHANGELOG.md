# Changelog

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
