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

## Running it

	play.cmd            two windowed clients; the campaign is dealt once both are up
	play.cmd demo       two windowed clients dropped straight into a staged battle,
						for tuning how the battle feels to drive

Campaign: left-click your army, click a tile to march, click your own settlement to
recruit, End Turn bottom-right. The turn advances when every player has pressed it.
Battle: left-click or box-drag to select, right-click to move, right-drag to set the
facing you arrive on. WASD or screen edges pan, wheel zooms.

## Gates

	test.cmd       unit suite, headless, ~1s. Every source file must compile.
	nettest.cmd    two processes: mirror matches the server's bytes, orders are
                   validated, a foreign order is refused.
    camptest.cmd   two processes: campaign turns, armies meet, real-time battle,
                   casualties written back, campaign resumes. ~60s (battles run
                   in real time).

## Tests

	& "C:\Users\bojid\Downloads\Godot_v4.7.2-stable_win64.exe\Godot_v4.7.2-stable_win64.exe" --path "E:\rts test\new-game-project" --headless --script res://tests/run.gd

`tests/run.gd` extends `SceneTree` (Godot rejects a plain script for `--script`). Exit code 0
means green. Add a test file to the `TESTS` list in `run.gd` to register it.

## Measured

Snapshot cost with the `var_to_bytes` encoder (`tests/test_snapshot.gd` prints it):
**128 B/regiment**, so 100 regiments = 12.8 KB/snapshot = 125 KB/s per client at 10 Hz.
A realistic 40-regiment battle is ~50 KB/s per client. Fine on LAN, marginal over the
internet with several clients. Hand-roll a `PackedFloat32Array` codec (roughly halves it)
when that number starts to hurt, delta encoding after that.

## Things that were not obvious

- A campaign regiment is `[kind, strength]`, not a bare kind. Carrying only the kind
  handed a five-man regiment back to the campaign at full strength, so battles decided
  nothing and the same two armies re-fought forever.
- A battle ends both armies' movement for that turn, or a survivor with move points
  left simply attacks again, several times per turn.
- Battle snapshots carry an epoch. Snapshots are unreliable and the end-of-battle
  message is reliable, and nothing orders the two; without the epoch a snapshot still
  in flight resurrects a finished battle on the client.
- Autoload globals (`Net`) are NOT registered when a `--script` main script is parsed.
  The headless harnesses hold their own reference. View scripts are fine: they are
  loaded later, at runtime.
- `func f(): ... return null` infers the return type as `null`, and you cannot
  subscript that. Annotate `-> Variant`.

## Deliberate shortcuts

Marked in code with `# ponytail:` comments naming the ceiling and the upgrade path.
Currently deferred: delta encoding, client-side prediction, reconnect/host migration,
fog of war, AI opponents, NAT punch-through (LAN + direct IP only).
