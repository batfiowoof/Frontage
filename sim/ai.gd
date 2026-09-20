extends RefCounted
## A crude opponent, so the game can be played and tuned by one person.
##
## It produces ORDERS and never touches the world. Every decision it makes is encoded
## and fed through the same `_receive_order` a remote client's packet lands in, so it
## passes the same shape validation and the same ownership checks a human does. That
## is deliberate and stronger than it looks: if the AI cannot express something as a
## legal order, neither could a player, and no AI mistake can corrupt the world.
##
## It holds a little memory of its own (which cavalry are mid-sweep, which turn it
## last acted on). That is the AI's notebook, not world state -- nothing here is
## authoritative and nothing here is on the wire.

const Rules := preload("res://sim/rules.gd")
const Campaign := preload("res://sim/campaign_state.gd")
const Regiment := preload("res://sim/regiment.gd")
const Formation := preload("res://sim/formation.gd")
const Orders := preload("res://net/orders.gd")

## Where an advancing line aims relative to the enemy centre. It has to clear the
## enemy's own half-depth or the order points inside the enemy block, which now means
## marching past the front rank it was supposed to stop against.
const STANDOFF := 120.0
const LINE_SPACING := 110.0
## How far round the enemy a cavalry sweep goes before turning in.
const SWEEP_WIDE := 420.0
const SWEEP_DEPTH := 260.0
const SWEEP_ARRIVED := 90.0
## Close enough that a regiment should stop dressing its line and just go and hit
## somebody. Without this the last few regiments stand in their slots a hundred
## units to the side of the only remaining enemy, politely not joining in.
const ENGAGE_RANGE := 320.0

## How close a horseman has to be before the foot forms square.
const HORSE_ALARM := 430.0

## What it wants standing on its land, in the order it wants it.
const BUILD_ORDER := [&"walls", &"farm", &"barracks", &"library", &"market", &"mine", &"lumber", &"pasture"]

var seat := 0
var _acted_on_turn := -1
var _sweep_to := {}                # regiment id -> latched waypoint, or null once past it


func _init(owner_id: int) -> void:
	seat = owner_id


# --- campaign -------------------------------------------------------------

## One turn's worth of decisions, ending with End Turn.
##
## Whether it has finished its turn is read from the world, not remembered. Marching
## can start a battle, and every order after that one -- including End Turn -- is
## refused while the battle runs. An AI that trusted its own memory therefore thought
## it had ended a turn it had not, and the game waited on it forever.
func campaign_orders(cs) -> Array:
	if cs == null or bool(cs.ready.get(seat, false)):
		return []
	var out := []
	if cs.turn != _acted_on_turn:
		_acted_on_turn = cs.turn          # spend money once a turn, not once a frame
		_build_something(cs, out)
		_recruit_something(cs, out)
		_burn_something(cs, out)
		_march(cs, out)
	out.append(Orders.ready(true))
	return out


## One structure a turn, on the first hex near one of its towns that will take it.
## Walls first, then whatever else it can afford -- it is not a clever planner, but it
## does put things on the map where they can be come for.
func _build_something(cs, out: Array) -> void:
	var purse := int(cs.gold.get(seat, 0))
	for s: Dictionary in cs.settlements:
		if s["owner"] != seat:
			continue
		for name: StringName in BUILD_ORDER:
			if int(Rules.STRUCTURES[name]["cost"]) > purse:
				continue
			for tile in cs.structures.size():
				if Campaign.hex_distance(tile, s["tile"]) > Rules.WORK_RADIUS:
					continue
				if cs.can_place(seat, tile, name):
					out.append(Orders.build(tile, name))
					return                 # one a turn; the rest can wait for income


func _recruit_something(cs, out: Array) -> void:
	# Only raise what it can feed, or it starves itself into a rout on turn six.
	if int(cs.food.get(seat, 0)) < cs.upkeep_of(seat):
		return
	var purse := int(cs.gold.get(seat, 0))
	for s: Dictionary in cs.settlements:
		if s["owner"] != seat:
			continue
		var best := &""
		var best_cost := 0
		for kind: StringName in cs.recruitable_at(s["tile"]):
			var cost := int(Rules.KINDS[kind]["cost"])
			if cost <= purse and cost > best_cost:
				best = kind                # the best it can afford, not the cheapest
				best_cost = cost
		if best != &"":
			out.append(Orders.recruit(s["tile"], best))
			return


## Anything of theirs under our feet goes up. Razing ends the army's turn, so it is
## worth doing before deciding where to march rather than after.
func _burn_something(cs, out: Array) -> void:
	for id in cs.sorted_army_ids():
		var a = cs.armies[id]
		if a["owner"] != seat or a["move_left"] <= 0:
			continue
		if cs.structure_at(a["tile"]) == &"":
			continue
		var s = cs.working_settlement(a["tile"])
		if s != null and s["owner"] != seat:
			out.append(Orders.raze(id))
			return


func _march(cs, out: Array) -> void:
	var target := _nearest_prize(cs)
	if target < 0:
		return
	for id in cs.sorted_army_ids():
		var a = cs.armies[id]
		if a["owner"] == seat and a["move_left"] > 0:
			out.append(Orders.army_move(id, target))


## The nearest thing worth walking to: an enemy or neutral settlement.
func _nearest_prize(cs) -> int:
	var home := -1
	for id in cs.sorted_army_ids():
		if cs.armies[id]["owner"] == seat:
			home = cs.armies[id]["tile"]
			break
	if home < 0:
		return -1
	var best := -1
	var best_distance := 1 << 30
	for s: Dictionary in cs.settlements:
		if s["owner"] == seat:
			continue
		var d := _tile_distance(home, s["tile"])
		if d < best_distance:
			best_distance = d
			best = s["tile"]
	return best


static func _tile_distance(a: int, b: int) -> int:
	return Campaign.hex_distance(a, b)


# --- battle ---------------------------------------------------------------

## Orders for this instant. Regiments already FIGHTING are left alone: re-issuing a
## move order would set them back to MOVING and pull them out of the melee, so an AI
## that "helpfully" re-ordered every second would never actually fight anybody.
func battle_orders(bs) -> Array:
	if bs == null:
		return []
	var mine := []
	var foes := []
	for id in bs.sorted_ids():
		var r: Regiment = bs.regiments[id]
		if not r.is_alive():
			continue
		if r.owner_id == seat:
			mine.append(r)
		elif r.state != Regiment.State.ROUTING:
			# Broken regiments are not targets and must not count toward the enemy
			# centre. Routers flee a thousand units in any direction, so averaging
			# them in sent the whole line marching to an empty patch of field, where
			# it arrived, stopped, and stood there while the battle never ended.
			foes.append(r)
	if mine.is_empty() or foes.is_empty():
		return []

	var enemy_centre := _centre(foes)
	var my_centre := _centre(mine)
	var approach := (enemy_centre - my_centre)
	if approach.length_squared() < 1.0:
		approach = Vector2.RIGHT
	approach = approach.normalized()
	var across := Vector2(-approach.y, approach.x)

	var out := []
	var foot := []
	for r: Regiment in mine:
		if r.can_shoot():
			continue                       # handled by _stand_off
		if float(Rules.KINDS[r.kind]["speed"]) >= 1.4:
			_sweep(r, out, enemy_centre, approach, across)
		else:
			foot.append(r)

	_mind_the_cavalry(mine, foes, out)

	var shooters := []
	for r: Regiment in mine:
		if r.can_shoot():
			shooters.append(r)
	_stand_off(shooters, foes, out, enemy_centre, approach)

	# Everything slow forms one line and walks at them -- unless somebody is already
	# within reach, in which case it goes and fights instead of dressing ranks.
	for i in foot.size():
		var r: Regiment = foot[i]
		if r.state != Regiment.State.IDLE and r.state != Regiment.State.MOVING:
			continue
		var near = _nearest(r, foes)
		var target: Vector2
		var face: float
		if near != null and r.pos.distance_to(near.pos) < ENGAGE_RANGE:
			target = near.pos
			face = (near.pos - r.pos).angle()
		else:
			target = enemy_centre + across * (float(i) - float(foot.size() - 1) * 0.5) * LINE_SPACING
			target -= approach * STANDOFF
			face = approach.angle()
		if r.pos.distance_to(target) > 20.0:
			out.append(Orders.battle_move(PackedInt32Array([r.id]), target, face))
	return out


## Archers hold back inside their own range and stop, because a bow needs a moment and
## a regiment that is still walking never looses. Out of arrows, they join the line.
func _stand_off(shooters: Array, foes: Array, out: Array, enemy_centre: Vector2, approach: Vector2) -> void:
	for r: Regiment in shooters:
		if r.state == Regiment.State.FIGHTING or r.state == Regiment.State.ROUTING:
			continue
		# Stop the moment anything is in range, and do not re-order after that. Chasing
		# a stand-off point computed from a moving enemy centre means never standing
		# still, and a regiment that is still walking never looses an arrow -- so the
		# quiver never empties, the archers never join the line, and the battle never
		# ends. Exactly the way the cavalry sweep used to circle forever.
		var near = _nearest(r, foes)
		if near != null and r.pos.distance_to(near.pos) <= r.range_of() * 0.9:
			continue
		var stand: Vector2 = enemy_centre - approach * (r.range_of() * 0.8)
		if r.pos.distance_to(stand) > 40.0:
			out.append(Orders.battle_move(PackedInt32Array([r.id]), stand, approach.angle()))


## Foot with horsemen bearing down on it forms square; once they are gone it goes back
## to a line, because a square is a poor way to kill anybody.
func _mind_the_cavalry(mine: Array, foes: Array, out: Array) -> void:
	var horses := []
	for f: Regiment in foes:
		if f.is_cavalry():
			horses.append(f)
	for r: Regiment in mine:
		if r.is_cavalry() or r.reforming > 0.0 or r.state == Regiment.State.ROUTING:
			continue
		var near = _nearest(r, horses)
		var threatened: bool = near != null and r.pos.distance_to(near.pos) < HORSE_ALARM
		var wanted: StringName = &"square" if threatened else &"line"
		if r.formation != wanted:
			out.append(Orders.set_formation(PackedInt32Array([r.id]), wanted, 0))


static func _nearest(r: Regiment, others: Array):
	var best = null
	var best_distance := INF
	for o: Regiment in others:
		var d := r.pos.distance_squared_to(o.pos)
		if d < best_distance:
			best_distance = d
			best = o
	return best


## Cavalry goes round rather than into the front. Two stages, because a single order
## at the enemy's back sends it straight through the melee it was supposed to avoid.
##
## The waypoint is LATCHED the first time. Recomputing it each second from a moving
## enemy centre had the horse chasing a point that receded as fast as it rode, so it
## circled the battle forever and the battle never ended.
func _sweep(r: Regiment, out: Array, enemy_centre: Vector2, approach: Vector2, across: Vector2) -> void:
	if r.state == Regiment.State.FIGHTING or r.state == Regiment.State.ROUTING:
		return

	if not _sweep_to.has(r.id):
		var side: float = 1.0 if r.pos.dot(across) >= 0.0 else -1.0
		_sweep_to[r.id] = enemy_centre + across * SWEEP_WIDE * side - approach * SWEEP_DEPTH * 0.2

	var waypoint = _sweep_to[r.id]
	if waypoint != null:
		if r.pos.distance_to(waypoint) < SWEEP_ARRIVED:
			_sweep_to[r.id] = null         # round the side; now turn in
		else:
			out.append(Orders.battle_move(PackedInt32Array([r.id]), waypoint, (waypoint - r.pos).angle()))
			return

	var behind: Vector2 = enemy_centre + approach * SWEEP_DEPTH
	out.append(Orders.battle_move(PackedInt32Array([r.id]), behind, (enemy_centre - behind).angle()))


static func _centre(regiments: Array) -> Vector2:
	var sum := Vector2.ZERO
	for r: Regiment in regiments:
		sum += r.pos
	return sum / float(regiments.size())
