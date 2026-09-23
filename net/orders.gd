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
const CampaignState := preload("res://sim/campaign_state.gd")

const VERSION := 1
const MAX_IDS_PER_ORDER := 64          # a box selection, not a whole army list
const TILE_COUNT := Rules.MAP_W * Rules.MAP_H

## APPEND ONLY. These ints go on the wire and into saved .rpl files, so renumbering
## them silently reinterprets every recording ever made.
enum Type { BATTLE_MOVE, ARMY_MOVE, RECRUIT, READY, BUILD, SET_FORMATION, FOCUS, RAZE,
	RESEARCH, MERGE, SPLIT, FORFEIT, STANCE, FOUND, ARMY_STANCE, DEPLOYED, PROPOSE,
	ANSWER, PICK_CIV }


## The orders that change a BATTLE, and therefore the orders a recording has to keep.
##
## ONE list, because it was three: `net.gd` filtered what to record, `replay.gd` filtered
## what to apply on playback, and the two had to agree with each other and with reality.
## Adding DEPLOYED to the game and to neither of them produced a recording that replayed a
## battle which never left its deployment phase -- and `_keep_the_recording()` only warned,
## so it sat in a working tree while the gate printed PASS.
##
## FORFEIT is deliberately absent. It only FLAGS the battle and `net.gd::_process` ends it
## inside the tick loop; recording it would put that tick's orders in the closing snapshot
## while playback stops before applying them.
const CHANGES_A_BATTLE := [Type.BATTLE_MOVE, Type.SET_FORMATION, Type.FOCUS, Type.STANCE,
	Type.DEPLOYED]


# --- encoding -------------------------------------------------------------

static func battle_move(ids: PackedInt32Array, target: Vector2, facing: float) -> PackedByteArray:
	return var_to_bytes([VERSION, Type.BATTLE_MOVE, ids, target, facing])


static func army_move(army_id: int, dest_tile: int) -> PackedByteArray:
	return var_to_bytes([VERSION, Type.ARMY_MOVE, army_id, dest_tile])


static func recruit(tile: int, kind: StringName) -> PackedByteArray:
	return var_to_bytes([VERSION, Type.RECRUIT, tile, kind])


static func ready(value: bool) -> PackedByteArray:
	return var_to_bytes([VERSION, Type.READY, value])


## One order for everything you can put on a hex, since there is one catalogue now.
static func build(tile: int, structure: StringName) -> PackedByteArray:
	return var_to_bytes([VERSION, Type.BUILD, tile, structure])


static func raze(army_id: int) -> PackedByteArray:
	return var_to_bytes([VERSION, Type.RAZE, army_id])


## Put a town down where this army is standing. It carries no tile for the same reason
## RAZE does not: where the army is is the server's business, and a tile in the packet
## would be a second thing to validate against the first.
static func found(army_id: int) -> PackedByteArray:
	return var_to_bytes([VERSION, Type.FOUND, army_id])


## What an army does between turns -- march, force the march, dig in, lie in wait. A
## separate order from STANCE, which is a BATTLE regiment's posture and has always been
## a bitfield of something else entirely.
static func army_stance(army_id: int, stance: int) -> PackedByteArray:
	return var_to_bytes([VERSION, Type.ARMY_STANCE, army_id, stance])


## Done arranging the line; start the battle. Carries no seat -- which side said it is
## the sender, which the server takes from the peer id and never from the packet -- and a
## bool only because decode() refuses anything shorter than three elements.
static func deployed(confirm: bool) -> PackedByteArray:
	return var_to_bytes([VERSION, Type.DEPLOYED, confirm])


## Offer this seat peace, or -- if we are already at peace with them -- tell them it is
## over. Which seat is OFFERING is the sender, taken from the peer id and never from the
## packet, exactly as a forfeit is.
static func propose(to_seat: int) -> PackedByteArray:
	return var_to_bytes([VERSION, Type.PROPOSE, to_seat])


## Answer an offer. `from_seat` is who made it, so a stale answer to an offer somebody
## else made cannot be mistaken for this one.
static func answer(from_seat: int, accept: bool) -> PackedByteArray:
	return var_to_bytes([VERSION, Type.ANSWER, from_seat, accept])


## How these regiments behave when left alone: a mask of Regiment.Stance bits.
static func stance(ids: PackedInt32Array, mask: int) -> PackedByteArray:
	return var_to_bytes([VERSION, Type.STANCE, ids, mask])


## Give up the field. The payload is a confirm flag and carries no owner: which seat
## forfeited is the sender, which the server takes from the peer id and never from the
## packet. It also has to carry SOMETHING -- decode() refuses anything shorter than
## three elements before a type-specific decoder is ever reached.
static func forfeit(confirm: bool) -> PackedByteArray:
	return var_to_bytes([VERSION, Type.FORFEIT, confirm])


## Play as this people. A lobby order, refused once the campaign is dealt. It names a seat
## only so the host can choose for its AIs; whether the sender may speak for that seat is
## the server's business, like everything else about ownership.
static func pick_civ(seat: int, civ: StringName) -> PackedByteArray:
	return var_to_bytes([VERSION, Type.PICK_CIV, seat, civ])


static func research(tech: StringName) -> PackedByteArray:
	return var_to_bytes([VERSION, Type.RESEARCH, tech])


static func merge(army_id: int, into_id: int) -> PackedByteArray:
	return var_to_bytes([VERSION, Type.MERGE, army_id, into_id])


static func split(army_id: int, indices: PackedInt32Array, to_tile: int) -> PackedByteArray:
	return var_to_bytes([VERSION, Type.SPLIT, army_id, indices, to_tile])


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
		Type.RAZE:
			return _decode_raze(d)
		Type.RESEARCH:
			return _decode_research(d)
		Type.MERGE:
			return _decode_merge(d)
		Type.SPLIT:
			return _decode_split(d)
		Type.FORFEIT:
			return _decode_forfeit(d)
		Type.STANCE:
			return _decode_stance(d)
		Type.FOUND:
			return _decode_found(d)
		Type.ARMY_STANCE:
			return _decode_army_stance(d)
		Type.DEPLOYED:
			return _decode_deployed(d)
		Type.PROPOSE:
			return _decode_propose(d)
		Type.ANSWER:
			return _decode_answer(d)
		Type.PICK_CIV:
			return _decode_pick_civ(d)
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


static func _decode_stance(d: Array) -> Dictionary:
	if d.size() != 4 or typeof(d[2]) != TYPE_PACKED_INT32_ARRAY or typeof(d[3]) != TYPE_INT:
		return {}
	var ids: PackedInt32Array = d[2]
	if ids.is_empty() or ids.size() > MAX_IDS_PER_ORDER:
		return {}
	if d[3] < 0 or d[3] > 3:
		return {}                          # only the two bits that exist
	return {"type": Type.STANCE, "ids": ids, "mask": d[3]}


static func _decode_forfeit(d: Array) -> Dictionary:
	if d.size() != 3 or typeof(d[2]) != TYPE_BOOL:
		return {}
	return {"type": Type.FORFEIT, "confirm": d[2]}


static func _decode_build(d: Array) -> Dictionary:
	if d.size() != 4:
		return {}
	if typeof(d[2]) != TYPE_INT or not _is_tile(d[2]):
		return {}
	if typeof(d[3]) != TYPE_STRING_NAME or not Rules.STRUCTURES.has(d[3]):
		return {}
	return {"type": Type.BUILD, "tile": d[2], "structure": d[3]}


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


static func _decode_raze(d: Array) -> Dictionary:
	if d.size() != 3 or typeof(d[2]) != TYPE_INT:
		return {}
	return {"type": Type.RAZE, "army_id": d[2]}


static func _decode_found(d: Array) -> Dictionary:
	if d.size() != 3 or typeof(d[2]) != TYPE_INT:
		return {}
	return {"type": Type.FOUND, "army_id": d[2]}


static func _decode_propose(d: Array) -> Dictionary:
	if d.size() != 3 or typeof(d[2]) != TYPE_INT:
		return {}
	return {"type": Type.PROPOSE, "seat": d[2]}


static func _decode_answer(d: Array) -> Dictionary:
	if d.size() != 4 or typeof(d[2]) != TYPE_INT or typeof(d[3]) != TYPE_BOOL:
		return {}
	return {"type": Type.ANSWER, "seat": d[2], "accept": d[3]}


static func _decode_deployed(d: Array) -> Dictionary:
	if d.size() != 3 or typeof(d[2]) != TYPE_BOOL:
		return {}
	return {"type": Type.DEPLOYED, "confirm": d[2]}


static func _decode_army_stance(d: Array) -> Dictionary:
	if d.size() != 4 or typeof(d[2]) != TYPE_INT or typeof(d[3]) != TYPE_INT:
		return {}
	# Range-checked here as well as in the sim: an unknown stance int would be stored on
	# the army and go straight back out on the wire to everybody.
	if d[3] < 0 or d[3] > CampaignState.Stance.BESIEGE:
		return {}
	return {"type": Type.ARMY_STANCE, "army_id": d[2], "stance": d[3]}


static func _decode_merge(d: Array) -> Dictionary:
	if d.size() != 4 or typeof(d[2]) != TYPE_INT or typeof(d[3]) != TYPE_INT:
		return {}
	if d[2] == d[3]:
		return {}
	return {"type": Type.MERGE, "army_id": d[2], "into_id": d[3]}


static func _decode_split(d: Array) -> Dictionary:
	if d.size() != 5 or typeof(d[2]) != TYPE_INT:
		return {}
	if typeof(d[3]) != TYPE_PACKED_INT32_ARRAY:
		return {}
	var indices: PackedInt32Array = d[3]
	if indices.is_empty() or indices.size() > MAX_IDS_PER_ORDER:
		return {}
	if typeof(d[4]) != TYPE_INT or not _is_tile(d[4]):
		return {}
	return {"type": Type.SPLIT, "army_id": d[2], "indices": indices, "to_tile": d[4]}


static func _decode_research(d: Array) -> Dictionary:
	if d.size() != 3 or typeof(d[2]) != TYPE_STRING_NAME:
		return {}
	if not Rules.TECHS.has(d[2]):
		return {}
	return {"type": Type.RESEARCH, "tech": d[2]}


static func _decode_pick_civ(d: Array) -> Dictionary:
	if d.size() != 4 or typeof(d[2]) != TYPE_INT or typeof(d[3]) != TYPE_STRING_NAME:
		return {}
	if not Rules.CIVS.has(d[3]):
		return {}
	return {"type": Type.PICK_CIV, "seat": d[2], "civ": d[3]}


static func _is_tile(i: int) -> bool:
	return i >= 0 and i < TILE_COUNT


## Orders land on the battlefield or not at all.
static func clamp_to_field(p: Vector2) -> Vector2:
	var e := Rules.BATTLE_HALF_EXTENT
	return Vector2(clampf(p.x, -e, e), clampf(p.y, -e, e))
