extends RefCounted
## The campaign world: terrain, settlements, armies, treasuries.
##
## Orders apply immediately on the server (Civ-style) rather than being queued and
## resolved at end of turn. Simultaneous turns then need no ordering rule between
## players, no deferred-order determinism, and the player sees their gold move when
## they click. End Turn only does the bookkeeping: income, upkeep, move points.

const Rules := preload("res://sim/rules.gd")

enum Terrain { PLAINS, FOREST, MOUNTAIN, HILLS, WATER }

const MAX_REGIMENTS_PER_ARMY := 8

var turn := 1
var terrain := PackedByteArray()
var improvements := PackedByteArray()   # parallel to terrain, a name from Rules.IMPROVEMENTS
var settlements := []              # [{tile:int, owner:int, name:String, buildings:Array}]
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
	if i < 0 or i >= terrain.size():
		return false
	return terrain[i] != Terrain.MOUNTAIN and terrain[i] != Terrain.WATER


## Six ways out of a hex. In odd-r offset the answer depends on whether the row is one
## of the ones shifted half a hex to the right, which is the entire cost of moving off a
## square grid -- everything else about the map is stored and searched the same way.
const EVEN_ROW := [Vector2i(1, 0), Vector2i(0, -1), Vector2i(-1, -1),
	Vector2i(-1, 0), Vector2i(-1, 1), Vector2i(0, 1)]
const ODD_ROW := [Vector2i(1, 0), Vector2i(1, -1), Vector2i(0, -1),
	Vector2i(-1, 0), Vector2i(0, 1), Vector2i(1, 1)]


static func directions(row: int) -> Array:
	return ODD_ROW if row % 2 != 0 else EVEN_ROW


## Neighbouring tiles, passable or not. Use `neighbours` for somewhere an army can go.
func adjacent(i: int) -> PackedInt32Array:
	var out := PackedInt32Array()
	var x := tile_x(i)
	var y := tile_y(i)
	for d: Vector2i in directions(y):
		var nx := x + d.x
		var ny := y + d.y
		if in_bounds(nx, ny):
			out.append(idx(nx, ny))
	return out


func neighbours(i: int) -> PackedInt32Array:
	var out := PackedInt32Array()
	for n in adjacent(i):
		if passable(n):
			out.append(n)
	return out


## How many hexes apart, by way of cube coordinates -- on a hex grid the Manhattan
## distance over offset coordinates is simply wrong, and it is what decides which
## settlement works a tile.
static func hex_distance(a: int, b: int) -> int:
	var ax := tile_x(a) - int((tile_y(a) - (tile_y(a) & 1)) / 2.0)
	var az := tile_y(a)
	var ay := -ax - az
	var bx := tile_x(b) - int((tile_y(b) - (tile_y(b) & 1)) / 2.0)
	var bz := tile_y(b)
	var by := -bx - bz
	return int((absi(ax - bx) + absi(ay - by) + absi(az - bz)) / 2.0)


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


## What a settlement is worth per turn on its own, before the land around it.
static func settlement_income(s: Dictionary) -> Dictionary:
	var gold_out := Rules.SETTLEMENT_GOLD
	var food_out := Rules.SETTLEMENT_FOOD
	for b: StringName in s["buildings"]:
		gold_out += int(Rules.BUILDINGS[b]["gold"])
		food_out += int(Rules.BUILDINGS[b]["food"])
	return {"gold": gold_out, "food": food_out}


## The improvement on a tile, or &"" for bare ground.
func improvement_at(tile: int) -> StringName:
	if tile < 0 or tile >= improvements.size() or improvements[tile] == 0:
		return &""
	var names: Array = Rules.IMPROVEMENTS.keys()
	var at := int(improvements[tile]) - 1
	return names[at] if at < names.size() else &""


static func improvement_code(name: StringName) -> int:
	var at: int = Rules.IMPROVEMENTS.keys().find(name)
	return 0 if at < 0 else at + 1


## Which settlement works this tile: the nearest one within WORK_RADIUS. Ties go to the
## lower tile index so two towns can never both bank the same field.
func working_settlement(tile: int) -> Variant:
	var best = null
	var best_distance := Rules.WORK_RADIUS + 1
	for s: Dictionary in settlements:
		if s["owner"] == 0:
			continue
		var d := hex_distance(tile, s["tile"])
		if d <= Rules.WORK_RADIUS and (d < best_distance or (d == best_distance and best != null and s["tile"] < best["tile"])):
			best_distance = d
			best = s
	return best


## Everything the land around a player's settlements produces.
func worked_yield(owner: int) -> Dictionary:
	var out := {"gold": 0, "food": 0}
	for tile in improvements.size():
		var name := improvement_at(tile)
		if name == &"":
			continue
		var s = working_settlement(tile)
		if s == null or s["owner"] != owner:
			continue
		out["gold"] += int(Rules.IMPROVEMENTS[name]["gold"])
		out["food"] += int(Rules.IMPROVEMENTS[name]["food"])
	return out


## Can this player put this improvement on this tile? The land has to suit it and it has
## to be close enough to a town of theirs to be worked from.
func can_improve(owner: int, tile: int, name: StringName) -> bool:
	if not Rules.IMPROVEMENTS.has(name):
		return false
	if tile < 0 or tile >= improvements.size() or improvements[tile] != 0:
		return false
	if not Rules.IMPROVEMENTS[name]["on"].has(int(terrain[tile])):
		return false
	if settlement_at(tile) != null:
		return false                       # a town is already what is on that tile
	var s = working_settlement(tile)
	return s != null and s["owner"] == owner


func improve(owner: int, tile: int, name: StringName) -> bool:
	if not can_improve(owner, tile, name):
		return false
	var cost := int(Rules.IMPROVEMENTS[name]["cost"])
	if int(gold.get(owner, 0)) < cost:
		return false
	gold[owner] = int(gold[owner]) - cost
	improvements[tile] = improvement_code(name)
	return true


## How much damage a defender shrugs off on this tile, 0..1.
func defense_at(tile: int, owner: int) -> float:
	var s = settlement_at(tile)
	if s == null or s["owner"] != owner:
		return 0.0
	var best := 0.0
	for b: StringName in s["buildings"]:
		best = maxf(best, float(Rules.BUILDINGS[b]["defense"]))
	return best


## Kinds this settlement can raise: the unconditional ones plus whatever its
## buildings unlock.
func recruitable_at(tile: int) -> Array:
	var s = settlement_at(tile)
	var out := []
	for kind: StringName in Rules.KINDS:
		var needs: StringName = Rules.KINDS[kind]["requires"]
		if needs == &"" or (s != null and s["buildings"].has(needs)):
			out.append(kind)
	return out


func build(owner: int, tile: int, building: StringName) -> bool:
	if not Rules.BUILDINGS.has(building):
		return false
	var s = settlement_at(tile)
	if s == null or s["owner"] != owner:
		return false
	if s["buildings"].has(building):
		return false
	var cost := int(Rules.BUILDINGS[building]["cost"])
	if int(gold.get(owner, 0)) < cost:
		return false
	gold[owner] = int(gold[owner]) - cost
	s["buildings"].append(building)
	return true


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


## Hand every seat to a new owner id. Peer ids are random per session, so loading a
## save means the empires have to be re-pointed at whoever has actually turned up; a
## mapping that misses anything silently gives somebody else's empire away.
func remap_owners(mapping: Dictionary) -> void:
	for s: Dictionary in settlements:
		if mapping.has(s["owner"]):
			s["owner"] = mapping[s["owner"]]
	for a in armies.values():
		if mapping.has(a["owner"]):
			a["owner"] = mapping[a["owner"]]
	gold = _remapped(gold, mapping)
	food = _remapped(food, mapping)
	ready = _remapped(ready, mapping)


static func _remapped(book: Dictionary, mapping: Dictionary) -> Dictionary:
	var out := {}
	for owner in book:
		out[mapping.get(owner, owner)] = book[owner]
	return out


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
	if not recruitable_at(tile).has(kind):
		return false                      # needs a building this settlement has not got
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
	var starving := {}
	for owner in gold.keys():
		var earned := worked_yield(owner)
		for s: Dictionary in settlements:
			if s["owner"] == owner:
				var income := settlement_income(s)
				earned["gold"] += income["gold"]
				earned["food"] += income["food"]
		gold[owner] = int(gold[owner]) + earned["gold"]
		var larder: int = int(food.get(owner, 0)) + int(earned["food"]) - upkeep_of(owner)
		if larder < 0:
			starving[owner] = true
			_starve(owner)
			larder = 0
		food[owner] = larder

	for a in armies.values():
		a["move_left"] = Rules.ARMY_MOVE_POINTS
		# An army that cannot be fed does not also top up its ranks. Replenishing a
		# starving army cancels the desertion out and upkeep goes back to being a
		# number with no consequences.
		if not starving.has(a["owner"]):
			_reinforce(a)
	for id in sorted_army_ids():
		_cull(id)
	ready.clear()
	turn += 1


## An army it cannot feed melts away. Regiments that melt entirely are gone.
func _starve(owner: int) -> void:
	for a in armies.values():
		if a["owner"] != owner:
			continue
		for r: Array in a["regiments"]:
			r[1] = maxi(0, int(r[1]) - Rules.DESERTION_PER_TURN)


func _cull(army_id: int) -> void:
	var a = armies.get(army_id)
	if a == null:
		return
	var left := []
	for r: Array in a["regiments"]:
		if int(r[1]) > 0:
			left.append(r)
	a["regiments"] = left
	disband_if_empty(army_id)


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
		if roll < 0.07:
			ground[i] = Terrain.MOUNTAIN
		elif roll < 0.13:
			ground[i] = Terrain.WATER
		elif roll < 0.27:
			ground[i] = Terrain.HILLS
		elif roll < 0.47:
			ground[i] = Terrain.FOREST
		else:
			ground[i] = Terrain.PLAINS

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
		towns.append({"tile": tile, "owner": owner, "name": "Capital %d" % (n + 1), "buildings": [&"barracks"]})
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
			towns.append({"tile": tile, "owner": 0, "name": "Town %d" % (k + 1), "buildings": []})

	cs.terrain = ground
	cs.improvements = PackedByteArray()
	cs.improvements.resize(ground.size())
	cs.settlements = towns
	cs.gold = purse
	cs.food = larder
	for n in owner_ids.size():
		cs.add_army(owner_ids[n], towns[n]["tile"], [&"spear", &"spear", &"archer"])
	return cs
