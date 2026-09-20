# Total War–like prototype — architecture rules

2D. Godot 4.7. Turn-based campaign (Civ-like) + real-time battles (Total War-like).
Multiplayer is a hard requirement: listen server (one player hosts), server-authoritative, ENet + `@rpc`.

## Hard constraints

These are not style preferences. Breaking one costs a rewrite.

1. **Sim is pure.** Everything in `sim/` extends `RefCounted`, never `Node`. No scene-tree
   access, no input reading, no `_process`, no `get_node`, no signals to views. The sim must
   run headless in a test with no window and no tree.
2. **One entity per regiment.** The server simulates regiments and never soldiers.
   Soldiers exist only on the client (`view/battle/bodies.gd`), carry no game state, and
   nothing they do can change the outcome of a battle. A soldier's position is decoration;
   a regiment's position is truth. The wire stays at regiment granularity.
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
	play.cmd solo       one window, you against an AI opponent

An AI is a seat with a NEGATIVE id, which no ENet peer can ever be, so it is a player
everywhere that matters -- seating, colours, the end-turn ready check -- with no special
case anywhere in the order pipeline. It submits encoded orders through the same
`_receive_order` a remote packet lands in, so it passes the same validation a human does.
`host(port, false)` runs the server without taking a seat, for watching AIs play.

Campaign: left-click your army, click a tile to march, click your own settlement to
recruit or build, End Turn bottom-right. The turn advances when every player has
pressed it. Pike and cavalry need a barracks in the settlement raising them; walls
cut the damage a defender takes in a battle fought on that tile. Feed the army or
it deserts, and a starving army does not replenish either.
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
**135 B/regiment**, so 100 regiments = 13.6 KB/snapshot = 133 KB/s per client at 10 Hz.
A realistic 40-regiment battle is ~53 KB/s per client. Fine on LAN, marginal over the
internet with several clients. Hand-roll a `PackedFloat32Array` codec (roughly halves it)
when that number starts to hurt, delta encoding after that.

## Combat model

Battles are **frontage-limited**: output scales with the number of FILES in contact,
never with how many men a regiment contains. A regiment at half strength still fills its
front rank and hits just as hard; only one worn below its own width hits softer. Two
things follow, and they are the whole shape of a fight:

- Depth buys endurance, width buys output. Same casualties per second either way.
- A head-on tie **cannot break itself**. It is broken by widening, wrapping a flank,
  relieving a tired regiment, or shooting it.

Contact is measured between the two formations' **front ranks**, not their centres:
`reach()` is half a regiment's depth toward its front or back and half its frontage toward
a flank, taken from `max_strength` so the engagement distance does not drift as men die.
Two blocks now meet with their fronts about 13 units apart; centre-to-centre contact had
them interpenetrating by 35 and then drifting apart as they lost the overlapping depth.

Two angles matter per strike, not one. How the *defender* is hit sets what it suffers;
how the *attacker* stands sets how much of itself it can bring. That second one is what
makes a flank one-sided rather than merely favourable.

Measured (`tests/test_combat.gd` prints these):

	head-on, 60s        94/120 men left, still locked
	pinned + flanked    breaks at 11s, versus 75s frontally
	8s of fighting      13 lost when flanked, 5 when fronted
	same frontage       3-deep breaks at 32s, 10-deep at 75s
	two blocks meet     centres 94 apart, fronts 13 apart

## The men

`view/battle/bodies.gd` draws the soldiers, and everything in it is built on the **file**
-- the column running front to back -- because that was the fundamental unit of a real
formation, not the rank. A man is stored as `(file, depth)`, never as an index into a
flat array, and one rule covers every case:

> A man falls and the man **directly behind him in his own file** steps into his place.
> Everyone further back in that file closes up. No other file moves at all.

What changes with the angle of attack is only which man was standing in the way:

	front   the head of a file, so the file collapses forward
	rear    the tail of a file, so the file simply shortens
	flank   anywhere down the file at the struck end of the line, eaten inward

`BattleState.side_of()` gives FRONT / LEFT / RIGHT / REAR; `exposure_of()` is a view of it
that folds both flanks together, so the men know which flank while the damage maths does
not care. The engaged edges are worked out on the client from the mirror it already holds
and never go on the wire -- they decide which men fall, which is decoration.

Two more behaviours, both from how real formations worked:

- **The line is dressed.** After a frontal casualty a man crosses from the deepest file to
  the shallowest, so an emptied file does not leave a permanent hole. Not done after a
  flank or rear attack: the block has genuinely been eaten from that side and evening it
  up would undo the damage.
- **Men are relieved.** While fighting, a file rotates every `RELIEF_INTERVAL` seconds --
  front man to the back, everyone else up one. Cosmetic, and it is what makes a held line
  look like men working rather than a diagram.

Slots come from `max_strength`, computed once. Recomputing them from current strength --
which this used to do -- walked a regiment's drawn front rank backwards by 22 units as it
bled, so the men retreated from the fight they were in. Keying men by array index -- which
it also used to do -- made the man to the LEFT inherit a dead man's place instead of the
man behind him, so the block rippled sideways and nobody stepped forward.

Men chase their slots in **world** space, not local, so a regiment that turns or marches
drags them after it and they catch up. Easing in local space rotates the block rigidly,
which is the glued look.

Measured: 16 regiments x 120 men costs **3.25 ms/frame**, about 20% of a 60fps budget.
`tests/test_bodies.gd` prints it. If it ever stops fitting, the integration moves to a
shader rather than the look being abandoned.

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
- Contact stops a march INTO the enemy, not a march away from it. `_settle_state` used
  to force FIGHTING every tick while in contact, which silently cancelled a withdrawal
  order on the next tick and made relieving a tired regiment impossible.
- A regiment fights whichever foe is most nearly in front of it, not whichever has the
  lowest id. A unit pinned frontally must not turn its back to answer a flanker --
  that is the entire reason pinning-and-flanking works.
- Morale loss from casualties is measured against the men the regiment HAD when it was
  hit, not its paper `max_strength`. Against max_strength a regiment already down to a
  third felt each loss as lightly as a fresh one, so depth bought nothing.
- Wheeling in contact runs at `ENGAGED_TURN_MULT`. At full turn speed a flanked
  regiment simply faced its attacker within half a second and the flank evaporated.

## Deliberate shortcuts

Marked in code with `# ponytail:` comments naming the ceiling and the upgrade path.
Currently deferred: delta encoding, client-side prediction, reconnect/host migration,
fog of war, AI opponents, NAT punch-through (LAN + direct IP only).
