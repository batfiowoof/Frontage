extends RefCounted
## The battle world. Ticks at a fixed 20 Hz, owns every regiment, knows nothing
## about nodes, peers or rendering. The server steps it; clients hold a decoded
## mirror of it and never call step().

const Rules := preload("res://sim/rules.gd")
const Regiment := preload("res://sim/regiment.gd")

enum Exposure { FRONT, FLANK, REAR }

var tick := 0
var regiments := {}                # id -> Regiment
var _next_id := 1


func add(owner_id: int, kind: StringName, pos: Vector2, facing := 0.0) -> Regiment:
	var r: Regiment = Regiment.make(_next_id, owner_id, kind, pos, facing)
	_next_id += 1
	regiments[r.id] = r
	return r


func get_regiment(id: int) -> Variant:
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


func _standing_owners() -> Dictionary:
	var standing := {}
	for r in regiments.values():
		if r.is_alive() and r.state != Regiment.State.ROUTING:
			standing[r.owner_id] = true
	return standing


## Does every side still have someone willing to fight?
func is_over() -> bool:
	return _standing_owners().size() <= 1


## The owner still standing, or 0 if nobody / everybody is.
func winner() -> int:
	var standing := _standing_owners()
	return standing.keys()[0] if standing.size() == 1 else 0


# --- the tick -------------------------------------------------------------

## One fixed tick. Server-side only.
##
## Contacts are found first, then every regiment's state is settled, then all damage
## is computed against that settled picture and only afterwards applied. Resolving
## strike-by-strike instead would make the outcome depend on regiment id order: the
## lower id would kill men who had not yet swung back, which is exactly the kind of
## invisible unfairness a player cannot see but can feel.
func step() -> void:
	tick += 1
	var dt := Rules.TICK_DELTA
	var contacts := _find_contacts()

	for id in sorted_ids():
		_settle_state(regiments[id], contacts.get(id, []))

	var kills := {}
	var shocks := {}
	for id in sorted_ids():
		var defender: Regiment = regiments[id]
		if not defender.is_alive():
			continue
		for foe_id in contacts.get(id, []):
			_accumulate_strike(regiments[foe_id], defender, dt, kills, shocks)

	for id in kills:
		var r: Regiment = regiments[id]
		r.damage_pool += kills[id]
		var whole := int(floor(r.damage_pool))
		if whole > 0:
			r.damage_pool -= float(whole)
			r.take_casualties(whole)
	for id in shocks:
		regiments[id].shock(shocks[id])

	for id in sorted_ids():
		_step_regiment(regiments[id], dt)


## Who is touching whom. ponytail: O(n^2) over every pair. A battle is ~40 regiments,
## so this is 800 distance checks per tick; put them in a grid if that ever changes.
func _find_contacts() -> Dictionary:
	var out := {}
	var ids := sorted_ids()
	for i in ids.size():
		var a: Regiment = regiments[ids[i]]
		if not a.is_alive():
			continue
		for j in range(i + 1, ids.size()):
			var b: Regiment = regiments[ids[j]]
			if not b.is_alive() or a.owner_id == b.owner_id:
				continue
			if a.pos.distance_squared_to(b.pos) > Rules.CONTACT_RANGE * Rules.CONTACT_RANGE:
				continue
			if not out.has(a.id):
				out[a.id] = []
			if not out.has(b.id):
				out[b.id] = []
			out[a.id].append(b.id)
			out[b.id].append(a.id)
	return out


func _settle_state(r: Regiment, foes: Array) -> void:
	if not r.is_alive():
		return
	if foes.is_empty():
		if r.state == Regiment.State.FIGHTING:
			r.state = Regiment.State.IDLE
			r.target = r.pos
		r.engaged_with = -1
		return
	r.engaged_with = foes[0]
	if r.state != Regiment.State.ROUTING:
		# Contact stops a march. The player can always order it to disengage again.
		r.state = Regiment.State.FIGHTING
		r.target = r.pos


func _accumulate_strike(attacker: Regiment, defender: Regiment, dt: float, kills: Dictionary, shocks: Dictionary) -> void:
	if not attacker.is_alive() or attacker.state == Regiment.State.ROUTING:
		return                             # a broken regiment does not swing back
	var exposure := exposure_of(defender, attacker)
	var damage_mult := 1.0
	var morale_drain := Rules.MORALE_DRAIN_FIGHTING
	match exposure:
		Exposure.FLANK:
			damage_mult = Rules.FLANK_DAMAGE_MULT
			morale_drain = Rules.MORALE_DRAIN_FLANKED
		Exposure.REAR:
			damage_mult = Rules.REAR_DAMAGE_MULT
			morale_drain = Rules.MORALE_DRAIN_REAR
	if defender.state == Regiment.State.ROUTING:
		damage_mult *= Rules.RUNDOWN_DAMAGE_MULT

	var output := Rules.KILLS_PER_SECOND * attacker.fraction() * damage_mult * dt
	output *= 1.0 - clampf(defender.defense, 0.0, 0.9)
	kills[defender.id] = float(kills.get(defender.id, 0.0)) + output
	shocks[defender.id] = float(shocks.get(defender.id, 0.0)) + morale_drain * dt


## Where is `attacker` hitting `defender` from, relative to the way it is facing?
static func exposure_of(defender: Regiment, attacker: Regiment) -> Exposure:
	var bearing := (attacker.pos - defender.pos).angle()
	var off := absf(angle_difference(defender.facing, bearing))
	if off <= Rules.FLANK_ANGLE:
		return Exposure.FRONT
	return Exposure.FLANK if off <= Rules.REAR_ANGLE else Exposure.REAR


# --- movement -------------------------------------------------------------

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
		Regiment.State.FIGHTING:
			# Turn to face whoever it is fighting: a regiment that has noticed an
			# attack from the side will try to wheel, which is what makes a flank a
			# race rather than an instant loss.
			var foe = regiments.get(r.engaged_with)
			if foe != null:
				_turn_toward(r, (foe.pos - r.pos).angle(), dt)


func _advance(r: Regiment, dt: float) -> void:
	var routing: bool = r.state == Regiment.State.ROUTING
	var speed: float = Rules.MOVE_SPEED * float(Rules.KINDS[r.kind]["speed"])
	if routing:
		speed *= Rules.ROUT_SPEED_MULT
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
