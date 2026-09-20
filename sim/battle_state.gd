extends RefCounted
## The battle world. Ticks at a fixed 20 Hz, owns every regiment, knows nothing
## about nodes, peers or rendering. The server steps it; clients hold a decoded
## mirror of it and never call step().

const Rules := preload("res://sim/rules.gd")
const Regiment := preload("res://sim/regiment.gd")
const Formation := preload("res://sim/formation.gd")

enum Exposure { FRONT, FLANK, REAR }

## Which edge of a regiment an attack lands on. Combat only cares whether that is the
## front, a flank or the back, but the men need to know WHICH flank, so they die on the
## side being hit and the block is eaten from there.
##
## LEFT is the low-file end of the line and RIGHT the high-file end. A regiment's local
## +Y runs toward higher files, so an attacker at a positive angle from its facing is
## standing off its RIGHT.
enum Side { FRONT, LEFT, RIGHT, REAR }

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

	_shoot(contacts, dt)

	for id in sorted_ids():
		_step_regiment(regiments[id], dt)


## How far a regiment's formation extends toward an enemy at this angle: half its
## depth toward its own front or back, half its frontage toward a flank. This is what
## makes two blocks meet front rank to front rank instead of centre to centre.
##
## ponytail: measured from max_strength, so the engagement distance does not drift as
## a regiment is worn down -- which is the entire point. A ten-man remnant therefore
## keeps a full block's footprint. Give it a real occupied depth if that ever shows.
static func reach(r: Regiment, exposure: Exposure) -> float:
	if exposure == Exposure.FLANK:
		return Formation.frontage(r.max_strength, r.width, r.spacing())
	return Formation.half_depth(r.max_strength, r.width, r.spacing())


## The space between two regiments' facing edges. Negative means they overlap.
static func gap_between(a: Regiment, b: Regiment) -> float:
	return a.pos.distance_to(b.pos) - reach(a, exposure_of(a, b)) - reach(b, exposure_of(b, a))


## Everyone with arrows left looses at whoever they can actually see.
##
## Shooting happens after the melee is resolved, so a regiment that was cut down this
## tick does not get a volley off from beyond the grave.
func _shoot(contacts: Dictionary, dt: float) -> void:
	for id in sorted_ids():
		var r: Regiment = regiments[id]
		if not r.is_alive() or not r.can_shoot():
			continue
		r.reload = maxf(0.0, r.reload - dt)
		# Not while somebody is swinging at you, and not on the move: a bow needs both
		# hands and a moment, which is what makes archers a question of where you put
		# them rather than a number on a card.
		if contacts.has(id) or r.state != Regiment.State.IDLE:
			continue
		if r.reload > 0.0:
			continue
		var mark = _volley_target(r)
		if mark == null:
			continue
		r.reload = float(Rules.KINDS[r.kind]["reload"])
		r.ammo -= 1
		_land_volley(r, mark)


## Whoever the player named if it is still shootable, otherwise the nearest enemy that
## is both in range and not behind one of our own regiments.
func _volley_target(shooter: Regiment):
	var chosen = regiments.get(shooter.focus)
	if chosen != null and _shootable(shooter, chosen):
		return chosen
	var best = null
	var best_distance := INF
	for id in sorted_ids():
		var e: Regiment = regiments[id]
		if not _shootable(shooter, e):
			continue
		var d := shooter.pos.distance_squared_to(e.pos)
		if d < best_distance:
			best_distance = d
			best = e
	return best


func _shootable(shooter: Regiment, mark: Regiment) -> bool:
	if mark == null or mark.owner_id == shooter.owner_id or not mark.is_alive():
		return false
	if shooter.pos.distance_to(mark.pos) > shooter.range_of():
		return false
	return line_is_clear(shooter, mark, regiments.values())


## Nobody shoots through their own line. A friendly regiment anywhere between the two,
## within a regiment's width of the flight path, blocks it -- which is why archers go on
## a wing or in front and have to be pulled back before the lines meet.
static func line_is_clear(shooter: Regiment, mark: Regiment, everyone) -> bool:
	var flight: Vector2 = mark.pos - shooter.pos
	var length := flight.length()
	if length < 1.0:
		return true
	var along := flight / length
	for f in everyone:
		if f.id == shooter.id or f.owner_id != shooter.owner_id or not f.is_alive():
			continue
		var offset: Vector2 = f.pos - shooter.pos
		var travelled := offset.dot(along)
		if travelled <= 0.0 or travelled >= length:
			continue                       # beside us or behind the target
		var aside := absf(offset.cross(along))
		var width := Formation.frontage(f.max_strength, f.width, f.spacing()) + Rules.LINE_OF_FIRE_MARGIN
		if aside < width:
			return false
	return true


func _land_volley(shooter: Regiment, mark: Regiment) -> void:
	var distance := shooter.pos.distance_to(mark.pos)
	var reach := maxf(1.0, shooter.range_of())
	var falloff := lerpf(1.0, Rules.MISSILE_FALLOFF, clampf(distance / reach, 0.0, 1.0))
	var cover := clampf(float(mark.form()["missile"]), -1.0, 0.95)
	var kills := float(Rules.KINDS[shooter.kind]["volley"]) * shooter.fraction() * falloff
	kills *= (1.0 - cover) * shooter.order_factor()
	mark.take_casualties(int(round(maxf(0.0, kills))))
	mark.shock(Rules.MISSILE_SHOCK * (1.0 - clampf(cover, 0.0, 0.95)))


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
			if gap_between(a, b) > Rules.CONTACT_GAP:
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
	r.engaged_with = _primary_foe(r, foes)
	if r.state == Regiment.State.ROUTING:
		return
	# Contact stops a march -- but only a march INTO the enemy. A regiment ordered
	# away from the fight is disengaging, and forcing it back into FIGHTING every
	# tick silently cancelled the order, which made relieving a tired unit impossible
	# and quietly deleted the tactic frontage-limited combat exists to create.
	# It still takes hits while it pulls back, and it turns its back to do it.
	if r.state == Regiment.State.MOVING and _withdrawing(r, foes):
		return
	r.state = Regiment.State.FIGHTING
	r.target = r.pos


func _withdrawing(r: Regiment, foes: Array) -> bool:
	var foe = regiments.get(r.engaged_with)
	if foe == null:
		return false
	var away := r.target - r.pos
	if away.length_squared() < 1.0:
		return false
	return away.normalized().dot((foe.pos - r.pos).normalized()) < 0.0


## The enemy a regiment considers itself to be fighting: the one most nearly in
## front of it. A unit pinned from the front does not turn its back on that enemy to
## answer a flanker, which is the whole reason pinning-and-flanking works.
func _primary_foe(r: Regiment, foes: Array) -> int:
	var best: int = foes[0]
	var best_off := TAU
	for id: int in foes:
		var foe = regiments.get(id)
		if foe == null:
			continue
		var off := absf(angle_difference(r.facing, (foe.pos - r.pos).angle()))
		if off < best_off:
			best_off = off
			best = id
	return best


func _accumulate_strike(attacker: Regiment, defender: Regiment, dt: float, kills: Dictionary, shocks: Dictionary) -> void:
	if not attacker.is_alive() or attacker.state == Regiment.State.ROUTING:
		return                             # a broken regiment does not swing back

	# Two angles matter, not one. How the DEFENDER is hit decides what it suffers;
	# how the ATTACKER stands decides how much of itself it can bring. That second
	# one is what makes a flank one-sided instead of merely favourable.
	var hit_from := exposure_of(defender, attacker)
	var swinging_from := exposure_of(attacker, defender)
	if bool(defender.form()["all_round"]):
		hit_from = Exposure.FRONT          # a square has no flank to find
	if bool(attacker.form()["all_round"]):
		swinging_from = Exposure.FRONT

	var damage_mult := 1.0
	var morale_drain := Rules.MORALE_DRAIN_FIGHTING
	match hit_from:
		Exposure.FLANK:
			damage_mult = Rules.FLANK_DAMAGE_MULT
			morale_drain = Rules.MORALE_DRAIN_FLANKED
		Exposure.REAR:
			damage_mult = Rules.REAR_DAMAGE_MULT
			morale_drain = Rules.MORALE_DRAIN_REAR
	if defender.state == Regiment.State.ROUTING:
		damage_mult *= Rules.RUNDOWN_DAMAGE_MULT

	# Spears set against a charge hurt a horse, and are hurt rather less by one.
	if bool(attacker.form()["brace"]) and defender.is_cavalry():
		damage_mult *= Rules.BRACE_DAMAGE_MULT
	var braced := 1.0
	if bool(defender.form()["brace"]) and attacker.is_cavalry():
		braced = 1.0 - Rules.BRACE_PROTECTION

	var files := contact_files(attacker, defender, swinging_from, hit_from)
	var output := Rules.KILLS_PER_FILE_PER_SEC * float(files) * response_of(swinging_from)
	output *= attacker.readiness() * damage_mult * dt
	output *= float(attacker.form()["damage"]) * attacker.order_factor() * braced
	output *= 1.0 - clampf(defender.defense + float(defender.form()["defense"]) * defender.order_factor(), 0.0, 0.9)

	kills[defender.id] = float(kills.get(defender.id, 0.0)) + output
	shocks[defender.id] = float(shocks.get(defender.id, 0.0)) + morale_drain * dt


## How many files a regiment can turn toward an enemy at this angle. Frontally it
## fights on its full width; from the side or behind, only the ends of its ranks.
static func files_engaged(r: Regiment, exposure: Exposure) -> int:
	if exposure == Exposure.FRONT:
		return Formation.files_across(r.strength, r.width)
	return Formation.ranks_deep(r.strength, r.width)


## Men fight only where the formations actually touch, so an attacker cannot bring
## more files than the defender offers edge for -- plus a little for lapping round
## the ends of a narrower enemy.
static func contact_files(attacker: Regiment, defender: Regiment, swinging_from: Exposure, hit_from: Exposure) -> int:
	var brought := files_engaged(attacker, swinging_from)
	var offered := files_engaged(defender, hit_from)
	return mini(brought, maxi(1, ceili(float(offered) * Rules.WRAP_ALLOWANCE)))


static func response_of(exposure: Exposure) -> float:
	if exposure == Exposure.FLANK:
		return Rules.RESPONSE_FLANK
	if exposure == Exposure.REAR:
		return Rules.RESPONSE_REAR
	return Rules.RESPONSE_FRONT


## Where is `attacker` hitting `defender` from, relative to the way it is facing?
## Returns a `Side`. Typed as int because GDScript will not let a static function
## hand its own script's enum to another function in the same script.
static func side_of(defender: Regiment, attacker: Regiment) -> int:
	var bearing := (attacker.pos - defender.pos).angle()
	var off := angle_difference(defender.facing, bearing)
	var away := absf(off)
	if away <= Rules.FLANK_ANGLE:
		return Side.FRONT
	if away >= Rules.REAR_ANGLE:
		return Side.REAR
	return Side.RIGHT if off > 0.0 else Side.LEFT


## What the fight cares about. Both flanks are the same to the damage maths, which is
## why this is a view of `side_of` rather than a second angle calculation.
static func exposure_of(defender: Regiment, attacker: Regiment) -> Exposure:
	var side := side_of(defender, attacker)
	if side == Side.FRONT:
		return Exposure.FRONT
	if side == Side.REAR:
		return Exposure.REAR
	return Exposure.FLANK


# --- movement -------------------------------------------------------------

func _step_regiment(r: Regiment, dt: float) -> void:
	if r.reforming > 0.0:
		r.reforming = maxf(0.0, r.reforming - dt)
	match r.state:
		Regiment.State.DEAD:
			return
		Regiment.State.MOVING, Regiment.State.ROUTING:
			_advance(r, dt)
		Regiment.State.IDLE:
			if r.engaged_with == -1:
				r.recover(Rules.MORALE_RECOVERY * dt)
				r.rest(Rules.STAMINA_RECOVERY * dt)
			_turn_toward(r, r.target_facing, dt)
		Regiment.State.FIGHTING:
			r.tire(Rules.STAMINA_DRAIN_FIGHTING * dt)
			# Wheeling in contact is slow, so a flank is a race the victim can lose.
			var foe = regiments.get(r.engaged_with)
			if foe != null:
				_turn_toward(r, (foe.pos - r.pos).angle(), dt * Rules.ENGAGED_TURN_MULT)


func _advance(r: Regiment, dt: float) -> void:
	var routing: bool = r.state == Regiment.State.ROUTING
	var speed: float = Rules.MOVE_SPEED * float(Rules.KINDS[r.kind]["speed"]) * float(r.form()["speed"])
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
	r.facing = rotate_toward(r.facing, desired, Rules.TURN_SPEED * float(r.form()["turn"]) * dt)
