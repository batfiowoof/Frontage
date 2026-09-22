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
	play.cmd fight      one window, straight into a staged battle against an AI.
	                    The only mode that puts an AI and a battle on screen at the
	                    same time -- `demo` has NO AI in it at all, both of its armies
	                    are player-driven, and `solo` starts you on the campaign map

An AI is a seat with a NEGATIVE id, which no ENet peer can ever be, so it is a player
everywhere that matters -- seating, colours, the end-turn ready check -- with no special
case anywhere in the order pipeline. It submits encoded orders through the same
`_receive_order` a remote packet lands in, so it passes the same validation a human does.
`host(port, false)` runs the server without taking a seat, for watching AIs play.

Campaign: left-click your army, click a tile to march, click your own settlement to
recruit or build, End Turn bottom-right. WASD or drag to pan, wheel to zoom. The turn
advances when every player has pressed it. Pike and cavalry need a barracks in the
settlement raising them; walls cut the damage a defender takes in a battle fought on that
tile. Feed the army or it deserts, and a starving army does not replenish either.
You only see what your armies and towns can see, and only ever having seen a hex is enough
to keep it on your map. Raise a settler and march it somewhere clear to found a new town.
Towns grow on a food surplus and resent being conquered; hold more than you can govern and
one of them will throw you out. An army can force its march, dig in, or lie in wait.
A regiment that survives a battle brings its experience to the next one. The campaign ends
when somebody is the last one standing, or on settlements at TURN_LIMIT.
Regiments build up to a march and brake into a stop; they hold the facing you gave them
and walk in any direction, so ordering one backwards does not spin it round. Turning right
round is an about-face and moves nobody. Fighting AND marching tire a regiment, and a
spent one hits softer, dies faster, falls behind and breaks sooner.
Battle: left-click or box-drag to select, right-click to move, right-DRAG to draw the
line itself -- press and release are the two ends of the formation, the facing is square
to it, and the LENGTH is the frontage: drag long for a thin wide line, short for a deep
block. Right-click an enemy to attack that one. G guards, H skirmishes,
ctrl+1-9 remembers a group and 1-9 recalls it, and there is a button to give up the
field. WASD or screen edges pan, wheel zooms.

## Gates

	test.cmd       unit suite, headless, ~1s. Every source file must compile.
	nettest.cmd    two processes: mirror matches the server's bytes, orders are
                   validated, a foreign order is refused.
    camptest.cmd   two processes: campaign turns, armies meet, real-time battle,
                   casualties written back, campaign resumes. ~30s: the judge fights
                   for a bit and then forfeits, because a formed head-on tie now runs
                   past two minutes and this gate is about the handoff, not the grind.
    aitest.cmd     one process, two AIs, nobody watching. The broadest smoke test there
                   is: it plays turns, builds, researches, expands, fights a real battle
                   and comes back from it.

## Tests

	& "C:\Users\bojid\Downloads\Godot_v4.7.2-stable_win64.exe\Godot_v4.7.2-stable_win64.exe" --path "E:\rts test\new-game-project" --headless --script res://tests/run.gd

`tests/run.gd` extends `SceneTree` (Godot rejects a plain script for `--script`). Exit code 0
means green. Add a test file to the `TESTS` list in `run.gd` to register it.

## Measured

Snapshot cost with the `var_to_bytes` encoder (`tests/test_snapshot.gd` prints it):
**203 B/regiment**, so 100 regiments = 20.4 KB/snapshot = 199 KB/s per client at 10 Hz.
A realistic 40-regiment battle is ~80 KB/s per client. It was 195 before veterancy put
`xp` on the regiment. Fine on LAN, marginal over the internet with several clients.
Hand-roll a `PackedFloat32Array` codec (roughly halves it) when that number starts to
hurt, delta encoding after that.

The campaign snapshot is ~2.5 KB, and it now goes out **once per player** rather than once
-- see **Fog of war**. Turn-based, so a handful of encodes on a click is nothing.

## Combat model

Battles are **frontage-limited**: output scales with the number of FILES in contact,
never with how many men a regiment contains. A regiment at half strength still fills its
front rank and hits just as hard; only one worn below its own width hits softer. Two
things follow, and they are the whole shape of a fight:

- Depth buys endurance, width buys output. Same casualties per second either way.
- A head-on tie **cannot break itself**. It is broken by widening, wrapping a flank,
  relieving a tired regiment, or shooting it.

**Two blocks that have met are pushed apart until they are only touching.** Contact STOPS
a march into an enemy, but nothing ever walked a regiment back OUT, so an overlap arrived
at by any route -- a charge overrunning by a tick, a rout crossing the field, a re-form
changing how far a regiment reaches -- was permanent, and the two of them fought on
interleaved. Measured over a whole AI battle before `_separate` existed:

	a third of all contact-ticks had a NEGATIVE gap, the worst of them 113 units

That is most of a frontage. It is 3% of them now, and nearly all of what is left is a
ROUTING regiment running through, which is what a fleeing mob does. Enemies only: two of
your own regiments overlapping read as one mass of one colour, which is untidy rather
than confusing, and the fix for that is the spacing they were ordered into.

This is why it did not look like the men were in contact. They were not in contact, they
were merged, and two armies drawn on top of one another have no seam to read. It also
made honest a measurement that had been flattering us -- see **Going round the end of a
line**, because two merged blocks have an arbitrary angle between them and `exposure_of`
was reporting flank and rear more or less at random.

Contact is measured between the two formations' **front ranks**, not their centres:
`reach()` is half a regiment's depth toward its front or back and half its frontage toward
a flank, taken from `max_strength` so the engagement distance does not drift as men die.
Two blocks now meet with their fronts about 13 units apart; centre-to-centre contact had
them interpenetrating by 35 and then drifting apart as they lost the overlapping depth.

Two angles matter per strike, not one. How the *defender* is hit sets what it suffers;
how the *attacker* stands sets how much of itself it can bring. That second one is what
makes a flank one-sided rather than merely favourable.

Measured (`tests/test_combat.gd` prints these):

	head-on, 60s        82/120 men left, morale 23, spent, still locked
	pinned + flanked    breaks at 11s, versus 42s frontally
	8s of fighting      18 lost when flanked, 9 when fronted
	same frontage       3-deep breaks at 14s, 10-deep at 42s
	two blocks meet     centres 57 apart, fronts 12 apart
	3s of contact       a charge kills 6, a shoving match 2
	4s of charge        a line loses 6, a braced square 1

These moved when the default frontages went from ~10 ranks to 4-6 (see **Formations**).
A line that stands 20 files wide instead of 12 puts 20 files in contact, and output
scales with files, so **everything bleeds about 1.7x faster than these numbers used to
say**. The one knob that undoes it without touching the shapes is
`KILLS_PER_FILE_PER_SEC` (0.06; 0.036 restores the old pace exactly).

The casualty ratios held -- a flank is still 5x a frontal fight -- but one absolute did
not: a head-on tie began resolving itself at **68s** where it used to run to the
`BATTLE_TIME_LIMIT`, and it is **42s** now. "A head-on tie cannot break itself" is
therefore weaker than it reads above: it still cannot be broken QUICKLY, but it no longer
cannot be broken at all. The erosion is tracked where each piece of it happened -- see
**Exhaustion** and **Coming back, which used to be free**.

## Marching, wheeling, and turning about

**A regiment builds up to its pace and brakes into its destination.** There was no
velocity anywhere: it was at full speed on the first tick of an order and still at full
speed on the tick it arrived, where `r.pos = r.target` snapped it up to a whole stride.
`pace` is server-side like `damage_pool` -- it starts at zero, a replay opens from a
snapshot where nothing is moving, and a client only draws interpolated positions.

`ACCELERATION_SECONDS` is a TIME to top speed, not a rate. A flat units/s^2 has a column
and a line cover identical ground in the first second because both are still winding up,
and the whole point of a column is that it is quicker. As a time, everything scales with
its own top speed. `ARRIVE_CRAWL` is the floor that lets it actually arrive: braking alone
approaches the target asymptotically forever.

**Movement has no front, and never needed one.** `r.pos +=` walks straight at the target
whatever way the block faces. What put a front on it was one line at the bottom of
`_advance`, `_turn_toward(r, to_target.angle(), dt)` -- the regiment turned to face
wherever it was walking, so ordering one to a point BEHIND it swung the whole block round.
It now holds the facing it was **ordered**, and `plan_order` was already sending the right
thing: a plain click orders the facing toward the destination, a right-DRAG orders the
line you drew. The sim was overriding the view.

**Turning right round is an ABOUT-FACE, and costs no rotation at all.** A rectangle
rotated 180 degrees about its centre stands on exactly the same ground, so it is a
relabelling and not a wheel: `file -> width-1-file`, `depth -> ranks-1-depth` negates a
man's slot, and rotating a negated slot by `facing + PI` returns his original world
position -- every man, exactly. Measured in `test_turning_right_round_moves_nobody`:

	about-face WITH the relabel      nobody moves more than 1 unit
	the same flip WITHOUT it         111 units, and that is the spin

So the sim flips `facing` in a single tick, `bodies.gd::_turn_about` relabels, and the only
thing that visibly moves is each man turning his own body round over about a second. The
rear rank becomes the front rank, which is what an about-face IS.

Three things hold that up, and all three are tested:

- **It is refused in contact.** A regiment taken in the rear that could flip to face its
  attacker would delete the flank-and-rear mechanic outright. In a melee it has to wheel
  round slowly at `ENGAGED_TURN_MULT` and eat the rear attack while it does.
- **The view must not interpolate across it.** `_pose_of` eases `facing` between 10 Hz
  snapshots; easing across a flip sweeps the block through ninety degrees, which is the
  exact thing this exists to avoid.
- **A depleted regiment does move a little.** Its men sit in the front part of the nominal
  block, so after turning about the files re-dress forward by the empty depth. A full one
  does not move at all.

**A wheel -- a real change of ground, 90 degrees or less -- is slower than the men march,
and that is the bar.** `TURN_SPEED` is not a free number: a 20-file block reaches 66.5
units out, so the ceiling is `MOVE_SPEED / 66.5`. It was 3.0, which put the end file
through 209 units in a second: **200 u/s against a 70 u/s march, three times faster than
the men could walk.** 0.9 was still 60 against 45. It is 0.6, and
`test_a_wheel_never_outruns_the_men` pins it.

## Exhaustion

One idea read four ways, each `lerpf(worst, 1.0, stamina)`:

	readiness()      damage DEALT     1.0 -> 0.45
	vulnerability()  damage TAKEN     1.0 -> 1.35
	legs()           marching pace    1.0 -> 0.60
	nerve()          its own morale   1.0 -> 1.50

Only the first existed. Exhaustion reached damage dealt and nothing else -- not what a
tired man suffers, not how fast he walks, and not how soon he breaks. `nerve()` is the
defender's OWN exhaustion making it break sooner, which is a different thing from the
attacker's `readiness()` inside `pressure`: that is how hard he can press.

**Marching tires**, by the pace actually kept, so a walk costs little and a rout costs more
than a march. Crossing the field used to be free, which put no price on a flanking march
at all. A regiment on a long march therefore never quite reaches its paper speed -- it is
always being fought by its own `legs()`, and `test_a_regiment_builds_up_to_its_pace` pins
that gap rather than pretending it is not there.

**This cost the head-on tie another fifteen seconds**, and it is worth being plain about
which part did it. The tie ran to 68s; it now breaks at **53s**. Measured with the tired
morale term switched off entirely it still breaks at 55s, so it is `TIRED_VULNERABILITY`
-- heavier casualties -- doing almost all of it, and `nerve()` is worth about two seconds.
"A head-on tie cannot break itself" has now eroded from never, to 125s, to 68s, to 53s.
`TIRED_VULNERABILITY` is the dial if that is too far.

## Formations

Six shapes in `Rules.FORMATIONS`, and a frontage the player sets directly by right-DRAGGING
the line. Under frontage-limited combat these are real decisions, not costumes -- width buys
output, depth buys endurance, and every number in the table feeds something the fight
already reads.

	line     balanced, the default
	column   narrow and quick; good on the road, bad if caught
	square   no flank or rear penalty at all, but few files and slow
	wedge    hits harder, narrower front
	loose    stands nearly twice as wide, poor in a melee, hard to shoot
	shield   heavy frontal protection, very slow to turn, braced

Picking a shape resets the frontage to what that shape wants; a right-DRAG sets it
directly, and `[` and `]` nudge it.

**Changing SHAPE costs; changing FRONTAGE does not.** A formation is a manoeuvre and
takes `FORMATION_CHANGE_SECONDS` at `REFORM_PENALTY`, so it has to be chosen before the
moment it is needed rather than at it. Widening or narrowing the line is dressing it:
free, immediate, at full output, and never refused. `set_width` used to charge the same
six seconds AND refuse while one was running, which made the drag that sets frontage
expensive to use and silently rate-limited `[` and `]` to one press every six seconds --
the second press was dropped by a guard with nothing anywhere to say so.

**Free, but it does not arrive before the men do.** The men have to walk into their new
files, and until they are there the regiment goes on fighting at the frontage it is
actually standing in: `was_width`, blended out over `dressed`, read by `files_engaged`.
Both are server-side like `pace` -- they start settled and a replay rebuilds them from the
orders -- and `dressed` defaults to 1.0, which is what keeps everything that writes
`width` directly honest. Snapshot decode and every test that pokes `r.width = 24` leave it
at 1.0 and get the width they asked for. Only `set_width()` starts a ramp.

Without that, a regiment already locked in a melee -- which cannot walk anywhere, because
`_settle_state` snaps it back to FIGHTING with `target = pos` -- still took the
SET_FORMATION from the same drag and **doubled its output in place in 50 ms, for
nothing**. Dragging a wide line across a melee was the cheapest thing in the game.

`reach()` deliberately still reads `width` and not the blend: the footprint is in flux
while the men walk anyway, and ramping it too would have contact distance wobbling through
every re-dress for no gain.

The ramp and the walk take the same time by construction, not by two constants that agree
today -- both are `|frontage(new) - frontage(old)|` over `DRESS_SPEED`. The HUD counts down
the walk you are watching, where it used to assert a flat three seconds while the men
finished in under one.

**The default frontages are 4-6 ranks, not 10.** They used to be near-square -- a
120-man spear at 12 files was 77 units across by 81 deep, and a sword was 63 by 81,
*deeper than wide*. Ten ranks is not a line, it is a block, and it is what made a
regiment read as one blob whatever you did to it. A frontage is also not a free number
to pick: `DEPLOY_SPACING` is a frontage plus a shoulder, and at 110 against the new
133-unit width the regiments in a deployed line stood 23 units inside one another.

Measured (`tests/test_formations.gd` prints these):

	24 files vs 6 files      16 killed against 4 over 12s
	spears vs cavalry, 8s    a line loses 6 and kills 9
	                         a shield wall loses 2 and kills 15

Two things that are easy to get wrong here:

- **Contact is front rank to front rank, so a wider regiment is a shallower one and
  reaches less far forward.** Two regiments placed at the same centre distance may be
  locked together or not touching at all depending only on their shapes. Tests that set
  up a fight have to position them from `BattleState.reach()`, not from a fixed gap.
- A square is deliberately narrow, so its brace bonus cannot out-kill a full line however
  well it is set. Its job is not being flanked; the shield wall's is standing in front of
  horses.

## Morale, and the man it hangs on

**Morale measures how badly you are being handled, not how long you have stood there.**
It used to be two independent full-strength sinks summed -- a flat
`MORALE_DRAIN_FIGHTING` and a casualty term -- each tuned to break a regiment on its own.
A head-on duel routed at 75s having lost 31 of 120 men: **26% casualties for 80% of the
morale**, a regiment collapsing while visibly barely scratched, and a head-on tie
breaking itself, which is the one thing the combat model says cannot happen.

The flat drain is now a nudge and the casualties carry the frontal fight. Flank (5/s) and
rear (12/s) are untouched, so breaking a formed enemy from the front takes minutes and
from the flank seconds -- and the *ratio* between them got sharper, not softer.

**Shock scales with how hard the attacker can actually press.** Damage passes through ten
multipliers and shock used to pass through one, so an exhausted regiment at 0.45
readiness, a loose order at 0.55 damage and one mid-reform all frightened a man exactly
as much as a fresh block did.

**The rally was unreachable code.** `Regiment.recover()` has always known how to rally at
`MORALE_RALLY_THRESHOLD`, but the sim only called it in the IDLE branch and a router is
never IDLE. Broken men who get clear now pull themselves together.

### Coming back, which used to be free

A regiment breaks at 20 and rallies at 45, so the number that matters is the climb between
them. At the old `MORALE_RECOVERY` of 4.0/s that was **six seconds** -- against a frontal
melee drain of 0.15 to 0.225/s. One second of standing still undid eighteen to twenty-seven
seconds of fighting, and it could be done all battle.

Four things now stand between a broken regiment and the line:

- **`RALLY_DELAY` first.** Breaking contact used to start the climb on the very next tick,
  because a router clears `CONTACT_GAP` in well under a second at `ROUT_SPEED_MULT`.
- **`MORALE_RECOVERY` is 1.2/s**, so a rally costs the better part of a minute.
- **`morale_ceiling()` caps it at `MORALE_MAX * fraction()`.** A regiment that broke at 41%
  casualties used to climb all the way back to a full bar in twenty seconds and return as
  though nothing had happened. There was no permanent morale damage of any kind, and that
  is most of why units seemed to recover instantly.
- **`ROUTS_BEFORE_SHATTERED`.** Past three breaks a regiment is finished: `recover()`
  refuses to rally it however calm it gets, and it runs until it is off the field. Total
  War's shattered state, and what stops a broken flank quietly re-forming.

Recovery also follows **safety, not state**. It was gated on the state machine, so a router
pulled itself together at 4.0/s while a regiment merely repositioning recovered nothing --
running away restored morale and manoeuvring did not. `_hearten()` now covers IDLE, MOVING
and ROUTING alike, gated on being out of contact and having had its moment.

### What breaks a line, which is the whole shape of a battle

`Regiment.shock()` has always documented *"seeing a neighbour break"* as one of its
callers. **Nothing ever called it for that.** Every regiment's morale was entirely its own
business, so two lines simply ground each other down until one happened to cross a
threshold, and battles were decided by attrition. `_spread_panic()` is where a battle gets
its shape instead:

	PANIC_SHOCK      a routing friend within PANIC_RADIUS frightens you
	COLLAPSE_SHOCK   your army being under ARMY_BREAKS of itself frightens you
	ALONE_SHOCK      having nobody within SHOULDER_RADIUS frightens you
	CHARGE_HEART     ...and being mid-charge puts heart back

The first is the one that matters: one break at the end of a line travels down it, so a
battle now ends suddenly from one flank. `COLLAPSE_SHOCK` has to beat `MORALE_RECOVERY`
handily or the two simply cancel -- at 2.5 against a 1.2 climb through the general's 0.7,
a collapsing army bled half a point a second and never actually went.

All of it passes through `GENERAL_STEADY`, so a commander holds a line together against
exactly the thing that unravels it.

**The head-on tie is down to 41s**, from 53. That figure has gone 125 -> 68 -> 53 -> 42
-> 41 across the frontage retune, the exhaustion work, panic, and veterancy. `PANIC_SHOCK` and
`TIRED_VULNERABILITY` are the dials if it has gone too far.

**The biggest regiment on each side carries the general.** No unit to recruit and nothing
new on the campaign map. He steadies the men within `GENERAL_RADIUS` -- himself included,
which is why a commander in the line is worth something -- routers rally faster near him,
and losing him shakes the whole army once. He is **not on the wire**: he falls out of
`max_strength` and the ids, both of which the snapshot already carries, so the server,
every client and a replay all derive the same man. Commissioned over the dead as well as
the living, or an army would lose its general and instantly acquire another.

## The charge

Arriving at a run multiplies damage by `CHARGE_MULT`, decaying to nothing over
`CHARGE_SECONDS`. Only from MOVING: taking it whenever the contact list changed would
make a one-off bonus permanent. A braced formation takes `CHARGE_BRACED` of it out, so
square and shield wall finally repay the frontage they cost, and **when** you release the
cavalry is the decision. Without it a horse was fast infantry that killed more slowly
than a spearman.

## Giving up

A battle can now be **forfeited**. Survivors go home, the field goes to the other side,
and the army falls back to an adjacent passable empty hex minus `FORFEIT_STRAGGLERS` --
the men who did not get away. Cornered with nowhere to go it stays put and still loses the
ground; being wiped out for being surrounded would make one bad hex an instant loss.

The AI quits when it is **outnumbered AND coming apart**, never on the headcount alone: a
smaller army that is still formed can hold, and resigning on the count would have it give
up fights it was winning. Before this, a losing AI ground every lost battle out to
`BATTLE_TIME_LIMIT`.

**A forfeit only FLAGS the battle; `_process` ends it inside the tick loop.** Ending it
from the order handler left that tick's orders in the closing snapshot while
`Replay.replay()` stops before applying them, so the recording no longer reproduced
itself -- `_keep_the_recording()` caught it exactly as it was designed to.

## Going round the end of a line

The AI sends its **spare** regiments round a flank instead of making a longer line. Foot
used to be sent to SLOTS rather than to enemies, so a regiment with nobody in front of it
stood in its slot doing nothing, and the only thing that ever went round was the cavalry
sweep.

It is **self-limiting by construction**: a regiment wraps only if nobody is on it, so two
matched lines produce no envelopment and it starts exactly when you are outnumbered
locally. It also waits for the lines to MEET -- envelopment answers a fight that exists,
it is not an opening move.

**The line is laid out to OVERLAP theirs at the ENDS, and that is where the envelopment
comes from.** `LINE_SPACING` was a flat 110 units per regiment -- narrower than the 150 the
two sides deploy at, and narrower than the 133 a regiment physically occupies, so the AI
ordered its own line to stand INSIDE ITSELF and arrived as a clump. It was always the
lapped line, never the lapping one, and no regiment ever found itself past a flank with
nobody in front of it. Same trap as `DEPLOY_SPACING`: a spacing between regiments is a
FRONTAGE plus a shoulder, never a free number.

**Only the outermost regiment on each side stretches out, and the whole line keeps facing
forward.** The first attempt at this spread EVERY slot and aimed each one at the enemy
centre, which put three regiments across 883 units against the enemy's 583, left 242 units
of open ground between neighbours, and turned the wings **72 degrees off the line of
advance** -- walking in with their own flanks presented, which is the one thing the combat
model says not to do. It was not a line with horns, it was three detachments going the same
way, and it still scored well on "how much contact lands on a flank" because a
disintegrating line ends up beside the enemy by accident. Two things keep it honest now:
the wings stretch by at most enough to leave one regiment's own width of open ground beside
them, and **a regiment walking at the enemy faces the enemy** -- turning in is `_wrap`'s
job, after contact, with a latched waypoint and a focus order.

`tests/test_encircle.gd` guards the SHAPE as well as the destinations, because every test
written the first time round checked where an order pointed and none of them noticed the
formation had come apart.

Three more things, and the last is the one that matters:

- **The outward leg is latched.** A flank position is by definition a point worked out
  from a moving enemy, which is the shape of bug that has already eaten the archers, the
  cavalry sweep and the withdrawal step in turn.
- **The waypoint is pulled BACK to our own side** by `WRAP_BACK`. A point level with the
  enemy's flank is reached by cutting the corner, straight through the fighting it was
  supposed to go round -- clipping in and out of contact the whole way, which took a 120s
  battle from 66 changes of "how many of us are locked in" to 180.
- **The last stretch is not an order at all.** On arrival the regiment NAMES the man it
  came for and `BattleState._pursue` closes from whichever side it is standing on,
  recomputed in the sim every tick with nobody issuing anything. `sim/ai.gd` had never
  emitted `Orders.focus` before this; it is the cleanest lever in the file, because it is
  the one order whose target keeps itself current.

Two faults this turned up in the cavalry sweep beside it: its side was
`r.pos.dot(across)` -- signed distance from the **world origin**, so two horsemen both on
the left of our line but right of the map's middle both swung the same way -- and
`_sweep_to` was never pruned, so a dead regiment's waypoint persisted and ids from the
LAST battle silenced a regiment in this one. The AI object outlives the battle.

Measured (`tests/test_encircle.gd` prints it), over a whole four-a-side AI battle:

	before          97% of contact into a FRONT, 3% round the side
	stretched line  56% front, 44% round the side -- but see above, that line
	                had come apart and the number flattered it
	coherent line   73% front, 27% round the side -- flattered too, by regiments
	                standing INSIDE one another, which leaves exposure_of an
	                arbitrary angle to report
	now             83% front, 17% round the side, with the blocks separated

That outcome test is the only one here that measures the RESULT rather than the orders, and
the only one that would still fail if every piece of the geometry were right and the
manoeuvre were useless. It is also, on its own, not enough, and twice over: 44% from a
broken formation scored better than 27% from a coherent one, and 27% from merged blocks
scored better than 20% from separated ones. Both times the number went DOWN as the thing
got better, which is why the shape guards sit beside it, and why none of these figures
means anything quoted without the ones above it.

## Telling a regiment what to do

- **Attack that one.** Right-click an enemy and `focus` means "the enemy this regiment
  has been told to deal with", read in three places: the volley target, the melee
  opponent, and a chase that walks it across the field. The chase lives in the **sim** and
  is recomputed each tick rather than being re-issued orders -- a unit re-ordered every
  tick at a point worked out from a moving enemy never arrives, which has bitten the
  archers, the cavalry sweep and the withdrawal step in turn. An archer that can already
  reach its mark stands still, because standing still is how it shoots.
- **Guard** holds the ground and suppresses the chase. **Skirmish** backs a missile unit
  away from whatever closes inside `SKIRMISH_TRIGGER` of its own reach, and stops once
  the quiver is empty because there is nothing left to protect. One bitfield, one order.
- **Ctrl+1-9** remembers a selection and **1-9** recalls it. View only -- a control group
  is a note about what you are looking at, not a fact about the world.

## The ground

A battle is fought on the hex the armies met on. `BattleState.lay_ground()` puts a
handful of **circles** on the field -- woods, hills, marsh -- chosen by that hex's terrain
and seeded from the tile and the turn, so the same meeting always produces the same
field and a replay of it still lines up. Circles rather than a grid: a few of them say
everything a prototype needs, cost nothing to send, and are trivial to test against.

Woods slow men and hide them from arrows; hills make the men on them hit harder and shoot
further; marsh is miserable to fight in. Overlapping patches take the worst of each, so a
wood on a hillside is slow *and* gives cover instead of cancelling into open field.

## Shooting

Archers fire a volley every `reload` seconds at whatever is in range, and have a finite
quiver. Two rules make them a question of where you put them rather than a number:

- **Nobody shoots through their own line.** A friendly regiment between the archers and
  their target blocks the shot, so bows go on a wing or in front and have to be pulled
  back before the lines meet.
- **Not on the move and not in a melee.** A bow needs a moment and both hands, so a
  regiment that is still walking never looses.

Out of arrows they are simply bad infantry, which is what stops a missile duel being free.
Formation matters more here than anywhere: over 16 seconds under the same archers, a line
loses 48 men, loose order 18, and a square 59.

Selecting archers draws their reach as a ring, and rings the enemies inside it: gold for
the ones they can actually hit, red with a line back to the shooter for the ones a friend
is standing in front of. **The ring alone would lie** -- nobody shoots through their own
line, so half of what falls inside the circle may be unshootable, and which is which is
the thing you are really asking. The ring greys out once the quiver is empty, and the
order preview draws it at the destination too, since reaching further is most of why you
move an archer at all.

The AI holds its archers back until something is in range and then **stops re-ordering
them**. This is the third time that shape of bug has appeared -- a unit chasing a point
computed from a moving enemy centre never arrives, so it never does the thing arriving was
for, and the battle never ends. The cavalry sweep latches its waypoint for the same reason.

## Ordering a battle move

`BattleView.plan_order()` works out, for every selected regiment, where it will stand and
which way it will face. **The preview and the order both read its rows and neither
computes anything of its own.** That is the only way a preview stays honest: when the
spread rule changes, the ghosts change with it instead of quietly lying.

It takes a pose dictionary rather than reaching for the scene tree, so it tests headless
the way `bodies.gd` does.

**The drag IS the line**: where you press and where you release are the two ends of the
formation, and the facing is perpendicular to it.

**And the drag sets their FRONTAGE, not the air between them.** Each selected regiment
takes an equal share of the line and stands that many files wide, so they finish shoulder
to shoulder as one continuous line. `_files_for()` inverts `Formation.frontage()` to turn
a share of the drag into a file count; the drag length used to become `extra`, slack
inserted BETWEEN neighbours, so a long drag gave the same blocks further apart and a
regiment never changed shape at all. **Nothing else in the game wrote a regiment's width
except the formation bar and `[` `]`**, which is why it read as one immovable blob however
far you dragged. With ONE regiment selected it was worse than useless: the slack was
divided by `n - 1`, so a lone unit was sent to the PRESS point at its original width.

One clamp, in `plan_order` so the ghost shows the shape the regiment is going to be in:

- `DRAG_MAX_RANKS` floors the frontage. Shoulders alone exceed a short drag over several
  regiments, so the share goes negative and the raw answer is `MIN_WIDTH`: two files,
  sixty ranks deep. The `column` and `square` buttons still reach the extremes, because
  `natural_width()` does not come through here.

Both of the clamps that used to sit beside it are gone, and the file says so: a two-file
deadband, and a `reforming > 0` fallback. They existed only to keep an ordinary move-drag
from spending `FORMATION_CHANGE_SECONDS`, and frontage stopped costing that.
`test_order_preview.gd` now tests the ABSENCE of the second one.

A regiment has a maximum frontage, so a drag longer than the men can stand in **caps and
centres** rather than stretching, and the ghost says so by not growing. Tests here measure
FILES; how far apart the targets ended up is a side effect.

The frontage rides out as a second `SET_FORMATION` order beside the move rather than a
sixth element on `BATTLE_MOVE`, because `SET_FORMATION` already carries a width and every
`.rpl` ever recorded decodes `BATTLE_MOVE` as exactly five elements. The formation goes out
UNCHANGED on purpose: `_set_formation` only reaches `set_width` when `set_formation`
returned false, and asking for the shape it already has is what makes it return false.

Three quieter faults went with the original: slots were spaced by each regiment's own
half-width, so a mixed selection was ordered to stand inside itself; they were handed out
in id order rather than left to right, so box-selected lines crossed on the way; and
`half_width` came from current strength while `half_depth` and the sim's own `reach()` came
from `max_strength`, so the honest preview lied about any regiment that had taken losses.

Each ghost is the regiment's real footprint -- `Formation.frontage()` and `half_depth()` at
`max_strength`, at **the width it is being ordered into** and its formation's spacing -- so
the preview shows the reshape while you are still dragging. Frontage is what decides the
fight; it should not be invisible until after you have committed.

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

**Every man has his own facing**, and turns toward whichever enemy is nearest to *him*
rather than the one his regiment is nominally fighting. A flanked regiment therefore has
its end files coming round while its front rank keeps fighting forward, and something
hitting the rear turns the back ranks about while the front is undisturbed. Men who turn
also edge toward what they have turned to face, so the struck edge thickens and bows into
a hook -- refusing the flank, arrived at by men reacting rather than by the block being
re-laid out.

**And the line he is standing in BENDS ROUND what it is fighting.** This is the one that
makes an encirclement something you can see rather than something the orders imply: two
rectangles meeting edge-on read as two rectangles however they got there.

The men are mapped onto an arc around the enemy, keeping the clearance they already had.
The behaviour falls out of the geometry instead of being posed -- the middle man of a line
is NEARER the enemy than the man at its end, so bringing everybody to the middle man's
standoff carries **the ends forward** until a straight line has become a crescent. The
middle man has no offset along the line and therefore does not move at all.

**Only the WIDER of the two bends, and only by as much as it is wider.** Both sides
wrapping is self-defeating and cannot be tuned away: each regiment is happily outside the
other's block, so the two of them meet in the open ground beside it -- measured, our man
at (0, 33) and theirs at (0, 33), the same square yard. It is the honest rule as well,
because you envelop somebody by OVERLAPPING him and two lines of a width overlap nowhere.
Equal frontages meet flat, deliberately, and `_advantage()` scales everything between.
It is also what gives the frontage you set by dragging a visible payoff: widen your line
and you wrap round him.

**It is the enemy's BOX that is bent around, not his centre.** A regiment is wide and
shallow -- 133 across against 45 deep -- so an arc at a constant distance from its middle
clears the front comfortably and is well inside the flanks by the time it gets there. The
threat therefore carries its footprint (half-depth, half-frontage, facing) beside its
position, and a man keeps the same clearance from that outline the whole way round.

A box and not an ellipse, which was the first try and looks like a harmless
simplification. It is not: a 12-file block is nearly square, and an ellipse inscribed in a
square is **fifteen units short of it at the corners**, so men cleared its flanks by a
comfortable margin and stood in its corners. The approximation failed worst in the one
place it mattered.

**And under all of it, `KEEP_CLEAR`: nobody stands inside the men he is fighting.** A hard
clamp, applied last, against every enemy in contact rather than only the one a man is
dealing with -- somebody caught between two of them is otherwise clear of one and inside
the other. It has to cover THEIR lean as well as his own body: `CONTACT_GAP` is 14, and
seven units of `LEAN` from each side closes the whole of it, so the two front ranks landed
in the same place.

`WRAP_MAX` is 140 degrees -- the ends come right round onto the flanks and a little past,
a full envelopment rather than a bow. `WRAP_FADE` matters more than it looks: fading the
bend by distance the whole way made the ENDS of a line bend least, and the ends are
exactly the men who should be coming round, so it now fades only at the very edge of the
notice band. `LEAN` sits beside all this doing a different job -- `LEAN` moves a man
TOWARD what he faces, the bend moves him AROUND it, and `KEEP_CLEAR` overrules them both.

Measured (`tests/test_bodies.gd` prints these):

	a wider line's front rank    125..136 units from the enemy, was 132..155
	closest man to enemy man     4.9 units, 0 overlapping pairs; without the
	                             clamp it is 0.1 units and 6 pairs, against a
	                             body 4 across

It is a rendering displacement and nothing more: a man keeps his `(file, depth)`, and
`places()` is identical with and without an enemy in front of him. The moment the bend
re-filed anybody, every invariant above would be up for grabs.

How far back the reaction reaches is measured from the regiment's own closest approach to
that enemy, not a fixed radius, so it means the same thing for a 140-man pike block as for
a 70-man cavalry wedge. One regiment-wide basis is what used to make a flanked block read
as a single sprite swinging round. **The bend obeys the same band**, which is not a
detail: bending the whole formation globally would curl a regiment round a flanker two
hundred units away, and the far end of a line has no business reacting to that.

Two more behaviours, both from how real formations worked:

- **The line is dressed.** After a frontal casualty a man crosses from the deepest file to
  the shallowest, so an emptied file does not leave a permanent hole. Not done after a
  flank or rear attack: the block has genuinely been eaten from that side and evening it
  up would undo the damage.
- **A man keeps his place.** His file and his depth change when somebody in front of him
  dies, and at no other time. Files used to ROTATE while fighting -- front man to the
  back, everyone else up one -- and he walked straight back through his own file to get
  there, overlapping his file-mates the whole way. A block whose men constantly swap
  places reads as a scatter rather than a formation, so it is gone, and
  `test_nobody_swaps_places_while_fighting` is the guard on the deletion.

Slots come from `max_strength`, computed once. Recomputing them from current strength --
which this used to do -- walked a regiment's drawn front rank backwards by 22 units as it
bled, so the men retreated from the fight they were in. Keying men by array index -- which
it also used to do -- made the man to the LEFT inherit a dead man's place instead of the
man behind him, so the block rippled sideways and nobody stepped forward.

Men chase their slots in **world** space, not local, so a regiment that turns or marches
drags them after it and they catch up. Easing in local space rotates the block rigidly,
which is the glued look.

**And a man walks.** He has a ceiling and an acceleration, which he did not have at all:
his speed was proportional to how far he was from his slot, so one 100 units out moved at
349 world units a second and one 200 units out at 699, against a regiment that marches at
45. Rotation had a governor -- `MAN_TURN_RATE` -- and translation had none.

Worse than the top speed was the shape of it. An exponential closes the same FRACTION of
any gap per second, so **95% of ANY distance closed in 0.83 seconds**: a one-file dressing
shuffle and a complete reshape took exactly as long as each other. That is why re-forming
looked instant however drastic it was, and why a wheel read as a rigid spin -- the outer
files, which should lag, simply teleported round.

The ceiling is **his own regiment's current speed plus `DRESS_SPEED`**, measured from the
pose rather than looked up, so cavalry, a column, marsh and an exhausted regiment's
`legs()` all come out right without the view knowing that any of them exist. He can always
keep station, and has a dressing pace in hand on top. The exponential still sets the SHAPE
of the approach -- it is what stops him jittering on his slot -- but no longer how fast he
gets there. `PACE_SPREAD` is deliberately far gentler than `CATCH_UP_SPREAD`: that one
makes men ARRIVE raggedly, and putting it on the ceiling as well had the slowest man
walking at 11 u/s while the quickest did 29.

**`_reform` deals file-major, and sorts each file by the depth the men are already at.**
Both halves matter and both were wrong. Dealing rank-major re-numbers everybody the moment
the rank count changes, so widening twelve files to fourteen scrambled the whole regiment;
and dealing depths straight off the lateral sweep sent the man at the BACK of one file to
the FRONT of the next. Measured, worst man on a 12-to-14 change:

	rank-major                     76 units  (further than 12-to-20 moved him)
	file-major, depths off sweep   76 units
	file-major, depths by his own  15 units

A small change has to be a small walk. It now is:

	12 -> 14 files    0.8s
	12 -> 40 files    5.9s
	fastest man       23 u/s, against a 45 u/s march -- it was 521

`tests/test_bodies.gd` measures that from where the men actually ARE, one frame to the
next, never from what the code believes their speed to be. The first version of that test
asked the speed accessor and passed happily with the limit deleted, because the intended
speed is still computed whether or not anything obeys it.

**A man is a round dot with a dark rim**, not a bare quad. Four units across on a
seven-unit pitch is 57% filled, and at the default zoom that is a 3px square 5px from its
neighbour, which the eye joins into one slab. The rim is what does the work: it gives
every man his own outline, so two touching dots still read as two. The texture is
generated in code and tinted by the per-instance colour, so it costs no asset and keeps
the team colour exactly as it was.

Measured: 16 regiments x 120 men costs **6.33 ms/frame**, about a third of a 60fps budget.
`tests/test_bodies.gd` prints it. If it ever stops fitting, the integration moves to a
shader rather than the look being abandoned.

## Banners

A flag above each regiment: what it is, how it is holding up, and something you can
actually click. It follows Total War, where the banner IS the morale readout -- a coloured
bar for state, a white flag when the unit is routing, and **no banner at all once it is
shattered**, which is the clearest way to say that one is never coming back.

It is drawn in world space but at a **constant size on screen** (`BANNER_W` / zoom), which
is the entire point: a regiment's own footprint shrinks to nothing as you zoom out, and the
banner is the thing that stays hittable.

**Picking was worse than it looked, and the banner is what fixed it.** It was one circle of
`PICK_RADIUS`, 46 world units, around the sim's centre point:

	a 14-file regiment    half-frontage  45.5   (just inside)
	a 20-file regiment    half-frontage  66.5   (wings unclickable)
	a 40-file regiment    half-frontage 136.5   (the middle third, and no more)

At the zoomed-out end that circle was 23 pixels across, and the click-versus-drag threshold
was 6.0 **world** units -- a pixel and a half, so a small wobble turned every click into a
box-select. Drawing used `_men.centre_of()` while picking used `pos`, so at half strength
the block you could see sat forward of the circle you had to hit. Box-select tested only
`pos`, so a regiment whose whole line was inside the box but whose centre was a few units
outside it was left behind.

`pick_at()` replaces both pickers -- they were near-identical loops differing only in an
owner comparison -- and tries the banner, then the regiment's real footprint, then the
circle as a last resort. It is **static and takes a pose**, so it tests headless the way
`plan_order` does. Nothing covered picking at all before `tests/test_picking.gd`.

## The map

Hexes, in **odd-r offset coordinates**: stored row by row exactly as squares were, so
`idx`, `tile_x`, `tile_y` and the breadth-first search over them never noticed the change.
`neighbours()` went from four directions to six, parity-dependent on the row, and that is
the whole of it. `view/campaign/hex.gd` holds the pixel geometry and the click picking.

Two things worth pinning, both of which have tests sweeping the entire map:

- **Neighbours must be mutual.** Get the row parity wrong and A is next to B while B is
  not next to A, so armies path one way and not back.
- **Distance is measured in cube coordinates, not Manhattan.** Offset arithmetic is simply
  wrong on a hex grid, and that number decides which town works a tile and where the AI
  marches.

Clicking uses cube rounding rather than dividing and flooring, which puts clicks in the
wrong hex along every slanted edge -- and most hex edges are slanted.

## The land

**One catalogue.** Everything you can put on a hex lives in `Rules.STRUCTURES` -- farm,
pasture, lumber, mine, market, library, barracks, walls -- one to a hex, inside
`WORK_RADIUS` of a town you hold. There used to be two tables, buildings belonging to a
settlement and improvements belonging to the land, which meant `farm` existed twice doing
nearly the same job and neither had anywhere an enemy could reach.

	on        terrain it may go on
	in_town   walls only, and nothing else may share the town's hex
	unlocks   kinds the town can raise while this stands on land it works
	defense   what a defender shrugs off in a battle fought on this hex

Three things follow from a building having a location:

- **`recruitable_at()` reads the land, not the town.** A barracks is a place on the map,
  so burning it takes the cavalry with it.
- **A hex is worked by exactly one settlement** -- the nearest, ties to the lower index --
  or two neighbouring towns both bank the same field.
- The structure stays when a town changes hands; the income follows the town.

**Razing** is a deliberate order, not automatic on entering: an army standing on a hex can
burn what is on it, which ends its turn and pays it `RAZE_LOOT` of what the thing cost.
Deliberate because marching through enemy farmland without torching it has to stay an
option, or there is no decision in it. Burned ground can be built on again -- this is
pillage, not salting the earth.

## Armies

Two armies **cannot share a hex**. `army_at()` returns the first army on one, and
movement, collision detection and razing all lean on that, so a stack would quietly break
all three. Everything about merging and splitting follows from it.

- **Merge** folds one army into an adjacent one of yours. Regiments transfer up to the
  cap and the remainder stays behind as a smaller army; the result takes `min` of the two
  movement allowances, so combining is never a way to buy a move. Shift-click in the UI.
- **Split** detaches chosen regiments onto an **adjacent, passable, empty** hex -- it
  marches out rather than standing in place -- with no movement left that turn. Something
  always stays behind.

Both are deliberate orders rather than automatic, for the same reason razing is: a column
marching past its own garrison must not silently swallow it.

Splitting exists because you have fast cavalry and you have razing. Peeling one horse
regiment off a stack to go burn farmland is the move that makes raiding worth doing.

## The tech trees

Two trees, **one pool**. Research is a third resource produced by settlements and by
libraries; both trees spend it, so every tech taken in one is a tech not taken in the
other. That tension is the reason there are two trees rather than one long list.

`Rules.TECHS` is one table: tree, cost, prerequisites, and one effect. Effects are **data,
not code** -- a small set of keys the sim reads uniformly (`yield`, `build_cost`,
`work_radius`, `town_gold`; `attack`, `armour`, `horse_speed`, `horse_attack`, `stamina`,
`resolve`, `siege`) -- so adding a tech is a table row and a test, never a new branch.

`ADDITIVE` in `campaign_state.gd` decides which keys sum and which compound, in one place.

**Battle techs are per owner, not per regiment.** The battle snapshot carries a small
`techs` header and `BattleState.tech()` derives the multipliers. Four more floats on every
regiment would cost ~32 B each on a wire already at 171; the header is a few dozen bytes
for the whole battle. It has to be on the wire at all because a replay rebuilds the fight
from the opening snapshot -- the same reason `defense` is on there.

Measured: over a 50s duel, untrained keeps 81 men and leaves the enemy 81; drilled and
armoured keeps 92 and leaves them 76. Fifty seconds, not seventy: past about sixty both
sides have broken and run, and two regiments that have stopped taking casualties measure
nothing.

## Towns that grow, and towns that resent you

A settlement was a static object worth a flat `SETTLEMENT_GOLD` a turn forever, and taking
one was permanent, silent and free. Between them that made the campaign a **headcount of
towns**: no reason to develop what you held, and no cost to taking more.

**Population multiplies, unrest suppresses, and the two are independent.** A big angry town
is worth less than a small contented one, which is the whole argument against taking every
settlement you can reach. `settlement_income()` reads both; `contentment()` is a ramp
rather than a branch, so there is no cliff where a town stops paying.

Growth is bought with the **surplus**, not with income: an empire that eats everything it
makes is fed and static, and the decision is another regiment or another point of
population that pays for the rest of the campaign. An angry town does not grow either —
`unrest` gates growth rather than merely taxing it, or a province in revolt would still be
quietly getting bigger.

`ponytail:` every town of a fed empire grows at the same rate, so a capital and a village
founded last turn are equally good. Per-town food is the upgrade, and it wants
`worked_yield` attributing its output to a settlement rather than to an owner.

**The empire term is the important half of unrest.** Unrest decays on its own, so a
captured town in a SMALL empire calms down and becomes yours; past `UNREST_FREE_TOWNS` it
gains as fast as it settles and the town stays angry. That is the ceiling on conquest —
not that you cannot take the next town, but that taking it keeps the last one angry. A
small empire can never lose a town this way, however angry, and that is deliberate:
governing what you can hold has to actually work or the mechanic is a timer.

**A town that boils over goes back to being nobody's.** Never to another player — it
revolted against YOU, and handing it to whoever is nearest would make unrest a weapon
pointed at somebody else.

Both fields are range-checked on decode and not merely typed: population multiplies a
town's output and unrest divides it, so a peer that could name either could name its
income. Both are read through `pop_of()` / `unrest_of()` defaults, so a settlement built by
hand in a test has neither key and still works.

## Roads

A structure like any other, which is the point: laying one down is a hex you did not farm.
**Free only from one road hex onto another** — a road is worth nothing alone and everything
as a chain, so a single made-up hex in open country buys precisely nothing and building a
route is building a route.

`ponytail:` the AI does not build them. Its planner places one structure a turn on the
first hex that will take it, so it would scatter single road hexes that connect to nothing.
A planner that lays a ROUTE is the upgrade.

## What an army is doing between turns

Total War's campaign stances. An army was only ever marching.

	march    walk, and be seen
	forced   more ground, and the men arrive spent
	fortify  stand and dig in: defence in a battle fought on this hex
	ambush   not sent to the enemy at all, even where they can see the hex

**Fortify and ambush cost the whole turn's movement, charged the moment you adopt one.**
Next turn would be free: an army marches its three hexes, digs in on arrival and has paid
nothing at all.

**A forced march is paid for in `_deploy` and nowhere else.** The regiments arrive at
`FORCED_MARCH_STAMINA`, so an army that covered five hexes and never fought has spent
nothing — that is the whole of the gamble, and it is why the price cannot sit on the
campaign map where it would be invisible. It is also the one stance that describes HOW an
army is moving, so marching does not clear it; marching does clear the other two, because
an army that walked is not dug in and is not hiding.

**Ambush is the stance fog made possible.** `armies_visible_to` drops it for everybody but
its owner, so seeing the hex is not seeing the army, and marching into one is the ambush.
The order is `ARMY_STANCE` and not `STANCE` — that one has always been a BATTLE regiment's
posture bitfield, and reusing it would have put two unrelated things behind one name.

Fortification stacks with walls and goes through `siege` like walls do; `_strike` clamps
the total at 0.9 as it always did.

## Fog of war

**The campaign snapshot goes out once per player, not once.** `broadcast_campaign()` sent
one blob to everybody, so anything hidden would have been a curtain drawn in the view that
a modified client walks straight through. It now loops the peers and `rpc_id`s each one
`Snapshot.encode_campaign(campaign, peer)`.

`CampaignState.seen` is owner -> a byte per hex, and it only ever GROWS: ground you have
walked over stays on your map when you walk away, which is the difference between fog of
war and a blindfold. Sight is recomputed fresh each time from where the armies and towns
actually are; `seen` is the memory.

**Armies and structures are hidden. Terrain and settlements are not.** Settlements are
landmarks, which is how Total War plays it, and terrain is static and identical for
everyone from map generation, so hiding it buys a client-side redraw and nothing else.
`ponytail:` the upgrade is a remembered per-owner copy carrying a STALE owner id, so a town
that changed hands behind the fog still reads as its old holder.

`armies_visible_to()` is **one function with two callers**, and that is the whole design:
the wire filter calls it and so does the campaign map's own `_draw`. The host holds the
real `CampaignState` and is never sent a snapshot at all, so without a shared rule the
host's window would show everything while a joined client's showed nothing — hard
constraint #4, and the exact shape of the bug that ate the roster.

Three things that are easy to get wrong here, all tested:

- **Your own armies are always sent to you.** An army you cannot see is an army you cannot
  order, and losing your own units to your own fog is not a mechanic.
- **A campaign with no memory at all is omniscient.** `can_see` returns true when the
  `seen` row is missing or the wrong length, so fog is something a campaign ACQUIRES by
  calling `observe()`, never a default. Every test and harness written before it keeps
  working unchanged.
- **`seen` is in the save and in `remap_owners()`.** Dropping it from the save hands back a
  revealed map; missing it in the remap hands somebody another player's map, and nothing
  else in the game would notice. `tests/test_save.gd` checks each book separately for
  exactly this reason.

`observe_all()` hangs off `broadcast_campaign()` rather than off each of the dozen places
that move an army or take a town. "Anything that changes the world broadcasts" is an
invariant the design already rests on, so a sight update on the same call cannot go stale.

**The AI sees through it.** `sim/ai.gd` is handed the server's own state and reads
`armies` directly. Marked `ponytail:` — the fix is not a filter but a memory model, since
every scoring function in that file would then need a reason to believe an enemy is still
where it last stood.

## Founding a town

The map used to be dealt once at `generate()` — one capital each plus four neutral towns —
and never change shape again, so the only way to grow was conquest and the whole
Civilization half of this game was missing. A **settler** is a regiment kind like any
other: it rides in an army, it is on the wire as `[kind, strength, xp]` like everything
else, and `found()` consumes it.

It is deliberately a bad unit — 40 men with farm tools, slow, no `requires` — so a settler
party marching alone is an invitation and escorting it is the decision.

**`MIN_TOWN_DISTANCE` is `WORK_RADIUS + 1`, and that is not a free number.** Any closer and
two towns bank the same fields, so founding becomes a way of counting land somebody is
already working twice over. At exactly `WORK_RADIUS + 1` their worked areas touch without
overlapping, which is as tight as packing can honestly get.

Founding clears whatever stood on the hex: a town on top of a farm would be worked by
itself and counted twice, and `can_place` guards the town hex from then on.

The AI expands, and had to. `_settle_something` runs before `_march`, `_settling` keeps
`_march` from sending a settler party at a defended capital, and the settler is excluded
from the "best unit it can afford" pick — it is the worst regiment in the game and that
branch would have raised it the moment the purse allowed. `_settling` is rebuilt every turn
from the world rather than remembered: the AI object outlives the battle, which is exactly
how the cavalry sweep's stale waypoints got in.

## Veterancy

A campaign regiment is `[kind, strength, xp]`. It used to be `[kind, strength]`, so the
only thing an army brought home from a fight was a smaller headcount — a regiment raised
fresh at full strength was strictly better than one that had survived two battles, and
there was never a reason to pull a battered unit out of the line rather than spend it.

`xp` is men killed, cumulative, and it is read like the four exhaustion terms —
`lerpf(1.0, best, seasoning())` — but off `xp` instead of `stamina` and in the opposite
direction: exhaustion goes from bad to 1.0 as a regiment rests, this goes from 1.0 to good
as it learns. Two readings, `veteran_attack()` and `veteran_resolve()`.

It is **on the battle wire**, +8 B on a 195 B regiment, for the same reason `defense` and
the tech header are: a replay rebuilds the fight from its opening snapshot, so anything the
sim reads to decide the outcome has to be in it. Per-regiment and not a per-owner header
like the techs, because it is genuinely per regiment.

Earned in whole men through a pool on the attacker, the mirror of `damage_pool` — a tick's
worth of killing is a fraction of a man. Archers earn it too, or they would be the one unit
whose veterancy depended on running out of arrows.

Measured (`tests/test_veterancy.gd` prints it):

	50s duel     green keeps 80 men and leaves the enemy 80
	             a full veteran keeps 86 and leaves them 76

Deliberately about what one battle tech is worth (drill + armoury is 92 and 76). A veteran
that walked through a green regiment would decide a campaign in the first fight and make
the loser's position unrecoverable, and `test_it_is_worth_about_as_much_as_a_tech` is the
guard on that rather than on the mechanic working.

## Winning

The campaign had no end at all: `net.gd` announced "driven from the map" and the game
carried on with one player clicking End Turn forever.

`CampaignState.winner(seats)` is pure and on the sim side, so every machine decides it
identically and a test can ask without a tree. Two ways: everyone else driven from the map,
or the most settlements once `TURN_LIMIT` is up. A tie at the limit goes to the lower seat —
arbitrary, but a decided game beats a game that never ends.

- **Owner 0 never wins.** The four neutral towns are not a player.
- **An army in the field is still in the game.** Losing every settlement is not losing, or
  taking one town would be an instant win.
- Asked at the two places a campaign can end — a turn rolling over and a battle settling —
  rather than on a clock, and `winner_seat` resets when a campaign is dealt or loaded or a
  second game opens already won.

## The edge of the field, and the edge of the map

**`BATTLE_HALF_EXTENT` was 3000 and invisible.** Move orders and the camera were both
already clamped to it, but that is a 6000-unit field a regiment crosses in 187 seconds
against a 420-second limit, with the two lines deployed 520 apart in the middle of it. The
fight happened in a thousand-unit box and the rest was somewhere to lose an army in by
accident — and because nothing drew the boundary, a regiment sent past it simply stopped
short for no reason a player could see.

It is 1200, about 75 seconds across, and `battle_view.gd::_draw_field` draws it first so the
men stand on top of it. Constant thickness on SCREEN, like the banner: a hairline at the
zoomed-out end is exactly where you most need to know which way the edge is.

Anything that measures against the field has to be derived from the constant and not
written down beside it. `tests/net_harness.gd` had a literal probe target of (1234, -567),
which sat inside a 3000-unit half-extent and outside a 1200-unit one, so shrinking the
field silently turned the order-delivery probe into an out-of-bounds-clamping probe and
`nettest.cmd` failed saying the order never arrived. It had arrived; `clamp_to_field` had
moved it.

**The campaign camera had no bounds at all.** Zoom was already there (wheel, 0.35–2.5);
dragging far enough left the window looking at empty space with nothing to steer by and no
way back but more dragging. `_clamp_camera()` runs every frame rather than at each of the
three places that move the camera — a drag, a zoom and a key — because zooming out past the
edge has to pull the view back in too. It clamps so the MAP fills the window, not so the
camera centre stays on the map: at 0.35 zoom half a screen is most of the map, so an axis
the window already covers is simply centred. WASD/arrows pan; no edge scroll, unlike the
battle, because the campaign HUD lives in three corners and reaching for End Turn would
send the map sliding out from under the cursor.

## Who is playing

**The roster is replicated, and it has to be.** `players` is server state, but four view
call sites read `Net.player_ids()` as the seating and `Colors.of_owner()` returns NEUTRAL
for an owner it cannot find in it. `join()` set up the transport and nothing ever sent a
roster, so a joined client's `player_ids()` was empty for the whole session and **both
armies drew the same grey** -- along with the strength bars, and every settlement and
army on the campaign map. The host's own window looked perfect, which is why it survived:
`play.cmd demo` opens two windows and only the second one was wrong.

It goes out as an ORDERED seat array rather than the dictionary, because the order is the
thing that decides colour -- sending it explicitly is what makes host and client agree by
construction instead of by both happening to sort the same way. `nettest.cmd` now checks
that a joined client can name every owner standing on the field.

Colour by seat and not by peer id, for the same reason it always was: peer ids are random
32-bit numbers, so hashing one into a hue gives a different colour every session.

## Jev

The opponent's scorer, and **it never issues an order**. `sim/ai.gd` finds the legal
moves as it always did; Jev only reorders them.

Jev (TypeSafe AI) is a "System One" model: it writes no prose. It evaluates a state
against typed questions and returns a bounded `choice`, `score` or `noul` with a
calibrated confidence. That is the only reason it is safe to have in here -- it cannot
invent an option that was not on the list, so whatever it names still goes through
`can_learn` / `can_place` and still comes out as an encoded order landing in
`_receive_order`, exactly like a human's click. If Jev cannot express something as a
legal order, neither could a player.

	TYPESAFE_API_KEY=...      in .env, gitignored; .env.example is the template
	                          a real environment variable wins over the file

**It is entirely optional, and every failure is the same failure.** No key, a timeout, a
429, a reply that will not parse -- the advice dictionary stays empty and the AI plays
the heuristics it always played. `sim/ai.gd` reads `advice` and nothing else: no
preload, no Node, nothing on the wire, so the sim stays the pure `RefCounted` it has to
be. `net.use_jev = false` turns it off outright, which is what the harnesses do, because
a gate that reaches across the internet fails when somebody else's API is slow and that
says nothing at all about this game.

**"Deterministic" does not mean here what it means everywhere else in this file.**
TypeSafe promise a deterministic *policy* -- the threshold is ours, at `MIN_CONFIDENCE`
-- not a deterministic model, and `jev-latest` is a mutable alias whose answers change
under you. That is survivable only because a replay records the order BYTES, so a
recorded battle still reproduces itself whoever chose the orders. Replaying a recording
stays exact. Re-running a *scenario* never was reproducible, because the AI has always
thought from `_process`.

What it is asked:

	campaign, once a turn    which tech, which structure, which settlement to march on
	battle, on change        commit / hold / withdraw

The campaign question is asked at the top of the turn and the AI is held back until it
lands -- `campaign_orders` is what appends End Turn, so holding it holds the turn rather
than spending the money twice.

**The battle question is asked when the fight CHANGES, not on a clock.** `_shape()`
fingerprints the situation -- men in tenths, how many are locked in, how many have
broken, whether the archers still have arrows -- and the question goes out only when that
moves. Position is deliberately absent: regiments move every tick and movement on its own
is not news, so keying on it would be the old two-second timer again at sixty times a
second. Tenths are ROUNDED, not truncated, or full strength is a knife edge and the first
man to fall reads as a collapse. How many of a side are locked in or broken is carried as
a SHARE rather than a count, for the same reason.

**It no longer beats the two-second poll, and that is the envelopment's doing.** It used
to ask 31 times where a clock asked 108. Now the AI sends its spare regiments round a
flank, regiments join and leave melees far more often, and the fight genuinely changes
more -- it is within a handful of the clock either way. The bar that still holds, and the
one that matters for something that fires on a change, is against asking EVERY THINK: 47
against 288. The in-flight guard is what caps the real cost at one question per seat at a
time, so a livelier fingerprint buys information rather than calls.

Measured (`tests/test_jev.gd` prints it):

	51s battle       47 stance questions, 50 on the old 2s timer, 288 every think
	round trip       ~860ms cold; the in-flight guard caps it at one per seat

Every answer is logged to `user://jev.log`, beside the replays and the saves and for the
same reason -- **the dropped ones too**:

	turn 1 | seat -1 | build=walls (0.59) target=154 (0.22) DROPPED tech=husbandry (0.55)
	battle 0s | seat -1 | posture=hold (0.93)

A dropped answer is the most interesting line in that file when you are deciding where
`MIN_CONFIDENCE` belongs: it is the model saying it had an opinion and was not sure
enough to be listened to. Logging only what was taken would hide the evidence.

## Replays

Every battle is recorded to `user://replays/`, verified against the state it actually
ended in, and saved. A recording is the opening snapshot plus the orders, each stamped
with the tick it was applied on -- a real 72-second AI battle is 1447 ticks, 567 orders,
52 KB. It works because the sim is pure, fixed-tick and has no randomness in it.

	play.cmd replay <path>     watch one back

This is how to tune how a fight feels: replay the exact same battle, change one constant
in `rules.gd`, watch it again. `verify()` failing after a rules change is not a bug, it is
the point of keeping the file. It failing *without* one means something in the sim has
stopped being deterministic, and `_keep_the_recording()` warns when that happens.

## Saving

A campaign saves to `user://saves/` from the button on the campaign screen, and loads
from the lobby. `Snapshot.encode_campaign` does nearly all of it.

The part that is not obvious: **peer ids are random and change every session**, so a save
stores the *seats* -- the owner ids in a stable order -- and loading maps them onto
whoever has turned up this time, in order. `CampaignState.remap_owners()` re-points the
settlements, armies, treasuries and ready flags together. A mapping that misses one of
those silently hands somebody another player's empire, and nothing else in the game would
notice, which is why the tests check each of them separately.

A save that wants a different number of players than are at the table is refused rather
than approximated. Saving mid-battle is refused too: a campaign is only coherent between
fights.

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
- `AI_THINK_TICKS` counted FRAMES, not ticks, so the opposition thought 2.4x more often
  on a 144 Hz monitor than on a 60 Hz one, and a loaded host played a different battle
  from an idle one. It counts `battle.tick` now, through `Net.due()`, which also treats
  the counter going BACKWARDS as a new battle -- otherwise a stale count from the last
  fight silences the AI for minutes into the next one.
- The battle AI must not think much faster than it does. `order_move` is not idempotent:
  it sets a regiment back to MOVING, and IDLE is what gates shooting, morale recovery and
  stamina recovery. An archer re-ordered every tick is never IDLE, so it never looses,
  the quiver never empties, it never joins the line, and the battle never ends.
- Wheeling in contact runs at `ENGAGED_TURN_MULT`. At full turn speed a flanked
  regiment simply faced its attacker within half a second and the flank evaporated.

## Deliberate shortcuts

Marked in code with `# ponytail:` comments naming the ceiling and the upgrade path.
Currently deferred: delta encoding, client-side prediction, reconnect/host migration,
NAT punch-through (LAN + direct IP only), an AI that respects fog, a remembered stale
owner for towns behind the fog, per-town food, an AI that lays road ROUTES, sieges and
diplomacy.
