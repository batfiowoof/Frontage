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
const ARRIVE_EPSILON := 4.0
const CONTACT_RANGE := 46.0                # centre-to-centre to count as engaged
const ROUT_SPEED_MULT := 1.35              # routers run faster than they marched

## Deployment: how far apart the two lines start, and the gap between regiments.
const DEPLOY_SEPARATION := 520.0
const DEPLOY_SPACING := 110.0
## A battle nobody can win still has to end, or the campaign never resumes.
const BATTLE_TIME_LIMIT := 300.0

# --- battle: attrition --------------------------------------------------
const KILLS_PER_SECOND := 5.0              # a full-strength regiment's output
const FLANK_DAMAGE_MULT := 1.6
const REAR_DAMAGE_MULT := 2.2
## A regiment that has broken cannot fight back, so chasing one down is nearly free.
## ponytail: no automatic pursuit AI -- running routers down is the player's decision,
## which keeps the flank legible instead of resolving itself off-screen.
const RUNDOWN_DAMAGE_MULT := 3.0

# --- battle: morale -----------------------------------------------------
const MORALE_MAX := 100.0
const MORALE_ROUT_THRESHOLD := 20.0
const MORALE_RALLY_THRESHOLD := 45.0
const MORALE_DRAIN_FIGHTING := 3.0         # per second while engaged frontally
const MORALE_DRAIN_FLANKED := 9.0          # per second while engaged from the side
const MORALE_DRAIN_REAR := 16.0            # per second while engaged from behind
## Morale lost for losing the WHOLE regiment, scaled by the fraction actually lost.
## Per-man drain would be scale-dependent: a 12-man skirmisher and a 120-man block
## would break at wildly different casualty rates, and big blocks would never break
## at all — they would die first, which deletes morale as a mechanic.
## At 200, a regiment routs at roughly 40% losses.
const MORALE_DRAIN_PER_FRACTION := 200.0
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
