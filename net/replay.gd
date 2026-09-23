extends RefCounted
## A battle, reproducible.
##
## The sim is pure, fixed-tick and has no randomness in it -- `test_combat.gd` asserts that
## the same fight replays identically -- so a recording is only the state the battle was
## dealt from plus the orders, each stamped with the tick it was applied on. A few hundred
## bytes for a whole battle, and a near-free consequence of decisions already made.
##
## This is the honest way to tune how a fight feels: replay the exact same battle, change
## one constant in `rules.gd`, and watch what it does to it. It doubles as a regression
## format that catches balance changes no unit test would think to look for.

const Snapshot := preload("res://net/snapshot.gd")
const Orders := preload("res://net/orders.gd")
const BattleState := preload("res://sim/battle_state.gd")

const VERSION := 1
const FOLDER := "user://replays"
## A long battle is a few hundred orders. This is a guard against a corrupt file
## claiming to hold millions, not a design limit.
const MAX_ORDERS := 200000

var opening := PackedByteArray()      # the battle as it was dealt
var orders := []                      # [[tick, sender, bytes], ...] in the order given
var closing := PackedByteArray()      # the battle as it ended, for verification
var ticks := 0


func begin(bytes: PackedByteArray) -> void:
	opening = bytes
	orders = []
	closing = PackedByteArray()
	ticks = 0


func note(tick: int, sender: int, bytes: PackedByteArray) -> void:
	if opening.is_empty() or orders.size() >= MAX_ORDERS:
		return
	orders.append([tick, sender, bytes])


func finish(bytes: PackedByteArray, tick: int) -> void:
	closing = bytes
	ticks = tick


func recording() -> bool:
	return not opening.is_empty()


# --- replaying ------------------------------------------------------------

## Orders grouped by the tick they were applied on, which is how playback feeds them.
func by_tick() -> Dictionary:
	var out := {}
	for row: Array in orders:
		var t: int = row[0]
		if not out.has(t):
			out[t] = []
		out[t].append(row)
	return out


## Re-run the recording and hand back the state it ends in, or null if it will not load.
func replay():
	var bs = Snapshot.decode_battle(opening)
	if bs == null:
		return null
	var schedule := by_tick()
	while bs.tick < ticks:
		for row: Array in schedule.get(bs.tick, []):
			apply_order(bs, row[1], row[2])
		bs.step()
	return bs


## The same ownership check the server makes. A replay that let through an order the
## server refused would diverge the moment anybody tried to cheat.
static func apply_order(bs, sender: int, bytes: PackedByteArray) -> void:
	var order := Orders.decode(bytes)
	if order.is_empty():
		return
	var kind: int = order["type"]
	# Saying the line is arranged carries no regiment ids at all, so it is answered
	# here, before the loop below reaches for them. Leaving it out of this list was a
	# replay that never left the deployment phase: it sat there for every recorded
	# tick while the real battle fought them, and verify() compared two battles.
	if kind == Orders.Type.DEPLOYED:
		bs.say_ready(sender)
		return
	if not Orders.CHANGES_A_BATTLE.has(kind):
		return
	for id in order["ids"]:
		var r = bs.get_regiment(id)
		if r == null or r.owner_id != sender:
			continue
		if kind == Orders.Type.BATTLE_MOVE:
			# `steer` and not `order_move`: before the fight starts the same order
			# PLACES the regiment, and the server applied it that way when it
			# recorded. One branch, in the sim, for the live path and this one.
			bs.steer(r, order["target"], order["facing"])
		elif kind == Orders.Type.FOCUS:
			bs.aim(r, int(order["mark"]))
		elif kind == Orders.Type.STANCE:
			r.stance = int(order["mask"])
		elif not r.set_formation(order["formation"]) and int(order["width"]) > 0:
			r.set_width(int(order["width"]))


## Does this recording still produce the battle it recorded? False after a rules change
## is not a bug -- it is the whole point of keeping the file.
func verify() -> bool:
	var bs = replay()
	return bs != null and Snapshot.encode_battle(bs) == closing


# --- storage --------------------------------------------------------------

func to_bytes() -> PackedByteArray:
	return var_to_bytes([VERSION, opening, orders, closing, ticks])


## A file is not the network, but it is still something that arrives from outside the
## program, so it gets checked the same way a snapshot does.
static func from_bytes(data: PackedByteArray):
	if data.size() < 4:
		return null
	var d = bytes_to_var(data)
	if typeof(d) != TYPE_ARRAY or d.size() != 5:
		return null
	if typeof(d[0]) != TYPE_INT or d[0] != VERSION:
		return null
	if typeof(d[1]) != TYPE_PACKED_BYTE_ARRAY or typeof(d[3]) != TYPE_PACKED_BYTE_ARRAY:
		return null
	if typeof(d[2]) != TYPE_ARRAY or typeof(d[4]) != TYPE_INT:
		return null
	if d[4] < 0 or d[2].size() > MAX_ORDERS:
		return null
	for row in d[2]:
		if typeof(row) != TYPE_ARRAY or row.size() != 3:
			return null
		if typeof(row[0]) != TYPE_INT or typeof(row[1]) != TYPE_INT:
			return null
		if typeof(row[2]) != TYPE_PACKED_BYTE_ARRAY:
			return null
		if row[0] < 0 or row[0] > d[4]:
			return null

	var r = new()
	r.opening = d[1]
	r.orders = d[2]
	r.closing = d[3]
	r.ticks = d[4]
	return r


func save(path := "") -> String:
	if not recording():
		return ""
	if path.is_empty():
		path = "%s/battle_%d.rpl" % [FOLDER, Time.get_unix_time_from_system()]
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		push_warning("[replay] could not write %s" % path)
		return ""
	f.store_buffer(to_bytes())
	f.close()
	return path


static func load_from(path: String):
	if not FileAccess.file_exists(path):
		return null
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return null
	var data := f.get_buffer(f.get_length())
	f.close()
	return from_bytes(data)
