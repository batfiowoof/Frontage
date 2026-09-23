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
var structures := PackedByteArray()     # parallel to terrain, an index into Rules.STRUCTURES
var settlements := []              # [{tile:int, owner:int, name:String, pop:int, unrest:int}]
var armies := {}                   # id -> {id, owner, tile, move_left, stance:int, regiments:Array}
                                   # a regiment is [kind, strength, xp]
var gold := {}                     # owner -> int
var food := {}                     # owner -> int
var research := {}                 # owner -> int, the pool both tech trees spend
var known := {}                    # owner -> Array of tech names
var ready := {}                    # owner -> bool
## What each player has ever laid eyes on: owner -> PackedByteArray parallel to `terrain`,
## 1 for seen. It only ever grows -- ground you have walked over stays on your map when
## you walk away, which is what everyone means by fog of war as opposed to blindness.
##
## Server state, sliced per player on the wire: a client is sent its own row and nobody
## else's. It is in the save too, or loading a campaign would hand back a revealed map.
var seen := {}                     # owner -> PackedByteArray
## Who is at war with whom, as rows [seat_a, seat_b, state] with a < b -- one row per
## pair, so there is no way to store a contradiction. An array and not a nested dictionary
## for the reason `settlements` is one: a row of known length and known types is something
## `decode_campaign` can actually check. WAR is the default for any pair with no row.
var relations := []
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


## A campaign regiment is [kind, strength, xp] -- the men it has right now and what they
## have learned, not merely what kind of men they are. Carrying only the kind would hand a
## regiment cut down to five men back to the campaign at full strength, and a battle that
## costs nothing is a battle that decides nothing; carrying no xp means the only thing an
## army brings home is losses, so a fresh regiment always beats a surviving one.
##
## Indices and not keys: everything that ages a regiment -- starvation, forfeit
## stragglers, reinforcement -- reaches for r[1] by position, and a dictionary per
## regiment would put a string key on the wire for every one of them.
static func make_regiment(kind: StringName) -> Array:
	return [kind, int(Rules.KINDS[kind]["strength"]), 0]


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


## What a settlement is worth per turn on its own, before the land around it. Since
## every structure now stands on a hex, this really is just the town -- but the town is no
## longer a flat number: it is how many people live there and how much they like you.
##
## Population multiplies, unrest suppresses, and the two are deliberately independent: a
## big angry town is worth less than a small contented one, which is the whole argument
## against taking every settlement you can reach.
static func settlement_income(s: Dictionary) -> Dictionary:
	var scale := (1.0 + float(pop_of(s) - 1) * Rules.POP_YIELD) * contentment(s)
	return {
		"gold": int(round(float(Rules.SETTLEMENT_GOLD) * scale)),
		"food": int(round(float(Rules.SETTLEMENT_FOOD) * scale)),
		"research": int(round(float(Rules.SETTLEMENT_RESEARCH) * scale)),
	}


## How much of its output a town is actually handing over, 1.0 down to 0.0 at revolt.
## Read rather than branched on, so there is no cliff where a town stops paying.
static func contentment(s: Dictionary) -> float:
	return clampf(1.0 - float(unrest_of(s)) / float(Rules.UNREST_REVOLT), 0.0, 1.0)


## Defaulted readers, because a settlement dictionary built by hand in a test -- or
## decoded from a snapshot that predates either field -- has neither key. Everything that
## asks goes through these, so there is one place that decides what a missing one means.
static func pop_of(s: Dictionary) -> int:
	return int(s.get("pop", Rules.START_POP))


static func unrest_of(s: Dictionary) -> int:
	return int(s.get("unrest", 0))


## Everything this player has learned.
func techs_of(owner: int) -> Array:
	return known.get(owner, [])


## The value of an effect key across every tech this player knows. Multiplicative keys
## compound, additive ones sum -- which is which is decided here and nowhere else, so a
## new tech is a table row rather than a branch.
const ADDITIVE := [&"work_radius", &"town_gold", &"armour"]


func tech(owner: int, key: StringName) -> float:
	var additive := ADDITIVE.has(key)
	var out := 0.0 if additive else 1.0
	for name: StringName in techs_of(owner):
		var effect: Dictionary = Rules.TECHS[name]["effect"]
		if not effect.has(key):
			continue
		if additive:
			out += float(effect[key])
		else:
			out *= float(effect[key])
	return out


## What a named structure yields this player, after whatever they have learned.
func tech_yield(owner: int, structure: StringName) -> float:
	var out := 1.0
	for name: StringName in techs_of(owner):
		var effect: Dictionary = Rules.TECHS[name]["effect"]
		if effect.has("yield") and effect["yield"].has(structure):
			out *= float(effect["yield"][structure])
	return out


func reach_of(owner: int) -> int:
	return Rules.WORK_RADIUS + int(tech(owner, &"work_radius"))


func cost_of(owner: int, structure: StringName) -> int:
	return int(round(float(Rules.STRUCTURES[structure]["cost"]) * tech(owner, &"build_cost")))


## Can this player learn it: a tech they do not have, whose prerequisites they do, and
## which they can pay for out of the one pool both trees share.
func can_learn(owner: int, name: StringName) -> bool:
	if not Rules.TECHS.has(name) or techs_of(owner).has(name):
		return false
	for needed: StringName in Rules.TECHS[name]["needs"]:
		if not techs_of(owner).has(needed):
			return false
	return int(research.get(owner, 0)) >= int(Rules.TECHS[name]["cost"])


func learn(owner: int, name: StringName) -> bool:
	if not can_learn(owner, name):
		return false
	research[owner] = int(research[owner]) - int(Rules.TECHS[name]["cost"])
	if not known.has(owner):
		known[owner] = []
	known[owner].append(name)
	return true


## Everything this player could learn right now, for the buttons.
func learnable(owner: int) -> Array:
	var out := []
	for name: StringName in Rules.TECHS:
		if can_learn(owner, name):
			out.append(name)
	return out


## What stands on a tile, or &"" for bare ground.
func structure_at(tile: int) -> StringName:
	if tile < 0 or tile >= structures.size() or structures[tile] == 0:
		return &""
	var names: Array = Rules.STRUCTURES.keys()
	var at := int(structures[tile]) - 1
	return names[at] if at < names.size() else &""


static func structure_code(name: StringName) -> int:
	var at: int = Rules.STRUCTURES.keys().find(name)
	return 0 if at < 0 else at + 1


## Which settlement works this tile: the nearest one within WORK_RADIUS. Ties go to the
## lower tile index so two towns can never both bank the same field.
func working_settlement(tile: int) -> Variant:
	var best = null
	var best_distance := 1 << 20
	for s: Dictionary in settlements:
		if s["owner"] == 0:
			continue
		var d := hex_distance(tile, s["tile"])
		if d <= reach_of(s["owner"]) and (d < best_distance or (d == best_distance and best != null and s["tile"] < best["tile"])):
			best_distance = d
			best = s
	return best


## Everything standing on the land a player's settlements work.
func worked_yield(owner: int) -> Dictionary:
	var out := {"gold": 0, "food": 0, "research": 0}
	for tile in structures.size():
		var name := structure_at(tile)
		if name == &"":
			continue
		var s = working_settlement(tile)
		if s == null or s["owner"] != owner:
			continue
		var spec: Dictionary = Rules.STRUCTURES[name]
		var better := tech_yield(owner, name)
		out["gold"] += int(round(float(spec["gold"]) * better))
		out["food"] += int(round(float(spec["food"]) * better))
		out["research"] += int(round(float(spec["research"]) * better))
	return out


## Can this player put this on this hex? The ground has to suit it, the hex has to be
## empty, and it has to be close enough to a town of theirs to be worked from.
func can_place(owner: int, tile: int, name: StringName) -> bool:
	if not Rules.STRUCTURES.has(name):
		return false
	if tile < 0 or tile >= structures.size() or structures[tile] != 0:
		return false
	var spec: Dictionary = Rules.STRUCTURES[name]
	var town = settlement_at(tile)
	if bool(spec["in_town"]):
		# Walls go on the town itself and nowhere else.
		return town != null and town["owner"] == owner
	if town != null:
		return false                       # the town hex is for the town's own walls
	if not spec["on"].has(int(terrain[tile])):
		return false
	var s = working_settlement(tile)
	return s != null and s["owner"] == owner


func place(owner: int, tile: int, name: StringName) -> bool:
	if not can_place(owner, tile, name):
		return false
	var cost := cost_of(owner, name)
	if int(gold.get(owner, 0)) < cost:
		return false
	gold[owner] = int(gold[owner]) - cost
	structures[tile] = structure_code(name)
	return true


## Everything this player could put on this hex right now, for the buttons.
func placeable_at(owner: int, tile: int) -> Array:
	var out := []
	for name: StringName in Rules.STRUCTURES:
		if can_place(owner, tile, name):
			out.append(name)
	return out


## Burn what is on the hex an army is standing on. Deliberate rather than automatic:
## marching through enemy farmland without torching it has to stay an option, or there
## is no decision in it. It ends the raider's turn and pays them part of what it cost.
func raze(owner: int, army_id: int) -> bool:
	var a = armies.get(army_id)
	if a == null or a["owner"] != owner or a["move_left"] <= 0:
		return false
	var tile: int = a["tile"]
	var name := structure_at(tile)
	if name == &"":
		return false
	var s = working_settlement(tile)
	if s != null and s["owner"] == owner:
		return false                       # nobody burns their own barns
	structures[tile] = 0
	a["move_left"] = 0
	gold[owner] = int(gold.get(owner, 0)) + int(round(float(Rules.STRUCTURES[name]["cost"]) * Rules.RAZE_LOOT))
	return true


# --- who is at war with whom ----------------------------------------------
## Everyone used to be permanently at war with everyone, which is not a state so much as
## the absence of one: two armies meeting always fought, and there was nothing a player
## could do about a second enemy except lose to both at once.

enum Relation { WAR, PEACE }


## Sorted, so `at_war(a, b)` and `at_war(b, a)` cannot disagree by construction.
static func _pair(a: int, b: int) -> Array:
	return [mini(a, b), maxi(a, b)]


func relation(a: int, b: int) -> int:
	if a == b:
		return Relation.PEACE                  # nobody fights themselves
	var want := _pair(a, b)
	for row: Array in relations:
		if int(row[0]) == want[0] and int(row[1]) == want[1]:
			return int(row[2])
	return Relation.WAR                        # the default, and what it always was


func at_war(a: int, b: int) -> bool:
	return relation(a, b) == Relation.WAR


## Owner 0 is the neutral towns and is at war with everybody by definition: they are
## there to be taken, and a peace with nobody-in-particular would make them untakeable.
func set_relation(a: int, b: int, state: int) -> bool:
	if a == b or a == 0 or b == 0:
		return false
	if state < 0 or state > Relation.PEACE:
		return false
	var want := _pair(a, b)
	for row: Array in relations:
		if int(row[0]) == want[0] and int(row[1]) == want[1]:
			row[2] = state
			return true
	relations.append([want[0], want[1], state])
	return true


## An offer outstanding from `from` to `to`? Offers are not stored -- they are an order
## that arrives, is answered, and is gone. What IS stored is the answer.
func make_peace(a: int, b: int) -> bool:
	return set_relation(a, b, Relation.PEACE)


func declare_war(a: int, b: int) -> bool:
	return set_relation(a, b, Relation.WAR)


# --- who is commanding ----------------------------------------------------
## The man at the head of the army, and the one thing the campaign remembers about a
## battle besides who won and who died.
##
## `sim/battle_state.gd` has always commissioned a general -- the biggest regiment carries
## him -- but he was anonymous, identical in every battle and forgotten the moment it
## ended. The flag is the same flag; what this adds is that it is somebody's, that he gets
## better at it, and that he can be killed.
##
## His NAME is derived from the army id and never sent: every machine reaches the same
## answer from something the snapshot already carries, which is exactly how the battle
## general falls out of `max_strength` and the ids.
static func general_name(army_id: int) -> String:
	return Rules.GENERAL_NAMES[absi(army_id) % Rules.GENERAL_NAMES.size()]


## Battles he has won. Defaulted, because an army decoded from a snapshot that predates
## him -- or built by hand in a test -- has no such key.
static func renown_of(a: Dictionary) -> int:
	return int(a.get("renown", 0))


## What he is worth to the men around him, 1.0 for a commander in his first battle. It
## SCALES the general's existing effects rather than adding a fourth number, because he
## is the same man doing the same job and only better at it.
static func renown_factor(a: Dictionary) -> float:
	var t := clampf(float(renown_of(a)) / float(Rules.RENOWN_WINS), 0.0, 1.0)
	return lerpf(1.0, Rules.RENOWN_BEST, t)


# --- what an army is doing ------------------------------------------------
## APPEND ONLY, like the order enum: these ints go on the wire and into saves.
enum Stance { MARCH, FORCED, FORTIFY, AMBUSH, BESIEGE }


static func stance_of(a: Dictionary) -> int:
	return int(a.get("stance", Stance.MARCH))


## How far this army may march this turn. FORCED buys ground with the state the men
## arrive in -- the price is taken in `_deploy`, not here, because a tired army that
## never fought should not have paid anything.
static func move_points(a: Dictionary) -> int:
	return Rules.ARMY_MOVE_POINTS + (Rules.FORCED_MARCH_BONUS if stance_of(a) == Stance.FORCED else 0)


## Standing still is the price of both of the standing-still stances, and it is charged
## the moment you adopt one rather than next turn: otherwise an army marches its three
## hexes, digs in on arrival and has paid nothing at all.
func set_stance(owner: int, army_id: int, stance: int) -> bool:
	var a = armies.get(army_id)
	if a == null or a["owner"] != owner:
		return false
	if stance < 0 or stance > Stance.BESIEGE:
		return false
	# Sitting down in front of a town is something you do TO a town, so there has to be
	# one under you and it has to be somebody else's.
	if stance == Stance.BESIEGE:
		var town = settlement_at(int(a["tile"]))
		if town == null or town["owner"] == owner:
			return false
	a["stance"] = stance
	if stance != Stance.MARCH and stance != Stance.FORCED:
		a["move_left"] = 0
	return true


## What a dug-in army adds to the ground it is standing on, over and above any walls.
static func fortification(a: Dictionary) -> float:
	return Rules.FORTIFY_DEFENSE if stance_of(a) == Stance.FORTIFY else 0.0


# --- founding a town ------------------------------------------------------
## The map used to be fixed at generation, so the only way to grow was to take somebody
## else's town. A settler is how a player makes a new one.
##
## Deliberate, like razing and splitting: an army carrying a settler does not drop it on
## the first decent hex it walks over. Where a town goes is most of the decision.

## Where in this army's line the settlers are, or -1. The first one, so an army carrying
## two founds one town now and keeps the other.
func settler_in(a: Dictionary) -> int:
	for i in a["regiments"].size():
		if a["regiments"][i][0] == Rules.SETTLER:
			return i
	return -1


## Can this army found a town where it is standing? Passable ground, nobody else's town
## underfoot, far enough from every existing town, a settler in the line, and a move left
## -- the same five-way check `raze` makes, for the same reason.
func can_found(owner: int, army_id: int) -> bool:
	var a = armies.get(army_id)
	if a == null or a["owner"] != owner or a["move_left"] <= 0:
		return false
	if settler_in(a) < 0:
		return false
	var tile: int = a["tile"]
	if not passable(tile):
		return false
	for s: Dictionary in settlements:
		if hex_distance(tile, int(s["tile"])) < Rules.MIN_TOWN_DISTANCE:
			return false
	return true


## Found it. The settlers become the town, which is why they leave the army: a settler
## that founded a town and stayed in the line would be a free regiment forever.
func found(owner: int, army_id: int) -> bool:
	if not can_found(owner, army_id):
		return false
	var a: Dictionary = armies[army_id]
	var tile: int = a["tile"]
	# Whatever stood on this hex is built over. A town on top of a farm would be worked
	# by itself and counted twice, and `can_place` guards the town hex from then on.
	structures[tile] = 0
	settlements.append({
		"tile": tile, "owner": owner,
		"name": "Town %d" % (settlements.size() + 1),
		"pop": Rules.START_POP, "unrest": 0,
	})
	a["regiments"].remove_at(settler_in(a))
	a["move_left"] = 0
	disband_if_empty(army_id)
	observe(owner)                     # a new town is a new pair of eyes
	return true


## How much damage a defender shrugs off on this tile, 0..1.
func defense_at(tile: int, owner: int) -> float:
	var s = settlement_at(tile)
	if s == null or s["owner"] != owner:
		return 0.0
	var name := structure_at(tile)
	return 0.0 if name == &"" else float(Rules.STRUCTURES[name]["defense"])


## Kinds this settlement can raise: the unconditional ones, plus whatever is unlocked by
## structures standing on the land it works. A barracks is a place on the map now, so
## burning it takes the cavalry away with it.
func unlocked_at(tile: int) -> Array:
	var out := []
	var town = settlement_at(tile)
	if town == null:
		return out
	for near in structures.size():
		if hex_distance(near, tile) > Rules.WORK_RADIUS:
			continue
		var name := structure_at(near)
		if name == &"":
			continue
		var s = working_settlement(near)
		if s == null or s["tile"] != tile:
			continue
		out.append_array(Rules.STRUCTURES[name]["unlocks"])
	return out


func recruitable_at(tile: int) -> Array:
	var unlocked := unlocked_at(tile)
	var out := []
	for kind: StringName in Rules.KINDS:
		var needs: StringName = Rules.KINDS[kind]["requires"]
		if needs == &"" or unlocked.has(kind):
			out.append(kind)
	return out



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


## Who has won, or 0 for "nobody yet". Owner 0 is neutral, so it is never an answer.
##
## Two ways to win, and the second is what stops a stalemate running forever: everyone
## else driven from the map, or the most settlements once TURN_LIMIT is up. A tie on
## settlements at the limit goes to the lower seat -- an arbitrary rule, but a decided
## game beats a game that never ends, and seats are stable within a session.
##
## Pure and on the sim side, so it is decided identically on every machine and a test
## can ask it without a tree.
func winner(seats: Array) -> int:
	var standing := []
	for owner in seats:
		if owner != 0 and is_alive(owner):
			standing.append(owner)
	if standing.size() == 1:
		return standing[0]
	if standing.is_empty() or turn <= Rules.TURN_LIMIT:
		return 0
	var best: int = standing[0]
	for owner in standing:
		var n := settlements_of(owner)
		if n > settlements_of(best) or (n == settlements_of(best) and owner < best):
			best = owner
	return best


# --- what a player can see ------------------------------------------------
## Fog of war. Everything here is pure and index-based, so the server, a loaded save and
## a test all reach the same answer, and `Snapshot.encode_campaign` can slice a snapshot
## with it without knowing anything about the map.

## Fold everything this owner can currently see into what it has already seen. Sight is
## worked out fresh each time from where its armies and towns actually are; `seen` is the
## memory, and it only grows.
func observe(owner: int) -> void:
	if owner == 0:
		return                         # nobody plays the neutral towns
	var memory: PackedByteArray = seen.get(owner, PackedByteArray())
	if memory.size() != terrain.size():
		memory = PackedByteArray()
		memory.resize(terrain.size())
	for tile in _watchtowers(owner):
		for i in terrain.size():
			if hex_distance(tile, i) <= Rules.SIGHT_RADIUS:
				memory[i] = 1
	seen[owner] = memory


## Everyone at once, which is what the server does after any change to the world.
func observe_all() -> void:
	for owner in gold.keys():
		observe(owner)


## The things that do the looking: every army and every settlement this owner holds.
func _watchtowers(owner: int) -> PackedInt32Array:
	var out := PackedInt32Array()
	for s: Dictionary in settlements:
		if s["owner"] == owner:
			out.append(int(s["tile"]))
	for a in armies.values():
		if a["owner"] == owner:
			out.append(int(a["tile"]))
	return out


## Has this owner ever seen this hex? An owner with no memory at all sees everything,
## which is what keeps every test and every harness written before fog existed honest:
## fog is something a campaign acquires by calling `observe`, not a default.
func can_see(owner: int, tile: int) -> bool:
	var memory: PackedByteArray = seen.get(owner, PackedByteArray())
	if memory.size() != terrain.size():
		return true
	return tile >= 0 and tile < memory.size() and memory[tile] != 0


## The armies this owner is allowed to know about: its own always, and anyone else's
## only where it can see.
##
## ONE function, and the reason there is only one is the listen-server rule. The wire
## filter (`Snapshot.encode_campaign`) and the campaign map's own drawing both call it,
## so the host's window and a joined client's window hide exactly the same armies. A
## view-side rule for the host and a wire-side rule for the client would be two rules
## that agree today.
func armies_visible_to(owner: int) -> Array:
	var out := []
	for id in sorted_army_ids():
		var a: Dictionary = armies[id]
		if a["owner"] == owner:
			out.append(a)
		elif stance_of(a) == Stance.AMBUSH:
			continue           # lying in wait: seeing the hex is not seeing the army
		elif can_see(owner, int(a["tile"])):
			out.append(a)
	return out


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
	research = _remapped(research, mapping)
	known = _remapped(known, mapping)
	ready = _remapped(ready, mapping)
	seen = _remapped(seen, mapping)    # miss this and a player loads somebody else's map
	# Both ends of every row, and re-sorted afterwards: the pair is stored low-id-first
	# and a remap can invert which of the two that is.
	for row: Array in relations:
		var pair := _pair(int(mapping.get(row[0], row[0])), int(mapping.get(row[1], row[1])))
		row[0] = pair[0]
		row[1] = pair[1]


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
		"stance": Stance.MARCH,
		"renown": 0,
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
			# Somebody we are not fighting is in the way, not a battle waiting to happen.
			# Peace has to block the march as well as the fight, or the two armies would
			# simply stand in the same hex -- which `army_at` cannot represent.
			if blocker["owner"] == a["owner"] or not at_war(int(a["owner"]), int(blocker["owner"])):
				break                              # a friendly army blocks the road
			a["move_left"] -= 1
			result["collision"] = [army_id, blocker["id"]]
			return result                          # stop on contact; a battle decides the tile
		# A road is worth nothing on its own and everything as a chain: the step is free
		# only if BOTH ends of it are made up. One road hex in open country buys nothing,
		# which is what makes building a route a route rather than a hex.
		var free: bool = Rules.ROAD_IS_FREE and structure_at(a["tile"]) == &"road" 			and structure_at(step) == &"road"
		a["tile"] = step
		if not free:
			a["move_left"] -= 1
		result["moved"] += 1
		_capture_if_undefended(a)
	# An army that marched is not dug in and is not hiding, whatever it was doing before.
	if result["moved"] > 0 and stance_of(a) != Stance.FORCED:
		a["stance"] = Stance.MARCH
	return result


## Taking a town is not the end of taking a town. It comes with people who did not ask
## for you, and a big empire cannot calm them all down at once -- see `_settle_unrest`.
func _capture_if_undefended(a: Dictionary) -> void:
	var s = settlement_at(a["tile"])
	if s != null and not at_war(int(a["owner"]), int(s["owner"])):
		return                             # walking into a friend's town is a visit
	if s != null and s["owner"] != a["owner"]:
		s["owner"] = a["owner"]
		s["unrest"] = Rules.UNREST_ON_CAPTURE


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


## Two armies of the same owner standing beside each other become one. Deliberate
## rather than automatic, for the same reason razing is: a column marching past its own
## garrison must not silently swallow it.
func can_merge(owner: int, army_id: int, into_id: int) -> bool:
	if army_id == into_id:
		return false
	var a = armies.get(army_id)
	var b = armies.get(into_id)
	if a == null or b == null:
		return false
	if a["owner"] != owner or b["owner"] != owner:
		return false
	if a["move_left"] <= 0:
		return false
	if b["regiments"].size() >= MAX_REGIMENTS_PER_ARMY:
		return false
	return Array(adjacent(a["tile"])).has(b["tile"])


func merge(owner: int, army_id: int, into_id: int) -> bool:
	if not can_merge(owner, army_id, into_id):
		return false
	var a = armies[army_id]
	var b = armies[into_id]
	var room: int = MAX_REGIMENTS_PER_ARMY - b["regiments"].size()
	for i in mini(room, a["regiments"].size()):
		b["regiments"].append(a["regiments"].pop_front())
	# The slower half sets the pace, so combining is never a way to buy a move.
	b["move_left"] = mini(int(b["move_left"]), int(a["move_left"]))
	a["move_left"] = 0
	disband_if_empty(army_id)
	return true


## A battle is about to be fought on this army's hex, so everything of ours standing
## next to it walks in. Total War's reinforcements, and the reason they matter is that
## armies cannot share a hex: without this, two of your stacks a hex apart fight the
## enemy one at a time and lose to a single force neither could beat alone.
##
## It is `merge`, deliberately. Merging already handles the regiment cap, leaves the
## remainder behind as a smaller army, and spends the movement -- writing a second path
## into a battle would be a second set of those rules to keep in step. One army a side
## goes into `_begin_battle` afterwards exactly as one always did, so nothing downstream
## of the deployment knows this happened.
##
## Only those with movement left: an army that has already marched and fought this turn
## is not also available to turn up somewhere else.
func reinforce(army_id: int) -> int:
	var a = armies.get(army_id)
	if a == null:
		return 0
	var joined := 0
	for near in adjacent(int(a["tile"])):
		var other = army_at(near)
		if other == null or other["owner"] != a["owner"]:
			continue    # ponytail: only your OWN armies reinforce, never an ally's
		var brought: int = other["regiments"].size()
		if merge(int(a["owner"]), int(other["id"]), army_id):
			joined += brought - (other["regiments"].size() if armies.has(other["id"]) else 0)
	return joined


## Peel regiments off into a new army on an adjacent hex.
##
## It has to march out rather than stand where it was: `army_at()` returns the FIRST army
## on a hex and movement, collision detection and razing all lean on that, so two armies
## sharing one would quietly break all three.
func can_split(owner: int, army_id: int, indices: PackedInt32Array, to_tile: int) -> bool:
	var a = armies.get(army_id)
	if a == null or a["owner"] != owner:
		return false
	if indices.is_empty() or indices.size() >= a["regiments"].size():
		return false                       # somebody has to stay behind
	var seen := {}
	for i in indices:
		if i < 0 or i >= a["regiments"].size() or seen.has(i):
			return false
		seen[i] = true
	if not passable(to_tile) or army_at(to_tile) != null:
		return false
	return Array(adjacent(a["tile"])).has(to_tile)


## Returns the new army's id, or -1.
func split(owner: int, army_id: int, indices: PackedInt32Array, to_tile: int) -> int:
	if not can_split(owner, army_id, indices, to_tile):
		return -1
	var a = armies[army_id]
	var order := Array(indices)
	order.sort()
	order.reverse()                        # take from the back so earlier indices hold
	var taken := []
	for i: int in order:
		taken.push_front(a["regiments"][i])
		a["regiments"].remove_at(i)

	var b := add_army(owner, to_tile, [])
	b["regiments"] = taken
	b["move_left"] = 0                     # forming up takes the day
	_capture_if_undefended(b)
	return b["id"]


## Fall back off a field you have given up. Returns the tile retreated to, or -1 for an
## army with nowhere to go.
##
## It has to MOVE rather than stand where it was, because two armies cannot share a hex
## -- `army_at()` returns the first one there and movement, collision and razing all lean
## on that -- and the side that held the field is about to be standing on it.
##
## Breaking contact costs men: FORFEIT_STRAGGLERS of every regiment is left behind, so
## quitting saves an army without being a free undo. Cornered against water, mountains or
## somebody else's army it stays put and simply loses the ground; being wiped out for
## being surrounded would make one bad hex an instant loss.
func retreat(army_id: int) -> int:
	var a = armies.get(army_id)
	if a == null:
		return -1
	for r: Array in a["regiments"]:
		r[1] = maxi(0, int(r[1]) - int(ceil(float(r[1]) * Rules.FORFEIT_STRAGGLERS)))
	_cull(army_id)
	a = armies.get(army_id)
	if a == null:
		return -1                          # the stragglers were the whole army
	a["move_left"] = 0
	for step in adjacent(a["tile"]):
		if not passable(step) or army_at(step) != null:
			continue
		var town = settlement_at(step)
		if town != null and town["owner"] != a["owner"]:
			continue                       # falling back into their town is not a retreat
		a["tile"] = step
		return step
	return -1


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
		var earned := income_of(owner)
		gold[owner] = int(gold[owner]) + earned["gold"]
		research[owner] = int(research.get(owner, 0)) + int(earned["research"])
		var larder: int = int(food.get(owner, 0)) + int(earned["food"]) - upkeep_of(owner)
		if larder < 0:
			starving[owner] = true
			_starve(owner)
			larder = 0
		food[owner] = larder - _grow_towns(owner, larder)
		_settle_unrest(owner)

	# After the unrest pass, so a turn of being sat on shows up on the NEXT one --
	# the same turn would let an army arrive and take the town in a single end-turn.
	_raise_barbarians()
	_press_the_sieges()
	for a in armies.values():
		a["move_left"] = move_points(a)
		# An army that cannot be fed does not also top up its ranks. Replenishing a
		# starving army cancels the desertion out and upkeep goes back to being a
		# number with no consequences.
		if not starving.has(a["owner"]):
			_reinforce(a)
	for id in sorted_army_ids():
		_cull(id)
	ready.clear()
	turn += 1


## What a turn brings in, before upkeep. One function because the HUD shows it and
## end_turn pays it, and two copies of this sum would be two answers to one question.
func income_of(owner: int) -> Dictionary:
	var earned := worked_yield(owner)
	for s: Dictionary in settlements:
		if s["owner"] == owner:
			var income := settlement_income(s)
			earned["gold"] += income["gold"] + int(tech(owner, &"town_gold"))
			earned["food"] += income["food"]
			earned["research"] += income["research"]
	return earned


## Towns grow on a food SURPLUS, and the surplus is what they cost. An empire that eats
## everything it produces feeds its army and develops nothing, which is the decision:
## another regiment, or another point of population that pays for the rest of the game.
##
## Returns what was spent, so end_turn can take it out of the larder. Every town of a fed
## empire grows together -- see the ponytail note on Rules.FOOD_PER_GROWTH.
func _grow_towns(owner: int, larder: int) -> int:
	var spent := 0
	for s: Dictionary in settlements:
		if s["owner"] != owner or pop_of(s) >= Rules.MAX_POP:
			continue
		# An angry town does not grow either: contentment gates it rather than merely
		# taxing it, or a revolting province would still be quietly getting bigger.
		if unrest_of(s) > 0:
			continue
		if larder - spent < Rules.FOOD_PER_GROWTH:
			break
		s["pop"] = pop_of(s) + 1
		spent += Rules.FOOD_PER_GROWTH
	return spent


## Unrest settles on its own, and an empire past UNREST_FREE_TOWNS undoes that as fast as
## it happens. That is the ceiling on conquest: not that you cannot take the next town,
## but that taking it keeps the last one angry.
##
## A town that boils over goes back to being nobody's. It does not go to another player --
## it revolted against YOU, and handing it to your enemy would make unrest a weapon
## pointed at whoever happens to be nearest.
## An army sitting on a town starves it: the people leave and the rest lose patience,
## and at UNREST_REVOLT the place throws its owner out exactly as an ungovernable one
## does. Slow on purpose -- if starving a town out were quick nobody would ever assault
## one, and the assault is the more interesting half.
func _press_the_sieges() -> void:
	for a in armies.values():
		if stance_of(a) != Stance.BESIEGE:
			continue
		var town = settlement_at(int(a["tile"]))
		if town == null or town["owner"] == a["owner"]:
			continue
		town["pop"] = maxi(1, pop_of(town) - Rules.BESIEGE_STARVES)
		town["unrest"] = unrest_of(town) + Rules.BESIEGE_ANGERS
		if unrest_of(town) < Rules.UNREST_REVOLT:
			continue
		# Starved out. It goes to the BESIEGER and not to nobody, which is the one place
		# this differs from an ungovernable province throwing its owner out: somebody is
		# sitting outside the gate waiting for exactly this, and they get it -- with the
		# same resentment any other conquest comes with.
		town["owner"] = a["owner"]
		town["unrest"] = Rules.UNREST_ON_CAPTURE


func _settle_unrest(owner: int) -> void:
	var over: int = maxi(0, settlements_of(owner) - Rules.UNREST_FREE_TOWNS)
	for s: Dictionary in settlements.duplicate():
		if s["owner"] != owner:
			continue
		var level: int = unrest_of(s) - 1 + over
		if level >= Rules.UNREST_REVOLT:
			s["owner"] = 0
			s["unrest"] = 0
			continue
		s["unrest"] = maxi(0, level)


## Raiders out of the empty country. They cost nothing to keep, because they are not in
## `gold` and therefore not in the economy at all -- no income, no upkeep, no starvation.
##
## They appear where **nobody can see**, which is the one thing fog bought that nothing
## else uses: a band that materialised in the middle of somebody's territory would read as
## a cheat rather than as a raid. `can_see` already answers it.
##
## Deterministic from the turn, so a save reloaded plays the same campaign.
func _raise_barbarians() -> void:
	if turn % Rules.BARBARIAN_EVERY != 0:
		return
	var bands := 0
	for a in armies.values():
		if a["owner"] == Rules.BARBARIAN_SEAT:
			bands += 1
	if bands >= Rules.BARBARIAN_BANDS:
		return
	var hidden := PackedInt32Array()
	for tile in terrain.size():
		if not passable(tile) or army_at(tile) != null or settlement_at(tile) != null:
			continue
		var watched := false
		for owner in gold.keys():
			if can_see(int(owner), tile):
				watched = true
				break
		if not watched:
			hidden.append(tile)
	if hidden.is_empty():
		return
	add_army(Rules.BARBARIAN_SEAT, hidden[turn % hidden.size()],
		Rules.BARBARIAN_BAND.duplicate())


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
		towns.append({"tile": tile, "owner": owner, "name": "Capital %d" % (n + 1),
			"pop": Rules.START_POP, "unrest": 0})
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
			towns.append({"tile": tile, "owner": 0, "name": "Town %d" % (k + 1),
				"pop": Rules.START_POP, "unrest": 0})

	cs.terrain = ground
	cs.structures = PackedByteArray()
	cs.structures.resize(ground.size())
	cs.settlements = towns
	cs.gold = purse
	cs.food = larder
	for n in owner_ids.size():
		cs.research[owner_ids[n]] = Rules.START_RESEARCH
		cs.known[owner_ids[n]] = []
		cs.add_army(owner_ids[n], towns[n]["tile"], [&"spear", &"spear", &"archer"])
	cs.observe_all()                   # everybody can see the ground they are standing on

	# Every capital starts with a barracks standing on a hex beside it: a real place,
	# which an enemy can march to and burn.
	for n in owner_ids.size():
		for near in cs.adjacent(towns[n]["tile"]):
			if cs.can_place(owner_ids[n], near, &"barracks"):
				cs.structures[near] = structure_code(&"barracks")
				break
	return cs
