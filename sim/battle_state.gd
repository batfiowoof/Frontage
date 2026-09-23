extends RefCounted
## The battle world. Ticks at a fixed 20 Hz, owns every regiment, knows nothing
## about nodes, peers or rendering. The server steps it; clients hold a decoded
## mirror of it and never call step().

const Rules := preload("res://sim/rules.gd")
const Regiment := preload("res://sim/regiment.gd")
const Formation := preload("res://sim/formation.gd")
const Pathing := preload("res://sim/pathing.gd")

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
## The pathfinder, made when first needed. See `nav()`.
var _nav = null


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
	var zone := deploy_zone(r.owner_id)
	return Vector2(clampf(to.x, zone.position.x, zone.end.x), clampf(to.y, zone.position.y, zone.end.y))


## The ground this side may set up on. One rectangle, read by the clamp above and drawn by
## the view, so what you are shown is what you get.
func deploy_zone(owner: int) -> Rect2:
	var side := side_of_owner(owner)
	var near := Rules.DEPLOY_MARGIN
	# Behind your own wall, if it is yours. Letting the defender set up in FRONT of it
	# would hand the attacker the open-field fight the wall exists to refuse, and it is
	# the one mistake the geometry makes easy.
	if not walls.is_empty() and signf(float(walls[0][0])) == side:
		near = Rules.WALL_STANDOFF + Rules.WALL_CLEAR
	# ...and no further back or out than DEPLOY_DEPTH: the whole half-field is a place to
	# lose an army in, not a zone to arrange one.
	var far := maxf(near, Rules.DEPLOY_DEPTH)
	var xs := [near * side, far * side]
	return Rect2(minf(xs[0], xs[1]), -Rules.DEPLOY_HALF_WIDTH, far - near, Rules.DEPLOY_HALF_WIDTH * 2.0)


## Put it there. Deploying is not marching: the men are set out where you want them
## rather than walking, so this moves the regiment outright and leaves it IDLE. Not into
## a lake: it stays where it was and only turns.
func place(r: Regiment, to: Vector2, face: float) -> void:
	if phase != Phase.DEPLOY or not r.is_alive():
		return
	var at := deployable(r, to)
	if not wet(at):
		r.pos = at
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
		return
	# Told to stand on a bridge, it stands on the middle of it: a column whose centre is
	# off the centreline hangs its outer files over the water.
	var on = bridge_at(to)
	if on != null:
		to.y = float(on[2])
	r.order_move(to, face)


## Tell a regiment who to deal with. Refused -- false, focus untouched -- for an enemy its
## side cannot see: an attack order naming a hidden regiment would be a way to probe ids
## through the fog. In the sim, like `steer`, so the live path and a replay agree.
func aim(r: Regiment, mark: int) -> bool:
	var m = regiments.get(mark)
	if m != null and m.owner_id != r.owner_id and not visible_to(r.owner_id, m):
		return false
	r.focus = mark
	return true


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
			if not b.is_alive():
				continue
			# Friends too, once both have stopped: two of your own blocks standing inside
			# one another read as one mass. Not while either marches -- two passing on the
			# move is passing, and the planner already keeps a march clear of the standing.
			if b.owner_id == a.owner_id and (_on_the_move(a) or _on_the_move(b)):
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
			# ...and nobody is shoved into a river either.
			if not crosses_a_wall(a.pos, a.pos + push) and not wet(a.pos + push):
				a.pos += push
			if not crosses_a_wall(b.pos, b.pos - push) and not wet(b.pos - push):
				b.pos -= push


static func _on_the_move(r: Regiment) -> bool:
	return r.state == Regiment.State.MOVING or r.state == Regiment.State.ROUTING


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
##
## Water and a river are not "ground" -- nobody stands in them -- so their rows are empty
## and skipped here. See `wet()`.
func ground_at(pos: Vector2) -> Dictionary:
	var out := {"speed": 1.0, "damage": 1.0, "cover": 0.0}
	for f: Array in features:
		var g: Dictionary = Rules.GROUND.get(int(f[0]), {})
		if g.is_empty():
			continue
		if pos.distance_squared_to(Vector2(f[1], f[2])) > f[3] * f[3]:
			continue
		out["speed"] = minf(out["speed"], float(g["speed"]))
		out["damage"] = maxf(out["damage"], float(g["damage"])) if float(g["damage"]) > 1.0 \
			else minf(out["damage"], float(g["damage"]))
		out["cover"] = maxf(out["cover"], float(g["cover"]))
	return out


## How high the ground stands here: the highest hill under this point, each one a dome
## whose peak is its radius times HILL_RISE -- so a bigger hill is a higher one and height
## costs nothing on the wire.
func height_at(pos: Vector2) -> float:
	var h := 0.0
	for f: Array in features:
		if int(f[0]) != Rules.GROUND_HILL:
			continue
		var r := float(f[3])
		var d2 := pos.distance_squared_to(Vector2(f[1], f[2]))
		if d2 < r * r:
			h = maxf(h, r * Rules.HILL_RISE * (1.0 - d2 / (r * r)))
	return h


## How far `a` stands above `b`, from -1 (a full slope below) to 1 (a full slope above).
func slope(a: Vector2, b: Vector2) -> float:
	return clampf((height_at(a) - height_at(b)) / Rules.HEIGHT_SPAN, -1.0, 1.0)


## What height does to how far a man at `a` shoots and sees toward `b`.
func lift(a: Vector2, b: Vector2) -> float:
	return 1.0 + Rules.HEIGHT_RANGE * slope(a, b)


## A river's centreline at this y. The whole river is one row: [kind, x0, phase, half_width].
static func river_x(row: Array, y: float) -> float:
	return float(row[1]) + Rules.RIVER_BEND * sin(y * Rules.RIVER_WAVE + float(row[2]))


func _in(kind: int, pos: Vector2) -> bool:
	for f: Array in features:
		if int(f[0]) == kind and pos.distance_squared_to(Vector2(f[1], f[2])) < f[3] * f[3]:
			return true
	return false


## Too near a lake or a river to stand, and not on a bridge. A regiment's centre keeps
## WATER_CLEAR off the water, because it is a block and not a point: tested at the centre
## alone, its front ranks stood in the river whenever it walked along the bank.
func wet(pos: Vector2) -> bool:
	if bridge_at(pos) != null:
		return false
	for f: Array in features:
		match int(f[0]):
			Rules.GROUND_LAKE:
				var reach := float(f[3]) + Rules.WATER_CLEAR
				if pos.distance_squared_to(Vector2(f[1], f[2])) < reach * reach:
					return true
			Rules.GROUND_RIVER:
				if absf(pos.x - river_x(f, pos.y)) < float(f[3]) + Rules.WATER_CLEAR:
					return true
	return false


## The bridge under this point, or null. A bridge is a strip straight across its river --
## its row's radius either side of its middle, BRIDGE_HALF_LENGTH out along it -- and the
## planks drawn are exactly this strip. `approach` widens it, for the ground in front.
func bridge_at(pos: Vector2, approach := 0.0) -> Variant:
	for f: Array in features:
		if int(f[0]) == Rules.GROUND_BRIDGE and absf(pos.y - float(f[2])) < float(f[3]) \
				and absf(pos.x - float(f[1])) < Rules.BRIDGE_HALF_LENGTH + approach:
			return f
	return null


## A regiment on a bridge, or walking onto one, crosses it as a column BRIDGE_FILES wide:
## the facing that column takes, or null when it is not crossing. Pointed at the far bank
## when it is going over, and along the bridge the way it already faces when it is only
## standing on one.
##
## The sim holds a regiment's ordered facing and frontage whatever it walks through, so
## without this a twenty-file line walked over the planks with its files strung up and
## down the river. The view draws the column; `_accumulate_strike` fights at it.
func crossing(r: Regiment) -> Variant:
	var on = bridge_at(r.pos, Rules.BRIDGE_APPROACH)
	if on == null:
		return null
	var river = _river()
	if river == null:
		return null
	var there := r.target.x - river_x(river, r.target.y)
	var here := r.pos.x - river_x(river, r.pos.y)
	if (there >= 0.0) != (here >= 0.0):
		return 0.0 if there >= 0.0 else PI
	# Over, or standing on it: a column until its REAR is off the planks too, facing away
	# from the water. Opening out the moment its centre reached the bank left the back
	# half of it standing over the river.
	if bridge_at(r.pos, column_reach(r)) == null:
		return null                        # beside the bridge, or well clear of it
	return 0.0 if r.pos.x >= float(on[1]) else PI


## Half the length of the column a regiment crosses a bridge in: its ranks at
## BRIDGE_FILES wide. A column is long, and all of it has to be off the water.
static func column_reach(r: Regiment) -> float:
	return ceilf(float(r.max_strength) / float(Rules.BRIDGE_FILES)) * Rules.RANK_SPACING * r.spacing() * 0.5


func _river() -> Variant:
	for f: Array in features:
		if int(f[0]) == Rules.GROUND_RIVER:
			return f
	return null


## Out of whatever water `into` is in, measured at the dry point `at` beside it: away from
## a lake's centre, or square to the river's centreline on the side `at` is on. At `at` and
## not at `into`, because the tangent at a point already inside a circle leans into it --
## a regiment sliding along that stalled on the rim.
func _water_normal(into: Vector2, at: Vector2) -> Vector2:
	for f: Array in features:
		match int(f[0]):
			Rules.GROUND_LAKE:
				var reach := float(f[3]) + Rules.WATER_CLEAR
				if into.distance_squared_to(Vector2(f[1], f[2])) < reach * reach:
					return (at - Vector2(f[1], f[2])).normalized()
			Rules.GROUND_RIVER:
				if absf(into.x - river_x(f, into.y)) < float(f[3]) + Rules.WATER_CLEAR:
					var bend := Rules.RIVER_BEND * Rules.RIVER_WAVE * cos(at.y * Rules.RIVER_WAVE + float(f[2]))
					var off := at.x - river_x(f, at.y)
					return Vector2(1.0, -bend).normalized() * (1.0 if off >= 0.0 else -1.0)
	return Vector2.RIGHT


## Lay out a battlefield for the hex the armies met on AND the six around it. Seeded, so
## the same meeting always produces the same ground; random, because the seed is the tile
## and the turn, so the next battle on the same hex is a different field.
##
## `ring` is `CampaignState.ring_of()`, and `toward` is the direction the attacker came
## from, so the hex behind him is on his side of the field (-x) and the rest go round.
## A lake is only ever where a water hex is; a big hill only where a mountain is.
func lay_ground(here: int, seed_value: int, ring := [], toward := 3) -> void:
	features = []
	var rng := RandomNumberGenerator.new()
	# Hashed: neighbouring seeds -- the same hex a turn later -- otherwise start the
	# generator in nearly the same place and lay nearly the same field.
	rng.seed = hash(seed_value)
	var reach := Rules.DEPLOY_SEPARATION * 0.9

	# A river first, so the cap never squeezes out the bridge across it. Kept inside the
	# deployment margin, so it is always no-man's-land between the two lines.
	var near_water: bool = here == 4 or ring.has(4)
	if rng.randf() < (Rules.RIVER_CHANCE_NEAR_WATER if near_water else Rules.RIVER_CHANCE):
		var room := Rules.DEPLOY_MARGIN - Rules.RIVER_HALF_WIDTH - Rules.RIVER_BEND - Rules.WATER_CLEAR - 5.0
		var river := [Rules.GROUND_RIVER, rng.randf_range(-room, room), rng.randf_range(0.0, TAU),
			Rules.RIVER_HALF_WIDTH]
		_lay(river)
		var spans := [rng.randf_range(-300.0, 300.0)] if rng.randf() < 0.5 \
			else [rng.randf_range(-450.0, -120.0), rng.randf_range(120.0, 450.0)]
		for y: float in spans:
			_lay([Rules.GROUND_BRIDGE, river_x(river, y), y, Rules.RIVER_HALF_WIDTH * Rules.BRIDGE_REACH])

	# Somewhere to hide on each side, if there are trees anywhere near: the wood is what
	# the battle fog is for, and one that fell behind the enemy line hides nobody of yours.
	if here == 1 or ring.has(1):
		for side in [-1.0, 1.0]:
			_lay([Rules.GROUND_WOOD, side * rng.randf_range(300.0, 550.0),
				rng.randf_range(-500.0, 500.0), rng.randf_range(100.0, 150.0)])

	# The hex itself, across the whole field.
	var kind := Rules.GROUND_WOOD
	var wanted := 1
	match here:
		1: wanted = 3                              # forest
		2, 3:                                      # mountain, hills
			wanted = 3
			kind = Rules.GROUND_HILL
		4:                                         # water, so the field is half marsh
			wanted = 3
			kind = Rules.GROUND_MARSH
	for i in wanted:
		_lay([kind, rng.randf_range(-reach, reach), rng.randf_range(-reach * 0.7, reach * 0.7),
			rng.randf_range(90.0, 190.0)])

	# Each neighbour, out toward its own edge of the field.
	for j in ring.size():
		var bearing := PI - float(j - toward) * PI / 3.0 + rng.randf_range(-0.35, 0.35)
		var out := rng.randf_range(600.0, 950.0)
		match int(ring[j]):
			1:
				for k in 1 + rng.randi() % 2:
					_lay_toward(Rules.GROUND_WOOD, bearing + rng.randf_range(-0.3, 0.3),
						out + rng.randf_range(-150.0, 100.0), rng.randf_range(90.0, 170.0))
			3:
				_lay_toward(Rules.GROUND_HILL, bearing, out, rng.randf_range(140.0, 200.0))
			2:
				_lay_toward(Rules.GROUND_HILL, bearing, out, rng.randf_range(220.0, 300.0))
			4:
				_lay_toward(Rules.GROUND_LAKE, bearing, out, rng.randf_range(120.0, 220.0))
			_:
				if rng.randf() < 0.25:
					_lay_toward(Rules.GROUND_WOOD, bearing, out, rng.randf_range(80.0, 130.0))

	_keep_the_land_dry()


## Woods, hills and marsh are land, and none of them may stand in the water. They are laid
## from the hexes round the field with no regard to the river running through it -- and a
## lake can land after a wood -- so the trees grew out of the middle of the river. Each is
## shrunk until it clears every lake and the river's bank by LAND_CLEAR, and dropped if
## that leaves too little of it to be worth anything.
func _keep_the_land_dry() -> void:
	var kept := []
	for f: Array in features:
		var kind := int(f[0])
		if kind != Rules.GROUND_WOOD and kind != Rules.GROUND_HILL and kind != Rules.GROUND_MARSH:
			kept.append(f)
			continue
		var at := Vector2(f[1], f[2])
		var radius := minf(float(f[3]), _to_water(at) - Rules.LAND_CLEAR)
		if radius >= Rules.LAND_MIN_RADIUS:
			kept.append([kind, f[1], f[2], radius])
	features = kept


## How far `at` is from the nearest water's edge: a lake's rim, or the river's bank --
## the closest point of its bending centreline, less its half-width.
func _to_water(at: Vector2) -> float:
	var best := INF
	for f: Array in features:
		match int(f[0]):
			Rules.GROUND_LAKE:
				best = minf(best, at.distance_to(Vector2(f[1], f[2])) - float(f[3]))
			Rules.GROUND_RIVER:
				var y := -Rules.BATTLE_HALF_EXTENT
				while y <= Rules.BATTLE_HALF_EXTENT:
					best = minf(best, at.distance_to(Vector2(river_x(f, y), y)) - float(f[3]))
					y += 10.0
	return best


func _lay(row: Array) -> void:
	if features.size() < Rules.MAX_FEATURES:
		features.append(row)


## A circle out along a bearing. A lake is walked further out until it covers nobody's
## deployment: an army dealt into the water could not move, and one dealt against it has
## lost half its line before the battle starts.
func _lay_toward(kind: int, bearing: float, out: float, radius: float) -> void:
	var dir := Vector2.from_angle(bearing)
	if kind == Rules.GROUND_LAKE:
		while _covers_a_deployment(dir * out, radius):
			out += 50.0
			if out > Rules.BATTLE_HALF_EXTENT:
				return
	_lay([kind, dir.x * out, dir.y * out, radius])


static func _covers_a_deployment(at: Vector2, radius: float) -> bool:
	var slots := Rules.DEPLOY_SPACING * 4.0
	for x in [-Rules.DEPLOY_SEPARATION * 0.5, Rules.DEPLOY_SEPARATION * 0.5]:
		if _distance_to_segment(at, Vector2(x, -slots), Vector2(x, slots)) < radius + Rules.DEPLOY_SPACING:
			return true
	return false


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
			_face_what_it_could_hit(r)
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
	if not in_arc(shooter, mark.pos, reach_of(shooter, mark.pos)):
		return false
	if not visible_to(shooter.owner_id, mark):
		return false
	return line_is_clear(shooter, mark, regiments.values())


## Nothing in the arc, but something it could reach if it turned: it turns. A standing
## bow with an enemy off its flank is otherwise a regiment doing nothing, and an AI that
## never set its facing would never shoot at all. The one it was told to deal with first.
func _face_what_it_could_hit(r: Regiment) -> void:
	var best = null
	var best_distance := INF
	for id in sorted_ids():
		var e: Regiment = regiments[id]
		if e.owner_id == r.owner_id or not e.is_alive() or not visible_to(r.owner_id, e):
			continue
		var d := r.pos.distance_to(e.pos)
		if d > reach_of(r, e.pos):
			continue
		if e.id == r.focus:
			best = e
			break
		if d < best_distance:
			best_distance = d
			best = e
	if best != null:
		r.target_facing = (best.pos - r.pos).angle()


## How far this shooter reaches toward that point: its bow, lengthened by standing above
## what it is shooting at and shortened by standing below it.
func reach_of(shooter: Regiment, at: Vector2) -> float:
	return shooter.range_of() * lift(shooter.pos, at)


## A bow looses into an arc in front of the line: a fan off each end of the front rank,
## splayed out by ARC_SPREAD, rounded off at `reach` from the nearest point of the line.
## So a wider line covers a wider arc, and nothing behind or beside it can be hit at all.
## Static and pure, so the view draws exactly what the sim uses.
static func in_arc(shooter: Regiment, point: Vector2, reach: float) -> bool:
	var local := (point - shooter.pos).rotated(-shooter.facing)
	if local.x < 0.0:
		return false
	var half_front := shooter.extent().y
	if absf(local.y) > half_front + local.x * tan(Rules.ARC_SPREAD):
		return false
	return local.distance_to(Vector2(0.0, clampf(local.y, -half_front, half_front))) <= reach


## Can `owner` see this regiment? Your own always; anybody within sight of one of yours,
## further from higher ground; and a regiment standing in a wood only from WOOD_SPOT --
## unless it has given itself away by fighting or by loosing a volley in the last reload.
##
## Owner 0 sees everything: that is the replay, the save and every test.
##
## One rule, three callers: the wire (`Snapshot.encode_battle`), the host's own view, and
## the sim itself -- nobody shoots or chases what their side cannot see. Without the
## second, the host would see everything a joined client cannot.
func visible_to(owner: int, r: Regiment) -> bool:
	if owner == 0 or r.owner_id == owner:
		return true
	var hidden: bool = r.engaged_with < 0 and r.reload <= 0.0 and _in(Rules.GROUND_WOOD, r.pos)
	var fielded := false
	for id in sorted_ids():
		var o: Regiment = regiments[id]
		if o.owner_id != owner:
			continue
		fielded = true
		if not o.is_alive():
			continue
		var sight := Rules.WOOD_SPOT if hidden else Rules.BATTLE_SIGHT * lift(o.pos, r.pos)
		if o.pos.distance_squared_to(r.pos) <= sight * sight:
			return true
	# Somebody with no regiment on this field at all -- the dead count, they were here --
	# is watching it: a spectator seat, or a replay of somebody else's battle.
	return not fielded


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
	var reach := maxf(1.0, reach_of(shooter, mark.pos))
	var falloff := lerpf(1.0, Rules.MISSILE_FALLOFF, clampf(distance / reach, 0.0, 1.0))
	var cover := clampf(float(mark.form()["missile"]) + float(ground_at(mark.pos)["cover"]), -1.0, 0.95)
	var kills := float(Rules.KINDS[shooter.kind]["volley"]) * shooter.fraction() * falloff
	kills *= (1.0 - cover) * shooter.order_factor() * tech(shooter.owner_id, &"missile")
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
	# The man you named has gone into the trees: you keep his name and lose his trail.
	if not visible_to(r.owner_id, mark):
		return
	# In reach, if not yet in the arc: _shoot turns it the rest of the way.
	if r.can_shoot() and r.pos.distance_to(mark.pos) <= reach_of(r, mark.pos):
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

	# Height between the two of them. The man above hits harder and frightens more; the man
	# below does neither as well -- so a hill is easier to hold and harder to take, and
	# that is one number, not two.
	var hill := 1.0 + Rules.HIGH_GROUND * slope(attacker.pos, defender.pos)

	var files := contact_files(attacker, defender, swinging_from, hit_from)
	# On a bridge, the bridge is the frontage: the planks take BRIDGE_FILES and no more,
	# whichever side of the fight is standing on them. A bridge is held the way a gate is.
	if bridge_at(attacker.pos) != null or bridge_at(defender.pos) != null:
		files = mini(files, Rules.BRIDGE_FILES)
	var output := Rules.KILLS_PER_FILE_PER_SEC * float(files) * response_of(swinging_from) * hill
	output *= attacker.readiness() * damage_mult * dt
	output *= float(attacker.form()["damage"]) * attacker.order_factor() * braced
	output *= float(ground_at(attacker.pos)["damage"])
	output *= tech(attacker.owner_id, &"attack") * attacker.veteran_attack()
	output *= float(Rules.KINDS[attacker.kind].get("attack", 1.0))
	if attacker.is_cavalry():
		output *= tech(attacker.owner_id, &"horse_attack")
	output *= 1.0 - clampf(tech(defender.owner_id, &"armour")
		+ float(Rules.KINDS[defender.kind].get("armour", 0.0)), 0.0, 0.6)
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
	var pressure := attacker.readiness() * attacker.order_factor() * float(attacker.form()["damage"]) * hill
	# defender.nerve() is the defender's OWN exhaustion making it break sooner, which is a
	# different thing from the attacker's readiness inside `pressure` -- that is how hard
	# he can press. Tired men breaking sooner had no expression here at all.
	# A wedge driven into a line is breaking it, and that goes through its nerve as well
	# as its numbers. Scaled by how far in the point has got.
	if attacker.shape() == &"wedge" and swinging_from == Exposure.FRONT:
		morale_drain += Rules.WEDGE_SHOCK * clampf(attacker.bite, 0.0, 1.0)
	var shaken := morale_drain * pressure * tech(defender.owner_id, &"resolve") * dt
	shaken *= defender.nerve() * defender.veteran_resolve()
	shaken *= float(Rules.KINDS[defender.kind].get("resolve", 1.0))
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
		r.dressed = 1.0 if walk <= 0.01 else minf(1.0, r.dressed + Rules.REFORM_SPEED / walk * dt)
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
		if not crosses_a_wall(r.pos, to) and not wet(to):
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

	# Where it is walking this tick: the next waypoint of its plan, and how far it still
	# has to go along the whole of it. Routers do not plan -- they run straight away from
	# what broke them, and the shore and the walls stop them as they always did.
	var goal := r.target
	var last := true
	if not routing:
		_follow(r, dt)
		goal = r.path[0]
		last = r.path.size() == 1
		dist = r.pos.distance_to(goal)
		for k in range(1, r.path.size()):
			dist += r.path[k - 1].distance_to(r.path[k])

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
	# the up-to-ARRIVE_EPSILON teleport this used to finish on. The end of the plan may be
	# short of the target -- the shore of a lake it was sent into, the outside of a wall --
	# and then that is where it stops, and that is its target now.
	var halt := dist <= step_len and last
	if halt and not wet(goal):
		if not crosses_a_wall(r.pos, goal):
			r.pos = goal
		if not routing:
			r.target = goal
			r.path = PackedVector2Array()
		_halt(r, routing, dt)
		return

	var heading := goal - r.pos
	if heading.length() <= 0.001:
		heading = to_target
	if heading.length() <= 0.001:
		_halt(r, routing, dt)
		return
	var step := heading.normalized() * step_len
	# Water is walked round, not through: a step that would end in a lake or a river slides
	# along the shore instead. One sent INTO the water halts on its edge -- nobody stands in
	# a lake, and sliding round one looking for a way in would circle it forever.
	var shore := _shore(r.pos, step)
	if shore != step and wet(r.target):
		r.target = r.pos
		_halt(r, routing, dt)
		return
	step = shore
	r.waiting = false
	if not routing:
		var blocker = _blocker(r, step, dist)
		if blocker != null:
			# Blocked on the way in by a friend standing on its destination: it stops
			# there rather than queueing behind him for the rest of the battle.
			if _spot_taken(r):
				r.target = r.pos
				r.path = PackedVector2Array()
				_halt(r, routing, dt)
				return
			if _gives_way(r, blocker):
				r.waiting = true
			else:
				r.replan = minf(r.replan, Rules.BLOCKED_REPLAN)
			r.pace = 0.0
			_turn_toward(r, r.target_facing, dt)
			return
	# The plan goes round walls, through the gate; this is the backstop that means no step
	# ever crosses one whatever the plan says -- a router has no plan at all.
	if not crosses_a_wall(r.pos, r.pos + step):
		r.pos += step
	# The facing it was ORDERED, not the way it happens to be walking. This one line was
	# the spin: a regiment turned to point at wherever it was going, so sending it
	# anywhere behind itself swung the whole block round. Movement never needed a front --
	# `r.pos +=` above walks straight at the target whatever way the block faces.
	_turn_toward(r, r.target_facing, dt)


## Friends on the move give way to one another.
##
## The planner goes round whoever is STANDING, but two marching blocks used to walk
## straight through each other -- two columns over one bridge were one column. Steering
## round each other did not work, and it is worth knowing why: `gap_between` measures by
## the angle between two blocks, so a sidestep out of a head-on meeting brings the FLANK
## into play and the gap still shrinks. Every dodge read as worse, and the two merged by a
## hundred units.
##
## So the planner does it, and the rule is a queue and a detour:
##
##   a friend on the march crossing in front of you    you WAIT for him
##   a friend standing, or waiting himself            you plan round him
##
## A waiting regiment counts as standing to the planner, so whoever it waits for walks
## round it. Two meeting head-on would each wait for the other; the lower id is the one
## that does not, and a replay agrees because the rule is deterministic.
##
## Friends only -- an enemy in the way is not somebody to step round, it is contact, and
## the fight is the point. Routers neither wait nor get waited for: a fleeing mob goes
## through its own lines.
func _gives_way(r: Regiment, f: Regiment) -> bool:
	if f.state != Regiment.State.MOVING or f.waiting:
		return false                           # standing: go round him instead
	return f.id < r.id or _blocker(f, _heading(f), _heading(f).length()) != r


## The friend `r` would run into within AVOID_LOOKAHEAD along `step`, or null.
##
## Seen that far ahead so the one who waits stops outside the other's planning margin --
## at 40 units he was already inside it, and the detour round him was too tight to be one.
## Measured with the two real footprints (`separation`), not `gap_between`, whose reach
## flips from front to flank as a block moves sideways: a detour past somebody read as a
## collision with him. Only an approach counts, so two already tangled can walk apart.
##
## Never further than `left`, the rest of its own route. Looking a hundred units past
## where it meant to stop, a regiment closing on an enemy's flank saw the friend already
## fighting that enemy's front -- and stopped short of the flank it was sent to take.
func _blocker(r: Regiment, step: Vector2, left: float):
	if step.length() < 0.0001:
		return null
	var dir := step.normalized()
	var look := minf(Rules.AVOID_LOOKAHEAD, left)
	var mine := r.extent()
	for id in sorted_ids():
		var o: Regiment = regiments[id]
		if o.id == r.id or o.owner_id != r.owner_id or not o.is_alive():
			continue
		# Not a friend in a melee: coming up alongside him to hit the same enemy's flank IS
		# the flank attack. Blocking on him had the flankers re-planning a stride short of
		# the fight they were sent to, and flank contact fell from 17% of a battle to 7%.
		if o.state == Regiment.State.ROUTING or o.state == Regiment.State.FIGHTING:
			continue
		var theirs := o.extent()
		if r.pos.distance_to(o.pos) > mine.length() + theirs.length() + look:
			continue
		var now := separation(r.pos, r.facing, mine, o.pos, o.facing, theirs)
		for part in [0.5, 1.0]:
			var then := separation(r.pos + dir * look * part, r.facing, mine,
				o.pos, o.facing, theirs)
			if then < Rules.AVOID_CLEAR and then < now:
				return o
	return null


## How far apart two footprints are -- rectangles at `pos`, turned to `facing`, half
## `extent` (depth, frontage) -- on the axis that separates them best. Negative is how
## deep they overlap. The separating-axis test: continuous whichever way either faces.
static func separation(pa: Vector2, fa: float, ea: Vector2, pb: Vector2, fb: float, eb: Vector2) -> float:
	var d := pb - pa
	var best := -INF
	for axis: Vector2 in [Vector2.from_angle(fa), Vector2.from_angle(fa + PI * 0.5),
			Vector2.from_angle(fb), Vector2.from_angle(fb + PI * 0.5)]:
		best = maxf(best, absf(d.dot(axis)) - _half_along(axis, fa, ea) - _half_along(axis, fb, eb))
	return best


static func _half_along(axis: Vector2, facing: float, e: Vector2) -> float:
	return e.x * absf(axis.dot(Vector2.from_angle(facing))) \
		+ e.y * absf(axis.dot(Vector2.from_angle(facing + PI * 0.5)))


## Which way a marching regiment is going this tick: at its next waypoint.
static func _heading(r: Regiment) -> Vector2:
	var to: Vector2 = r.path[0] if not r.path.is_empty() else r.target
	return to - r.pos


## Blocked, and its destination is somebody else's ground: close enough, it stops. Two
## sent to one spot would otherwise leave the second marching on the spot forever -- and a
## regiment that is never IDLE never shoots and never rests.
##
## Only a friend who has STOPPED there, and only if the two would genuinely stand in one
## another at the destination. Measured loosely -- any friend, anywhere near -- it had the
## AI's spears give up and stand for half a battle, because the sword marching beside them
## happened to be passing their slot.
func _spot_taken(r: Regiment) -> bool:
	for id in sorted_ids():
		var o: Regiment = regiments[id]
		if o.id == r.id or o.owner_id != r.owner_id or not o.is_alive():
			continue
		if o.state == Regiment.State.MOVING or o.state == Regiment.State.ROUTING:
			continue
		if separation(r.target, r.target_facing, r.extent(), o.pos, o.facing, o.extent()) < 0.0:
			return true
	return false


func _halt(r: Regiment, routing: bool, dt: float) -> void:
	r.pace = 0.0
	if not routing:
		r.state = Regiment.State.IDLE
	_turn_toward(r, r.target_facing, dt)


## This step, or the same length along the shore if it would end in the water, or nothing
## if neither is dry. Already standing in water, any step goes: that is how you get out.
func _shore(from: Vector2, step: Vector2) -> Vector2:
	if wet(from) or not wet(from + step):
		return step
	var normal := _water_normal(from + step, from)
	var along := normal.orthogonal()
	if along.dot(step) < 0.0:
		along = -along
	# A hair outward as well: a straight line along a curved shore still clips it.
	var slid := (along + normal * 0.05).normalized() * step.length()
	return slid if not wet(from + slid) else Vector2.ZERO


## Keep the plan current. It is made again when there is none, when the target has moved
## further than REPLAN_DISTANCE from where it was planned to, and every REPLAN_SECONDS
## while marching -- somebody may have stopped in the way since. Between those a plan that
## reaches its target simply follows it, so a chase costs nothing until something is
## actually in the way. Waypoints are dropped as they are reached.
##
## Never issued as an order, the way `_pursue` keeps a chase current: nothing is
## re-ordered, so MOVING stays MOVING and arrival still means arrival.
func _follow(r: Regiment, dt: float) -> void:
	r.replan -= dt
	if r.path.is_empty() or r.replan <= 0.0 or r.path_to.distance_to(r.target) > Rules.REPLAN_DISTANCE:
		r.path = nav().plan(self, r)
		r.path_to = r.target
		r.path_whole = r.path[r.path.size() - 1] == r.target
		r.replan = Rules.REPLAN_SECONDS
	elif r.path_whole:
		r.path[r.path.size() - 1] = r.target
	while r.path.size() > 1 and r.pos.distance_to(r.path[0]) <= Rules.WAYPOINT_REACHED:
		r.path.remove_at(0)


## The planner, made the first time anybody needs it. Server-side and never sent.
func nav() -> Pathing:
	if _nav == null:
		_nav = Pathing.new()
	return _nav


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
