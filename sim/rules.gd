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
const CONTACT_RANGE := 22.0                # centre-to-centre to count as engaged
const ROUT_SPEED_MULT := 1.35              # routers run faster than they marched

# --- battle: attrition --------------------------------------------------
const KILLS_PER_SECOND := 5.0              # a full-strength regiment's output
const FLANK_DAMAGE_MULT := 1.6
const REAR_DAMAGE_MULT := 2.2

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
## strength, width, cost, upkeep.  Deliberately three kinds; more at M11.
const KINDS := {
	&"spear":  {"strength": 120, "width": 12, "cost": 120, "upkeep": 2},
	&"sword":  {"strength": 100, "width": 10, "cost": 150, "upkeep": 3},
	&"archer": {"strength": 80,  "width": 16, "cost": 140, "upkeep": 2},
}

# --- campaign -----------------------------------------------------------
const MAP_W := 24
const MAP_H := 16
const TILE_PX := 48
const ARMY_MOVE_POINTS := 3
const START_GOLD := 500
const START_FOOD := 200
const SETTLEMENT_GOLD := 60                # per turn, per owned settlement
const SETTLEMENT_FOOD := 25
