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
const BattleState := preload("res://sim/battle_state.gd")

## Where an advancing line aims relative to the enemy centre. It has to clear the
## enemy's own half-depth or the order points inside the enemy block, which now means
## marching past the front rank it was supposed to stop against.
const STANDOFF := 120.0
## The gap between two regiments in the AI's own line. This is a FRONTAGE plus a
## shoulder, not a free number: a 20-file regiment stands 133 units across, so at the old
## 110 the AI ordered its own line to stand INSIDE ITSELF and arrived as a clump instead
## of a line. Same trap as DEPLOY_SPACING.
const LINE_SPACING := 150.0
## How far past the end of the enemy line the wings try to reach. Enough to clear their
## flank by half a frontage -- NOT enough to double the line, which is what it used to do.
##
## A line no wider than the one it is walking at can only ever meet it head-on, so some
## overhang is the whole of the envelopment. But stretching EVERY slot to get it spread
## three regiments over 883 units where the enemy held 583, left 242 units of open ground
## between neighbours, and was not a line at all: three detachments walking past the enemy
## in parallel. Only the outermost regiment on each side reaches out now, and never by
## more than one LINE_SPACING, so the formation stretches at its ends instead of coming
## apart in its middle.
const OVERHANG := 90.0
## How far round the enemy a cavalry sweep goes before turning in.
const SWEEP_WIDE := 420.0
const SWEEP_DEPTH := 260.0
const SWEEP_ARRIVED := 90.0
## Envelopment. How far OUTSIDE a pinned enemy's flank a wrapping regiment aims, past
## what the two of them physically occupy, and how close it has to get before it commits.
## Added to reach() rather than being a constant on its own, so it keeps meaning "outside
## his flank" when frontages change instead of quietly becoming "into his front".
const WRAP_MARGIN := 120.0
const WRAP_ARRIVED := 80.0
## How far back toward our OWN side the flank waypoint sits. The regiment starts behind
## our line, so a point level with the enemy's flank is reached by cutting the corner --
## straight through the fighting it was supposed to go round, clipping in and out of
## contact the whole way. Pulled back, the walk stays on our side and only the final
## turn-in, which the sim does, crosses the line at all.
const WRAP_BACK := 170.0
## Close enough that a regiment should stop dressing its line and just go and hit
## somebody. Without this the last few regiments stand in their slots a hundred
## units to the side of the only remaining enemy, politely not joining in.
const ENGAGE_RANGE := 320.0

## How close a horseman has to be before the foot forms square.
const HORSE_ALARM := 430.0

## How far back a withdrawing regiment steps at a time. Re-issued when it arrives and
## not before, for the same reason the archers stop re-ordering: a unit re-told every
## frame to go somewhere never gets there.
const WITHDRAW_STEP := 300.0

## When to stop fighting altogether. An army being taken apart should save what is left
## rather than feed the rest of it in, and an AI with no way to quit simply grinds every
## lost battle to BATTLE_TIME_LIMIT -- four hundred and twenty seconds of a fight that
## was decided in the first sixty.
##
## Both conditions, not either. Being outnumbered is not the same as being beaten: a
## smaller army that is still formed can hold, and quitting on the count alone would
## make the AI resign fights it was winning on ground it had chosen. Men already running
## is the evidence the line has actually gone.
const GIVE_UP_RATIO := 0.45        # our standing men against theirs
const GIVE_UP_BROKEN := 0.34       # ...and this much of us already routing

## What it reaches for first. Cheap things early, and it alternates trees rather than
## emptying one, because a pool shared between them is the whole point.
const TECH_ORDER := [&"husbandry", &"drill", &"coinage", &"armoury", &"masonry",
	&"horsemanship", &"irrigation", &"discipline", &"banking", &"siegecraft",
	&"guilds", &"stirrups"]


## What it wants standing on its land, in the order it wants it.
## Roads are deliberately absent. They pay nothing, they are only worth anything as a
## chain, and this planner places one structure a turn on the first hex that will take it
## -- so it would scatter single road hexes that buy nothing at all.
## ponytail: the AI does not build roads. A planner that lays a ROUTE is the upgrade.
const BUILD_ORDER := [&"walls", &"farm", &"barracks", &"library", &"market", &"mine", &"lumber", &"pasture"]

## How far away a prize has to be before the AI decides to force the march. Two hexes
## further at the cost of arriving spent is worth it for a long approach and not for a
## short one -- a forced march onto the tile next door pays the price for nothing.
const FORCE_MARCH_BEYOND := 5

var seat := 0
var _acted_on_turn := -1
var _sweep_to := {}                # regiment id -> latched waypoint, or null once past it
var _wrap_to := {}                 # regiment id -> latched flank waypoint, erased on arrival

## What Jev thinks, when there is a Jev. Plain data, written from outside by net/jev.gd
## and only ever READ in here -- no preload, no Node, nothing on the wire, so this file
## stays the pure RefCounted it has to be. Every key is a preference among options this
## file had already found to be legal, so an empty dictionary is not a broken AI, it is
## the AI as it was before Jev existed. Each reader below tries the advised value once
## and then falls into the same loop it always ran, which is what makes bad advice,
## stale advice and no advice all cost exactly nothing.
var advice := {}


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
	# Answered first and outside the once-a-turn gate: an offer arrives when it arrives,
	# and leaving somebody waiting a whole turn for an answer is how a negotiation stops
	# feeling like one.
	# `advice` is already filled by the time this runs: `consider_turn` holds the AI back
	# entirely while a question is out, so there is nothing to wait for here. An offer
	# that arrives AFTER the turn's question went out gets the heuristic, which is the
	# same answer every other Jev failure gets.
	# A raider does none of the rest of it. It has no towns to build in, no
	# research, no treasury and nothing to found -- it marches at the nearest
	# settlement somebody HOLDS, and that is the whole of what a raid is.
	if raids:
		if cs.turn != _acted_on_turn:
			_acted_on_turn = cs.turn
			_march(cs, out)
		out.append(Orders.ready(true))
		return out

	if pending_offer != 0:
		out.append(Orders.answer(pending_offer, _accepts_peace(cs, pending_offer)))
		pending_offer = 0
	if cs.turn != _acted_on_turn:
		_acted_on_turn = cs.turn          # spend money once a turn, not once a frame
		_build_something(cs, out)
		_learn_something(cs, out)
		_recruit_something(cs, out)
		_burn_something(cs, out)
		_settle_something(cs, out)
		_gather_up(cs, out)
		_march(cs, out)
	out.append(Orders.ready(true))
	return out


## One structure a turn, on the first hex near one of its towns that will take it.
## Walls first, then whatever else it can afford -- it is not a clever planner, but it
## does put things on the map where they can be come for.
func _build_something(cs, out: Array) -> void:
	var purse := int(cs.gold.get(seat, 0))
	var wanted: Array = BUILD_ORDER
	var advised = advice.get("build")
	if advised != null and Rules.STRUCTURES.has(advised):
		wanted = [advised] + BUILD_ORDER    # tried first, then the old order behind it
	elif _pressed():
		wanted = [&"walls"] + BUILD_ORDER   # under threat, the wall comes first
	for s: Dictionary in cs.settlements:
		if s["owner"] != seat:
			continue
		for name: StringName in wanted:
			if int(Rules.STRUCTURES[name]["cost"]) > purse:
				continue
			for tile in cs.structures.size():
				if Campaign.hex_distance(tile, s["tile"]) > Rules.WORK_RADIUS:
					continue
				if cs.can_place(seat, tile, name):
					out.append(Orders.build(tile, name))
					return                 # one a turn; the rest can wait for income


## One tech a turn at most, the first in its order it can actually pay for.
func _learn_something(cs, out: Array) -> void:
	# can_learn is the gate, not the advice. Something it cannot afford or has not the
	# prerequisites for falls through to the list, exactly as if nobody had asked.
	var advised = advice.get("tech")
	if advised != null and cs.can_learn(seat, advised):
		out.append(Orders.research(advised))
		return
	for name: StringName in TECH_ORDER:
		if cs.can_learn(seat, name):
			out.append(Orders.research(name))
			return


func _recruit_something(cs, out: Array) -> void:
	# Only raise what it can feed, or it starves itself into a rout on turn six.
	if int(cs.food.get(seat, 0)) < cs.upkeep_of(seat):
		return
	var purse := int(cs.gold.get(seat, 0))
	# Expand first, while there is anywhere left to expand into. A settler is worth more
	# than the regiment it displaces: a new town is income and research every turn for
	# the rest of the campaign, and the AI that only ever recruited soldiers simply lost
	# on production to anybody who did not.
	if _wants_a_settler(cs) and purse >= int(Rules.KINDS[Rules.SETTLER]["cost"]):
		for s: Dictionary in cs.settlements:
			if s["owner"] == seat:
				out.append(Orders.recruit(s["tile"], Rules.SETTLER))
				return
	# A ram, once there is a walled town worth marching on and nobody carrying one. It
	# is useless in every other fight, so buying it speculatively is a wasted regiment
	# and buying it late is a siege you sit through.
	if _wants_a_ram(cs) and purse >= int(Rules.KINDS[Rules.RAM]["cost"]):
		for s: Dictionary in cs.settlements:
			if s["owner"] == seat and cs.recruitable_at(s["tile"]).has(Rules.RAM):
				out.append(Orders.recruit(s["tile"], Rules.RAM))
				return
	for s: Dictionary in cs.settlements:
		if s["owner"] != seat:
			continue
		var best := &""
		var best_cost := 0
		for kind: StringName in cs.recruitable_at(s["tile"]):
			if kind == Rules.SETTLER or kind == Rules.RAM:
				continue               # neither is a soldier; both are bought on purpose
			var cost := int(Rules.KINDS[kind]["cost"])
			if cost <= purse and cost > best_cost:
				best = kind                # the best it can afford, not the cheapest
				best_cost = cost
		if best != &"":
			out.append(Orders.recruit(s["tile"], best))
			return


## Take the peace, or fight on.
##
## Jev's answer is a **noul** -- the probability that a statement is true, which is the
## first non-`choice` question this game asks. It suits exactly this: a yes-or-no about a
## state, where the number IS the confidence and there is no list of options to pick from.
## A noul at or above 0.5 is a yes; below it, or with no key at all, the heuristic has it.
##
## The heuristic is the shape `_beaten` uses in a battle, one layer up: accept when they
## have more towns and more men than we do, because a peace is worth most to whoever is
## losing and a player who is winning has no reason to stop.
func _accepts_peace(cs, from_seat: int) -> bool:
	var said = advice.get("peace")
	if said != null:
		return float(said) >= 0.5
	var ours: int = cs.settlements_of(seat) * TOWN_WORTH + cs.men_of(seat)
	var theirs: int = cs.settlements_of(from_seat) * TOWN_WORTH + cs.men_of(from_seat)
	return float(ours) < float(theirs) * PEACE_RATIO


## What a town counts for against a headcount when deciding whether we are losing. A town
## is worth roughly a full army, or an empire that had just lost a battle would sue for
## peace while holding the whole map.
const TOWN_WORTH := 300
const PEACE_RATIO := 0.8


## One settler in the field at a time, and only while the map has room. Two at once is
## two escorts it has not got, and a settler wandering alone is a gift.
func _wants_a_settler(cs) -> bool:
	# A NOUL: "this empire is holding more than it can govern". The heuristic below
	# counts towns against a flat cap, where the real question is whether the unrest
	# ceiling can absorb another one -- which is a judgement, not a count.
	var stretched = advice.get("overextended")
	if stretched != null and float(stretched) >= 0.5:
		return false
	if cs.settlements_of(seat) >= MAX_TOWNS:
		return false
	for a in cs.armies.values():
		if a["owner"] == seat and cs.settler_in(a) >= 0:
			return false
	return _somewhere_to_settle(cs, -1) >= 0


## Is somebody at the gates? Jev answers this as a score over ordered levels and the
## threshold is ours, which is the doctrine everywhere else in here: the model makes the
## fuzzy judgement and we decide what to do at what level.
##
## No advice means no, deliberately. Without a key the AI plays exactly the game it played
## before any of this existed.
func _pressed() -> bool:
	var level = advice.get("threat")
	return level != null and float(level) >= PRESSED_AT


## Where on the quiet / watchful / pressed scale we start behaving as though it is real.
## High, because digging in is expensive: it costs the army its whole turn.
const PRESSED_AT := 0.66


## One ram in the field at a time, and only while somebody we might march on is behind
## a wall. Without a wall to knock down it is thirty men who cannot fight.
func _wants_a_ram(cs) -> bool:
	for a in cs.armies.values():
		if a["owner"] == seat:
			for r: Array in a["regiments"]:
				if r[0] == Rules.RAM:
					return false
	for s: Dictionary in cs.settlements:
		if s["owner"] != seat and cs.structure_at(int(s["tile"])) == &"walls":
			return true
	return false


## The nearest hex a town could legally go on, from `from` (-1 means from anywhere, which
## is how it answers "is there any room left at all"). Everything about WHERE is
## can_found's rule; this only has to find ground that passes it.
func _somewhere_to_settle(cs, from: int) -> int:
	var best := -1
	var best_distance := 1 << 30
	for tile in cs.terrain.size():
		if not cs.passable(tile):
			continue
		var clear := true
		for s: Dictionary in cs.settlements:
			if Campaign.hex_distance(tile, int(s["tile"])) < Rules.MIN_TOWN_DISTANCE:
				clear = false
				break
		if not clear:
			continue
		if from < 0:
			return tile
		var d := Campaign.hex_distance(from, tile)
		if d < best_distance:
			best_distance = d
			best = tile
	return best


## Put the town down if we are standing somewhere it may go; otherwise walk toward
## somewhere it may. An army carrying settlers does not march at the enemy -- `_march`
## skips it, which is what `_settling` is for.
func _settle_something(cs, out: Array) -> void:
	_settling.clear()
	for id in cs.sorted_army_ids():
		var a = cs.armies[id]
		if a["owner"] != seat or cs.settler_in(a) < 0:
			continue
		_settling[id] = true
		if a["move_left"] <= 0:
			continue
		if cs.can_found(seat, id):
			out.append(Orders.found(id))
			continue
		var spot := _somewhere_to_settle(cs, int(a["tile"]))
		if spot >= 0:
			out.append(Orders.army_move(id, spot))


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


## A remnant standing next to a bigger army of ours joins it, rather than wandering
## off alone to be picked off. One merge a turn is plenty.
const REMNANT := 3

## How many towns the AI will try to found before it stops expanding and just fights.
## Not a cap on what it can hold -- conquest is unlimited -- only on how long it keeps
## spending 200 gold on somebody with a shovel.
const MAX_TOWNS := 4

## Armies carrying settlers this turn, so `_march` does not send them at the enemy.
## Rebuilt every turn from the world rather than remembered: an army that lost its
## settlers in a battle must stop being a settling party, and the AI object outlives
## the battle, which is exactly how the cavalry sweep's stale waypoints got in.
var _settling := {}

## A seat that has offered us peace and is waiting. Written from outside by `net.gd` --
## the same shape `advice` has, and for the same reason: this file stays a pure
## RefCounted that reads plain data and never reaches for a node or the network.
var pending_offer := 0

## A raiding band rather than a player: it only ever marches. Set by `net.gd` for
## the barbarian owner, which is an owner id and NOT a seat -- see
## Rules.BARBARIAN_SEAT, and the comment there for why that distinction does all
## the work by itself.
var raids := false


func _gather_up(cs, out: Array) -> void:
	for id in cs.sorted_army_ids():
		var a = cs.armies[id]
		if a["owner"] != seat or a["regiments"].size() > REMNANT or a["move_left"] <= 0:
			continue
		for other in cs.sorted_army_ids():
			if other == id:
				continue
			var b = cs.armies[other]
			if b["owner"] != seat or b["regiments"].size() <= a["regiments"].size():
				continue
			if cs.can_merge(seat, id, other):
				out.append(Orders.merge(id, other))
				return


func _march(cs, out: Array) -> void:
	var target := _nearest_prize(cs)
	if target < 0:
		return
	for id in cs.sorted_army_ids():
		var a = cs.armies[id]
		if _settling.has(id):
			continue                       # it has somewhere else to be
		if a["owner"] != seat or a["move_left"] <= 0:
			continue
		# A long approach is worth arriving tired for; the tile next door is not. The
		# stance goes out BEFORE the move, since it is what decides how far that move
		# gets -- and it costs nothing on a turn the army was marching anyway.
		var far: bool = Campaign.hex_distance(int(a["tile"]), target) > FORCE_MARCH_BEYOND
		var want: int = Campaign.Stance.FORCED if far else Campaign.Stance.MARCH
		# A SCORE, read as a threshold: under real pressure the army stops marching at
		# the enemy and digs in where it is. A score is the right shape here because the
		# answer is how much, not which -- and the threshold is ours, as always.
		if _pressed() and Campaign.hex_distance(int(a["tile"]), target) > 1:
			want = Campaign.Stance.FORTIFY
		if Campaign.stance_of(a) != want:
			out.append(Orders.army_stance(id, want))
		out.append(Orders.army_move(id, target))


## Getting through a wall, or standing behind one. A branch rather than a mode: the
## moment the last segment is breached this returns null and the AI goes back to fighting
## the battle it already knows how to fight.
## Annotated Variant because it has three answers, and the difference between two of them
## matters: `null` means there is no wall in this battle and the ordinary logic should
## run, while an EMPTY array means hold where you are and issue nothing.
func _siege_orders(bs, mine: Array) -> Variant:
	var standing := []
	for w: Array in bs.walls:
		if bs.standing(w):
			standing.append(w)
	if standing.is_empty():
		return null                        # no wall, or not any more: fight normally
	var gate := _gate_of(standing)
	var side := signf(float(standing[0][0]))
	if signf(_centre(mine).x) == side:
		# We are the ones behind it. Standing still IS the plan: coming out through our
		# own gate hands back the whole advantage, and the attacker has to come to us.
		return []

	var out := []
	for r: Regiment in mine:
		if r.state == Regiment.State.FIGHTING or r.state == Regiment.State.ROUTING:
			continue
		var to: Vector2 = gate
		if r.kind == Rules.RAM:
			# Rams at the nearest segment, a little short of it so they stop against
			# the wall rather than trying to walk into it.
			var w: Array = _nearest_segment(standing, r.pos)
			var mid := (Vector2(w[0], w[1]) + Vector2(w[2], w[3])) * 0.5
			to = mid - Vector2(side * Rules.BREACH_REACH * 0.5, 0.0)
		# Facing the wall: it stands on `side`, so an attacker coming at it from the
		# other half looks along +x when side is positive and -x when it is not.
		var face := 0.0 if side > 0.0 else PI
		out.append(Orders.battle_move(PackedInt32Array([r.id]), to, face))
	return out


## The middle of the gap. Worked out from the two segment ends nearest the centre line
## rather than stored, so it keeps meaning the same thing if the wall ever changes shape.
static func _gate_of(standing: Array) -> Vector2:
	var best := INF
	var at := Vector2.ZERO
	for w: Array in standing:
		for p in [Vector2(w[0], w[1]), Vector2(w[2], w[3])]:
			if absf(p.y) < best:
				best = absf(p.y)
				at = p
	return Vector2(at.x, 0.0)


static func _nearest_segment(standing: Array, from: Vector2) -> Array:
	var best: Array = standing[0]
	var best_d := INF
	for w: Array in standing:
		var mid := (Vector2(w[0], w[1]) + Vector2(w[2], w[3])) * 0.5
		var d := from.distance_squared_to(mid)
		if d < best_d:
			best_d = d
			best = w
	return best


## The nearest thing worth walking to: an enemy or neutral settlement.
func _nearest_prize(cs) -> int:
	var home := -1
	for id in cs.sorted_army_ids():
		if cs.armies[id]["owner"] == seat:
			home = cs.armies[id]["tile"]
			break
	if home < 0:
		return -1
	# A named settlement wins if it is still somebody else's. Distance alone rates a
	# defended capital and an empty village the same, which is the one judgement here
	# most worth handing over.
	var advised := int(str(advice.get("target", "-1")))
	for s: Dictionary in cs.settlements:
		if int(s["tile"]) == advised and s["owner"] != seat:
			return advised
	var best := -1
	var best_distance := 1 << 30
	for s: Dictionary in cs.settlements:
		if s["owner"] == seat:
			continue
		# Raiders go for what somebody HOLDS. An empty village is not a raid, and
		# it would park every band on a neutral town for the whole campaign.
		if raids and int(s["owner"]) == 0:
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
	# It takes the line it was dealt. Saying so at once rather than sitting out the
	# clock is what keeps an AI battle from opening with a minute of nothing -- and an
	# AI that never said it was ready would do exactly that, every time.
	# ponytail: it does not arrange anything first. A planner that sets its own frontage
	# and puts the horse on a wing before the fight is the upgrade.
	if bs.phase == bs.Phase.DEPLOY:
		return [] if bool(bs.ready.get(seat, false)) else [Orders.deployed(true)]
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

	# Checked before anything else is ordered: there is no point dressing a line that is
	# about to walk off the field. One order, and the battle is over.
	if _beaten(mine, foes):
		return [Orders.forfeit(true)]

	# A wall changes the question entirely: everything behind it is unreachable, so the
	# line has no business dressing against the enemy centre. It goes for the gate, the
	# rams go for the wall, and only once something is open does the ordinary fight
	# resume -- at which point `walls` no longer blocks and this branch falls through.
	var assault = _siege_orders(bs, mine)
	if assault != null:
		return assault

	var enemy_centre := _centre(foes)
	var my_centre := _centre(mine)
	var approach := (enemy_centre - my_centre)
	if approach.length_squared() < 1.0:
		approach = Vector2.RIGHT
	approach = approach.normalized()
	var across := Vector2(-approach.y, approach.x)

	var out := []
	var posture := StringName(str(advice.get("posture", &"commit")))

	# Withdrawing is an order, not the absence of one. The sim stops a march INTO the
	# enemy and not one away from it, so this genuinely breaks contact -- and the horses
	# have to be called off with everyone else, or they go on riding round a fight that
	# is no longer happening. Re-issued only once a regiment has arrived or been caught,
	# never while it is already walking back.
	# Latches are keyed by regiment id and this object outlives the battle, so without a
	# prune a dead regiment's waypoint persists -- and worse, ids from the LAST battle
	# silence a regiment in this one before it has moved.
	var alive := {}
	for r: Regiment in mine:
		alive[r.id] = true
	for id in _sweep_to.keys():
		if not alive.has(id):
			_sweep_to.erase(id)
	for id in _wrap_to.keys():
		if not alive.has(id):
			_wrap_to.erase(id)

	if posture == &"withdraw":
		_sweep_to.clear()
		_wrap_to.clear()
		for r: Regiment in mine:
			if r.state == Regiment.State.ROUTING or r.state == Regiment.State.MOVING:
				continue
			out.append(Orders.battle_move(PackedInt32Array([r.id]),
				r.pos - approach * WITHDRAW_STEP, approach.angle()))
		return out

	# Has anybody actually met? Until then everything forms a line and walks, exactly as
	# before. Envelopment is an answer to a fight that exists, not an opening move.
	var locked := false
	for r: Regiment in mine:
		if r.state == Regiment.State.FIGHTING:
			locked = true
			break

	# How many regiments may go round at once. The envelopment is otherwise limited
	# only by geometry -- a regiment wraps if nobody is in front of it -- with
	# nothing weighing that against a thinner centre. At the middle of the scale
	# this is the whole line, which is what it was, so no advice changes nothing.
	var wrap_budget: int = maxi(1, int(round(float(mine.size()) * _envelop_appetite() * 2.0)))
	var wrapped := 0

	var foot := []
	for r: Regiment in mine:
		if r.can_shoot():
			continue                       # handled by _stand_off
		if float(Rules.KINDS[r.kind]["speed"]) >= Rules.CAVALRY_SPEED:
			_sweep(r, out, my_centre, enemy_centre, approach, across,
				_release_the_horse(locked))
		elif locked and posture == &"commit" and wrapped < wrap_budget \
				and _wrap(r, foes, out, my_centre, enemy_centre, approach, across):
			wrapped += 1                   # going round: no line slot as well
		else:
			foot.append(r)

	# A CHOICE, and the only one of the four that names a thing rather than judging
	# a situation. Breaking one regiment at the end of a line sends the panic down
	# it, so WHICH one is worth asking about -- and the answer rides in the same
	# request as the posture. `focus` is already the cleanest lever in this file:
	# the sim recomputes the chase every tick with nobody re-issuing anything.
	_concentrate(mine, foes, out)

	_mind_the_cavalry(mine, foes, out)

	var shooters := []
	for r: Regiment in mine:
		if r.can_shoot():
			shooters.append(r)
	_stand_off(shooters, foes, out, enemy_centre, approach)

	# Everything slow forms one line and walks at them -- unless somebody is already
	# within reach, in which case it goes and fights instead of dressing ranks.
	#
	# The line is laid out to OVERLAP theirs at the ends, which is where the envelopment
	# comes from. Spaced by a flat constant it was 110 units per regiment against their
	# 150, so it was always the NARROWER line: its ends were the ones being lapped round,
	# and no regiment ever found itself past a flank with nobody in front of it.
	var reach_out := _half_span(foes, enemy_centre, across) + OVERHANG
	for i in foot.size():
		var r: Regiment = foot[i]
		if r.state != Regiment.State.IDLE and r.state != Regiment.State.MOVING:
			continue
		var near = _nearest(r, foes)
		var target: Vector2
		var face: float
		# Holding keeps the standoff line so the archers can work -- nobody looses on the
		# move or in a melee, so closing is what ends the shooting. Skipping this one
		# branch is the whole difference between holding and committing.
		if posture != &"hold" and near != null and r.pos.distance_to(near.pos) < ENGAGE_RANGE:
			target = near.pos
			face = (near.pos - r.pos).angle()
		else:
			# Everyone keeps the line's own spacing; only the outermost regiment on each
			# side is pushed out past the end of theirs, and never by more than one more
			# spacing. It scales itself: with three regiments the wings reach as far as
			# that allows, and with five the line already overhangs so they barely move.
			var slot := (float(i) - float(foot.size() - 1) * 0.5) * LINE_SPACING
			if foot.size() >= 3 and (i == 0 or i == foot.size() - 1):
				# Stretch out toward their flank, but never far enough to leave more than
				# one regiment's own width of open ground beside it. That is the line
				# between a line with horns and a set of separate columns, and it is the
				# rule the last attempt had no expression of at all.
				var span := Formation.frontage(r.max_strength, r.width, r.spacing()) * 2.0
				var most := maxf(0.0, span * 2.0 - LINE_SPACING)
				slot += signf(slot) * clampf(reach_out - absf(slot), 0.0, most)
			target = enemy_centre + across * slot - approach * STANDOFF
			# A regiment walking at the enemy FACES the enemy. Aiming each slot at the
			# enemy centre instead turned the wings 72 degrees off the advance -- walking
			# in with their own flanks presented, which is the one thing the whole combat
			# model says not to do. Turning in is what _wrap is for, after contact, with a
			# latched waypoint and a focus order.
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


## Is this beaten rather than merely losing? `mine` carries our routers, `foes` does not
## carry theirs, so both counts are of men still willing to fight.
static func _beaten(mine: Array, foes: Array) -> bool:
	var ours := 0
	var theirs := 0
	var broken := 0
	for r: Regiment in mine:
		if r.state == Regiment.State.ROUTING:
			broken += 1
		else:
			ours += r.strength
	for r: Regiment in foes:
		theirs += r.strength
	if theirs <= 0:
		return false
	return float(ours) < float(theirs) * GIVE_UP_RATIO \
		and float(broken) / float(mine.size()) >= GIVE_UP_BROKEN


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
func _sweep(r: Regiment, out: Array, my_centre: Vector2, enemy_centre: Vector2,
		approach: Vector2, across: Vector2, go := true) -> void:
	if r.state == Regiment.State.FIGHTING or r.state == Regiment.State.ROUTING:
		return

	# Held on the wing until the moment is right. A charge is a multiplier on a
	# window of CHARGE_SECONDS and there was no rule for WHEN to spend it -- the
	# horse went in whenever the line did, which is when it is worth least.
	if not go and _sweep_to.get(r.id) == null:
		return                             # already round the side; wait there
	if not _sweep_to.has(r.id):
		var side := _side_of_the_line(r, my_centre, across)
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


## Is it time to let the cavalry go?
##
## A NOUL -- the probability that "now is the moment" is true, thresholded at
## ours. The right shape: no list to choose from, a judgement about an instant,
## and the number the model returns already IS its confidence.
##
## Without advice the horse goes when the lines are locked, which is what it did
## before any of this and is the same answer every other Jev failure produces.
func _release_the_horse(locked: bool) -> bool:
	var now = advice.get("charge")
	return float(now) >= 0.5 if now != null else locked


## How much of the line to send round, from Jev's SCORE. The middle answer is what
## the geometry did on its own -- send whatever has nobody in front of it -- so no
## advice changes nothing, and the ends widen or narrow the appetite either side.
func _envelop_appetite() -> float:
	var much = advice.get("envelop")
	return float(much) if much != null else 0.5


## Everybody not already dealing with somebody goes after the one Jev named.
##
## Only the idle: re-pointing a regiment already locked in a melee would pull it
## out of the fight it is in, and `order_move` is not idempotent -- the lesson the
## whole file is built round.
func _concentrate(mine: Array, foes: Array, out: Array) -> void:
	var named = advice.get("mark")
	if named == null:
		return
	var mark := int(str(named))
	var exists := false
	for f: Regiment in foes:
		if f.id == mark:
			exists = true
			break
	if not exists:
		return                         # it died while the answer was in flight
	for r: Regiment in mine:
		if r.state == Regiment.State.FIGHTING or r.state == Regiment.State.ROUTING:
			continue
		if r.can_shoot() or r.focus == mark:
			continue               # the archers have their own rule, in _stand_off
		out.append(Orders.focus(PackedInt32Array([r.id]), mark))


## Which wing of OUR OWN line this regiment stands on, +1 or -1.
##
## Measured from our centre. `_sweep` used to measure from the world ORIGIN, so two
## horsemen both on the left of our line but right of the map's middle both swung the
## same way and the other flank was never touched.
static func _side_of_the_line(r: Regiment, my_centre: Vector2, across: Vector2) -> float:
	return 1.0 if (r.pos - my_centre).dot(across) >= 0.0 else -1.0


## Go round the end of the line rather than queueing up behind it. Returns true if this
## regiment is enveloping, so the caller leaves it out of the line.
##
## Three stages, and the last one is the trick. A flank position is by definition a point
## computed from a MOVING enemy, which is the shape of bug that has already eaten the
## archers, the cavalry sweep and the withdrawal step: re-issue it every think and the
## regiment creeps after a receding point and never arrives. So the outward leg is
## LATCHED, and the moment it lands the regiment is handed to the sim instead --
## `Orders.focus` means "deal with that one", and BattleState._pursue keeps the target
## current every tick, closing from whichever side the regiment is standing on, without
## anybody issuing another order at all.
func _wrap(r: Regiment, foes: Array, out: Array, my_centre: Vector2, enemy_centre: Vector2, approach: Vector2, across: Vector2) -> bool:
	if r.state == Regiment.State.ROUTING:
		_wrap_to.erase(r.id)
		return false

	# It has found somebody. That was the entire point, so the manoeuvre is OVER: mark it
	# done, name the man it ran into so the sim keeps it on him, and never speak to it
	# again. Without this the regiment kept its now-stale waypoint, and the moment the
	# melee let go of it for a tick it was ordered back out to a patch of grass the enemy
	# had long since left -- in and out of contact, twice a second, all battle.
	if r.state == Regiment.State.FIGHTING or r.engaged_with != -1:
		if _wrap_to.get(r.id) != null:
			_wrap_to[r.id] = null
			if r.engaged_with != -1 and r.focus != r.engaged_with:
				out.append(Orders.focus(PackedInt32Array([r.id]), r.engaged_with))
		return false
	if _wrap_to.has(r.id) and _wrap_to[r.id] == null:
		return false                       # already had its go; it is line infantry now

	# Already committed: the sim is walking it in, and re-ordering would only reset it to
	# MOVING at a point it has since left. Say nothing, and stay out of the line.
	#
	# If the man it named is gone from `foes` -- dead, or broken and running -- fall
	# through and pick another. Nothing is cleared here: this file emits ORDERS and never
	# touches sim state, and the focus order below overwrites it anyway.
	if _marked(r, foes):
		return true

	var side := _side_of_the_line(r, my_centre, across)
	var mark = _outermost(foes, enemy_centre, across, side)
	if mark == null:
		return false

	if not _wrap_to.has(r.id):
		# Outside his flank, not into his front: half his FRONTAGE plus half our depth,
		# and then enough margin that the approach is unmistakably round the end.
		var clear := BattleState.reach(mark, BattleState.Exposure.FLANK) \
			+ BattleState.reach(r, BattleState.Exposure.FRONT) + WRAP_MARGIN
		_wrap_to[r.id] = mark.pos + across * side * clear - approach * WRAP_BACK

	var waypoint: Vector2 = _wrap_to[r.id]
	if r.pos.distance_to(waypoint) > WRAP_ARRIVED:
		out.append(Orders.battle_move(PackedInt32Array([r.id]), waypoint,
			(mark.pos - r.pos).angle()))
		return true

	# Round the end. Hand it to the sim and stop talking to it.
	_wrap_to.erase(r.id)
	out.append(Orders.focus(PackedInt32Array([r.id]), mark.id))
	return true


## Has this regiment been told to deal with somebody who is still on the field? If so the
## sim is steering it every tick and nothing here should say another word to it.
static func _marked(r: Regiment, foes: Array) -> bool:
	if r.focus < 0:
		return false
	for f: Regiment in foes:
		if f.id == r.focus:
			return true
	return false                           # dead, or broken and running


## The enemy furthest out on this side of the field, preferring one that is already
## pinned: a regiment somebody else is holding by the nose cannot turn to meet you, which
## is the entire reason for going round.
static func _outermost(foes: Array, enemy_centre: Vector2, across: Vector2, side: float):
	var best = null
	var best_along := -INF
	var best_pinned := false
	for f: Regiment in foes:
		var along := (f.pos - enemy_centre).dot(across) * side
		var pinned: bool = f.engaged_with != -1
		if best == null or (pinned and not best_pinned) \
				or (pinned == best_pinned and along > best_along):
			best = f
			best_along = along
			best_pinned = pinned
	return best


## How far the outermost of these reaches from their own centre, across the line of
## approach. Half the width of the formation we are walking at.
static func _half_span(regiments: Array, centre: Vector2, across: Vector2) -> float:
	var out := 0.0
	for r: Regiment in regiments:
		out = maxf(out, absf((r.pos - centre).dot(across)))
	return out


static func _centre(regiments: Array) -> Vector2:
	var sum := Vector2.ZERO
	for r: Regiment in regiments:
		sum += r.pos
	return sum / float(regiments.size())
