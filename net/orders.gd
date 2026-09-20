extends RefCounted
## Orders are the only thing a client may send that changes the world.
##
## Everything here arrives from the network and is hostile until proven otherwise:
## shape, version, types, array lengths, ranges and finiteness are all checked. A
## single NaN position accepted here would poison the sim for every player and never
## recover; a tile index out of range would crash the server on the next frame.
##
## Ownership and affordability are the server's job (net.gd, campaign_state.gd).
## This file only proves that the bytes describe a well-formed order.

const Rules := preload("res://sim/rules.gd")

const VERSION := 1
const MAX_IDS_PER_ORDER := 64          # a box selection, not a whole army list
const TILE_COUNT := Rules.MAP_W * Rules.MAP_H

enum Type { BATTLE_MOVE, ARMY_MOVE, RECRUIT, READY, BUILD, SET_FORMATION, FOCUS }


# --- encoding -------------------------------------------------------------

static func battle_move(ids: PackedInt32Array, target: Vector2, facing: float) -> PackedByteArray:
	return var_to_bytes([VERSION, Type.BATTLE_MOVE, ids, target, facing])


static func army_move(army_id: int, dest_tile: int) -> PackedByteArray:
	return var_to_bytes([VERSION, Type.ARMY_MOVE, army_id, dest_tile])


static func recruit(tile: int, kind: StringName) -> PackedByteArray:
	return var_to_bytes([VERSION, Type.RECRUIT, tile, kind])


static func ready(value: bool) -> PackedByteArray:
	return var_to_bytes([VERSION, Type.READY, value])


static func build(tile: int, building: StringName) -> PackedByteArray:
	return var_to_bytes([VERSION, Type.BUILD, tile, building])


## One order for both, because changing either is the same manoeuvre. A width of 0
## means "whatever this formation naturally wants".
static func set_formation(ids: PackedInt32Array, shape: StringName, width: int) -> PackedByteArray:
	return var_to_bytes([VERSION, Type.SET_FORMATION, ids, shape, width])


## Shoot at that one. -1 hands the choice back to the regiment.
static func focus(ids: PackedInt32Array, mark: int) -> PackedByteArray:
	return var_to_bytes([VERSION, Type.FOCUS, ids, mark])


# --- decoding -------------------------------------------------------------

## Returns a validated order dictionary, or {} if these bytes are not an order.
static func decode(bytes: PackedByteArray) -> Dictionary:
	if bytes.size() < 4:
		return {}
	var d = bytes_to_var(bytes)
	if typeof(d) != TYPE_ARRAY or d.size() < 3:
		return {}
	if typeof(d[0]) != TYPE_INT or d[0] != VERSION:
		return {}
	if typeof(d[1]) != TYPE_INT:
		return {}
	match d[1]:
		Type.BATTLE_MOVE:
			return _decode_battle_move(d)
		Type.ARMY_MOVE:
			return _decode_army_move(d)
		Type.RECRUIT:
			return _decode_recruit(d)
		Type.READY:
			return _decode_ready(d)
		Type.BUILD:
			return _decode_build(d)
		Type.SET_FORMATION:
			return _decode_set_formation(d)
		Type.FOCUS:
			return _decode_focus(d)
	return {}


static func _decode_battle_move(d: Array) -> Dictionary:
	if d.size() != 5:
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
		"type": Type.BATTLE_MOVE,
		"ids": ids,
		"target": clamp_to_field(target),
		"facing": wrapf(facing, -PI, PI),
	}


static func _decode_army_move(d: Array) -> Dictionary:
	if d.size() != 4:
		return {}
	if typeof(d[2]) != TYPE_INT or typeof(d[3]) != TYPE_INT:
		return {}
	if not _is_tile(d[3]):
		return {}
	return {"type": Type.ARMY_MOVE, "army_id": d[2], "dest": d[3]}


static func _decode_recruit(d: Array) -> Dictionary:
	if d.size() != 4:
		return {}
	if typeof(d[2]) != TYPE_INT or not _is_tile(d[2]):
		return {}
	if typeof(d[3]) != TYPE_STRING_NAME or not Rules.KINDS.has(d[3]):
		return {}
	return {"type": Type.RECRUIT, "tile": d[2], "kind": d[3]}


static func _decode_ready(d: Array) -> Dictionary:
	if d.size() != 3 or typeof(d[2]) != TYPE_BOOL:
		return {}
	return {"type": Type.READY, "value": d[2]}


static func _decode_build(d: Array) -> Dictionary:
	if d.size() != 4:
		return {}
	if typeof(d[2]) != TYPE_INT or not _is_tile(d[2]):
		return {}
	if typeof(d[3]) != TYPE_STRING_NAME or not Rules.BUILDINGS.has(d[3]):
		return {}
	return {"type": Type.BUILD, "tile": d[2], "building": d[3]}


static func _decode_set_formation(d: Array) -> Dictionary:
	if d.size() != 5:
		return {}
	if typeof(d[2]) != TYPE_PACKED_INT32_ARRAY:
		return {}
	var ids: PackedInt32Array = d[2]
	if ids.is_empty() or ids.size() > MAX_IDS_PER_ORDER:
		return {}
	if typeof(d[3]) != TYPE_STRING_NAME or not Rules.FORMATIONS.has(d[3]):
		return {}
	if typeof(d[4]) != TYPE_INT or d[4] < 0 or d[4] > Rules.MAX_WIDTH:
		return {}
	return {"type": Type.SET_FORMATION, "ids": ids, "formation": d[3], "width": d[4]}


static func _decode_focus(d: Array) -> Dictionary:
	if d.size() != 4:
		return {}
	if typeof(d[2]) != TYPE_PACKED_INT32_ARRAY:
		return {}
	var ids: PackedInt32Array = d[2]
	if ids.is_empty() or ids.size() > MAX_IDS_PER_ORDER:
		return {}
	if typeof(d[3]) != TYPE_INT:
		return {}
	return {"type": Type.FOCUS, "ids": ids, "mark": d[3]}


static func _is_tile(i: int) -> bool:
	return i >= 0 and i < TILE_COUNT


## Orders land on the battlefield or not at all.
static func clamp_to_field(p: Vector2) -> Vector2:
	var e := Rules.BATTLE_HALF_EXTENT
	return Vector2(clampf(p.x, -e, e), clampf(p.y, -e, e))
