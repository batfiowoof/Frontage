extends RefCounted
## One regiment: the only entity the battle sim knows about.
## Dumb data plus the handful of transitions that are always legal.
## Combat resolution lives in battle_state.gd — this file never looks at other regiments.

const Rules := preload("res://sim/rules.gd")
const Formation := preload("res://sim/formation.gd")

enum State { IDLE, MOVING, FIGHTING, ROUTING, DEAD }

## How a regiment behaves when nobody is telling it anything. A bitfield rather than two
## bools because it goes on the wire, and one int is one int however many of these there
## turn out to be.
##
## GUARD: hold this ground. Suppresses the chase, so a regiment told to attack somebody
##   goes for them and a guarding one waits for them to come.
## SKIRMISH: back away from whatever is closing, while there are arrows left. It is what
##   makes a missile unit worth its own orders rather than a slow infantry block.
enum Stance { GUARD = 1, SKIRMISH = 2 }

var id := 0
var owner_id := 0                  # multiplayer peer id
var kind := &"spear"
var strength := 0
var max_strength := 0
var morale := Rules.MORALE_MAX
var stamina := 1.0
var pos := Vector2.ZERO
var facing := 0.0                  # radians; 0 = +X
var width := Rules.DEFAULT_WIDTH
var formation := Rules.DEFAULT_FORMATION
var reforming := 0.0
var ammo := 0
var state := State.IDLE
var target := Vector2.ZERO         # move order destination
var target_facing := 0.0
var engaged_with := -1             # regiment id, or -1

## Fractional casualties waiting to become whole men. Server-side only: it is not on
## the wire, because a client never continues the simulation, only draws it.
var damage_pool := 0.0
## The same idea for the other side of the ledger: fractional men KILLED, waiting to
## become a whole point of xp. Server-side for the same reason -- a client only draws.
var xp_pool := 0.0
## How fast it is actually going, world units a second. Server-side, like damage_pool: it
## starts at zero, a replay opens from a snapshot where nothing is moving, and a client
## only ever draws interpolated positions. Nothing on the wire has to carry it.
var pace := 0.0

## Where it is walking to get to `target`, the target that was planned for, whether the
## plan reaches it, and how long until the plan is checked again. Server-side, like `pace`:
## not on the wire, empty in any snapshot, and a replay rebuilds it from the orders --
## `Pathing` is deterministic, so it rebuilds the same one.
var path := PackedVector2Array()
var path_to := Vector2.INF
var path_whole := false
var replan := 0.0
## Stopped on the march because a friend is crossing in front of it. The planner treats a
## waiting regiment as standing, so whoever it is waiting for plans round it. Server-side.
var waiting := false

## The frontage it is still actually FIGHTING at, and how far through the re-dress it is.
## Server-side like `pace`: they start settled and a replay rebuilds them from the orders.
##
## `dressed` defaults to 1.0 and that is load-bearing. Everything that writes `width`
## directly -- snapshot decode, and every test that pokes `r.width = 24` -- leaves it at
## 1.0 and gets the width it asked for with no blending. Only `set_width()` starts a ramp.
## How many times it has broken, and how long since it was last in contact. `routs` is on
## the wire: the banner has to show a shattered regiment as having no flag at all, and a
## client cannot derive that from anything else it holds.
var routs := 0
var rally_wait := 0.0

var was_width := 0
var dressed := 1.0

## Seconds of charge left. Set when a regiment at a run reaches the enemy and burnt
## down every tick after, so the bonus belongs to the impact and not to the melee.
## Server-side, like damage_pool: it lasts three seconds and a client draws bodies.
var charge := 0.0

## Seconds until it can loose again, and whoever the player told it to shoot at.
## Server-side only, like damage_pool: a client draws the battle, it does not run it.
var reload := 0.0
var focus := -1
## How far a wedge has driven into what is in front of it, 0..1. Server-side like `pace`:
## it starts at nothing, a replay rebuilds it from the fight, and a client only draws the
## positions it produces. See Rules.WEDGE_*.
var bite := 0.0
var stance := 0                    # a mask of Stance bits

## Fortification credit from whatever the regiment is standing behind, 0..1.
##
## This one IS on the wire, unlike damage_pool and reload. It is set at deploy from the
## defending settlement's walls, and a replay rebuilds the battle from the opening
## snapshot -- so leaving it off meant a battle fought at a walled town did not
## reproduce itself. Nothing caught it because every recorded battle had been in a field.
var defense := 0.0

## Men this regiment has killed, across every battle it has fought. Carried between
## battles in the campaign tuple and therefore on the battle wire too: a replay rebuilds
## the fight from its opening snapshot, so anything that changes the outcome has to be in
## it. Same reason `defense` and the tech header are already there.
var xp := 0


static func make(p_id: int, p_owner: int, p_kind: StringName, p_pos: Vector2, p_facing := 0.0):
	var spec: Dictionary = Rules.KINDS.get(p_kind, Rules.KINDS[&"spear"])
	var r = new()
	r.id = p_id
	r.owner_id = p_owner
	r.kind = p_kind
	r.strength = spec["strength"]
	r.max_strength = spec["strength"]
	r.width = spec["width"]
	r.was_width = r.width
	r.pos = p_pos
	r.facing = p_facing
	r.target = p_pos
	r.target_facing = p_facing
	r.ammo = int(spec.get("ammo", 0))
	return r


## How hard it can still swing, 0..1, between exhausted and fresh.
func readiness() -> float:
	return lerpf(Rules.TIRED_EFFECTIVENESS, 1.0, clampf(stamina, 0.0, 1.0))


## ...and the other three things exhaustion decides, read exactly the same way, because
## they are one idea and not four. A spent regiment hits softer, is easier to kill, cannot
## keep up, and breaks sooner; only the first of those used to be true.
func vulnerability() -> float:
	return lerpf(Rules.TIRED_VULNERABILITY, 1.0, clampf(stamina, 0.0, 1.0))


func legs() -> float:
	return lerpf(Rules.TIRED_PACE, 1.0, clampf(stamina, 0.0, 1.0))


func nerve() -> float:
	return lerpf(Rules.TIRED_RESOLVE, 1.0, clampf(stamina, 0.0, 1.0))


## What this regiment has learned, 0 green to 1 fully blooded. Cumulative men killed
## across every battle it has fought, carried home in the campaign tuple.
##
## Read like the exhaustion terms, but off `xp` instead of `stamina`, and in the opposite
## direction: exhaustion lerps from bad to 1.0 as a regiment rests, this lerps from 1.0
## to good as it learns.
func seasoning() -> float:
	return clampf(float(xp) / Rules.VETERAN_KILLS, 0.0, 1.0)


func veteran_attack() -> float:
	return lerpf(1.0, Rules.VETERAN_ATTACK, seasoning())


func veteran_resolve() -> float:
	return lerpf(1.0, Rules.VETERAN_RESOLVE, seasoning())


## Turn right round without wheeling. A rectangle rotated 180 degrees about its centre
## stands on exactly the same ground, so this costs no rotation at all -- the men hold
## their places and the rear rank becomes the front rank. bodies.gd relabels them to
## match, and the only price is that the regiment has to stop and start again.
##
## Refused in contact, and that is load-bearing: a regiment taken in the rear that could
## flip to face its attacker would delete the whole flank-and-rear mechanic.
func about_face() -> void:
	facing = wrapf(facing + PI, -PI, PI)
	pace = 0.0


func tire(amount: float) -> void:
	stamina = maxf(0.0, stamina - amount)


func rest(amount: float) -> void:
	stamina = minf(1.0, stamina + amount)


## The formation's numbers. Anything asking "how fast, how hard, how tough" goes
## through here rather than reaching into the table itself.
func form() -> Dictionary:
	return Rules.FORMATIONS.get(formation, Rules.FORMATIONS[Rules.DEFAULT_FORMATION])


func spacing() -> float:
	return float(form()["spacing"])


## The outline it stands in: block, wedge or hollow. See Formation.shape_of.
func shape() -> StringName:
	return StringName(form().get("shape", &"block"))


## (half depth, half frontage) of the shape it stands in, from max_strength like reach().
func extent() -> Vector2:
	return Formation.extent(shape(), max_strength, width, spacing())

## Caught mid-change, a regiment is worth rather less than either shape it is between.
func order_factor() -> float:
	return Rules.REFORM_PENALTY if reforming > 0.0 else 1.0


func can_shoot() -> bool:
	return ammo > 0 and float(Rules.KINDS[kind]["range"]) > 0.0


func range_of() -> float:
	return float(Rules.KINDS[kind]["range"])


func is_cavalry() -> bool:
	return float(Rules.KINDS[kind]["speed"]) >= Rules.CAVALRY_SPEED


## Change shape. Refused while already re-forming, or the player could flicker between
## formations to dodge the penalty for doing it at the wrong moment.
func set_formation(name: StringName) -> bool:
	if state == State.DEAD or reforming > 0.0 or not Rules.FORMATIONS.has(name):
		return false
	if name == formation:
		return false
	formation = name
	width = natural_width()
	reforming = Rules.FORMATION_CHANGE_SECONDS
	bite = 0.0
	return true


## The frontage this kind wants in this formation, before the player adjusts it.
func natural_width() -> int:
	var base := float(Rules.KINDS[kind]["width"]) * float(form()["width"])
	return clampi(int(round(base)), Rules.MIN_WIDTH, maxi(Rules.MIN_WIDTH, max_strength))


## Change the frontage. **Free, immediate, and never refused** -- unlike a change of
## SHAPE, which still costs FORMATION_CHANGE_SECONDS at REFORM_PENALTY.
##
## The split is the point: picking a formation is a manoeuvre, widening the line is
## dressing it. Charging for the frontage made the drag that sets it expensive to use and
## silently rate-limited [ and ] to one step every six seconds -- the second press was
## refused by the `reforming > 0` guard that used to be on this function, with nothing
## anywhere to say so.
##
## Free, but **it does not arrive before the men do**. The men have to walk into their new
## files, and until they are there the regiment goes on fighting at the frontage it is
## actually standing in -- `was_width`, blended out over `dressed`.
##
## Without that, a regiment already locked in a melee -- which cannot walk anywhere,
## because `_settle_state` snaps it back to FIGHTING with `target = pos` -- still took the
## SET_FORMATION from the same drag and DOUBLED ITS OUTPUT IN PLACE IN 50 MS, for nothing.
## Dragging a wide line across a melee was the cheapest thing in the game.
func set_width(w: int) -> bool:
	if state == State.DEAD:
		return false
	var wanted := clampi(w, Rules.MIN_WIDTH, mini(Rules.MAX_WIDTH, maxi(Rules.MIN_WIDTH, max_strength)))
	if wanted == width:
		return false
	# Blend out from wherever it had actually got to, not from the last width ORDERED, or
	# a second drag part-way through the first would start it over from a line it never
	# stood in.
	was_width = fighting_width()
	dressed = 0.0
	width = wanted
	return true


## How far the end man still has to walk, which is what paces both the re-dress and the
## ramp. Zero when there is nothing to do.
func dress_walk() -> float:
	return absf(Formation.frontage(max_strength, width, spacing())
		- Formation.frontage(max_strength, was_width, spacing()))


## The frontage it is FIGHTING at right now, somewhere between the one it is standing in
## and the one it was told to take up.
func fighting_width() -> int:
	if dressed >= 1.0 or was_width <= 0:
		return width
	return int(round(lerpf(float(was_width), float(width), dressed)))


func is_alive() -> bool:
	return state != State.DEAD


## Fraction of the regiment still standing, 0..1.
func fraction() -> float:
	return 0.0 if max_strength <= 0 else float(strength) / float(max_strength)


## A move order.  The dead ignore orders; so do routers — that is the whole
## point of a rout, and letting a player steer one would erase morale as a mechanic.
func order_move(to: Vector2, face: float) -> bool:
	if state == State.DEAD or state == State.ROUTING:
		return false
	target = to
	target_facing = face
	state = State.MOVING
	engaged_with = -1
	path = PackedVector2Array()         # a new order is a new plan
	return true


## Returns men actually lost (the request is clamped by who is left).
func take_casualties(n: int) -> int:
	if state == State.DEAD or n <= 0:
		return 0
	var lost := mini(n, strength)
	strength -= lost
	# Against the men it HAD when it was hit, not its paper strength. Measured against
	# max_strength, a regiment already down to a third felt each loss as lightly as a
	# fresh one, so a thin line endured exactly as long as a deep one and depth bought
	# nothing. Losing a fifth of who is left is losing a fifth.
	var had := maxi(1, strength + lost)
	morale = maxf(0.0, morale - Rules.MORALE_DRAIN_PER_FRACTION * float(lost) / float(had))
	if strength <= 0:
		strength = 0
		state = State.DEAD
		engaged_with = -1
	elif morale <= Rules.MORALE_ROUT_THRESHOLD:
		_start_rout()
	return lost


## Morale damage from something other than casualties: being flanked, seeing a
## neighbour break, losing the general.
func shock(amount: float) -> void:
	if state == State.DEAD or amount <= 0.0:
		return
	morale = maxf(0.0, morale - amount)
	if state != State.ROUTING and morale <= Rules.MORALE_ROUT_THRESHOLD:
		_start_rout()


## A regiment that has broken too many times is finished: it never rallies again and runs
## until it is off the field. Three routs, as Total War has it.
func shattered() -> bool:
	return routs >= Rules.ROUTS_BEFORE_SHATTERED


## The best morale this regiment can still reach. A wreck does not get a full bar back:
## one that broke at 41% casualties used to climb all the way to 100 in twenty seconds and
## come back as though nothing had happened. There was no permanent morale damage of any
## kind, which is most of why units seemed to recover instantly.
func morale_ceiling() -> float:
	return Rules.MORALE_MAX * maxf(0.15, fraction())


func recover(amount: float) -> void:
	if state == State.DEAD:
		return
	morale = minf(morale_ceiling(), maxf(morale, morale + amount))
	# Shattered men do not come back, however calm they get on the way out.
	if state == State.ROUTING and not shattered() and morale >= Rules.MORALE_RALLY_THRESHOLD:
		state = State.IDLE
		target = pos


func _start_rout() -> void:
	state = State.ROUTING
	routs += 1
	rally_wait = Rules.RALLY_DELAY
	engaged_with = -1
	# Run directly away from whatever it was facing.
	target = pos - Vector2.from_angle(facing) * 1000.0
