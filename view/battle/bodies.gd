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
##   - while a regiment is fighting, files rotate: the man at the front goes to the back
##     and the rest step up, which is Roman line relief at the scale we can draw it.
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
## A small shuffle so a standing regiment is not a frozen diagram.
const SWAY := 1.1
const SWAY_RATE := 2.3
## Further than this from his place and a man has been teleported, not outrun.
const SNAP_DISTANCE := 400.0
## How often one file rotates its front man to the back while the regiment is fighting.
## Zero turns relief off. Too short and the line reads as fidgeting rather than working.
const RELIEF_INTERVAL := 3.0


class Troop extends RefCounted:
	var width := 0
	var max_strength := 0
	var ranks := 1
	var world := PackedVector2Array()    # where each living man is right now
	var file := PackedInt32Array()       # his column
	var depth := PackedInt32Array()      # his place in it, 0 = front rank
	var man_id := PackedInt32Array()     # stable identity, so his gait survives a death
	var per_file := PackedInt32Array()   # how many men each column holds
	var next_id := 0
	var phase := 0.0
	var centre := Vector2.ZERO
	var relief := 0.0


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
		_troops[id] = troop
		for i in troop.world.size():
			troop.world[i] = _place_of(troop, p, i)          # arrive already formed
		return strength

	if troop.width != int(p["width"]):
		_reform(troop, int(p["width"]))                      # walk into the new shape

	var hits: Array = p.get("hits", [])
	while troop.world.size() > strength:
		# Dressing the line is what a file-closer does to the FIGHTING line. After a
		# flank or a rear attack the block has genuinely been eaten from that side, and
		# pulling men back across to even it up would undo the damage.
		if _kill(troop, hits) == BattleState.Side.FRONT:
			_close_the_line(troop)
	while troop.world.size() < strength:
		_enlist(troop, p)

	if RELIEF_INTERVAL > 0.0 and p["state"] == Regiment.State.FIGHTING:
		troop.relief += delta
		while troop.relief >= RELIEF_INTERVAL:
			troop.relief -= RELIEF_INTERVAL
			_relieve_a_file(troop)

	var ease := 1.0 - exp(-CATCH_UP * delta)
	var sum := Vector2.ZERO
	for i in troop.world.size():
		var target := _place_of(troop, p, i)
		var here: Vector2 = troop.world[i]
		if here.distance_squared_to(target) > SNAP_DISTANCE * SNAP_DISTANCE:
			troop.world[i] = target
		else:
			var rate := ease * (1.0 + CATCH_UP_SPREAD * _wobble(troop.man_id[i]))
			troop.world[i] = here.lerp(target, clampf(rate, 0.0, 1.0))
		sum += troop.world[i]
	troop.centre = sum / float(maxi(1, troop.world.size()))
	return strength


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
		troop.per_file[f] += 1
		troop.next_id += 1
	return troop


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


## Line relief: the front man of a file goes to the back and the rest step up. Cosmetic,
## and the reason a held line looks like men working rather than a diagram.
##
## ponytail: he walks straight back through his own file rather than stepping round it,
## so he briefly overlaps his file-mates. Give him a lane if that ever reads badly.
func _relieve_a_file(troop: Troop) -> void:
	var candidates := PackedInt32Array()
	for f in troop.per_file.size():
		if troop.per_file[f] >= 2:
			candidates.append(f)
	if candidates.is_empty():
		return
	var f: int = candidates[randi() % candidates.size()]
	var back := troop.per_file[f] - 1
	for i in troop.file.size():
		if troop.file[i] != f:
			continue
		if troop.depth[i] == 0:
			troop.depth[i] = back
		else:
			troop.depth[i] -= 1


func _discharge(troop: Troop, i: int) -> void:
	troop.world.remove_at(i)
	troop.file.remove_at(i)
	troop.depth.remove_at(i)
	troop.man_id.remove_at(i)


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
	var offset := Formation.slot(troop.file[i], troop.depth[i], troop.width, troop.ranks)
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
	var facing := float(p["facing"])
	var ax := Vector2(cos(facing), sin(facing))
	var ay := Vector2(-ax.y, ax.x)

	for i in troop.world.size():
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
		out[troop.man_id[i]] = Formation.slot(troop.file[i], troop.depth[i], troop.width, troop.ranks)
	return out


## The local slots the living men stand in, in no particular order.
func occupied_slots(id: int) -> PackedVector2Array:
	var out := PackedVector2Array()
	for offset in slots(id).values():
		out.append(offset)
	return out


func men_per_file(id: int) -> PackedInt32Array:
	var troop = _troops.get(id)
	return PackedInt32Array() if troop == null else troop.per_file
