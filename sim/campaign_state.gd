extends RefCounted
## The campaign world: terrain, settlements, armies, treasuries.
##
## Orders apply immediately on the server (Civ-style) rather than being queued and
## resolved at end of turn. Simultaneous turns then need no ordering rule between
## players, no deferred-order determinism, and the player sees their gold move when
## they click. End Turn only does the bookkeeping: income, upkeep, move points.

const Rules := preload("res://sim/rules.gd")

enum Terrain { PLAINS, FOREST, MOUNTAIN }

const MAX_REGIMENTS_PER_ARMY := 8

var turn := 1
var terrain := PackedByteArray()
var settlements := []              # [{tile:int, owner:int, name:String}]
var armies := {}                   # id -> {id, owner, tile, move_left, regiments:Array}
                                   # a regiment is [kind, strength]
var gold := {}                     # owner -> int
var food := {}                     # owner -> int
var ready := {}                    # owner -> bool
var _next_army := 1


# --- tile helpers ---------------------------------------------------------

static func idx(x: int, y: int) -> int:
	return y * Rules.MAP_W + x


static func tile_x(i: int) -> int:
	return i % Rules.MAP_W


static func tile_y(i: int) -> int:
	return i / Rules.MAP_W


static func in_bounds(x: int, y: int) -> bool:
	return x >= 0 and y >= 0 and x < Rules.MAP_W and y < Rules.MAP_H


func passable(i: int) -> bool:
	return i >= 0 and i < terrain.size() and terrain[i] != Terrain.MOUNTAIN


func neighbours(i: int) -> PackedInt32Array:
	var out := PackedInt32Array()
	var x := tile_x(i)
	var y := tile_y(i)
	for d: Vector2i in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
		var nx := x + d.x
		var ny := y + d.y
		if in_bounds(nx, ny) and passable(idx(nx, ny)):
			out.append(idx(nx, ny))
	return out


## Shortest passable route, excluding `from`, or empty if there is none.
## Breadth-first rather than a greedy step: greedy walks into mountain pockets and
## sulks there, and the map is 384 tiles, so correctness is free.
func path(from: int, to: int) -> PackedInt32Array:
	if from == to or not passable(to) or not passable(from):
		return PackedInt32Array()
	var came := {from: -1}
	var queue := [from]
	var head := 0
	var found := false
	while head < queue.size():
		var cur: int = queue[head]
		head += 1
		if cur == to:
			found = true
			break
		for n in neighbours(cur):
			if not came.has(n):
				came[n] = cur
				queue.append(n)
	if not found:
		return PackedInt32Array()
	var route := PackedInt32Array()
	var step := to
	while step != from:
		route.append(step)
		step = came[step]
	route.reverse()
	return route


# --- queries --------------------------------------------------------------

func army_at(tile: int) -> Variant:
	for a in armies.values():
		if a["tile"] == tile:
			return a
	return null


func settlement_at(tile: int) -> Variant:
	for s in settlements:
		if s["tile"] == tile:
			return s
	return null


func settlements_of(owner: int) -> int:
	var n := 0
	for s in settlements:
		if s["owner"] == owner:
			n += 1
	return n


## A campaign regiment is [kind, strength] -- the men it has right now, not merely
## what kind of men they are. Carrying only the kind would hand a regiment cut down
## to five men back to the campaign at full strength, and a battle that costs nothing
## is a battle that decides nothing.
static func make_regiment(kind: StringName) -> Array:
	return [kind, int(Rules.KINDS[kind]["strength"])]


static func army_men(a: Dictionary) -> int:
	var total := 0
	for r: Array in a["regiments"]:
		total += int(r[1])
	return total


func men_of(owner: int) -> int:
	var total := 0
	for a in armies.values():
		if a["owner"] == owner:
			total += army_men(a)
	return total


func upkeep_of(owner: int) -> int:
	var total := 0
	for a in armies.values():
		if a["owner"] == owner:
			for r: Array in a["regiments"]:
				total += int(Rules.KINDS[r[0]]["upkeep"])
	return total


## A player with no settlements and no armies is out of the game.
func is_alive(owner: int) -> bool:
	if settlements_of(owner) > 0:
		return true
	for a in armies.values():
		if a["owner"] == owner:
			return true
	return false


func sorted_army_ids() -> Array:
	var ids := armies.keys()
	ids.sort()
	return ids


# --- actions (server side; authority is checked before we get here) -------

func add_army(owner: int, tile: int, kinds: Array) -> Dictionary:
	var raised := []
	for kind: StringName in kinds:
		raised.append(make_regiment(kind))
	var a := {
		"id": _next_army,
		"owner": owner,
		"tile": tile,
		"move_left": Rules.ARMY_MOVE_POINTS,
		"regiments": raised,
	}
	_next_army += 1
	armies[a["id"]] = a
	return a


## Walk an army toward `dest`, spending one move point per tile.
## Returns {"moved": n, "collision": [mover_id, defender_id]}. A collision is the
## campaign's whole reason to exist, so it is a return value, not a side effect.
func move_army(army_id: int, dest: int) -> Dictionary:
	var result := {"moved": 0, "collision": []}
	var a = armies.get(army_id)
	if a == null or a["move_left"] <= 0 or not passable(dest):
		return result
	var route := path(a["tile"], dest)
	if route.is_empty():
		return result

	for step in route:
		if a["move_left"] <= 0:
			break
		var blocker = army_at(step)
		if blocker != null:
			if blocker["owner"] == a["owner"]:
				break                              # a friendly army blocks the road
			a["move_left"] -= 1
			result["collision"] = [army_id, blocker["id"]]
			return result                          # stop on contact; a battle decides the tile
		a["tile"] = step
		a["move_left"] -= 1
		result["moved"] += 1
		_capture_if_undefended(a)
	return result


func _capture_if_undefended(a: Dictionary) -> void:
	var s = settlement_at(a["tile"])
	if s != null and s["owner"] != a["owner"]:
		s["owner"] = a["owner"]


func recruit(owner: int, tile: int, kind: StringName) -> bool:
	if not Rules.KINDS.has(kind):
		return false
	var s = settlement_at(tile)
	if s == null or s["owner"] != owner:
		return false
	var cost := int(Rules.KINDS[kind]["cost"])
	if int(gold.get(owner, 0)) < cost:
		return false
	var a = army_at(tile)
	if a != null and a["owner"] != owner:
		return false
	if a != null and a["regiments"].size() >= MAX_REGIMENTS_PER_ARMY:
		return false
	if a == null:
		a = add_army(owner, tile, [])
	gold[owner] = int(gold[owner]) - cost
	a["regiments"].append(make_regiment(kind))
	return true


func disband_if_empty(army_id: int) -> void:
	var a = armies.get(army_id)
	if a != null and a["regiments"].is_empty():
		armies.erase(army_id)


# --- turn bookkeeping -----------------------------------------------------

func set_ready(owner: int, value: bool) -> void:
	ready[owner] = value


func all_ready(owners: Array) -> bool:
	if owners.is_empty():
		return false
	for o in owners:
		if not bool(ready.get(o, false)):
			return false
	return true


func end_turn() -> void:
	for owner in gold.keys():
		gold[owner] = int(gold[owner]) + settlements_of(owner) * Rules.SETTLEMENT_GOLD
		var net_food := settlements_of(owner) * Rules.SETTLEMENT_FOOD - upkeep_of(owner)
		# ponytail: food floors at zero instead of starving the army. Add attrition
		# when the player has a reason to care about running out.
		food[owner] = maxi(0, int(food.get(owner, 0)) + net_food)
	for a in armies.values():
		a["move_left"] = Rules.ARMY_MOVE_POINTS
		_reinforce(a)
	ready.clear()
	turn += 1


## An army resting in one of its own settlements fills its ranks back up.
func _reinforce(a: Dictionary) -> void:
	var s = settlement_at(a["tile"])
	if s == null or s["owner"] != a["owner"]:
		return
	for r: Array in a["regiments"]:
		r[1] = mini(int(Rules.KINDS[r[0]]["strength"]), int(r[1]) + Rules.REINFORCE_PER_TURN)


# --- generation -----------------------------------------------------------

## Deterministic from `map_seed`. Clients receive the map in the snapshot rather than
## regenerating it, but a reproducible map is worth a great deal when debugging.
static func generate(owner_ids: Array, map_seed: int):
	var cs = new()
	var rng := RandomNumberGenerator.new()
	rng.seed = map_seed

	var ground := PackedByteArray()
	ground.resize(Rules.MAP_W * Rules.MAP_H)
	for i in ground.size():
		var roll := rng.randf()
		ground[i] = Terrain.MOUNTAIN if roll < 0.10 else (Terrain.FOREST if roll < 0.32 else Terrain.PLAINS)

	# Capitals sit inset from the corners so nobody starts wedged against an edge.
	var spots := [
		Vector2i(3, 3),
		Vector2i(Rules.MAP_W - 4, Rules.MAP_H - 4),
		Vector2i(Rules.MAP_W - 4, 3),
		Vector2i(3, Rules.MAP_H - 4),
	]
	var towns := []
	var purse := {}
	var larder := {}
	for n in owner_ids.size():
		var owner: int = owner_ids[n]
		var spot: Vector2i = spots[n % spots.size()]
		var tile := idx(spot.x, spot.y)
		ground[tile] = Terrain.PLAINS
		for nb: int in [tile - 1, tile + 1, tile - Rules.MAP_W, tile + Rules.MAP_W]:
			if nb >= 0 and nb < ground.size():
				ground[nb] = Terrain.PLAINS              # never wall a capital in
		towns.append({"tile": tile, "owner": owner, "name": "Capital %d" % (n + 1)})
		purse[owner] = Rules.START_GOLD
		larder[owner] = Rules.START_FOOD

	# Neutral towns worth marching for, down the middle of the map.
	for k in 4:
		var x := int(round((k + 1) * Rules.MAP_W / 5.0))
		var y := int(Rules.MAP_H / 2) + (2 if k % 2 == 0 else -2)
		var tile := idx(x, y)
		ground[tile] = Terrain.PLAINS
		var taken := false
		for s: Dictionary in towns:
			if s["tile"] == tile:
				taken = true
		if not taken:
			towns.append({"tile": tile, "owner": 0, "name": "Town %d" % (k + 1)})

	cs.terrain = ground
	cs.settlements = towns
	cs.gold = purse
	cs.food = larder
	for n in owner_ids.size():
		cs.add_army(owner_ids[n], towns[n]["tile"], [&"spear", &"spear", &"archer"])
	return cs
