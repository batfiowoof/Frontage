extends RefCounted
## Every tunable number in the game.  No logic, no state.
## Sim code reads these; nothing writes them.

# --- timing -------------------------------------------------------------
const TICK_HZ := 20
const TICK_DELTA := 1.0 / float(TICK_HZ)
const SNAPSHOT_EVERY_N_TICKS := 2          # -> 10 Hz on the wire
const INTERP_DELAY_MS := 100               # client renders this far in the past

# --- battle: movement ---------------------------------------------------
const MOVE_SPEED := 70.0                   # world units / second
const TURN_SPEED := 3.0                    # radians / second
## A regiment locked in melee cannot pivot. Without this a flanked unit simply turns
## to face in half a second and the flank becomes a frontal attack before it has cost
## anybody anything -- which is precisely what made flanking decorative.
const ENGAGED_TURN_MULT := 0.15
const ARRIVE_EPSILON := 4.0
const CONTACT_RANGE := 46.0                # centre-to-centre to count as engaged
const ROUT_SPEED_MULT := 1.35              # routers run faster than they marched

## Deployment: how far apart the two lines start, and the gap between regiments.
const DEPLOY_SEPARATION := 520.0
const DEPLOY_SPACING := 110.0
## A battle nobody can win still has to end, or the campaign never resumes.
const BATTLE_TIME_LIMIT := 420.0

# --- battle: attrition --------------------------------------------------
## Combat is frontage-limited: only the men who can physically reach the enemy
## fight. Output scales with the number of FILES in contact, never with how many men
## the regiment happens to contain.
##
## This is the whole shape of a battle. Because a wider unit is not a stronger unit
## but a unit that kills faster and dies wider, and because depth costs nothing at
## the fighting line, two identical regiments head-on take identical losses forever
## and the tie cannot break itself. It is broken by widening, by wrapping a flank,
## by relieving a tired unit, or by shooting it -- which is the point.
const KILLS_PER_FILE_PER_SEC := 0.06

## An attacker can reach a little way round the ends of a narrower enemy, but not
## indefinitely: twenty files cannot all land on a two-file target.
const WRAP_ALLOWANCE := 2.0

## How much of itself a regiment can bring to bear, by the angle IT is fighting at.
## Men facing the wrong way cannot fight, and this is what makes a flank one-sided
## rather than merely favourable: the flanker fights with its whole front, the
## flanked with the ends of its ranks at half effect.
const RESPONSE_FRONT := 1.0
const RESPONSE_FLANK := 0.5
const RESPONSE_REAR := 0.2

const FLANK_DAMAGE_MULT := 1.6
const REAR_DAMAGE_MULT := 2.2
## A regiment that has broken cannot fight back, so chasing one down is nearly free.
## ponytail: no automatic pursuit AI -- running routers down is the player's decision,
## which keeps the flank legible instead of resolving itself off-screen.
const RUNDOWN_DAMAGE_MULT := 3.0

# --- battle: stamina ----------------------------------------------------
## The second half of why a tie breaks. Fighting tires a regiment, standing still
## rests it, and a tired one hits at TIRED_EFFECTIVENESS. Pulling an exhausted unit
## out of a locked line and feeding a fresh one in roughly doubles that stretch of
## the line, which is a decision rather than a click.
## Resting is slower than tiring on purpose: relief is worth something because it
## cannot be done twice in a hurry.
const STAMINA_DRAIN_FIGHTING := 0.03       # ~33s of melee to exhaust
const STAMINA_RECOVERY := 0.015            # ~67s standing to recover
const TIRED_EFFECTIVENESS := 0.45

# --- battle: morale -----------------------------------------------------
## Frontal shock is deliberately tiny. At 3.0/s a head-on fight broke somebody in
## under thirty seconds no matter what either player did, which is exactly the
## mutual collapse that made battles feel wrong. Breaking a formed enemy from the
## front should take minutes; from the flank, seconds.
const MORALE_MAX := 100.0
const MORALE_ROUT_THRESHOLD := 20.0
const MORALE_RALLY_THRESHOLD := 45.0
const MORALE_DRAIN_FIGHTING := 0.6         # per second while engaged frontally
const MORALE_DRAIN_FLANKED := 5.0          # per second while engaged from the side
const MORALE_DRAIN_REAR := 12.0            # per second while engaged from behind
## Morale lost for losing the WHOLE regiment, scaled by the fraction actually lost.
## Per-man drain would be scale-dependent: a 12-man skirmisher and a 120-man block
## would break at wildly different casualty rates, and big blocks would never break
## at all — they would die first, which deletes morale as a mechanic.
## At 200, a regiment routs at roughly 40% losses.
const MORALE_DRAIN_PER_FRACTION := 120.0
const MORALE_RECOVERY := 4.0               # per second while idle and unengaged

# --- battle: geometry ---------------------------------------------------
const FLANK_ANGLE := deg_to_rad(60.0)      # attack within this of facing = frontal
const REAR_ANGLE := deg_to_rad(120.0)      # beyond this = rear

## Half-size of the battlefield. Move orders are clamped to it, so a hostile or
## buggy client cannot send a regiment to infinity.
const BATTLE_HALF_EXTENT := 3000.0

# --- formation ----------------------------------------------------------
const FILE_SPACING := 7.0                  # sideways gap between men in a rank
const RANK_SPACING := 9.0                  # depth gap between ranks
const DEFAULT_WIDTH := 12

# --- regiment kinds -----------------------------------------------------
## `speed` multiplies MOVE_SPEED. `requires` is a building the recruiting settlement
## must have, or &"" for anything you can raise in a bare town.
##
## Cavalry is the point of this table: few men, expensive, and fast enough to get
## round a flank while the fronts are locked. Without something that can outrun a
## line, flanking is an accident rather than a decision.
const KINDS := {
	&"spear":   {"strength": 120, "width": 12, "cost": 120, "upkeep": 2, "speed": 1.0,  "requires": &""},
	&"sword":   {"strength": 100, "width": 10, "cost": 150, "upkeep": 3, "speed": 1.05, "requires": &""},
	&"archer":  {"strength": 80,  "width": 16, "cost": 140, "upkeep": 2, "speed": 1.0,  "requires": &""},
	&"pike":    {"strength": 140, "width": 14, "cost": 220, "upkeep": 4, "speed": 0.85, "requires": &"barracks"},
	&"cavalry": {"strength": 70,  "width": 10, "cost": 280, "upkeep": 5, "speed": 1.75, "requires": &"barracks"},
}

# --- buildings ----------------------------------------------------------
## What a settlement can be made into. `gold` and `food` are added to that
## settlement's income each turn, `unlocks` lets you recruit new kinds there, and
## `defense` cuts the damage a defender takes in a battle fought on that tile.
## One of each per settlement, bought outright -- no build queue, because a queue
## is a lot of machinery for a prototype nobody is pacing yet.
const BUILDINGS := {
	&"farm":     {"cost": 150, "gold": 0,  "food": 25, "unlocks": [],                      "defense": 0.0},
	&"market":   {"cost": 200, "gold": 45, "food": 0,  "unlocks": [],                      "defense": 0.0},
	&"barracks": {"cost": 250, "gold": 0,  "food": 0,  "unlocks": [&"pike", &"cavalry"],   "defense": 0.0},
	&"walls":    {"cost": 300, "gold": 0,  "food": 0,  "unlocks": [],                      "defense": 0.3},
}

# --- campaign -----------------------------------------------------------
const MAP_W := 24
const MAP_H := 16
const TILE_PX := 48
const ARMY_MOVE_POINTS := 3
## Men each regiment loses per turn when the larder is empty. Food used to floor at
## zero, which made upkeep a number with no teeth: you could field any army you liked
## as long as you did not mind the counter reading 0.
const DESERTION_PER_TURN := 12

## Men a regiment recovers per turn while sitting in one of its own settlements.
## Without this the campaign is a one-way decay and the second battle is always
## fought by two exhausted armies.
const REINFORCE_PER_TURN := 25
const START_GOLD := 500
const START_FOOD := 200
const SETTLEMENT_GOLD := 60                # per turn, per owned settlement
const SETTLEMENT_FOOD := 25
