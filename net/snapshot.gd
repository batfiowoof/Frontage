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
const CampaignState := preload("res://sim/campaign_state.gd")
const Rules := preload("res://sim/rules.gd")

const VERSION := 4

## Field order on the wire.  Add a field here and the round-trip test covers it.
const REGIMENT_FIELDS := [
	["id", TYPE_INT],
	["owner_id", TYPE_INT],
	["kind", TYPE_STRING_NAME],
	["strength", TYPE_INT],
	["max_strength", TYPE_INT],
	["morale", TYPE_FLOAT],
	["stamina", TYPE_FLOAT],
	["pos", TYPE_VECTOR2],
	["facing", TYPE_FLOAT],
	["width", TYPE_INT],
	["formation", TYPE_STRING_NAME],
	["reforming", TYPE_FLOAT],
	["ammo", TYPE_INT],
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
			if field[0] == "formation" and not Rules.FORMATIONS.has(row[i]):
				return null
			if field[0] == "width" and (row[i] < 1 or row[i] > Rules.MAX_WIDTH):
				return null
			r.set(field[0], row[i])
		if bs.regiments.has(r.id):
			return null                     # duplicate ids would silently drop a regiment
		bs.regiments[r.id] = r
	return bs


# --- campaign -------------------------------------------------------------
# Turn-based, so a full snapshot per change is cheap and there is nothing to
# interpolate. Flat rows rather than dictionaries: a row of known length and known
# types is something decode can actually check.

static func encode_campaign(cs) -> PackedByteArray:
	var settlements := []
	for s in cs.settlements:
		settlements.append([s["tile"], s["owner"], s["name"], s["buildings"]])
	var armies := []
	for id in cs.sorted_army_ids():
		var a = cs.armies[id]
		armies.append([a["id"], a["owner"], a["tile"], a["move_left"], a["regiments"]])
	return var_to_bytes([
		VERSION, cs.turn, cs._next_army, cs.terrain,
		settlements, armies, cs.gold, cs.food, cs.ready, cs.improvements,
	])


static func decode_campaign(bytes: PackedByteArray):
	if bytes.size() < 4:
		return null
	var d = bytes_to_var(bytes)
	if typeof(d) != TYPE_ARRAY or d.size() != 10:
		return null
	if typeof(d[0]) != TYPE_INT or d[0] != VERSION:
		return null
	if typeof(d[1]) != TYPE_INT or typeof(d[2]) != TYPE_INT:
		return null
	if typeof(d[3]) != TYPE_PACKED_BYTE_ARRAY or d[3].size() != Rules.MAP_W * Rules.MAP_H:
		return null
	if typeof(d[4]) != TYPE_ARRAY or typeof(d[5]) != TYPE_ARRAY:
		return null

	var cs = CampaignState.new()
	cs.turn = d[1]
	cs._next_army = d[2]
	cs.terrain = d[3]
	for t in cs.terrain:
		if t >= CampaignState.Terrain.size():
			return null

	for row in d[4]:
		if typeof(row) != TYPE_ARRAY or row.size() != 4:
			return null
		if typeof(row[0]) != TYPE_INT or typeof(row[1]) != TYPE_INT or typeof(row[2]) != TYPE_STRING:
			return null
		if not _is_tile(row[0]):
			return null
		if typeof(row[3]) != TYPE_ARRAY or row[3].size() > Rules.BUILDINGS.size():
			return null
		var seen := {}
		for b in row[3]:
			if typeof(b) != TYPE_STRING_NAME or not Rules.BUILDINGS.has(b):
				return null
			if seen.has(b):
				return null           # one of each, or income doubles for free
			seen[b] = true
		cs.settlements.append({"tile": row[0], "owner": row[1], "name": row[2], "buildings": row[3]})

	for row in d[5]:
		if typeof(row) != TYPE_ARRAY or row.size() != 5:
			return null
		for i in 4:
			if typeof(row[i]) != TYPE_INT:
				return null
		if not _is_tile(row[2]):
			return null
		if typeof(row[4]) != TYPE_ARRAY or row[4].size() > CampaignState.MAX_REGIMENTS_PER_ARMY:
			return null
		for entry in row[4]:
			# [kind, strength], both checked: a regiment with a negative or absurd
			# strength would make the next battle nonsense.
			if typeof(entry) != TYPE_ARRAY or entry.size() != 2:
				return null
			if typeof(entry[0]) != TYPE_STRING_NAME or not Rules.KINDS.has(entry[0]):
				return null
			if typeof(entry[1]) != TYPE_INT:
				return null
			if entry[1] < 0 or entry[1] > int(Rules.KINDS[entry[0]]["strength"]):
				return null
		if cs.armies.has(row[0]):
			return null                     # duplicate ids would silently drop an army
		cs.armies[row[0]] = {
			"id": row[0], "owner": row[1], "tile": row[2],
			"move_left": row[3], "regiments": row[4],
		}

	var purse = _int_map(d[6])
	var larder = _int_map(d[7])
	var flags = _bool_map(d[8])
	if purse == null or larder == null or flags == null:
		return null
	if typeof(d[9]) != TYPE_PACKED_BYTE_ARRAY or d[9].size() != cs.terrain.size():
		return null
	for code in d[9]:
		if code > Rules.IMPROVEMENTS.size():
			return null                    # an improvement nobody has heard of
	cs.improvements = d[9]
	cs.gold = purse
	cs.food = larder
	cs.ready = flags
	return cs


static func _is_tile(i: int) -> bool:
	return i >= 0 and i < Rules.MAP_W * Rules.MAP_H


static func _int_map(v):
	if typeof(v) != TYPE_DICTIONARY:
		return null
	for k in v:
		if typeof(k) != TYPE_INT or typeof(v[k]) != TYPE_INT:
			return null
	return v


static func _bool_map(v):
	if typeof(v) != TYPE_DICTIONARY:
		return null
	for k in v:
		if typeof(k) != TYPE_INT or typeof(v[k]) != TYPE_BOOL:
			return null
	return v
