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
recruit or build, End Turn bottom-right. The turn advances when every player has
pressed it. Pike and cavalry need a barracks in the settlement raising them; walls
cut the damage a defender takes in a battle fought on that tile. Feed the army or
it deserts, and a starving army does not replenish either.
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

## Tests

	& "C:\Users\bojid\Downloads\Godot_v4.7.2-stable_win64.exe\Godot_v4.7.2-stable_win64.exe" --path "E:\rts test\new-game-project" --headless --script res://tests/run.gd

`tests/run.gd` extends `SceneTree` (Godot rejects a plain script for `--script`). Exit code 0
means green. Add a test file to the `TESTS` list in `run.gd` to register it.

## Measured

Snapshot cost with the `var_to_bytes` encoder (`tests/test_snapshot.gd` prints it):
**187 B/regiment**, so 100 regiments = 18.8 KB/snapshot = 184 KB/s per client at 10 Hz.
A realistic 40-regiment battle is ~73 KB/s per client. Fine on LAN, marginal over the
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

	head-on, 60s        82/120 men left, morale 40, spent, still locked
	pinned + flanked    breaks at 12s, versus 53s frontally
	8s of fighting      18 lost when flanked, 9 when fronted
	same frontage       3-deep breaks at 15s, 10-deep at 53s
	two blocks meet     centres 57 apart, fronts 12 apart
	3s of contact       a charge kills 6, a shoving match 2
	4s of charge        a line loses 6, a braced square 1

These moved when the default frontages went from ~10 ranks to 4-6 (see **Formations**).
A line that stands 20 files wide instead of 12 puts 20 files in contact, and output
scales with files, so **everything bleeds about 1.7x faster than these numbers used to
say**. The one knob that undoes it without touching the shapes is
`KILLS_PER_FILE_PER_SEC` (0.06; 0.036 restores the old pace exactly).

The casualty ratios held -- a flank is still 5x a frontal fight -- but one absolute did
not: a head-on tie now resolves itself at **68s** where it used to run to the
`BATTLE_TIME_LIMIT`. "A head-on tie cannot break itself" is therefore weaker than it
reads above: it still cannot be broken QUICKLY, but it no longer cannot be broken at all.

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

Free is not instant to LOOK at: the men walk into their new files and `bodies.gd` runs a
`DRESS_SECONDS` clock so the HUD can say "RE-DRESSING". That clock is a fact about an
animation, so it lives on the client, derived from the width already in the mirror --
no sim state, no snapshot field, nothing a replay has to reproduce.

**The default frontages are 4-6 ranks, not 10.** They used to be near-square -- a
120-man spear at 12 files was 77 units across by 81 deep, and a sword was 63 by 81,
*deeper than wide*. Ten ranks is not a line, it is a block, and it is what made a
regiment read as one blob whatever you did to it. A frontage is also not a free number
to pick: `DEPLOY_SPACING` is a frontage plus a shoulder, and at 110 against the new
133-unit width the regiments in a deployed line stood 23 units inside one another.

Measured (`tests/test_formations.gd` prints these):

	24 files vs 6 files      15 killed against 3 over 12s
	spears vs cavalry, 8s    a line loses 6 and kills 8
	                         a shield wall loses 2 and kills 14

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
	now             80% front, 20% round the side, with the blocks separated

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
loses 48 men, loose order 18, and a square 60.

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

Three clamps, none of them optional, all of them in `plan_order` so the ghost shows the
shape the regiment is actually going to be in:

- `DRAG_MAX_RANKS` floors the frontage. Shoulders alone exceed a short drag over several
  regiments, so the share goes negative and the raw answer is `MIN_WIDTH`: two files,
  sixty ranks deep. The `column` and `square` buttons still reach the extremes, because
  `natural_width()` does not come through here.
- A deadband of two files. A change of one is not worth `FORMATION_CHANGE_SECONDS`, and
  without it every ordinary move-drag would re-form the regiment it was only moving.
- `reforming > 0` returns the current width, because `set_width` refuses outright while a
  regiment is mid-change and a preview must not draw an order the server drops.

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
	closest man to enemy man     4.9 to 7.6 units, and 0 overlapping pairs;
	                             it was 0.0 units, against a body 4 across

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

**A man is a round dot with a dark rim**, not a bare quad. Four units across on a
seven-unit pitch is 57% filled, and at the default zoom that is a 3px square 5px from its
neighbour, which the eye joins into one slab. The rim is what does the work: it gives
every man his own outline, so two touching dots still read as two. The texture is
generated in code and tinted by the per-instance colour, so it costs no asset and keeps
the team colour exactly as it was.

Measured: 16 regiments x 120 men costs **4.97 ms/frame**, about a third of a 60fps budget.
`tests/test_bodies.gd` prints it. If it ever stops fitting, the integration moves to a
shader rather than the look being abandoned.

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

Measured: over a 50s duel, untrained keeps 82 men and leaves the enemy 82; drilled and
armoured keeps 88 and leaves them 75. Fifty seconds, not seventy: past about sixty both
sides have broken and run, and two regiments that have stopped taking casualties measure
nothing.

## Replays## Armies

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

Measured: over a 50s duel, untrained keeps 82 men and leaves the enemy 82; drilled and
armoured keeps 88 and leaves them 75. Fifty seconds, not seventy: past about sixty both
sides have broken and run, and two regiments that have stopped taking casualties measure
nothing.

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
more -- 111 questions against 92 on the clock. The bar that still holds, and the one that
matters for something that fires on a change, is against asking EVERY THINK: 111 against
536. The in-flight guard is what caps the real cost at one question per seat at a time,
so a livelier fingerprint buys information rather than calls.

Measured (`tests/test_jev.gd` prints it):

	94s battle       111 stance questions, 92 on the old 2s timer, 536 every think
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
fog of war, AI opponents, NAT punch-through (LAN + direct IP only).
