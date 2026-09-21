extends RefCounted
## Every tunable number in the game.  No logic, no state.
## Sim code reads these; nothing writes them.

# --- timing -------------------------------------------------------------
const TICK_HZ := 20
const TICK_DELTA := 1.0 / float(TICK_HZ)
const SNAPSHOT_EVERY_N_TICKS := 2          # -> 10 Hz on the wire
const INTERP_DELAY_MS := 100               # client renders this far in the past

# --- battle: movement ---------------------------------------------------
## Top marching pace, and how quickly a regiment gets to it. Nothing used to build up:
## a regiment was at full speed on the first tick of an order and still at full speed on
## the tick it arrived, where it snapped onto its destination.
const MOVE_SPEED := 32.0                   # world units / second, at a walk
## Seconds to reach whatever top pace a regiment has, and to brake from it. A TIME and
## not a rate: a flat units/s^2 would have a column and a line cover identical ground in
## the first second, because they would both still be winding up, and the whole point of
## a column is that it is quicker. Everything scales with its own top speed this way, so
## cavalry lunges and a shield wall leans into it.
const ACCELERATION_SECONDS := 3.0
## The slowest a regiment closes the last few units. Braking alone approaches its target
## asymptotically and would never actually get there, so the arrival used to be a snap of
## up to ARRIVE_EPSILON -- a teleport bigger than a stride, right at the moment you are
## looking at it. A crawl floor lets it walk the last bit in.
const ARRIVE_CRAWL := 8.0
## How fast a man sidesteps into a new file, over and above whatever his regiment is
## already doing. Less than half a march, because dressing a line is not marching.
##
## It sets the pace of the men in bodies.gd AND the rate the sim's frontage ramps at, from
## the same distance, so the fighting and the walking finish together by construction
## rather than by two constants that happen to agree. A man used to have no speed limit at
## all: at 100 units from his slot he moved at 349 u/s against a 45 u/s march, and because
## the ease was exponential, 95% of ANY gap closed in 0.83s -- a one-file shuffle and a
## total reshape took exactly as long as each other.
const DRESS_SPEED := 20.0
## Radians a second, for a WHEEL: a change to the ground the block stands on. Turning
## right round is not a wheel at all, it is an about-face, and it costs no rotation
## whatever -- see Regiment.about_face and bodies.gd.
##
## It was 3.0, which put 180 degrees at a second: the end file of a 20-wide block swept
## 209 units in that second, 200 u/s, nearly three times marching pace. The men were
## flung sideways faster than they could walk.
## 0.6 and not 0.9: the bar is that the END FILE of a wheeling line must not be carried
## sideways faster than the men can march, and a 20-file block reaches 66.5 units out, so
## the ceiling is MOVE_SPEED / 66.5. At 0.9 the sweep came to 60 u/s against a 45 u/s
## march -- still outrunning them, just less absurdly than the 200 it used to be.
## 0.45, not 0.6: the ceiling is MOVE_SPEED / 66.5, and the march came down to 32. The
## rule is that the END FILE of a wheeling line may not be carried sideways faster than
## the men can walk, and test_a_wheel_never_outruns_the_men has now caught this twice --
## once at 0.9 against a 45 u/s march, and again at 0.6 against a 32 u/s one.
const TURN_SPEED := 0.45
## A regiment locked in melee cannot pivot. Without this a flanked unit simply turns
## to face in half a second and the flank becomes a frontal attack before it has cost
## anybody anything -- which is precisely what made flanking decorative.
const ENGAGED_TURN_MULT := 0.15
const ARRIVE_EPSILON := 4.0
## How fast two enemy regiments standing inside one another shove apart, world units a
## second. Contact STOPS a march but has never undone an overlap that already happened,
## so regiments that ended up merged simply stayed merged -- measured over a whole AI
## battle, a third of all contact-ticks had a negative gap and the worst was 113 units,
## most of a frontage. Two armies drawn on top of each other is exactly what "it does not
## look like they are in contact" looks like, because they are not touching, they are
## interleaved. Well under MOVE_SPEED so it reads as men shoving, not blocks jumping.
const SEPARATION_SPEED := 40.0
## The space left between two front ranks when they meet. Contact is measured from
## the FRONTS of the two formations, not their centres: centre-to-centre meant two
## fresh blocks interpenetrated by 35 units on contact and then drifted apart as they
## lost the depth that had been overlapping.
const CONTACT_GAP := 14.0
const ROUT_SPEED_MULT := 1.35              # routers run faster than they marched

## Deployment: how far apart the two lines start, and the gap between regiments.
##
## DEPLOY_SPACING is a FRONTAGE plus a shoulder, so it is not free to pick: the widest
## thing deployed stands (width - 1) * FILE_SPACING across, which at 20 files is 133. At
## 110 the regiments in a line stood 23 units inside one another, and neighbours that
## overlap flicker in and out of each other's reach for the whole battle.
const DEPLOY_SEPARATION := 520.0
const DEPLOY_SPACING := 150.0
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
## Marching tires too, scaled by the pace actually being kept, so a slow walk costs little
## and a rout -- at ROUT_SPEED_MULT -- costs more than a march. Crossing the field used to
## be free, which made a flanking march a decision with no price on it.
const STAMINA_DRAIN_MARCHING := 0.01       # at full pace; a third of fighting
const STAMINA_RECOVERY := 0.015            # ~67s standing to recover

## What an exhausted regiment is worth, each read the same way: lerp(worst, 1.0, stamina).
## One idea read four ways. Exhaustion used to reach damage DEALT and nothing else -- not
## what a tired man suffers, not how fast he walks, and not how soon he breaks.
const TIRED_EFFECTIVENESS := 0.45          # damage dealt
const TIRED_VULNERABILITY := 1.35          # damage taken
const TIRED_PACE := 0.6                    # how fast it can still march
const TIRED_RESOLVE := 1.5                 # how fast its own morale goes

# --- battle: morale -----------------------------------------------------
## Frontal shock is deliberately tiny, and it took two goes to get there. At 3.0/s a
## head-on fight broke somebody inside thirty seconds whatever either player did. At
## 0.6/s it still broke them at 75s having killed only 31 of 120 men -- 26% casualties
## for 80% of the morale, so a regiment collapsed while visibly barely scratched.
##
## The trouble was two INDEPENDENT full-strength sinks summed together: either the flat
## drain or the casualty term alone was tuned to break a regiment on its own. The flat
## one is now a nudge and the casualties carry the frontal fight, which is what makes a
## head-on tie unable to break itself -- the thing the combat model claims and did not
## do. Flank and rear are untouched: breaking a formed enemy from the front should take
## minutes, from the flank seconds.
const MORALE_MAX := 100.0
const MORALE_ROUT_THRESHOLD := 20.0
const MORALE_RALLY_THRESHOLD := 45.0
const MORALE_DRAIN_FIGHTING := 0.15        # per second while engaged frontally
const MORALE_DRAIN_FLANKED := 5.0          # per second while engaged from the side
const MORALE_DRAIN_REAR := 12.0            # per second while engaged from behind
## Morale lost for losing the WHOLE regiment, scaled by the fraction actually lost.
## Per-man drain would be scale-dependent: a 12-man skirmisher and a 120-man block
## would break at wildly different casualty rates, and big blocks would never break
## at all — they would die first, which deletes morale as a mechanic.
## At 150, a regiment routs at roughly 41% losses.
const MORALE_DRAIN_PER_FRACTION := 150.0
## Coming back from a break is the slow half of morale, and it used to be the fast half.
## At 4.0/s a regiment climbed from the rout threshold to the rally threshold in SIX
## SECONDS -- against a frontal melee drain of 0.15 to 0.225/s, so one second of standing
## still undid eighteen to twenty-seven seconds of fighting. And it could do it all battle.
const MORALE_RECOVERY := 1.2               # per second, once it has had a moment
## ...and it needs that moment first. Breaking contact used to start the climb on the very
## next tick, because a router clears CONTACT_GAP in well under a second.
const RALLY_DELAY := 6.0

## What a broken regiment takes with it. One rout cascading down a line is the single
## loudest thing on a Total War field and the reason their battles END rather than grind:
## "a single rout can cause a chain-reaction in the army". Every regiment's morale here
## was entirely its own business, so battles were decided by attrition.
##
## `Regiment.shock()` has always documented "seeing a neighbour break" as one of its
## callers. Nothing has ever called it for that.
const PANIC_RADIUS := 300.0
const PANIC_SHOCK := 3.0                   # per second, per routing friend in sight

## How many times a regiment can break before it is finished. Past this it never rallies
## again and runs until it is off the field -- Total War's "shattered", which is what
## stops a broken flank quietly re-forming and coming back.
const ROUTS_BEFORE_SHATTERED := 3

## When a side is this far gone, everything it has left starts to waver whatever its own
## morale says. "If the entire army as a whole has lost many of its units, this causes
## every unit of an army to waver and rout regardless of Leadership."
const ARMY_BREAKS := 0.4                   # fraction of its regiments still standing
## It has to beat MORALE_RECOVERY handily or the two cancel: at 2.5 against a 1.2 climb
## and the general's 0.7, a collapsing army bled half a point a second and never went.
const COLLAPSE_SHOCK := 4.0                # per second, to everything still fighting

## A regiment with nobody alongside is jumpier than one in a line, and one at the moment
## of impact is briefly braver. Both are small; both reward keeping a line together.
const SHOULDER_RADIUS := 220.0
const ALONE_SHOCK := 0.6                   # per second with no friend to either side
const CHARGE_HEART := 4.0                  # per second of morale back while charging

## A general steadies the men who can see him, and taking him out is worth doing.
## He is not a separate unit: the biggest regiment on each side carries him, so there
## is nothing to recruit and nothing new on the campaign map.
## ponytail: biggest-regiment-is-the-general. A real commander unit is the upgrade,
## and it would only change who gets the flag.
const GENERAL_RADIUS := 260.0
const GENERAL_STEADY := 0.7                # morale drain multiplier within his reach
const GENERAL_RALLY := 2.0                 # extra morale/s for a router within it
const GENERAL_FALLS := 25.0                # one-off shock to the whole army when he dies

# --- battle: the charge -------------------------------------------------
## Men at a run hit harder than men already locked in a shoving match, and then it is
## over. Without this a horse is just fast infantry: cavalry costs more than anything
## else on the field and had no moment that was its own.
##
## The window is short on purpose. It is the difference between a charge that lands and
## one that is met, which makes WHEN you release cavalry the decision, and it is why the
## brace flag on square and shield wall is worth the frontage it costs.
const CHARGE_SECONDS := 3.0
const CHARGE_MULT := 4.0                   # at the moment of impact, decaying to 1.0
## What a braced formation takes out of it. Set spears stop a charge dead; that is what
## they are for.
const CHARGE_BRACED := 0.25

## Skirmishing: how close something has to get, as a fraction of the shooter's own
## reach, before it gives ground, and how far it gives at a time.
const SKIRMISH_TRIGGER := 0.45
const SKIRMISH_STEP := 160.0

# --- battle: ground -----------------------------------------------------
## The battlefield is not a table. A few patches of ground, carried in from the hex the
## armies met on, so WHERE you fight is a decision and not scenery.
##
## Circles rather than a grid: a handful of them says everything a prototype needs about
## a wood or a hill, and costs nothing to send or to test against.
const GROUND := {
	0: {"speed": 0.72, "damage": 0.9,  "cover": 0.5,  "range": 1.0},    # wood
	1: {"speed": 0.9,  "damage": 1.18, "cover": 0.0,  "range": 1.2},    # hill
	2: {"speed": 0.45, "damage": 0.65, "cover": 0.0,  "range": 0.9},    # marsh or ford
}
const GROUND_WOOD := 0
const GROUND_HILL := 1
const GROUND_MARSH := 2
const MAX_FEATURES := 12

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
## `range` of 0 means it has nothing to shoot with. `volley` is the men a full-strength
## regiment kills with one, `reload` the seconds between them, `ammo` how many it brought.
const KINDS := {
	&"spear":   {"strength": 120, "width": 20, "cost": 120, "upkeep": 2, "speed": 1.0,  "requires": &"",         "range": 0.0,   "reload": 0.0, "volley": 0.0,  "ammo": 0},
	&"sword":   {"strength": 100, "width": 20, "cost": 150, "upkeep": 3, "speed": 1.05, "requires": &"",         "range": 0.0,   "reload": 0.0, "volley": 0.0,  "ammo": 0},
	&"archer":  {"strength": 80,  "width": 20, "cost": 140, "upkeep": 2, "speed": 1.0,  "requires": &"",         "range": 430.0, "reload": 3.0, "volley": 10.0, "ammo": 14},
	&"pike":    {"strength": 140, "width": 20, "cost": 220, "upkeep": 4, "speed": 0.85, "requires": &"barracks", "range": 0.0,   "reload": 0.0, "volley": 0.0,  "ammo": 0},
	&"cavalry": {"strength": 70,  "width": 14, "cost": 280, "upkeep": 5, "speed": 1.75, "requires": &"barracks", "range": 0.0,   "reload": 0.0, "volley": 0.0,  "ammo": 0},
}

# --- shooting -----------------------------------------------------------
## A volley at the far edge of its range is worth this much of one at point blank.
const MISSILE_FALLOFF := 0.55
## Morale cost of being shot at, per volley landed. Arrows are frightening out of all
## proportion to what they kill, which is most of what they were for.
const MISSILE_SHOCK := 6.0
## How wide a friendly regiment counts as when it is standing in the line of fire.
const LINE_OF_FIRE_MARGIN := 18.0

# --- formations ---------------------------------------------------------
## What a regiment can be told to do with its shape. Under frontage-limited combat
## these are real decisions rather than costumes: width buys output, depth buys
## endurance, and every one of these numbers feeds something the fight already reads.
##
##   width     the frontage this formation naturally wants, as a multiple of the
##             kind's own. The player can then set it exactly; see MIN/MAX_WIDTH.
##   spacing   how far apart the men stand, which widens or narrows the whole block
##             and therefore what a flanker has to reach across
##   speed     movement, turn: how fast it moves and how fast it wheels
##   damage    what it deals; defense: what it shrugs off, 0..1
##   all_round no flank or rear penalty -- the answer to being surrounded
##   brace     spears set against a charge: hurts cavalry, and is hurt less by it
##   missile   resistance to shooting, unused until M19
const FORMATIONS := {
	&"line":   {"width": 1.0,  "spacing": 1.0,  "speed": 1.0,  "turn": 1.0,  "damage": 1.0, "defense": 0.0,  "all_round": false, "brace": false, "missile": 0.0},
	&"column": {"width": 0.35, "spacing": 1.0,  "speed": 1.3,  "turn": 1.4,  "damage": 1.0, "defense": 0.0,  "all_round": false, "brace": false, "missile": 0.0},
	&"square": {"width": 0.55, "spacing": 1.0,  "speed": 0.55, "turn": 0.6,  "damage": 0.85, "defense": 0.1, "all_round": true,  "brace": true,  "missile": -0.25},
	&"wedge":  {"width": 0.6,  "spacing": 1.0,  "speed": 1.15, "turn": 1.1,  "damage": 1.25, "defense": 0.0, "all_round": false, "brace": false, "missile": 0.0},
	&"loose":  {"width": 1.0,  "spacing": 1.9,  "speed": 1.15, "turn": 1.3,  "damage": 0.55, "defense": 0.0, "all_round": false, "brace": false, "missile": 0.6},
	&"shield": {"width": 1.0,  "spacing": 0.85, "speed": 0.5,  "turn": 0.35, "damage": 0.9, "defense": 0.35, "all_round": false, "brace": true,  "missile": 0.45},
}
const DEFAULT_FORMATION := &"line"

## Frontage the player may ask for. Two is a file of one man wide either side of
## nothing; forty is wider than any regiment we field.
const MIN_WIDTH := 2
const MAX_WIDTH := 40

## Re-forming is not free, or picking the right shape would just be a click made at the
## last possible moment. While it is happening the regiment fights at REFORM_PENALTY and
## cannot be told to do it again.
const FORMATION_CHANGE_SECONDS := 6.0
const REFORM_PENALTY := 0.55

## Bracing: what a set spear does to a horse, and what a horse fails to do to it.
const BRACE_DAMAGE_MULT := 1.8
const BRACE_PROTECTION := 0.45
## A kind at or above this speed counts as cavalry for bracing and for the AI.
const CAVALRY_SPEED := 1.4

# --- the tech trees -----------------------------------------------------
## Two trees, one pool. Both draw on the same research, so every tech taken in one is a
## tech not taken in the other -- that tension is the reason there are two trees rather
## than one long list.
##
## Effects are DATA, not code: a small set of keys the sim reads uniformly, so adding a
## tech later is a table row and a test rather than a new branch anywhere.
##
##   tree    "economy" or "battle", for which column it appears in
##   cost    research points
##   needs   techs that must be known first
##   effect  one entry from the key list below
##
## economy keys, read by campaign_state.gd:
##   yield        multiplies what named structures produce, e.g. {"farm": 1.5}
##   build_cost   multiplies what every structure costs
##   work_radius  adds hexes to how far a town reaches
##   town_gold    adds to every settlement's own income
## battle keys, read by battle_state.gd through BattleState.tech():
##   attack       damage dealt
##   armour       damage taken
##   horse_speed  movement, cavalry only
##   horse_attack damage dealt, cavalry only
##   stamina      how fast stamina drains (lower is better)
##   resolve      how fast morale drains (lower is better)
##   siege        multiplies the defender's fortification, so 0.5 halves walls
const TECHS := {
	# --- economy
	&"husbandry":    {"tree": "economy", "cost": 40,  "needs": [],              "effect": {"yield": {"farm": 1.5, "pasture": 1.4}}},
	&"masonry":      {"tree": "economy", "cost": 55,  "needs": [],              "effect": {"build_cost": 0.75}},
	&"coinage":      {"tree": "economy", "cost": 50,  "needs": [],              "effect": {"yield": {"market": 1.5, "mine": 1.4}}},
	&"irrigation":   {"tree": "economy", "cost": 95,  "needs": [&"husbandry"],  "effect": {"yield": {"farm": 2.0}}},
	&"banking":      {"tree": "economy", "cost": 110, "needs": [&"coinage"],    "effect": {"town_gold": 30}},
	&"guilds":       {"tree": "economy", "cost": 130, "needs": [&"masonry"],    "effect": {"work_radius": 1}},

	# --- battle
	&"drill":        {"tree": "battle",  "cost": 45,  "needs": [],              "effect": {"stamina": 0.6}},
	&"armoury":      {"tree": "battle",  "cost": 60,  "needs": [],              "effect": {"armour": 0.15}},
	&"horsemanship": {"tree": "battle",  "cost": 50,  "needs": [],              "effect": {"horse_speed": 1.2}},
	&"discipline":   {"tree": "battle",  "cost": 100, "needs": [&"drill"],      "effect": {"resolve": 0.65}},
	&"siegecraft":   {"tree": "battle",  "cost": 105, "needs": [&"armoury"],    "effect": {"siege": 0.5}},
	&"stirrups":     {"tree": "battle",  "cost": 120, "needs": [&"horsemanship"], "effect": {"horse_attack": 1.4}},
}

# --- campaign -----------------------------------------------------------
## Hexes, in odd-r offset coordinates: stored row by row exactly as a square grid is,
## so `idx`, `tile_x`, `tile_y` and the breadth-first search over them never noticed
## the change. Only `neighbours()` did, going from four directions to six.
const MAP_W := 24
const MAP_H := 16
## Distance from centre to corner of a pointy-top hex.
const HEX_SIZE := 30.0

# --- structures ---------------------------------------------------------
## Everything you can put on a hex, in one catalogue. There used to be two -- buildings
## belonging to a settlement and improvements belonging to the land -- which meant `farm`
## existed twice doing nearly the same job, and neither had anywhere an enemy could reach.
##
## Now every structure stands on a hex inside a town's working radius, one to a hex, and
## every one of them can be burned. Burning a barracks stops the enemy raising cavalry,
## which is the point of it having a location at all.
##
##   on        terrain it may be built on, by Terrain enum value
##   in_town   must go on the settlement's own hex, and nothing else may
##   unlocks   regiment kinds the town can raise while this stands nearby
##   defense   damage a defender shrugs off in a battle fought on this hex
const STRUCTURES := {
	&"farm":     {"cost": 90,  "gold": 0,  "food": 14, "research": 0, "on": [0],    "unlocks": [],                    "defense": 0.0,  "in_town": false},
	&"pasture":  {"cost": 110, "gold": 8,  "food": 9,  "research": 0, "on": [0, 3], "unlocks": [],                    "defense": 0.0,  "in_town": false},
	&"lumber":   {"cost": 100, "gold": 10, "food": 0,  "research": 0, "on": [1],    "unlocks": [],                    "defense": 0.0,  "in_town": false},
	&"mine":     {"cost": 160, "gold": 26, "food": 0,  "research": 0, "on": [3, 2], "unlocks": [],                    "defense": 0.0,  "in_town": false},
	&"market":   {"cost": 200, "gold": 45, "food": 0,  "research": 0, "on": [0, 3], "unlocks": [],                    "defense": 0.0,  "in_town": false},
	&"library":  {"cost": 180, "gold": 0,  "food": 0,  "research": 6, "on": [0, 3], "unlocks": [],                    "defense": 0.0,  "in_town": false},
	&"barracks": {"cost": 250, "gold": 0,  "food": 0,  "research": 0, "on": [0, 3], "unlocks": [&"pike", &"cavalry"], "defense": 0.0,  "in_town": false},
	&"walls":    {"cost": 300, "gold": 0,  "food": 0,  "research": 0, "on": [],     "unlocks": [],                    "defense": 0.3,  "in_town": true},
}
const WORK_RADIUS := 2

## What a raider takes away from a burned structure, as a share of what it cost. Razing
## is pillage rather than salting the earth: the ground is clear again afterwards and the
## owner may rebuild.
const RAZE_LOOT := 0.4
const ARMY_MOVE_POINTS := 3
## Men each regiment loses per turn when the larder is empty. Food used to floor at
## zero, which made upkeep a number with no teeth: you could field any army you liked
## as long as you did not mind the counter reading 0.
const DESERTION_PER_TURN := 12

## What breaking contact costs an army that quits the field: the men who did not get
## away. Enough that forfeiting is a decision rather than a free undo, not so much that
## fighting a lost battle to the end is ever the better option.
const FORFEIT_STRAGGLERS := 0.15

## Men a regiment recovers per turn while sitting in one of its own settlements.
## Without this the campaign is a one-way decay and the second battle is always
## fought by two exhausted armies.
const REINFORCE_PER_TURN := 25
const START_GOLD := 500
const START_FOOD := 200
const START_RESEARCH := 0
const SETTLEMENT_GOLD := 60                # per turn, per owned settlement
const SETTLEMENT_FOOD := 25
## A town's own contribution to the pool. At 3 the cheapest tech was thirteen turns
## away, which is not a tree so much as a rumour of one; at 8 the first lands around
## turn five and a library roughly doubles the pace after that.
const SETTLEMENT_RESEARCH := 8
