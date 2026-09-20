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
var pos := Vector2.ZERO
var facing := 0.0                  # radians; 0 = +X
var width := Rules.DEFAULT_WIDTH
var state := State.IDLE
var target := Vector2.ZERO         # move order destination
var target_facing := 0.0
var engaged_with := -1             # regiment id, or -1


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
	return r


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
	morale = maxf(0.0, morale - Rules.MORALE_DRAIN_PER_FRACTION * float(lost) / float(max_strength))
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
