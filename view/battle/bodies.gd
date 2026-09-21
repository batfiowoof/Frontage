extends RefCounted
## The men.
##
## Client side only. The server simulates regiments and never soldiers; nothing in this
## file can change the outcome of a battle. A soldier's position is decoration, a
## regiment's position is truth.
##
## Everything here is built on the **file** -- the column of men running front to back --
## because that was the fundamental unit of a real formation, not the rank. A man is
## stored as the file he stands in and how far back he stands in it, so:
##
##   - when the man at the head of a file falls, the man DIRECTLY BEHIND him steps into
##     his place and the rest of that file each move up one. No other file moves at all.
##   - a file that is emptied leaves a hole, and the file-closer's job of dressing the
##     line is done by walking a man across from the deepest file.
##
## Keying men by their index in a flat rank-major array, which is what this used to do,
## makes the man to the LEFT inherit a dead man's place instead of the man behind him.
## The block ripples sideways and nobody steps forward.

const Rules := preload("res://sim/rules.gd")
const Formation := preload("res://sim/formation.gd")
const Regiment := preload("res://sim/regiment.gd")
const Colors := preload("res://view/colors.gd")
const BattleState := preload("res://sim/battle_state.gd")

const FLOATS_PER_INSTANCE := 12          # 8 transform + 4 colour

## How fast a man closes on his place. Exponential, so it is frame-rate independent and
## there is nothing to overshoot.
const CATCH_UP := 3.6
## Variation in that rate per man, so a block ripples on the move instead of sliding.
const CATCH_UP_SPREAD := 0.45
## A small shuffle so a standing regiment is not a frozen diagram. Kept well under half
## the gap between two files: men are drawn as dots with their own outline now, and two
## neighbours shuffling out of phase must not close the 3 units between them.
const SWAY := 0.8
const SWAY_RATE := 2.3
## Further than this from his place and a man has been teleported, not outrun.
const SNAP_DISTANCE := 400.0
## How long a regiment reads as busy after its frontage changes. Purely a clock about an
## animation: changing frontage costs nothing and gates nothing, but re-dressing a line is
## not instant and the player should be able to see that it is happening.
const DRESS_SECONDS := 3.0

## How fast a man swivels to meet something, radians per second. Far quicker than a
## regiment can wheel, because turning your own body is not a manoeuvre.
const MAN_TURN_RATE := 2.4
const MAN_TURN_SPREAD := 0.5
## How far back from the man closest to a threat the reaction reaches. Measured from the
## regiment's own nearest approach rather than as a fixed radius, so it means the same
## thing for a 140-man pike block and a 70-man cavalry wedge.
const NOTICE_BAND := 55.0
## How far a man edges toward what he has turned to face. Enough to thicken the struck
## edge into a hook; more than this and men drift out of their files and the formation
## stops reading as one.
const LEAN := 7.0

## How far round an enemy the fighting line bends, and how much of that to apply.
##
## LEAN on its own was the whole of "bows into a hook", and seven units is one file's
## width -- too small to read as anything, so two regiments in contact looked like two
## rectangles touching. This is the other half, and it is a different motion: LEAN moves a
## man TOWARD what he faces, this one moves him AROUND it.
##
## A hundred and forty degrees carries the ends of the line right round onto the enemy's
## flanks and a little past them -- a full envelopment rather than a bow. These two are
## the dials if it reads shy or overdone.
const WRAP_MAX := deg_to_rad(140.0)
const WRAP := 1.0
## Below this much of the notice band the bend fades out, so a man at the very edge of
## what he can see is not snapped into the arc. Above it he gets the full curve: fading it
## by distance the whole way made the ENDS of a line -- which are furthest from the enemy,
## and are exactly the men who should be coming round -- bend the least.
const WRAP_FADE := 0.35
## How far outside an enemy's outline a man must stay. It has to cover THEIR lean as well
## as his own body: their front rank edges LEAN units out toward him at the same time he
## edges toward them, and CONTACT_GAP is 14, so seven units of lean from each side closes
## the whole of it and the two front ranks land in the same place. Measured before this
## existed: the closest man-to-man distance across a contact was 0.0 units, against a body
## four across. Men standing inside other men is what "they overlap" looks like.
const KEEP_CLEAR := 12.0
## Closer than this to an enemy's centre and the arc is meaningless, so stop dividing by
## it. A man standing on top of the thing he is fighting has no "round" to go.
const WRAP_MIN_RADIUS := 12.0

## A facing change past this is an ABOUT-FACE, not a wheel, and the men must not be swung
## round for it. Comfortably over a right angle: the sim only ever flips by exactly PI.
const ABOUT_FACE := deg_to_rad(150.0)


class Troop extends RefCounted:
	var width := 0
	var max_strength := 0
	var ranks := 1
	var world := PackedVector2Array()    # where each living man is right now
	var file := PackedInt32Array()       # his column
	var depth := PackedInt32Array()      # his place in it, 0 = front rank
	var man_id := PackedInt32Array()     # stable identity, so his gait survives a death
	var face := PackedFloat32Array()     # which way he is looking, his own business
	var per_file := PackedInt32Array()   # how many men each column holds
	var next_id := 0
	var phase := 0.0
	var centre := Vector2.ZERO
	var dress := 0.0                     # seconds left visibly re-dressing
	var mount := 0.0                     # the facing the slots were last laid out at
	var spacing := 1.0


var _troops := {}                        # regiment id -> Troop
var _time := 0.0


## Advance every man and return this frame's MultiMesh buffer.
func build(pose: Dictionary, seating: Array, delta: float) -> PackedFloat32Array:
	_time += delta
	for id in _troops.keys():
		if not pose.has(id):
			_troops.erase(id)

	var total := 0
	for id in pose:
		total += _advance(id, pose[id], delta)

	var buffer := PackedFloat32Array()
	buffer.resize(total * FLOATS_PER_INSTANCE)
	var at := 0
	for id in pose:
		at = _write(id, pose[id], seating, buffer, at)
	return buffer


## Where the living men actually are, which at half strength is well forward of the
## regiment's own position. The bars hang off this, not off `pos`, or they float behind
## the block they belong to.
func centre_of(id: int, fallback: Vector2) -> Vector2:
	var troop = _troops.get(id)
	return fallback if troop == null or troop.world.is_empty() else troop.centre


func _advance(id: int, p: Dictionary, delta: float) -> int:
	var strength: int = maxi(0, int(p["strength"]))
	var troop = _troops.get(id)

	if troop == null or troop.max_strength != int(p["max_strength"]):
		troop = _raise(int(p["width"]), int(p["max_strength"]), strength, id)
		troop.mount = float(p["facing"])
		_troops[id] = troop
		for i in troop.world.size():
			troop.world[i] = _place_of(troop, p, i)          # arrive already formed
			troop.face[i] = float(p["facing"])
		return strength

	troop.spacing = float(p.get("spacing", 1.0))
	troop.dress = maxf(0.0, troop.dress - delta)
	# Turned right round: relabel rather than rotate, so nobody moves an inch.
	if absf(angle_difference(float(p["facing"]), troop.mount)) > ABOUT_FACE:
		_turn_about(troop)
	troop.mount = float(p["facing"])
	if troop.width != int(p["width"]):
		_reform(troop, int(p["width"]))                      # walk into the new shape
		troop.dress = DRESS_SECONDS

	var hits: Array = p.get("hits", [])
	while troop.world.size() > strength:
		# Dressing the line is what a file-closer does to the FIGHTING line. After a
		# flank or a rear attack the block has genuinely been eaten from that side, and
		# pulling men back across to even it up would undo the damage.
		if _kill(troop, hits) == BattleState.Side.FRONT:
			_close_the_line(troop)
	while troop.world.size() < strength:
		_enlist(troop, p)

	var threats: PackedVector2Array = p.get("threats", PackedVector2Array())
	var shapes: PackedVector3Array = p.get("shapes", PackedVector3Array())
	var reach := _nearest_approach(troop, threats)
	var facing := float(p["facing"])

	var ease := 1.0 - exp(-CATCH_UP * delta)
	var sum := Vector2.ZERO
	for i in troop.world.size():
		var here: Vector2 = troop.world[i]
		var target := _place_of(troop, p, i)

		# Whichever enemy is nearest to HIM, not the one his regiment is nominally
		# fighting. A man at the far end of a flanked line has no business turning round.
		var want := facing
		var t := _threat_for(threats, reach, here)
		if t >= 0:
			var toward: Vector2 = threats[t] - here
			if toward.length_squared() > 1.0:
				want = toward.angle()
				var near := _closeness(t, threats, reach, here)
				# ...and he edges toward it, so the struck edge thickens and bows into a
				# hook while the rest of the line keeps facing its own front.
				target += toward.normalized() * LEAN * near
				# ...and the line he is standing in bends ROUND it, which is what turns
				# two rectangles meeting edge-on into an encirclement you can see.
				var shape := Vector3.ZERO
				if t < shapes.size():
					shape = shapes[t]
				# Only the WIDER of the two bends, and only by as much as it is wider.
				# Both sides wrapping is self-defeating: each one is happily outside the
				# other's block, and they meet in the open ground beside it -- measured,
				# our man at (0, 33) and theirs at (0, 33), the same square yard. Which
				# is also the honest answer, because you envelop somebody by OVERLAPPING
				# him, and two lines of the same width overlap nowhere.
				var blend := clampf(near / WRAP_FADE, 0.0, 1.0) * WRAP * _advantage(p, shape)
				if blend > 0.0:
					target = target.lerp(_curl(target, threats[t], shape, troop.centre), blend)
			# ...and wherever all that put him, he does not end up standing in somebody.
			# Checked against EVERY enemy in contact, not just the one he is dealing with,
			# or a man caught between two of them is clear of one and inside the other.
			target = _keep_clear(target, threats, shapes)
		troop.face[i] = rotate_toward(troop.face[i], want,
			MAN_TURN_RATE * (1.0 + MAN_TURN_SPREAD * _wobble(troop.man_id[i])) * delta)

		if here.distance_squared_to(target) > SNAP_DISTANCE * SNAP_DISTANCE:
			troop.world[i] = target
		else:
			var rate := ease * (1.0 + CATCH_UP_SPREAD * _wobble(troop.man_id[i]))
			troop.world[i] = here.lerp(target, clampf(rate, 0.0, 1.0))
		sum += troop.world[i]
	troop.centre = sum / float(maxi(1, troop.world.size()))
	return strength


## How close this regiment's nearest man gets to each threat. The reaction is measured
## from here rather than from a fixed radius, so "near the fighting" means the same for
## a deep pike block as for a small cavalry wedge.
func _nearest_approach(troop: Troop, threats: PackedVector2Array) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	out.resize(threats.size())
	for t in threats.size():
		var best := INF
		for i in troop.world.size():
			best = minf(best, troop.world[i].distance_squared_to(threats[t]))
		out[t] = sqrt(best) if best < INF else 0.0
	return out


## Bend the line round the enemy, keeping every man the same distance from his OUTLINE.
##
## The whole of it is that the man in the MIDDLE of the line is nearer the enemy than the
## man at its END, so bringing everybody to the middle man's standoff carries the ends
## FORWARD until a straight line has become a crescent. It falls out of the geometry
## instead of being posed:
##
##   - the middle man has no offset along the line, so he does not move at all;
##   - a WIDE line close in has men at large offsets over a small radius, so it wraps hard
##     and visibly laps a narrow one, while a narrow or distant line barely curves. Which
##     side envelops which is therefore not a decision anybody makes.
##
## It is the OUTLINE and not the centre, which is the part that took two goes. A regiment
## is wide and shallow -- 133 across against 45 deep -- so going round it at a constant
## distance from its middle sends the men wrapping straight through its flanks, and two
## armies drawn inside one another is the opposite of looking like contact. `shape` is
## (half-depth, half-frontage, facing); an ellipse on those axes is close enough to a
## block and has no corners for men to catch on.
##
## `centre` is the regiment's own middle and only decides which way is "out".
static func _curl(at: Vector2, enemy: Vector2, shape: Vector3, centre: Vector2) -> Vector2:
	var out := centre - enemy
	if out.length_squared() < 1.0:
		return at
	var u := out.normalized()
	var v := Vector2(-u.y, u.x)
	var d := (at - enemy).dot(u)
	if d < WRAP_MIN_RADIUS:
		return at                        # he is level with it or past it; nothing to bend
	var theta := clampf((at - enemy).dot(v) / d, -WRAP_MAX, WRAP_MAX)
	var dir := u.rotated(theta)
	# How far he stands off the enemy's SURFACE now, kept the same all the way round.
	var clear := d - _skin(u, shape)
	return enemy + dir * (_skin(dir, shape) + clear)


## How much wider this regiment is than the one it is fighting, 0 to 1. Nothing at all
## when they are the same width, all of it at twice his frontage.
##
## This is what decides who envelops whom, and it is not a decision anybody makes -- it
## falls out of the two frontages. It also gives the frontage you set by dragging a real
## and visible payoff: widen your line and you wrap round him.
static func _advantage(p: Dictionary, shape: Vector3) -> float:
	var theirs := shape.y
	if theirs <= 0.0:
		return 1.0                       # nobody told us his size; assume we may
	var mine := Formation.frontage(int(p["max_strength"]), int(p["width"]),
		float(p.get("spacing", 1.0)))
	return clampf((mine - theirs) / theirs, 0.0, 1.0)


## Nobody stands inside the men he is fighting.
##
## The curl already hugs the enemy's outline, and LEAN already edges a man toward what he
## faces -- but both of them are aiming at a FOOTPRINT, and the enemy's own men are drawn
## right out to it and leaning back the other way. Two front ranks then occupy the same
## ground. This is the floor under all of it: a hard clamp, applied last, after everything
## else has had its say.
static func _keep_clear(at: Vector2, threats: PackedVector2Array, shapes: PackedVector3Array) -> Vector2:
	var out := at
	for i in threats.size():
		var off := out - threats[i]
		var far := off.length()
		if far < 0.01:
			continue
		var dir := off / far
		var least := _keep_out(dir, shapes, i)
		if far < least:
			out = threats[i] + dir * least
	return out


static func _keep_out(dir: Vector2, shapes: PackedVector3Array, i: int) -> float:
	var shape := shapes[i] if i < shapes.size() else Vector3.ZERO
	return _skin(dir, shape) + KEEP_CLEAR


## How far the enemy's outline reaches in this direction: the BOX his men actually stand
## in, `shape.x` deep along his facing by `shape.y` across it. Zero means nobody told us
## his size, in which case he is a point and the bend is a plain arc.
##
## A box and not an ellipse, which was the first try and looks like a harmless
## simplification. It is not: a 12-file block is nearly square, and an ellipse inscribed
## in a square is fifteen units short of it at the corners -- so men cleared its flanks by
## a comfortable margin and stood in its corners. Men standing in other men is the whole
## complaint, and it hid in the one place the approximation was worst.
static func _skin(dir: Vector2, shape: Vector3) -> float:
	var a := shape.x
	var b := shape.y
	if a <= 0.0 or b <= 0.0:
		return 0.0
	var local := dir.rotated(-shape.z)
	return minf(a / maxf(0.0001, absf(local.x)), b / maxf(0.0001, absf(local.y)))


## Index of the threat this man should be dealing with, or -1 if he is well out of it.
static func _threat_for(threats: PackedVector2Array, reach: PackedFloat32Array, man: Vector2) -> int:
	var best := -1
	var best_distance := INF
	for t in threats.size():
		var d := man.distance_to(threats[t])
		if d > reach[t] + NOTICE_BAND:
			continue                     # the fighting is happening somewhere else
		if d < best_distance:
			best_distance = d
			best = t
	return best


## 1 for the man closest to the fighting, fading to 0 at the back of the notice band.
static func _closeness(t: int, threats: PackedVector2Array, reach: PackedFloat32Array, man: Vector2) -> float:
	var over := man.distance_to(threats[t]) - reach[t]
	return clampf(1.0 - over / NOTICE_BAND, 0.0, 1.0)


# --- forming --------------------------------------------------------------

## Fill rank by rank, so a regiment that is already under strength stands in its front
## ranks rather than trailing off somewhere behind.
func _raise(width: int, max_strength: int, strength: int, id: int) -> Troop:
	var troop := Troop.new()
	troop.width = maxi(1, width)
	troop.max_strength = maxi(1, max_strength)
	troop.ranks = maxi(1, ceili(float(troop.max_strength) / float(troop.width)))
	troop.phase = float(id) * 1.7
	troop.per_file.resize(troop.width)
	troop.per_file.fill(0)
	for n in strength:
		var f := n % troop.width
		troop.file.append(f)
		troop.depth.append(n / troop.width)
		troop.man_id.append(troop.next_id)
		troop.world.append(Vector2.ZERO)
		troop.face.append(0.0)
		troop.per_file[f] += 1
		troop.next_id += 1
	return troop


## An about-face: the whole regiment turned right round, and NOBODY MOVES.
##
## A rectangle rotated 180 degrees about its centre stands on exactly the same ground, so
## turning about is a relabelling and not a rotation. Negating a man's slot --
## `file -> width-1-file`, `depth -> ranks-1-depth` -- and then rotating by `facing + PI`
## returns his original world position exactly, for every man. Verified against
## Formation.slot: 0.0000 units moved, against 140 for the same flip without relabelling.
##
## The rear rank becomes the front rank, which is what an about-face IS. Each man's own
## body then turns round over about a second on MAN_TURN_RATE, and that is the only thing
## you actually see move.
func _turn_about(troop: Troop) -> void:
	var by_file := {}
	for i in troop.file.size():
		troop.file[i] = troop.width - 1 - troop.file[i]
		troop.depth[i] = troop.ranks - 1 - troop.depth[i]
		if not by_file.has(troop.file[i]):
			by_file[troop.file[i]] = []
		by_file[troop.file[i]].append(i)

	# Close each file up to the new front. A full regiment does not move at all -- the
	# flipped depths already run 0..ranks-1. A depleted one, whose men sat in the front
	# part of the nominal block, re-dresses forward by the empty depth, which is what
	# ranks actually do after turning about.
	troop.per_file.resize(troop.width)
	troop.per_file.fill(0)
	for f in by_file:
		var men: Array = by_file[f]
		men.sort_custom(func(a: int, b: int) -> bool: return troop.depth[a] < troop.depth[b])
		for d in men.size():
			troop.depth[men[d]] = d
		troop.per_file[f] = men.size()


## A new frontage. The men keep where they are standing and are given new places to walk
## to, front rank first, so the regiment re-forms on the move instead of teleporting into
## its new shape. M17 hands this to the player, so it is worth being right now.
func _reform(troop: Troop, width: int) -> void:
	width = maxi(1, width)
	var order := []
	for i in troop.file.size():
		order.append([troop.depth[i] * 4096 + troop.file[i], i])
	order.sort_custom(func(a, b) -> bool: return a[0] < b[0])

	troop.width = width
	troop.ranks = maxi(1, ceili(float(troop.max_strength) / float(width)))
	troop.per_file.resize(width)
	troop.per_file.fill(0)
	for place in order.size():
		var i: int = order[place][1]
		var f := place % width
		troop.file[i] = f
		troop.depth[i] = place / width
		troop.per_file[f] += 1


func _enlist(troop: Troop, p: Dictionary) -> void:
	# Reinforcement mid-battle does not happen today, but the back of the shortest file
	# is where a man joining a formation goes.
	var f := _shallowest_file(troop)
	troop.file.append(f)
	troop.depth.append(troop.per_file[f])
	troop.man_id.append(troop.next_id)
	troop.world.append(Vector2.ZERO)
	troop.face.append(float(p["facing"]))
	troop.next_id += 1
	troop.per_file[f] += 1
	troop.world[troop.world.size() - 1] = _place_of(troop, p, troop.world.size() - 1)


# --- dying ----------------------------------------------------------------

## A man falls and the man behind him in his own file steps into his place. That one
## rule covers every direction: what changes with the angle of attack is only WHICH man
## is standing in the way.
##
##   front  the head of some file, so the file collapses forward
##   rear   the tail of some file, so the file simply shortens
##   flank  anywhere down the file at the exposed end of the line, because a flank
##          attack runs along the whole length of that file
##
## Returns the side the blow landed on, or -1 if there was nobody left to kill.
func _kill(troop: Troop, hits: Array) -> int:
	var side: int = BattleState.Side.FRONT
	if not hits.is_empty():
		side = hits[randi() % hits.size()]
	var f := _file_at_edge(troop, side)
	if f < 0:
		return -1
	var d := _depth_at_edge(troop, f, side)

	var victim := -1
	for i in troop.file.size():
		if troop.file[i] != f:
			continue
		if troop.depth[i] == d:
			victim = i
		elif troop.depth[i] > d:
			troop.depth[i] -= 1          # everyone behind him closes up
	if victim < 0:
		return -1
	_discharge(troop, victim)
	troop.per_file[f] -= 1
	return side


## Which column stands in the way. A frontal or rear attack falls anywhere along the
## line; a flank attack falls on the end file, and eats inward from there.
func _file_at_edge(troop: Troop, side: int) -> int:
	if side == BattleState.Side.LEFT:
		for f in troop.per_file.size():
			if troop.per_file[f] > 0:
				return f
		return -1
	if side == BattleState.Side.RIGHT:
		for f in range(troop.per_file.size() - 1, -1, -1):
			if troop.per_file[f] > 0:
				return f
		return -1
	return _a_file_with_men(troop)


func _depth_at_edge(troop: Troop, f: int, side: int) -> int:
	if side == BattleState.Side.REAR:
		return maxi(0, troop.per_file[f] - 1)
	if side == BattleState.Side.FRONT:
		return 0
	return randi() % maxi(1, troop.per_file[f])     # a flank runs the length of the file


## Dressing the line: the file-closer's job. One man per casualty crosses from the
## deepest file to the shallowest, so an emptied file does not leave a permanent hole in
## the front rank, and it reads as men shuffling across the rear rather than a jump.
func _close_the_line(troop: Troop) -> void:
	if troop.world.is_empty():
		return
	var deepest := 0
	var shallowest := 0
	for f in troop.per_file.size():
		if troop.per_file[f] > troop.per_file[deepest]:
			deepest = f
		if troop.per_file[f] < troop.per_file[shallowest]:
			shallowest = f
	if troop.per_file[deepest] - troop.per_file[shallowest] < 2:
		return

	var back := troop.per_file[deepest] - 1
	for i in troop.file.size():
		if troop.file[i] == deepest and troop.depth[i] == back:
			troop.file[i] = shallowest
			troop.depth[i] = troop.per_file[shallowest]
			troop.per_file[deepest] -= 1
			troop.per_file[shallowest] += 1
			return


func _discharge(troop: Troop, i: int) -> void:
	troop.world.remove_at(i)
	troop.file.remove_at(i)
	troop.depth.remove_at(i)
	troop.man_id.remove_at(i)
	troop.face.remove_at(i)


## Deliberately not deterministic: this is decoration, it never reaches the server, and
## two clients disagreeing about which man fell changes nothing.
func _a_file_with_men(troop: Troop) -> int:
	var candidates := PackedInt32Array()
	for f in troop.per_file.size():
		if troop.per_file[f] > 0:
			candidates.append(f)
	return -1 if candidates.is_empty() else candidates[randi() % candidates.size()]


func _shallowest_file(troop: Troop) -> int:
	var best := 0
	for f in troop.per_file.size():
		if troop.per_file[f] < troop.per_file[best]:
			best = f
	return best


# --- drawing --------------------------------------------------------------

## Places are rotated into WORLD space before the men chase them, so a regiment that
## turns or marches drags its men round after it and they catch up. Easing in local
## space instead would spin the whole block rigidly, which is the glued look.
static func _place_of(troop: Troop, p: Dictionary, i: int) -> Vector2:
	var offset := Formation.slot(troop.file[i], troop.depth[i], troop.width, troop.ranks, troop.spacing)
	return p["pos"] + offset.rotated(float(p["facing"]))


static func _wobble(man: int) -> float:
	return sin(float(man) * 7.13)


func _write(id: int, p: Dictionary, seating: Array, buffer: PackedFloat32Array, at: int) -> int:
	var troop = _troops.get(id)
	if troop == null:
		return at
	var c := Colors.of_owner(int(p["owner"]), seating)
	if p["state"] == Regiment.State.ROUTING:
		c = c.darkened(0.45)
	for i in troop.world.size():
		# Each man's own basis. One regiment-wide basis is what made a flanked block
		# read as a single sprite swinging round.
		var ax := Vector2.from_angle(troop.face[i])
		var ay := Vector2(-ax.y, ax.x)
		var shuffle := sin(_time * SWAY_RATE + troop.phase + float(troop.man_id[i]) * 1.7) * SWAY
		var here: Vector2 = troop.world[i] + Vector2(shuffle, shuffle * 0.6)
		buffer[at + 0] = ax.x
		buffer[at + 1] = ay.x
		buffer[at + 2] = 0.0
		buffer[at + 3] = here.x
		buffer[at + 4] = ax.y
		buffer[at + 5] = ay.y
		buffer[at + 6] = 0.0
		buffer[at + 7] = here.y
		buffer[at + 8] = c.r
		buffer[at + 9] = c.g
		buffer[at + 10] = c.b
		buffer[at + 11] = 1.0
		at += FLOATS_PER_INSTANCE
	return at


# --- for tests ------------------------------------------------------------

func living(id: int) -> int:
	var troop = _troops.get(id)
	return 0 if troop == null else troop.world.size()


## Seconds this regiment has left visibly re-dressing after a frontage change, for the
## HUD. Client-side and derived from the mirror: the sim neither knows nor cares, because
## changing frontage is free and the men walking into their new files is the whole of it.
func dressing(id: int) -> float:
	var troop = _troops.get(id)
	return 0.0 if troop == null else troop.dress


## Every living man's place, as man_id -> (file, depth).
func places(id: int) -> Dictionary:
	var out := {}
	var troop = _troops.get(id)
	if troop == null:
		return out
	for i in troop.file.size():
		out[troop.man_id[i]] = Vector2i(troop.file[i], troop.depth[i])
	return out


## Every living man's local slot, as man_id -> offset.
func slots(id: int) -> Dictionary:
	var out := {}
	var troop = _troops.get(id)
	if troop == null:
		return out
	for i in troop.file.size():
		out[troop.man_id[i]] = Formation.slot(troop.file[i], troop.depth[i], troop.width, troop.ranks, troop.spacing)
	return out


## The local slots the living men stand in, in no particular order.
func occupied_slots(id: int) -> PackedVector2Array:
	var out := PackedVector2Array()
	for offset in slots(id).values():
		out.append(offset)
	return out


## Every living man's facing, as man_id -> radians.
func facings(id: int) -> Dictionary:
	var out := {}
	var troop = _troops.get(id)
	if troop == null:
		return out
	for i in troop.face.size():
		out[troop.man_id[i]] = troop.face[i]
	return out


## Every living man's position, as man_id -> where he is standing.
func positions(id: int) -> Dictionary:
	var out := {}
	var troop = _troops.get(id)
	if troop == null:
		return out
	for i in troop.world.size():
		out[troop.man_id[i]] = troop.world[i]
	return out


func men_per_file(id: int) -> PackedInt32Array:
	var troop = _troops.get(id)
	return PackedInt32Array() if troop == null else troop.per_file
