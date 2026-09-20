extends RefCounted
## The battle world.  Ticks at a fixed 20 Hz, owns every regiment, knows nothing
## about nodes, peers or rendering.  The server steps it; clients hold a decoded
## mirror of it and never call step().

const Rules := preload("res://sim/rules.gd")
const Regiment := preload("res://sim/regiment.gd")

var tick := 0
var regiments := {}                # id -> Regiment
var _next_id := 1


func add(owner_id: int, kind: StringName, pos: Vector2, facing := 0.0) -> Regiment:
	var r: Regiment = Regiment.make(_next_id, owner_id, kind, pos, facing)
	_next_id += 1
	regiments[r.id] = r
	return r


func get_regiment(id: int) -> Regiment:
	return regiments.get(id)


## Living regiments belonging to a player, in id order.
func owned_by(owner_id: int) -> Array:
	var out := []
	for id in sorted_ids():
		var r: Regiment = regiments[id]
		if r.owner_id == owner_id and r.is_alive():
			out.append(r)
	return out


## Iteration order must be deterministic: Dictionary order follows insertion, which
## differs between a server that spawned regiments and a client that decoded them.
func sorted_ids() -> Array:
	var ids := regiments.keys()
	ids.sort()
	return ids


## Every side still has someone willing to fight?
func is_over() -> bool:
	var standing := {}
	for r in regiments.values():
		if r.is_alive() and r.state != Regiment.State.ROUTING:
			standing[r.owner_id] = true
	return standing.size() <= 1


## The owner still standing, or 0 if nobody / everybody is.
func winner() -> int:
	var standing := {}
	for r in regiments.values():
		if r.is_alive() and r.state != Regiment.State.ROUTING:
			standing[r.owner_id] = true
	return standing.keys()[0] if standing.size() == 1 else 0


## One fixed tick.  Server-side only.
func step() -> void:
	tick += 1
	for id in sorted_ids():
		_step_regiment(regiments[id], Rules.TICK_DELTA)
	# ponytail: movement and morale recovery only. Contact, attrition, flank morale
	# and pursuit land at M7 -- until then battles are resolved by autoresolve.gd.


func _step_regiment(r: Regiment, dt: float) -> void:
	match r.state:
		Regiment.State.DEAD:
			return
		Regiment.State.MOVING, Regiment.State.ROUTING:
			_advance(r, dt)
		Regiment.State.IDLE:
			if r.engaged_with == -1:
				r.recover(Rules.MORALE_RECOVERY * dt)
			_turn_toward(r, r.target_facing, dt)


func _advance(r: Regiment, dt: float) -> void:
	var routing: bool = r.state == Regiment.State.ROUTING
	var speed: float = Rules.MOVE_SPEED * (Rules.ROUT_SPEED_MULT if routing else 1.0)
	var to_target: Vector2 = r.target - r.pos
	var dist := to_target.length()
	var step_len := speed * dt

	if dist <= maxf(step_len, Rules.ARRIVE_EPSILON):
		r.pos = r.target
		if not routing:
			r.state = Regiment.State.IDLE
		_turn_toward(r, r.target_facing, dt)
		return

	r.pos += to_target / dist * step_len
	_turn_toward(r, to_target.angle(), dt)


func _turn_toward(r: Regiment, desired: float, dt: float) -> void:
	r.facing = rotate_toward(r.facing, desired, Rules.TURN_SPEED * dt)
