extends RefCounted
## Wire format for full world snapshots.
##
## ponytail: var_to_bytes over a flat Array -- Godot's own encoder, zero code, and it
## round-trips under the same test a hand-rolled codec would need. Floats go out as
## 64-bit doubles, so this is roughly 2x the size a packed codec would manage.
## Swap in a PackedFloat32Array codec when the byte size printed by the round-trip
## test actually hurts; delta encoding after that.
##
## Everything decoded here came off the network. It is untrusted: validate the shape
## and the types, return null on anything unexpected, and never use
## bytes_to_var_with_objects (which would let a peer instantiate scripts).

const Regiment := preload("res://sim/regiment.gd")
const BattleState := preload("res://sim/battle_state.gd")

const VERSION := 1

## Field order on the wire.  Add a field here and the round-trip test covers it.
const REGIMENT_FIELDS := [
	["id", TYPE_INT],
	["owner_id", TYPE_INT],
	["kind", TYPE_STRING_NAME],
	["strength", TYPE_INT],
	["max_strength", TYPE_INT],
	["morale", TYPE_FLOAT],
	["pos", TYPE_VECTOR2],
	["facing", TYPE_FLOAT],
	["width", TYPE_INT],
	["state", TYPE_INT],
	["target", TYPE_VECTOR2],
	["target_facing", TYPE_FLOAT],
	["engaged_with", TYPE_INT],
]


static func encode_battle(bs) -> PackedByteArray:
	var rows := []
	for id in bs.sorted_ids():
		var r = bs.regiments[id]
		var row := []
		for field in REGIMENT_FIELDS:
			row.append(r.get(field[0]))
		rows.append(row)
	return var_to_bytes([VERSION, bs.tick, bs._next_id, rows])


## Returns a BattleState, or null if the bytes are not a snapshot we understand.
static func decode_battle(bytes: PackedByteArray):
	if bytes.size() < 4:
		return null                         # too short for bytes_to_var to even look at
	var data = bytes_to_var(bytes)          # never _with_objects: that is remote code execution
	if typeof(data) != TYPE_ARRAY or data.size() != 4:
		return null
	if typeof(data[0]) != TYPE_INT or data[0] != VERSION:
		return null
	if typeof(data[1]) != TYPE_INT or typeof(data[2]) != TYPE_INT or typeof(data[3]) != TYPE_ARRAY:
		return null

	var bs = BattleState.new()
	bs.tick = data[1]
	bs._next_id = data[2]
	for row in data[3]:
		if typeof(row) != TYPE_ARRAY or row.size() != REGIMENT_FIELDS.size():
			return null
		var r = Regiment.new()
		for i in REGIMENT_FIELDS.size():
			var field = REGIMENT_FIELDS[i]
			if typeof(row[i]) != field[1]:
				# ints arriving where floats are expected is the one benign case
				if not (field[1] == TYPE_FLOAT and typeof(row[i]) == TYPE_INT):
					return null
			r.set(field[0], row[i])
		if bs.regiments.has(r.id):
			return null                     # duplicate ids would silently drop a regiment
		bs.regiments[r.id] = r
	return bs
