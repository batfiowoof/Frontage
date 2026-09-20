extends RefCounted
## Orders are the only thing a client may send that changes the world.
##
## Everything here arrives from the network and is hostile until proven otherwise:
## shape, version, types, array length, and finiteness are all checked. A single NaN
## position accepted here would poison the sim for every player and never recover.
## Ownership is checked by the server in net.gd — this file only proves the shape.

const Rules := preload("res://sim/rules.gd")

const VERSION := 1
const MAX_IDS_PER_ORDER := 64          # a box selection, not a whole army list

enum Type { BATTLE_MOVE }


static func battle_move(ids: PackedInt32Array, target: Vector2, facing: float) -> PackedByteArray:
	return var_to_bytes([VERSION, Type.BATTLE_MOVE, ids, target, facing])


## Returns a validated order dictionary, or {} if these bytes are not an order.
static func decode(bytes: PackedByteArray) -> Dictionary:
	if bytes.size() < 4:
		return {}
	var d = bytes_to_var(bytes)
	if typeof(d) != TYPE_ARRAY or d.size() != 5:
		return {}
	if typeof(d[0]) != TYPE_INT or d[0] != VERSION:
		return {}
	if typeof(d[1]) != TYPE_INT or d[1] != Type.BATTLE_MOVE:
		return {}
	if typeof(d[2]) != TYPE_PACKED_INT32_ARRAY:
		return {}
	var ids: PackedInt32Array = d[2]
	if ids.is_empty() or ids.size() > MAX_IDS_PER_ORDER:
		return {}
	if typeof(d[3]) != TYPE_VECTOR2 or typeof(d[4]) != TYPE_FLOAT:
		return {}
	var target: Vector2 = d[3]
	var facing: float = d[4]
	if not (is_finite(target.x) and is_finite(target.y) and is_finite(facing)):
		return {}
	return {
		"type": d[1],
		"ids": ids,
		"target": clamp_to_field(target),
		"facing": wrapf(facing, -PI, PI),
	}


## Orders land on the battlefield or not at all.
static func clamp_to_field(p: Vector2) -> Vector2:
	var e := Rules.BATTLE_HALF_EXTENT
	return Vector2(clampf(p.x, -e, e), clampf(p.y, -e, e))
