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
## [[kind, x, y, radius], ...]. Rows rather than objects because they go on the wire.
var features := []
## What each side has learned, carried in from the campaign. Per owner rather than per
## regiment: four more floats on every regiment would cost ~32 B each on a wire already
## at 171, and this is a few dozen bytes for the whole battle. It has to be on the wire
## at all because a replay rebuilds the fight from the opening snapshot.
var techs := {}

## owner -> the regiment id carrying that side's general.
##
## NOT on the wire, and it does not need to be: it is a pure function of `max_strength`
## and the ids, both of which the snapshot already carries, so the server, every client
## and a replay all derive the same answer from the same bytes. Sending it would be
## paying for something everyone can work out.
var generals := {}
## owner -> what its commander is worth, 1.0 for a man in his first battle. Carried in
## from the campaign and on the wire beside `techs`, for the same reason: a replay
## rebuilds the fight from its opening snapshot and has to reach the same answer.
var renown := {}

## Arranging the line, or fighting. DEFAULT IS FIGHTING, deliberately: every test and
## harness in the tree builds a BattleState and calls step() expecting a battle, and a
## phase that had to be dismissed would silently stop all of them. Only `_begin_battle`
## opens in DEPLOY, which is the one place a player is actually there to deploy.
enum Phase { DEPLOY, FIGHT }
var phase := Phase.FIGHT
var ready := {}                    # owner -> has said it is done arranging
## Which half of the field each side sets up in, -1 or +1. DERIVED, not decoded: the
## armies are laid out either side of x = 0 and cannot cross while deploying, so the mean
## x of a side answers it from a snapshot that already carries the positions -- the same
## trick the general uses to stay off the wire.
var sides := {}

## The town's walls, as flat rows [x1, y1, x2, y2, breach] -- the same shape `features`
## uses, and on the wire for the same reason: a replay rebuilds the fight from its opening
## snapshot. `breach` runs 0..1 and a segment stops blocking at 1.
var walls := []
## Whoever has already been mourned, so an army is shaken by losing him once.
var _mourned := {}


## The biggest regiment on each side carries the general.
##
## Computed over EVERY regiment, the dead included, so it never changes hands. Skipping
## the fallen would promote the next-biggest the moment he died -- the army would lose
## its general and instantly acquire a new one, and a client decoding a mid-battle
## snapshot would name a different man from the server.
## Ties go to the lower id, because iteration order must not decide it.
func commission_generals() -> void:
	generals.clear()
	_mourned.clear()
	var best := {}
	for id in sorted_ids():
		var r: Regiment = regiments[id]
		if not best.has(r.owner_id) or r.max_strength > int(best[r.owner_id]):
			best[r.owner_id] = r.max_strength
			generals[r.owner_id] = r.id


## Is this regiment close enough to its own general to be steadied by him? The general
## steadies himself too, which is why a commander in the line is worth something.
## What this owner's commander is worth. A side with no entry has an ordinary one.
func renown_of(owner: int) -> float:
	return float(renown.get(owner, 1.0))


func _in_reach_of_general(r: Regiment) -> bool:
	var id: int = int(generals.get(r.owner_id, -1))
	if id < 0:
		return false
	var g = regiments.get(id)
	if g == null or not g.is_alive() or g.state == Regiment.State.ROUTING:
		return false
	return r.pos.distance_squared_to(g.pos) <= Rules.GENERAL_RADIUS * Rules.GENERAL_RADIUS


## Losing him is felt by everybody at once, and only once.
func _mourn_the_fallen() -> void:
	for owner in generals:
		if bool(_mourned.get(owner, false)):
			continue
		var g = regiments.get(int(generals[owner]))
		if g != null and g.is_alive():
			continue
		_mourned[owner] = true
		for id in sorted_ids():
			var r: Regiment = regiments[id]
			if r.owner_id == owner and r.is_alive():
				r.shock(Rules.GENERAL_FALLS)


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


# --- walls ----------------------------------------------------------------
## Put a wall across the defender's front, with a gate in it.
##
## `side` is the half of the field the defender holds, so the wall stands between the two
## armies and the attacker has to come through it. Two segments and a gap: the gap is the
## mechanic, because combat here is frontage-limited and a gate is a frontage of four
## files however wide the line arriving at it is.
func lay_walls(side: float) -> void:
	var x := side * Rules.WALL_STANDOFF
	walls = [
		[x, -Rules.WALL_HALF_SPAN, x, -Rules.WALL_GATE_HALF, 0.0],
		[x, Rules.WALL_GATE_HALF, x, Rules.WALL_HALF_SPAN, 0.0],
	]


## Is this segment still standing?
static func standing(w: Array) -> bool:
	return float(w[4]) < 1.0


## Does the straight line from `a` to `b` cross a wall that is still up?
##
## Used for movement AND for contact. Blocking only movement would let two regiments
## either side of a wall fight through it, which is precisely the thing a wall is for.
func crosses_a_wall(a: Vector2, b: Vector2) -> bool:
	for w: Array in walls:
		if not standing(w):
			continue
		if _segments_cross(a, b, Vector2(w[0], w[1]), Vector2(w[2], w[3])):
			return true
	return false


## Standard orientation test. Two segments cross when each straddles the other.
static func _segments_cross(p1: Vector2, p2: Vector2, p3: Vector2, p4: Vector2) -> bool:
	var d1 := _side(p3, p4, p1)
	var d2 := _side(p3, p4, p2)
	var d3 := _side(p1, p2, p3)
	var d4 := _side(p1, p2, p4)
	return ((d1 > 0.0) != (d2 > 0.0)) and ((d3 > 0.0) != (d4 > 0.0))


static func _side(a: Vector2, b: Vector2, p: Vector2) -> float:
	return (b - a).cross(p - a)


## Rams at work. A ram standing against a segment opens it over BREACH_SECONDS, divided
## by whatever `siegecraft` its owner has -- the tech that until now only made the old
## flat wall number smaller.
##
## Only from OUTSIDE: a defender cannot knock down his own wall to get out, which would
## be a way of turning a siege back into an open field at will.
func _work_the_rams(dt: float) -> void:
	if walls.is_empty():
		return
	for id in sorted_ids():
		var r: Regiment = regiments[id]
		if r.kind != Rules.RAM or not r.is_alive() or r.state == Regiment.State.ROUTING:
			continue
		for w: Array in walls:
			if not standing(w):
				continue
			if _distance_to_segment(r.pos, Vector2(w[0], w[1]), Vector2(w[2], w[3])) > Rules.BREACH_REACH:
				continue
			var pace := dt / (Rules.BREACH_SECONDS * maxf(0.05, tech(r.owner_id, &"siege")))
			w[4] = minf(1.0, float(w[4]) + pace)
			break                              # one ram works on one segment


static func _distance_to_segment(p: Vector2, a: Vector2, b: Vector2) -> float:
	var ab := b - a
	var len2 := ab.length_squared()
	if len2 < 0.0001:
		return p.distance_to(a)
	var t := clampf((p - a).dot(ab) / len2, 0.0, 1.0)
	return p.distance_to(a + ab * t)


# --- arranging the line ---------------------------------------------------

## Nothing fights, nothing tires, nothing shoots and nobody's morale moves. The tick
## still advances, because a replay is a tick count and a list of orders: a deployment
## that did not consume ticks would replay the fight starting at the wrong moment.
func _step_deployment() -> void:
	if tick >= int(Rules.DEPLOY_SECONDS * float(Rules.TICK_HZ)) or _all_ready():
		phase = Phase.FIGHT


## Every side that still has somebody standing has said it is done. A side with nothing
## left on the field cannot be waited for -- it has no one to press the button.
func _all_ready() -> bool:
	var owners := _standing_owners()
	if owners.is_empty():
		return false
	for owner in owners:
		if not bool(ready.get(owner, false)):
			return false
	return true


## Which half of the field this side sets up in. Worked out once from where its regiments
## actually are, so it survives a decode and a replay without going on the wire.
func side_of_owner(owner: int) -> float:
	if not sides.has(owner):
		var total := 0.0
		var n := 0
		for id in sorted_ids():
			if regiments[id].owner_id == owner:
				total += regiments[id].pos.x
				n += 1
		sides[owner] = signf(total / float(n)) if n > 0 else 1.0
	return float(sides[owner])


## Where this regiment may actually be put while deploying: its own half of the field,
## kept DEPLOY_MARGIN clear of the middle. Setting up inside the enemy would make the
## phase a free first move rather than a chance to arrange the one you are about to make.
func deployable(r: Regiment, to: Vector2) -> Vector2:
	var side := side_of_owner(r.owner_id)
	var e := Rules.BATTLE_HALF_EXTENT
	var x := clampf(to.x, -e, e)
	var floor_x := Rules.DEPLOY_MARGIN
	# Behind your own wall, if it is yours. Letting the defender set up in FRONT of it
	# would hand the attacker the open-field fight the wall exists to refuse, and it is
	# the one mistake the geometry makes easy.
	if not walls.is_empty() and signf(float(walls[0][0])) == side:
		floor_x = Rules.WALL_STANDOFF + Rules.WALL_CLEAR
	x = maxf(x * side, floor_x) * side
	return Vector2(x, clampf(to.y, -e, e))


## Put it there. Deploying is not marching: the men are set out where you want them
## rather than walking, so this moves the regiment outright and leaves it IDLE.
func place(r: Regiment, to: Vector2, face: float) -> void:
	if phase != Phase.DEPLOY or not r.is_alive():
		return
	r.pos = deployable(r, to)
	r.target = r.pos
	r.facing = face
	r.target_facing = face
	r.state = Regiment.State.IDLE


## A move order, which means a different thing depending on the phase: before the fight
## it sets the men out where you want them, during it they march.
##
## ONE function, because `net.gd` applies orders live and `replay.gd` applies the same
## recorded bytes back. A branch in only the first of those is a recorded deployment that
## replays as a march -- two rules that agree today, which is the trap this file warns
## about everywhere else.
func steer(r: Regiment, to: Vector2, face: float) -> void:
	if phase == Phase.DEPLOY:
		place(r, to, face)
	else:
		r.order_move(to, face)


## A side is done arranging. Irreversible on purpose -- unreadying would let one player
## hold a lobby open forever, and the clock is already the answer to somebody who does
## not press it.
func say_ready(owner: int) -> void:
	if phase == Phase.DEPLOY:
		ready[owner] = true


# --- the tick -------------------------------------------------------------

## One fixed tick. Server-side only.
##
## Contacts are found first, then every regiment's state is settled, then all damage
## is computed against that settled picture and only afterwards applied. Resolving
## strike-by-strike instead would make the outcome depend on regiment id order: the
## lower id would kill men who had not yet swung back, which is exactly the kind of
## invisible unfairness a player cannot see but can feel.
func step() -> void:
	if generals.is_empty():
		commission_generals()      # first tick: the field is laid out, so it is decidable
	tick += 1
	if phase == Phase.DEPLOY:
		_step_deployment()
		return
	var dt := Rules.TICK_DELTA
	var contacts := _find_contacts()

	for id in sorted_ids():
		_settle_state(regiments[id], contacts.get(id, []))
		_pursue(regiments[id], contacts.get(id, []))
		_skirmish(regiments[id])

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

	# After the casualties, because this tick may be the one that killed him.
	_mourn_the_fallen()

	_shoot(contacts, dt)

	for id in sorted_ids():
		_step_regiment(regiments[id], dt)

	_spread_panic(dt)
	_separate(dt)
	_work_the_rams(dt)


## Two blocks that have met stand front to front, not inside one another.
##
## `_settle_state` stops a march INTO an enemy, which keeps a regiment from walking
## further in -- but nothing ever walked it back OUT, so an overlap arrived at by any
## route at all (a charge overrunning by a tick, a rout crossing the field, a re-form
## changing how far a regiment reaches) was permanent. The two blocks then fought on
## interleaved, which does not read as contact because it is not contact.
##
## Enemies only, deliberately: two of your own regiments overlapping read as one mass of
## one colour, which is untidy rather than confusing, and the honest fix for that is the
## spacing they were ordered into.
##
## Deterministic, which it must be to live in here: sorted_ids() order, symmetric
## impulses, and rate-limited so nobody is teleported.
func _separate(dt: float) -> void:
	var ids := sorted_ids()
	var step := Rules.SEPARATION_SPEED * dt
	for i in ids.size():
		var a: Regiment = regiments[ids[i]]
		if not a.is_alive():
			continue
		for j in range(i + 1, ids.size()):
			var b: Regiment = regiments[ids[j]]
			if not b.is_alive() or b.owner_id == a.owner_id:
				continue
			var overlap := -gap_between(a, b)
			if overlap <= 0.0:
				continue
			var away := a.pos - b.pos
			# Exactly on top of one another: pick a side rather than divide by zero, and
			# pick it from the ids so two clients agree on which way they came apart.
			if away.length_squared() < 1.0:
				away = Vector2.RIGHT if a.id < b.id else Vector2.LEFT
			var push := away.normalized() * minf(overlap, step) * 0.5
			# Shoving somebody THROUGH a wall would undo in one tick what the wall spent
			# the whole battle doing. A pair that cannot be pushed apart stays merged,
			# which is the lesser of the two and only reachable in a gateway anyway.
			if not crosses_a_wall(a.pos, a.pos + push):
				a.pos += push
			if not crosses_a_wall(b.pos, b.pos - push):
				b.pos -= push


## An effect key for one side, across everything it has learned. The same shape the
## campaign uses, so a tech means the same thing in both halves of the game.
func tech(owner: int, key: StringName) -> float:
	var additive: bool = key == &"armour"
	var out := 0.0 if additive else 1.0
	for name: StringName in techs.get(owner, []):
		var spec = Rules.TECHS.get(name)
		if spec == null or not spec["effect"].has(key):
			continue
		if additive:
			out += float(spec["effect"][key])
		else:
			out *= float(spec["effect"][key])
	return out


## What the ground does where a regiment is standing. Overlapping patches take the
## worst of each, so a wood on a hillside is slow AND gives cover rather than cancelling
## out into open field.
func ground_at(pos: Vector2) -> Dictionary:
	var out := {"speed": 1.0, "damage": 1.0, "cover": 0.0, "range": 1.0}
	for f: Array in features:
		var centre := Vector2(f[1], f[2])
		if pos.distance_squared_to(centre) > f[3] * f[3]:
			continue
		var g: Dictionary = Rules.GROUND.get(int(f[0]), {})
		if g.is_empty():
			continue
		out["speed"] = minf(out["speed"], float(g["speed"]))
		out["damage"] = maxf(out["damage"], float(g["damage"])) if float(g["damage"]) > 1.0 \
			else minf(out["damage"], float(g["damage"]))
		out["cover"] = maxf(out["cover"], float(g["cover"]))
		out["range"] = minf(out["range"], float(g["range"])) if float(g["range"]) < 1.0 \
			else maxf(out["range"], float(g["range"]))
	return out


## Lay out a battlefield for the hex the armies met on. Deterministic from the seed, so
## the same meeting always produces the same ground and a replay of it still lines up.
func lay_ground(terrain: int, seed_value: int) -> void:
	features = []
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value
	var reach := Rules.DEPLOY_SEPARATION * 0.9

	var wanted := 2
	var kind := Rules.GROUND_WOOD
	match terrain:
		1:                                 # forest
			wanted = 5
			kind = Rules.GROUND_WOOD
		3:                                 # hills
			wanted = 4
			kind = Rules.GROUND_HILL
		2:                                 # mountain, so rocky going
			wanted = 4
			kind = Rules.GROUND_HILL
		4:                                 # water, so the field is half marsh
			wanted = 4
			kind = Rules.GROUND_MARSH
		_:
			wanted = 2
			kind = Rules.GROUND_WOOD

	for i in mini(wanted, Rules.MAX_FEATURES):
		features.append([kind,
			rng.randf_range(-reach, reach), rng.randf_range(-reach * 0.7, reach * 0.7),
			rng.randf_range(90.0, 190.0)])


## How far a regiment's formation extends toward an enemy at this angle: half its
## depth toward its own front or back, half its frontage toward a flank. This is what
## makes two blocks meet front rank to front rank instead of centre to centre.
##
## ponytail: measured from max_strength, so the engagement distance does not drift as
## a regiment is worn down -- which is the entire point. A ten-man remnant therefore
## keeps a full block's footprint. Give it a real occupied depth if that ever shows.
##
## The SHAPE decides it, through Formation.extent: a hollow square reaches as far every way,
## a wedge's sides slope in, and a wedge that has bitten into a line reaches LESS far
## forward -- which is the penetration itself. Contact stops its march later and
## _separate lets the overlap stand, so the point physically drives in.
static func reach(r: Regiment, exposure: Exposure) -> float:
	var e := r.extent()
	var shape := r.shape()
	if exposure == Exposure.FLANK:
		return e.y * (Rules.WEDGE_FLANK_REACH if shape == &"wedge" else 1.0)
	if exposure == Exposure.FRONT and shape == &"wedge":
		return e.x * (1.0 - Rules.WEDGE_PENETRATION * clampf(r.bite, 0.0, 1.0))
	return e.x


## The space between two regiments' facing edges. Negative means they overlap.
static func gap_between(a: Regiment, b: Regiment) -> float:
	return a.pos.distance_to(b.pos) - reach(a, exposure_of(a, b)) - reach(b, exposure_of(b, a))


## How far apart two regiments' CENTRES stand when their front ranks are just touching.
##
## This cannot be a fixed number and that is the trap: contact is front rank to front
## rank, so a wider regiment is a shallower one and reaches less far forward. Two blocks
## placed at the same centre distance may be locked together or not touching at all
## depending only on their shapes -- so anything that wants two regiments in contact,
## the chase included, has to ask for the distance rather than assume one.
static func contact_distance(a: Regiment, b: Regiment, gap := Rules.CONTACT_GAP) -> float:
	return reach(a, Exposure.FRONT) + reach(b, Exposure.FRONT) + gap


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
		var width: float = f.extent().y + Rules.LINE_OF_FIRE_MARGIN
		if aside < width:
			return false
	return true


func _land_volley(shooter: Regiment, mark: Regiment) -> void:
	var distance := shooter.pos.distance_to(mark.pos)
	var reach := maxf(1.0, shooter.range_of())
	var falloff := lerpf(1.0, Rules.MISSILE_FALLOFF, clampf(distance / reach, 0.0, 1.0))
	var cover := clampf(float(mark.form()["missile"]) + float(ground_at(mark.pos)["cover"]), -1.0, 0.95)
	var kills := float(Rules.KINDS[shooter.kind]["volley"]) * shooter.fraction() * falloff
	kills *= (1.0 - cover) * shooter.order_factor()
	var fell := int(round(maxf(0.0, kills)))
	mark.take_casualties(fell)
	shooter.xp += fell             # archers learn their trade too, and in whole men
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
			# ...and nobody fights through a wall. Blocking only movement would have two
			# regiments either side of one killing each other across it, which is exactly
			# what a wall exists to stop.
			if crosses_a_wall(a.pos, b.pos):
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
	# Arriving at a run is a charge. Only from MOVING: a regiment already standing in
	# the line does not get a fresh impact every time the contact list changes, which is
	# what would turn a one-off bonus into a permanent one.
	if r.state == Regiment.State.MOVING:
		r.charge = Rules.CHARGE_SECONDS
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
## A regiment told to deal with a particular enemy goes and does it.
##
## The chase lives in the SIM and is recomputed every tick, rather than being an order
## the view re-issues. A unit re-ordered every tick at a point worked out from a moving
## enemy never arrives -- the archers, the cavalry sweep and the withdrawal step have
## each been bitten by that already. Here nothing is re-ordered: the existing move
## target is simply kept current, so MOVING stays MOVING and arrival still means arrival.
##
## An archer that can already reach its mark stands still, because standing still is how
## it shoots. Chasing would make it permanently MOVING, and a regiment on the move never
## looses an arrow.
func _pursue(r: Regiment, contacts: Array) -> void:
	if r.focus < 0 or not r.is_alive() or r.state == Regiment.State.ROUTING:
		return
	if r.stance & Regiment.Stance.GUARD:
		return                             # told to hold this ground, so it holds it
	if not contacts.is_empty():
		return                             # it has found somebody; that is the job done
	var mark = regiments.get(r.focus)
	if mark == null or not mark.is_alive() or mark.owner_id == r.owner_id:
		r.focus = -1                       # the man you named is gone
		return
	if r.can_shoot() and r.pos.distance_to(mark.pos) <= r.range_of():
		return
	var stop := contact_distance(r, mark)
	var gap: Vector2 = r.pos - mark.pos
	if gap.length() < 1.0:
		return
	r.target = mark.pos + gap.normalized() * stop
	r.target_facing = (mark.pos - r.pos).angle()
	if r.state == Regiment.State.IDLE and r.pos.distance_to(r.target) > Rules.ARRIVE_EPSILON:
		r.state = Regiment.State.MOVING


## Missile troops on skirmish order back off from whatever is closing on them, so long
## as they still have arrows. Out of them they are ordinary bad infantry and there is
## nothing to preserve, so they stop running and take their place in the line.
##
## The trigger is well inside their own reach: falling back the moment anything appeared
## on the horizon would walk them off the field, and a regiment on the move never looses
## anyway, so retreating too eagerly costs the volleys it is meant to protect.
func _skirmish(r: Regiment) -> void:
	if not (r.stance & Regiment.Stance.SKIRMISH) or not r.is_alive():
		return
	if r.state == Regiment.State.ROUTING or not r.can_shoot():
		return
	var closest = null
	var best := INF
	for id in sorted_ids():
		var e: Regiment = regiments[id]
		if not e.is_alive() or e.owner_id == r.owner_id or e.state == Regiment.State.ROUTING:
			continue
		var d := r.pos.distance_to(e.pos)
		if d < best:
			best = d
			closest = e
	if closest == null or best > r.range_of() * Rules.SKIRMISH_TRIGGER:
		return
	var away: Vector2 = (r.pos - closest.pos).normalized() * Rules.SKIRMISH_STEP
	r.target = r.pos + away
	r.target_facing = (closest.pos - r.pos).angle()
	if r.state != Regiment.State.MOVING:
		r.state = Regiment.State.MOVING


func _primary_foe(r: Regiment, foes: Array) -> int:
	# The one you named, if it is actually here. Told to deal with a particular enemy, a
	# regiment should fight that one rather than whichever happens to be squarest on --
	# otherwise ordering an attack and watching it hit somebody else is the whole
	# feature failing quietly.
	if r.focus >= 0 and foes.has(r.focus):
		return r.focus
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
	# A wedge's sloped sides are a rank or two deep where a line's flank is its whole
	# depth: the price of the point.
	if defender.shape() == &"wedge" and hit_from != Exposure.FRONT:
		damage_mult *= Rules.WEDGE_EXPOSED

	# The impact itself, decaying over CHARGE_SECONDS into an ordinary melee. A braced
	# defender takes most of it out -- set spears stopping a charge is the whole reason
	# to give up the frontage a square or a shield wall costs.
	if attacker.charge > 0.0:
		var bite := attacker.charge / Rules.CHARGE_SECONDS
		if bool(defender.form()["brace"]):
			bite *= Rules.CHARGE_BRACED
		damage_mult *= 1.0 + (Rules.CHARGE_MULT - 1.0) * bite

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
	output *= float(ground_at(attacker.pos)["damage"])
	output *= tech(attacker.owner_id, &"attack") * attacker.veteran_attack()
	if attacker.is_cavalry():
		output *= tech(attacker.owner_id, &"horse_attack")
	output *= 1.0 - clampf(tech(defender.owner_id, &"armour"), 0.0, 0.6)
	# Down to -0.5 and not 0: a column caught in a fight is WORSE than nothing at it.
	output *= 1.0 - clampf(defender.defense + float(defender.form()["defense"]) * defender.order_factor(), -0.5, 0.9)
	output *= defender.vulnerability()     # a spent regiment is easier to kill

	kills[defender.id] = float(kills.get(defender.id, 0.0)) + output
	# ...and the attacker learns by exactly what it cost the other side. Pooled the same
	# way the casualties are, because a tick's worth of killing is a fraction of a man.
	attacker.xp_pool += output
	var learned := int(floor(attacker.xp_pool))
	if learned > 0:
		attacker.xp_pool -= float(learned)
		attacker.xp += learned

	# Shock scales with how hard the attacker can actually press, the same way its
	# killing does. Damage passes through ten multipliers and morale used to pass
	# through one, so an exhausted regiment at 0.45 readiness, a loose order at 0.55
	# damage and one mid-reform all frightened a man exactly as much as a fresh block
	# did. Morale was measuring how long you had been standing there rather than how
	# badly you were being handled.
	var pressure := attacker.readiness() * attacker.order_factor() * float(attacker.form()["damage"])
	# defender.nerve() is the defender's OWN exhaustion making it break sooner, which is a
	# different thing from the attacker's readiness inside `pressure` -- that is how hard
	# he can press. Tired men breaking sooner had no expression here at all.
	# A wedge driven into a line is breaking it, and that goes through its nerve as well
	# as its numbers. Scaled by how far in the point has got.
	if attacker.shape() == &"wedge" and swinging_from == Exposure.FRONT:
		morale_drain += Rules.WEDGE_SHOCK * clampf(attacker.bite, 0.0, 1.0)
	var shaken := morale_drain * pressure * tech(defender.owner_id, &"resolve") * dt
	shaken *= defender.nerve() * defender.veteran_resolve()
	if _in_reach_of_general(defender):
		# A better commander steadies them harder: the drain multiplier is pushed further
		# below 1, never past 0, so renown cannot make a regiment immune to morale.
		shaken *= maxf(0.0, 1.0 - (1.0 - Rules.GENERAL_STEADY) * renown_of(defender.owner_id))
	shocks[defender.id] = float(shocks.get(defender.id, 0.0)) + shaken


## How many files a regiment can turn toward an enemy at this angle. Frontally it
## fights on its full width; from the side or behind, only the ends of its ranks.
## The width it is FIGHTING at, which lags the width it was ordered into by however long
## the men take to walk there. `reach()` deliberately still reads `width` -- the footprint
## is in flux while they walk anyway, and ramping it too would have contact distance
## wobbling through every re-dress for nothing.
##
## And the shape: a wedge fights with its point until it has bitten in, and a hollow
## square with one face, whichever way it is hit.
static func files_engaged(r: Regiment, exposure: Exposure) -> int:
	var w := r.fighting_width()
	if exposure == Exposure.FRONT:
		return Formation.front_files(r.shape(), r.strength, w, r.bite)
	return Formation.side_files(r.shape(), r.strength, w)


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
	if r.dressed < 1.0:
		# At the pace the men are walking, over the distance they actually have to cover,
		# so the ramp and the walk finish together whatever size the change was.
		var walk := r.dress_walk()
		r.dressed = 1.0 if walk <= 0.01 else minf(1.0, r.dressed + Rules.DRESS_SPEED / walk * dt)
	if r.charge > 0.0:
		r.charge = maxf(0.0, r.charge - dt)
	_drive_the_point(r, dt)
	match r.state:
		Regiment.State.DEAD:
			return
		Regiment.State.MOVING:
			_advance(r, dt)
			# Marching men catch their breath too. Recovery used to be gated on the
			# STATE rather than on being safe, so a router pulled itself together at
			# 4.0/s while a regiment merely repositioning recovered nothing at all --
			# running away restored morale and manoeuvring did not.
			_hearten(r, dt)
		Regiment.State.ROUTING:
			_advance(r, dt)
			# Broken men who get clear of the fighting pull themselves together, and
			# faster where their general can be seen. `Regiment.recover()` has always
			# known how to rally at MORALE_RALLY_THRESHOLD -- it was simply never
			# called for a router, because recovery lived in the IDLE branch and a
			# router is never IDLE. The rally threshold was unreachable code.
			_hearten(r, dt)
		Regiment.State.IDLE:
			r.pace = 0.0
			_hearten(r, dt)
			if r.engaged_with == -1:
				r.rest(Rules.STAMINA_RECOVERY * dt)
			_turn_toward(r, r.target_facing, dt)
		Regiment.State.FIGHTING:
			r.pace = 0.0
			r.tire(Rules.STAMINA_DRAIN_FIGHTING * tech(r.owner_id, &"stamina") * dt)
			# Wheeling in contact is slow, so a flank is a race the victim can lose.
			var foe = regiments.get(r.engaged_with)
			if foe != null:
				_turn_toward(r, (foe.pos - r.pos).angle(), dt * Rules.ENGAGED_TURN_MULT, false)


## A wedge in frontal contact drives further in, and one that is not works its way back
## out, at the same rate either way. Only a wedge, only pushing, only from its front.
func _drive_the_point(r: Regiment, dt: float) -> void:
	if r.shape() != &"wedge":
		r.bite = 0.0
		return
	var foe = regiments.get(r.engaged_with)
	var pushing: bool = r.state == Regiment.State.FIGHTING and foe != null 		and exposure_of(r, foe) == Exposure.FRONT
	var rate := dt / Rules.WEDGE_BITE_SECONDS
	var was := r.bite
	r.bite = clampf(r.bite + (rate if pushing else -rate), 0.0, 1.0)
	# ...and it moves forward by exactly the reach the bite took off it. A regiment in a
	# fight stands still, so shortening its reach alone would only open a gap between the
	# two lines -- contact lost, bite decaying, round and round. The point has to walk in.
	if r.bite > was:
		var to := r.pos + Vector2.from_angle(r.facing) \
			* r.extent().x * Rules.WEDGE_PENETRATION * (r.bite - was)
		if not crosses_a_wall(r.pos, to):
			r.pos = to
			r.target = to


## Morale comes back to anybody who is out of contact and has had a moment to breathe.
##
## The moment is the point. Breaking contact used to start the climb on the very next
## tick -- a router clears CONTACT_GAP in well under a second at ROUT_SPEED_MULT -- so a
## break cost six seconds and nothing else.
func _hearten(r: Regiment, dt: float) -> void:
	if r.engaged_with != -1:
		r.rally_wait = Rules.RALLY_DELAY
		return
	if r.rally_wait > 0.0:
		r.rally_wait = maxf(0.0, r.rally_wait - dt)
		return
	var rate := Rules.MORALE_RECOVERY
	if r.state == Regiment.State.ROUTING and _in_reach_of_general(r):
		rate += Rules.GENERAL_RALLY * renown_of(r.owner_id)
	r.recover(rate * dt)


## Everything that frightens a regiment without anyone striking it: a neighbour breaking,
## its own army coming apart, standing on its own, and the heart a charge puts in it.
##
## This is what gives a battle its shape. Before it, every regiment's morale was entirely
## its own business, so two lines simply ground each other down until one happened to
## cross a threshold. A line breaks from one end now.
func _spread_panic(dt: float) -> void:
	var ids := sorted_ids()

	# How much of each side is still willing to fight, for the army-collapse term.
	var standing := {}
	var total := {}
	for id in ids:
		var r: Regiment = regiments[id]
		if not r.is_alive():
			continue
		total[r.owner_id] = int(total.get(r.owner_id, 0)) + 1
		if r.state != Regiment.State.ROUTING:
			standing[r.owner_id] = int(standing.get(r.owner_id, 0)) + 1

	for id in ids:
		var r: Regiment = regiments[id]
		if not r.is_alive() or r.state == Regiment.State.ROUTING:
			continue

		var fright := 0.0
		var beside := false
		for other_id in ids:
			if other_id == id:
				continue
			var o: Regiment = regiments[other_id]
			if not o.is_alive():
				continue
			var apart := r.pos.distance_to(o.pos)
			if o.owner_id != r.owner_id:
				continue
			if o.state == Regiment.State.ROUTING:
				if apart <= Rules.PANIC_RADIUS:
					fright += Rules.PANIC_SHOCK * dt
			elif apart <= Rules.SHOULDER_RADIUS:
				beside = true

		# An army that has lost most of itself wavers whatever each regiment thinks.
		var left := int(standing.get(r.owner_id, 0))
		var had := maxi(1, int(total.get(r.owner_id, 0)))
		if float(left) / float(had) < Rules.ARMY_BREAKS:
			fright += Rules.COLLAPSE_SHOCK * dt

		if not beside:
			fright += Rules.ALONE_SHOCK * dt
		if _in_reach_of_general(r):
			fright *= Rules.GENERAL_STEADY
		r.shock(fright)

		# ...and a regiment at the moment of impact is briefly braver.
		if r.charge > 0.0:
			r.recover(Rules.CHARGE_HEART * dt)


func _advance(r: Regiment, dt: float) -> void:
	var routing: bool = r.state == Regiment.State.ROUTING
	var top: float = Rules.MOVE_SPEED * float(Rules.KINDS[r.kind]["speed"]) * float(r.form()["speed"])
	top *= float(ground_at(r.pos)["speed"])
	top *= r.legs()                        # a spent regiment cannot keep up
	if r.is_cavalry():
		top *= tech(r.owner_id, &"horse_speed")
	if routing:
		top *= Rules.ROUT_SPEED_MULT
	var to_target: Vector2 = r.target - r.pos
	var dist := to_target.length()

	# Brake into the destination rather than stopping dead on it. This is the term that
	# removes the arrival snap: `r.pos = r.target` used to jump a regiment up to a stride.
	var rate := top / Rules.ACCELERATION_SECONDS
	var want := minf(top, sqrt(2.0 * rate * maxf(0.0, dist)))
	want = maxf(want, minf(top, Rules.ARRIVE_CRAWL))
	r.pace = move_toward(r.pace, want, rate * dt)
	var step_len := r.pace * dt

	# Marching tires, by the pace actually kept -- so a walk costs little and a rout costs
	# more than a march. Crossing the field used to be free.
	r.tire(Rules.STAMINA_DRAIN_MARCHING * (r.pace / Rules.MOVE_SPEED)
		* tech(r.owner_id, &"stamina") * dt)

	# Only when it is genuinely within one step, so the last move is a shuffle rather than
	# the up-to-ARRIVE_EPSILON teleport this used to finish on.
	if dist <= step_len:
		if not crosses_a_wall(r.pos, r.target):
			r.pos = r.target
		r.pace = 0.0
		if not routing:
			r.state = Regiment.State.IDLE
		_turn_toward(r, r.target_facing, dt)
		return

	var step := to_target / dist * step_len
	# A wall stops a march the way an enemy does: the regiment comes up against it and
	# stays there. Nothing steers round, deliberately -- finding the gate is the player's
	# job and the AI's, and a pathfinder here would quietly solve the one problem a siege
	# is supposed to pose.
	if not crosses_a_wall(r.pos, r.pos + step):
		r.pos += step
	# The facing it was ORDERED, not the way it happens to be walking. This one line was
	# the spin: a regiment turned to point at wherever it was going, so sending it
	# anywhere behind itself swung the whole block round. Movement never needed a front --
	# `r.pos +=` above walks straight at the target whatever way the block faces.
	_turn_toward(r, r.target_facing, dt)


## Wheel toward `desired`, and take the free half of the turn first.
##
## A rectangle rotated 180 degrees about its centre stands on exactly the same ground, so
## turning right round is not a wheel at all -- it is an about-face, and it costs no
## rotation. Anything past a quarter-turn is therefore done as a flip plus a wheel of at
## most 90 degrees, which is both quicker and, far more importantly, does not sweep the
## end files across the field at three times marching pace.
##
## `free` is false in contact. That is not a detail: a regiment taken in the rear that
## could flip to face its attacker would delete the flank-and-rear mechanic outright.
##
## And only a symmetric shape may flip at all. A wedge turned about would have its point
## jump to the back, so a wedge wheels round like anything else changing its ground.
func _turn_toward(r: Regiment, desired: float, dt: float, free := true) -> void:
	if free and Formation.symmetric(r.shape()) and absf(angle_difference(r.facing, desired)) > PI * 0.5:
		r.about_face()
	r.facing = rotate_toward(r.facing, desired, Rules.TURN_SPEED * float(r.form()["turn"]) * dt)
