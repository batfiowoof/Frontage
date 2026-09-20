extends RefCounted
## One regiment: the only entity the battle sim knows about.
## Dumb data plus the handful of transitions that are always legal.
## Combat resolution lives in battle_state.gd — this file never looks at other regiments.

const Rules := preload("res://sim/rules.gd")

enum State { IDLE, MOVING, FIGHTING, ROUTING, DEAD }

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

## Seconds until it can loose again, and whoever the player told it to shoot at.
## Server-side only, like damage_pool: a client draws the battle, it does not run it.
var reload := 0.0
var focus := -1

## Fortification credit from whatever the regiment is standing behind, 0..1.
##
## This one IS on the wire, unlike damage_pool and reload. It is set at deploy from the
## defending settlement's walls, and a replay rebuilds the battle from the opening
## snapshot -- so leaving it off meant a battle fought at a walled town did not
## reproduce itself. Nothing caught it because every recorded battle had been in a field.
var defense := 0.0


static func make(p_id: int, p_owner: int, p_kind: StringName, p_pos: Vector2, p_facing := 0.0):
	var spec: Dictionary = Rules.KINDS.get(p_kind, Rules.KINDS[&"spear"])
	var r = new()
	r.id = p_id
	r.owner_id = p_owner
	r.kind = p_kind
	r.strength = spec["strength"]
	r.max_strength = spec["strength"]
	r.width = spec["width"]
	r.pos = p_pos
	r.facing = p_facing
	r.target = p_pos
	r.target_facing = p_facing
	r.ammo = int(spec.get("ammo", 0))
	return r


## How hard it can still swing, 0..1, between exhausted and fresh.
func readiness() -> float:
	return lerpf(Rules.TIRED_EFFECTIVENESS, 1.0, clampf(stamina, 0.0, 1.0))


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
	return true


## The frontage this kind wants in this formation, before the player adjusts it.
func natural_width() -> int:
	var base := float(Rules.KINDS[kind]["width"]) * float(form()["width"])
	return clampi(int(round(base)), Rules.MIN_WIDTH, maxi(Rules.MIN_WIDTH, max_strength))


func set_width(w: int) -> bool:
	if state == State.DEAD or reforming > 0.0:
		return false
	var wanted := clampi(w, Rules.MIN_WIDTH, mini(Rules.MAX_WIDTH, maxi(Rules.MIN_WIDTH, max_strength)))
	if wanted == width:
		return false
	width = wanted
	reforming = Rules.FORMATION_CHANGE_SECONDS
	return true


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


func recover(amount: float) -> void:
	if state == State.DEAD:
		return
	morale = minf(Rules.MORALE_MAX, morale + amount)
	if state == State.ROUTING and morale >= Rules.MORALE_RALLY_THRESHOLD:
		state = State.IDLE
		target = pos


func _start_rout() -> void:
	state = State.ROUTING
	engaged_with = -1
	# Run directly away from whatever it was facing.
	target = pos - Vector2.from_angle(facing) * 1000.0
