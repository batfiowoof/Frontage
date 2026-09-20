extends RefCounted
## The men.
##
## Client side only. The server simulates regiments and never soldiers; nothing in this
## file can change the outcome of a battle. A soldier's position is decoration, a
## regiment's position is truth.
##
## The whole mechanism is one line of bookkeeping: living soldier `i` stands in slot `i`,
## and slots run front rank first. When a regiment loses men, entries are removed from
## the FRONT of the array -- those are the men in contact, and they are who dies. Everyone
## behind a hole shifts down an index, so his target slot moves one place forward and the
## block steps up into the gap. Depth is lost from the back and the fighting line stays
## where it is, which is what a line of men actually does.

const Rules := preload("res://sim/rules.gd")
const Formation := preload("res://sim/formation.gd")
const Regiment := preload("res://sim/regiment.gd")
const Colors := preload("res://view/colors.gd")

const FLOATS_PER_INSTANCE := 12          # 8 transform + 4 colour

## How fast a man closes on his slot. Exponential, so it is frame-rate independent and
## there is nothing to overshoot.
const CATCH_UP := 3.6
## Variation in that rate per man, so a block ripples on the move instead of sliding.
const CATCH_UP_SPREAD := 0.45
## A small shuffle so a standing regiment is not a frozen diagram.
const SWAY := 1.1
const SWAY_RATE := 2.3
## Further than this from his slot and a man has been teleported, not outrun.
const SNAP_DISTANCE := 400.0


class Troop extends RefCounted:
	var slots := PackedVector2Array()    # local offsets for a FULL regiment, front first
	var world := PackedVector2Array()    # where the living men actually are, compacted
	var width := 0
	var max_strength := 0
	var phase := 0.0
	var centre := Vector2.ZERO


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
## regiment's own position. The strength and morale bars hang off this, not off `pos`,
## or they float behind the block they belong to.
func centre_of(id: int, fallback: Vector2) -> Vector2:
	var troop = _troops.get(id)
	return fallback if troop == null or troop.world.is_empty() else troop.centre


func _advance(id: int, p: Dictionary, delta: float) -> int:
	var strength: int = maxi(0, int(p["strength"]))
	var troop = _troops.get(id)

	if troop == null or troop.width != int(p["width"]) or troop.max_strength != int(p["max_strength"]):
		troop = Troop.new()
		troop.width = int(p["width"])
		troop.max_strength = int(p["max_strength"])
		troop.slots = Formation.offsets(troop.max_strength, troop.width)
		troop.phase = float(id) * 1.7
		troop.world.resize(strength)
		for i in strength:
			troop.world[i] = _slot_in_world(troop, p, i)     # arrive already formed
		_troops[id] = troop
		return strength

	while troop.world.size() > strength:
		troop.world.remove_at(_a_man_in_the_front_rank(troop))
	while troop.world.size() < strength:
		# Reinforcement mid-battle does not happen today, but arriving at the back is
		# the right answer if it ever does.
		troop.world.append(_slot_in_world(troop, p, troop.world.size()))

	var ease := 1.0 - exp(-CATCH_UP * delta)
	var sum := Vector2.ZERO
	for i in troop.world.size():
		var target := _slot_in_world(troop, p, i)
		var here: Vector2 = troop.world[i]
		if here.distance_squared_to(target) > SNAP_DISTANCE * SNAP_DISTANCE:
			troop.world[i] = target
		else:
			troop.world[i] = here.lerp(target, clampf(ease * (1.0 + CATCH_UP_SPREAD * _wobble(i)), 0.0, 1.0))
		sum += troop.world[i]
	troop.centre = sum / float(maxi(1, troop.world.size()))
	return strength


## Which man falls. Spread across the front rank rather than always the first, or the
## line appears to slide sideways instead of developing gaps along it.
##
## Deliberately not deterministic: this is decoration, it never reaches the server, and
## two clients disagreeing about which man fell changes nothing.
func _a_man_in_the_front_rank(troop: Troop) -> int:
	return randi() % maxi(1, mini(troop.width, troop.world.size()))


## Slots are rotated into WORLD space before the men chase them, so a regiment that
## turns or marches drags its men round after it and they catch up. Easing in local
## space instead would spin the whole block rigidly, which is the glued look.
static func _slot_in_world(troop: Troop, p: Dictionary, i: int) -> Vector2:
	if i >= troop.slots.size():
		return p["pos"]
	return p["pos"] + troop.slots[i].rotated(float(p["facing"]))


static func _wobble(i: int) -> float:
	return sin(float(i) * 7.13)


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
		var shuffle := sin(_time * SWAY_RATE + troop.phase + float(i) * 1.7) * SWAY
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

## The slots the living men are currently assigned to, in local space.
func occupied_slots(id: int) -> PackedVector2Array:
	var troop = _troops.get(id)
	if troop == null:
		return PackedVector2Array()
	var out := PackedVector2Array()
	for i in mini(troop.world.size(), troop.slots.size()):
		out.append(troop.slots[i])
	return out


func living(id: int) -> int:
	var troop = _troops.get(id)
	return 0 if troop == null else troop.world.size()
