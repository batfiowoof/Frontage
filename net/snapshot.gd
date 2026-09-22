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

const VERSION := 10

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
	["defense", TYPE_FLOAT],
	["state", TYPE_INT],
	["target", TYPE_VECTOR2],
	["target_facing", TYPE_FLOAT],
	["engaged_with", TYPE_INT],
	# Who this regiment was told to deal with, or -1. It was server-side only while it
	# steered nothing but arrows; now that it also decides melee and sends a regiment
	# across the field, the client has to be able to draw the line from the unit to the
	# enemy it is going for, or an order you gave is invisible until it lands.
	["focus", TYPE_INT],
	["stance", TYPE_INT],
	# How many times it has broken. On the wire because a SHATTERED regiment is drawn with
	# no banner at all, and a client cannot derive "it has run three times" from anything
	# else it holds -- morale and state both look the same on the third rout as the first.
	["routs", TYPE_INT],
	# Men killed, carried in from the campaign and back out again. On the wire because a
	# replay rebuilds the fight from the opening snapshot, so anything the sim reads to
	# decide the outcome has to be in it.
	["xp", TYPE_INT],
]


static func encode_battle(bs) -> PackedByteArray:
	var rows := []
	for id in bs.sorted_ids():
		var r = bs.regiments[id]
		var row := []
		for field in REGIMENT_FIELDS:
			row.append(r.get(field[0]))
		rows.append(row)
	return var_to_bytes([VERSION, bs.tick, bs._next_id, rows, bs.features, bs.techs,
		bs.renown, bs.phase, bs.ready, bs.walls])


## Returns a BattleState, or null if the bytes are not a snapshot we understand.
static func decode_battle(bytes: PackedByteArray):
	if bytes.size() < 4:
		return null                         # too short for bytes_to_var to even look at
	var data = bytes_to_var(bytes)          # never _with_objects: that is remote code execution
	if typeof(data) != TYPE_ARRAY or data.size() != 10:
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

	if typeof(data[4]) != TYPE_ARRAY or data[4].size() > Rules.MAX_FEATURES:
		return null
	for f in data[4]:
		if typeof(f) != TYPE_ARRAY or f.size() != 4:
			return null
		if typeof(f[0]) != TYPE_INT or not Rules.GROUND.has(f[0]):
			return null
		for i in range(1, 4):
			if typeof(f[i]) != TYPE_FLOAT or not is_finite(f[i]):
				return null
		if f[3] <= 0.0 or f[3] > Rules.BATTLE_HALF_EXTENT:
			return null
	bs.features = data[4]

	if typeof(data[5]) != TYPE_DICTIONARY:
		return null
	for owner in data[5]:
		if typeof(owner) != TYPE_INT or typeof(data[5][owner]) != TYPE_ARRAY:
			return null
		if data[5][owner].size() > Rules.TECHS.size():
			return null
		for name in data[5][owner]:
			if typeof(name) != TYPE_STRING_NAME or not Rules.TECHS.has(name):
				return null
	bs.techs = data[5]

	# What each side's commander is worth. Clamped, not merely typed: it divides a morale
	# drain, so a peer that could name it could make its army unbreakable.
	if typeof(data[6]) != TYPE_DICTIONARY:
		return null
	for owner in data[6]:
		if typeof(owner) != TYPE_INT:
			return null
		var worth = data[6][owner]
		if typeof(worth) != TYPE_FLOAT and typeof(worth) != TYPE_INT:
			return null
		if not is_finite(float(worth)) or worth < 1.0 or worth > Rules.RENOWN_BEST:
			return null
	bs.renown = data[6]

	# Whether the line is still being arranged, and who has said they are done. On the
	# wire and not derived: a client has to know not to draw a fight that is not
	# happening yet, and a replay has to reopen in the phase it was recorded in.
	if typeof(data[7]) != TYPE_INT or data[7] < 0 or data[7] > BattleState.Phase.FIGHT:
		return null
	bs.phase = data[7]
	if typeof(data[8]) != TYPE_DICTIONARY:
		return null
	for owner in data[8]:
		if typeof(owner) != TYPE_INT or typeof(data[8][owner]) != TYPE_BOOL:
			return null
	bs.ready = data[8]

	# The town's walls. On the wire beside the ground for the same reason: a replay
	# rebuilds the fight from its opening snapshot, and a battle fought through a gate is
	# a completely different battle from one fought in the open.
	if typeof(data[9]) != TYPE_ARRAY or data[9].size() > Rules.MAX_FEATURES:
		return null
	for w in data[9]:
		if typeof(w) != TYPE_ARRAY or w.size() != 5:
			return null
		for i in 4:
			if typeof(w[i]) != TYPE_FLOAT and typeof(w[i]) != TYPE_INT:
				return null
			if not is_finite(float(w[i])) or absf(float(w[i])) > Rules.BATTLE_HALF_EXTENT:
				return null
		if typeof(w[4]) != TYPE_FLOAT and typeof(w[4]) != TYPE_INT:
			return null
		if not is_finite(float(w[4])) or w[4] < 0.0 or w[4] > 1.0:
			return null
	bs.walls = data[9]

	# Derived, not decoded. Who carries the general falls out of max_strength and the
	# ids, which are already in the rows above, so the mirror reaches the same answer
	# the server did without a byte on the wire for it.
	bs.commission_generals()
	return bs


# --- campaign -------------------------------------------------------------
# Turn-based, so a full snapshot per change is cheap and there is nothing to
# interpolate. Flat rows rather than dictionaries: a row of known length and known
# types is something decode can actually check.

## `for_owner` of 0 is omniscient -- the true world, which is what a save stores and what
## a test asks for. With a real owner the snapshot is sliced to what that player may know:
## armies it cannot see are left out entirely, and structures it has not found are blanked.
##
## Left whole on purpose, and this is the ceiling rather than an oversight:
## ponytail: terrain and settlement ownership go out unfiltered. Terrain is static and
## identical for everyone from map generation, and settlements are landmarks the way they
## are in Total War. The upgrade is a remembered per-owner copy carrying a STALE owner id,
## so a town that changed hands behind the fog still reads as its old holder.
static func encode_campaign(cs, for_owner := 0) -> PackedByteArray:
	var settlements := []
	for s in cs.settlements:
		settlements.append([s["tile"], s["owner"], s["name"],
			CampaignState.pop_of(s), CampaignState.unrest_of(s)])
	var armies := []
	var known_armies: Array = cs.armies.values() if for_owner == 0 		else cs.armies_visible_to(for_owner)
	for a in known_armies:
		armies.append([a["id"], a["owner"], a["tile"], a["move_left"], a["regiments"],
			CampaignState.stance_of(a), CampaignState.renown_of(a)])
	armies.sort_custom(func(x, y): return x[0] < y[0])
	var structures: PackedByteArray = cs.structures
	if for_owner != 0:
		structures = structures.duplicate()
		for tile in structures.size():
			if not cs.can_see(for_owner, tile):
				structures[tile] = 0
	# The fog memory, always as a dictionary so decode has one shape to check. A save
	# stores the whole book; a player is sent its own single row and nobody else's, which
	# is the whole of what fog is for.
	var memory := {}
	if for_owner == 0:
		memory = cs.seen
	elif cs.seen.has(for_owner):
		memory[for_owner] = cs.seen[for_owner]
	return var_to_bytes([
		VERSION, cs.turn, cs._next_army, cs.terrain,
		settlements, armies, cs.gold, cs.food, cs.ready, structures,
		cs.research, cs.known, memory,
	])


static func decode_campaign(bytes: PackedByteArray):
	if bytes.size() < 4:
		return null
	var d = bytes_to_var(bytes)
	if typeof(d) != TYPE_ARRAY or d.size() != 13:
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
		if typeof(row) != TYPE_ARRAY or row.size() != 5:
			return null
		if typeof(row[0]) != TYPE_INT or typeof(row[1]) != TYPE_INT or typeof(row[2]) != TYPE_STRING:
			return null
		if not _is_tile(row[0]):
			return null
		# Both clamped, not merely typed: population multiplies a town's output and
		# unrest divides it, so a peer that could name either could name its income.
		if typeof(row[3]) != TYPE_INT or row[3] < 1 or row[3] > Rules.MAX_POP:
			return null
		if typeof(row[4]) != TYPE_INT or row[4] < 0 or row[4] > Rules.UNREST_REVOLT:
			return null
		cs.settlements.append({"tile": row[0], "owner": row[1], "name": row[2],
			"pop": row[3], "unrest": row[4]})

	for row in d[5]:
		if typeof(row) != TYPE_ARRAY or row.size() != 7:
			return null
		for i in 4:
			if typeof(row[i]) != TYPE_INT:
				return null
		if typeof(row[5]) != TYPE_INT or row[5] < 0 or row[5] > CampaignState.Stance.BESIEGE:
			return null
		if typeof(row[6]) != TYPE_INT or row[6] < 0 or row[6] > Rules.RENOWN_WINS:
			return null
		if not _is_tile(row[2]):
			return null
		if typeof(row[4]) != TYPE_ARRAY or row[4].size() > CampaignState.MAX_REGIMENTS_PER_ARMY:
			return null
		for entry in row[4]:
			# [kind, strength, xp], all three checked: a regiment with a negative or
			# absurd strength would make the next battle nonsense, and an uncapped xp
			# would hand a peer an arbitrary damage multiplier for the asking.
			if typeof(entry) != TYPE_ARRAY or entry.size() != 3:
				return null
			if typeof(entry[0]) != TYPE_STRING_NAME or not Rules.KINDS.has(entry[0]):
				return null
			if typeof(entry[1]) != TYPE_INT or typeof(entry[2]) != TYPE_INT:
				return null
			if entry[1] < 0 or entry[1] > int(Rules.KINDS[entry[0]]["strength"]):
				return null
			if entry[2] < 0:
				return null
		if cs.armies.has(row[0]):
			return null                     # duplicate ids would silently drop an army
		cs.armies[row[0]] = {
			"id": row[0], "owner": row[1], "tile": row[2],
			"move_left": row[3], "stance": row[5], "renown": row[6],
			"regiments": row[4],
		}

	var purse = _int_map(d[6])
	var larder = _int_map(d[7])
	var flags = _bool_map(d[8])
	if purse == null or larder == null or flags == null:
		return null
	if typeof(d[9]) != TYPE_PACKED_BYTE_ARRAY or d[9].size() != cs.terrain.size():
		return null
	for code in d[9]:
		if code > Rules.STRUCTURES.size():
			return null                    # a structure nobody has heard of
	var pool = _int_map(d[10])
	if pool == null:
		return null
	if typeof(d[11]) != TYPE_DICTIONARY:
		return null
	for owner in d[11]:
		if typeof(owner) != TYPE_INT or typeof(d[11][owner]) != TYPE_ARRAY:
			return null
		if d[11][owner].size() > Rules.TECHS.size():
			return null
		var seen := {}
		for name in d[11][owner]:
			if typeof(name) != TYPE_STRING_NAME or not Rules.TECHS.has(name) or seen.has(name):
				return null    # learning the same thing twice would compound its effect
			seen[name] = true
	# The fog memory. An empty book is legitimate and means nobody has looked yet, which
	# is what every campaign built by hand in a test looks like; `can_see` reads that as
	# omniscient, so fog is something a campaign acquires and never a default.
	if typeof(d[12]) != TYPE_DICTIONARY:
		return null
	for owner in d[12]:
		if typeof(owner) != TYPE_INT or typeof(d[12][owner]) != TYPE_PACKED_BYTE_ARRAY:
			return null
		if d[12][owner].size() != cs.terrain.size():
			return null
	cs.seen = d[12]
	cs.structures = d[9]
	cs.research = pool
	cs.known = d[11]
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
