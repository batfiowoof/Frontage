# Total War–like prototype — architecture rules

2D. Godot 4.7. Turn-based campaign (Civ-like) + real-time battles (Total War-like).
Multiplayer is a hard requirement: listen server (one player hosts), server-authoritative, ENet + `@rpc`.

## Hard constraints

These are not style preferences. Breaking one costs a rewrite.

1. **Sim is pure.** Everything in `sim/` extends `RefCounted`, never `Node`. No scene-tree
   access, no input reading, no `_process`, no `get_node`, no signals to views. The sim must
   run headless in a test with no window and no tree.
2. **One entity per regiment.** A regiment is one sim object with strength/morale/position.
   Individual soldiers are render-time offsets computed by `sim/formation.gd` and have no
   logic, ever. Never give a soldier a script, a body, or a state.
3. **Server is authoritative.** Clients send orders and render mirrors. A client never mutates
   sim state. All mutation happens behind `if multiplayer.is_server()`.
4. **The host plays through the same order pipeline as everyone else.** No
   `if is_server(): apply_directly()` shortcut anywhere — the host's clicks become orders,
   travel through validation, and come back as snapshots exactly like a remote client's.
   This is the listen-server bug that eats a week.
5. **Every change to snapshot structure ships with a round-trip serialization test.**
6. **Battle sim ticks at a fixed 20 Hz**, decoupled from frame rate. Clients render at
   `now - 100ms`, interpolating the two bracketing snapshots.

## Layout

    sim/    pure logic, RefCounted only
    net/    transport, serialization, order validation
    view/   nodes, rendering, input, cameras
    tests/  headless asserts

## Tests

    & "C:\Users\bojid\Downloads\Godot_v4.7.2-stable_win64.exe\Godot_v4.7.2-stable_win64.exe" --path "E:\rts test\new-game-project" --headless --script res://tests/run.gd

`tests/run.gd` extends `SceneTree` (Godot rejects a plain script for `--script`). Exit code 0
means green. Add a test file to the `TESTS` list in `run.gd` to register it.

## Deliberate shortcuts

Marked in code with `# ponytail:` comments naming the ceiling and the upgrade path.
Currently deferred: delta encoding, client-side prediction, reconnect/host migration,
fog of war, AI opponents, NAT punch-through (LAN + direct IP only).
