extends Node
## Jev (TypeSafe AI) -- the opponent's scorer.
##
## Jev is a "System One" model: it writes no prose. It evaluates a state against typed
## questions and returns a bounded choice with a calibrated confidence. That is the only
## reason it is safe to put in here -- it cannot invent an option that was not on the
## list, so it can only REORDER legal moves `sim/ai.gd` already found. Everything it
## advises still goes through `can_learn` / `can_place` and still comes out of the AI as
## an encoded order landing in `_receive_order`, exactly like a human's click. If Jev
## cannot express something as a legal order, neither could a player.
##
## It is advisory and nothing more. No key, a timeout, a 429, a mangled reply -- every
## failure is the same failure: the advice dictionary stays empty and the AI plays the
## heuristics it always played. That is what keeps test.cmd, nettest.cmd, camptest.cmd
## and aitest.cmd green on a machine with no key.
##
## Note what "deterministic" does and does not mean here. TypeSafe promise a
## deterministic POLICY -- the thresholds live in our code, at MIN_CONFIDENCE below --
## not a deterministic model, and `jev-latest` is a mutable alias whose answers can
## change under us with no change on our side. That is survivable only because
## `net/net.gd` records the order BYTES into the replay, stamped with the tick, so a
## recorded battle still reproduces itself whoever chose the orders. Replaying a
## recording stays exact; re-running a SCENARIO was never reproducible anyway, because
## the AI has always thought from `_process`, once per rendered frame.

const Rules := preload("res://sim/rules.gd")
const Campaign := preload("res://sim/campaign_state.gd")
const Regiment := preload("res://sim/regiment.gd")

const ENV_PATH := "res://.env"
const ENDPOINT := "/v1/systemone"

## Every answer is written here, the dropped ones too. Beside the replays and the saves,
## for the same reason: it is the record of a game that has already happened.
## ponytail: appends forever. A few KB a battle, so truncate it when it annoys you.
const LOG_PATH := "user://jev.log"

## Below this the answer is dropped and the heuristic has it. Jev's own doctrine: the
## model makes the fuzzy judgement, the threshold is ours. This is the tuning knob.
const MIN_CONFIDENCE := 0.45
## A turn must never hang on a network. Well past the documented 70-500ms.
const TIMEOUT := 4.0
## The floor between two battle questions, so a cascade of changes in one second is not a
## flood of requests. WALL CLOCK, deliberately -- counted in sim ticks, a slow frame would
## change how often the opposition gets advice. There is no ceiling on purpose: a fight
## where nothing is happening needs no new stance, and asking anyway was the old bug.
const BATTLE_MIN_INTERVAL := 0.5

var base_url := "https://api.typesafe.ai"
var model := "jev-latest"

var _key := ""
var _inflight := {}                # seat -> true while a request is out
var _asked_on_turn := {}           # seat -> the campaign turn we last asked on
var _asked_at := {}                # seat -> ticks_msec of the last battle question
var _last_shape := {}              # seat -> [bs.tick when taken, the shape it was]

## The last set of questions built, and how many requests have been made. Not used by
## anything that plays the game -- they exist so the economy of this can be MEASURED:
## adding questions must not add round trips.
var last_questions := {}
var requests := 0


func _init() -> void:
	var cfg := config()
	_key = str(cfg.get("TYPESAFE_API_KEY", ""))
	if str(cfg.get("TYPESAFE_BASE_URL", "")) != "":
		base_url = str(cfg["TYPESAFE_BASE_URL"])
	if str(cfg.get("TYPESAFE_DEFAULT_MODEL", "")) != "":
		model = str(cfg["TYPESAFE_DEFAULT_MODEL"])
	_write("--- %s, keeping the log at %s" % [
		model, ProjectSettings.globalize_path(LOG_PATH)])


# --- configuration --------------------------------------------------------

## The project's first config reader. A real environment variable WINS over the file,
## because res://.env is packed into an export and a shipped build has no business
## carrying a key at all.
## ponytail: res://.env for convenience; set the real env var for anything exported.
static func config() -> Dictionary:
	var out := {}
	if FileAccess.file_exists(ENV_PATH):
		out = read_env(FileAccess.get_file_as_string(ENV_PATH))
	for name in ["TYPESAFE_API_KEY", "TYPESAFE_BASE_URL", "TYPESAFE_DEFAULT_MODEL"]:
		var live := OS.get_environment(name)
		if live != "":
			out[name] = live
	return out


## Split on the FIRST `=` only, so a value may contain one.
static func read_env(text: String) -> Dictionary:
	var out := {}
	for raw in text.split("\n"):
		var line := raw.strip_edges()
		if line.is_empty() or line.begins_with("#"):
			continue
		var at := line.find("=")
		if at <= 0:
			continue
		out[line.substr(0, at).strip_edges()] = line.substr(at + 1).strip_edges()
	return out


## Whether it is worth constructing one at all. net.gd asks before it adds the node.
static func have_key() -> bool:
	return str(config().get("TYPESAFE_API_KEY", "")) != ""


# --- the wire -------------------------------------------------------------

## An answer that is not confident enough is not an answer. Anything dropped here is the
## same as never having asked: the heuristic takes it.
static func parse_answers(body: Dictionary, min_confidence := MIN_CONFIDENCE) -> Dictionary:
	var out := {}
	var answers = body.get("answers")
	if not answers is Dictionary:
		return out
	for key in answers:
		var a = answers[key]
		if not a is Dictionary:
			continue
		var confident := float(a.get("confidence", 0.0)) >= min_confidence
		match str(a.get("type", "")):
			"choice":
				if confident and a.has("choice"):
					out[str(key)] = StringName(str(a["choice"]))
			"score":
				if confident and a.has("score"):
					out[str(key)] = float(a["score"])
			"noul":
				# A noul carries no separate confidence -- the number IS one.
				if a.has("noul"):
					out[str(key)] = float(a["noul"])
	return out


## What Jev said, in one readable line, INCLUDING what was thrown away.
##
## A dropped answer is the most interesting thing in the log when you are deciding where
## MIN_CONFIDENCE belongs: it is the model telling you it had an opinion and was not sure
## enough to be listened to. Logging only what was taken would hide exactly the evidence
## you need to tune the threshold.
static func decisions(parsed, taken: Dictionary) -> String:
	var answers = parsed.get("answers") if parsed is Dictionary else null
	if not answers is Dictionary or (answers as Dictionary).is_empty():
		return "nothing usable came back"
	var parts := PackedStringArray()
	for key in answers:
		var a = answers[key]
		if not a is Dictionary:
			continue
		var value = a.get("choice", a.get("score", a.get("noul", "?")))
		# A noul has no separate confidence, because the number already is one.
		var sure := float(a.get("confidence", a.get("noul", 0.0)))
		parts.append("%s=%s (%.2f)%s" % [key, value, sure,
			"" if taken.has(str(key)) else " DROPPED"])
	return " ".join(parts)


## Opened and closed a line at a time, so the log is complete even when the game is
## killed rather than closed -- which is how a game under test usually ends.
func _write(line: String) -> void:
	var stamped := "%s  %s" % [Time.get_datetime_string_from_system(false, true), line]
	print("[jev] %s" % stamped)
	var f := FileAccess.open(LOG_PATH,
		FileAccess.READ_WRITE if FileAccess.file_exists(LOG_PATH) else FileAccess.WRITE)
	if f == null:
		return
	f.seek_end()
	f.store_line(stamped)


func pending(seat: int) -> bool:
	return _inflight.has(seat)


## `context` is for the log alone -- "turn 7", "battle 34s" -- so a line says when it was
## asked without carrying the whole state string.
func ask(seat: int, context: String, state: String, questions: Dictionary,
		on_answer: Callable) -> void:
	# Recorded before the key check, because what MATTERS about this is the shape of the
	# request and that is decided whether or not there is anybody to send it to. It is
	# what `test_jev.gd` measures: the questions must ride in one round trip, not one
	# each, and a test that needed a live key to check that would never run.
	last_questions = questions
	if questions.is_empty():
		return
	requests += 1
	if _key.is_empty() or _inflight.has(seat):
		return
	var http := HTTPRequest.new()
	http.timeout = TIMEOUT
	add_child(http)
	http.request_completed.connect(_answered.bind(seat, http, on_answer, context))
	var headers := PackedStringArray([
		"Content-Type: application/json",
		"Authorization: Bearer " + _key,
	])
	var body := JSON.stringify({"state": state, "model": model, "questions": questions})
	if http.request(base_url + ENDPOINT, headers, HTTPClient.METHOD_POST, body) != OK:
		http.queue_free()
		on_answer.call({})
		return
	_inflight[seat] = true


func _answered(result: int, code: int, _headers: PackedStringArray, body: PackedByteArray,
		seat: int, http: HTTPRequest, on_answer: Callable, context: String) -> void:
	_inflight.erase(seat)
	http.queue_free()
	if result != HTTPRequest.RESULT_SUCCESS or code != 200:
		# 401 bad key, 422 bad question, 429 rate limited, 529 overloaded -- all one
		# thing from here: no advice, and the heuristic plays this turn.
		# ponytail: no backoff on 429/529. Add one if the AI visibly skips turns.
		_write("%s | seat %d | no answer (result %d, http %d)" % [context, seat, result, code])
		on_answer.call({})
		return
	var parsed = JSON.parse_string(body.get_string_from_utf8())
	var taken := parse_answers(parsed) if parsed is Dictionary else {}
	_write("%s | seat %d | %s" % [context, seat, decisions(parsed, taken)])
	on_answer.call(taken)


# --- campaign -------------------------------------------------------------

## Asked once at the top of a turn. Returns true while the answer is still out, which is
## net.gd's cue to hold the AI back -- `campaign_orders` is what appends End Turn, so
## holding it holds the turn. A human takes seconds to press End Turn and Jev takes a
## few hundred milliseconds, so it lands in time; when it does not, TIMEOUT clears the
## flag and the AI plays its heuristic.
func consider_turn(seat: int, cs, ai) -> bool:
	if cs == null or bool(cs.ready.get(seat, false)):
		return false
	if _asked_on_turn.get(seat, -1) != cs.turn:
		_asked_on_turn[seat] = cs.turn
		ai.advice.clear()             # a new turn invalidates everything, posture included
		# The offer rides in the SAME request as the build, tech and target questions.
		# Every question in one request is evaluated in parallel, so a fourth costs
		# almost nothing next to a second round trip for it.
		ask(seat, "turn %d" % int(cs.turn), campaign_state(cs, seat),
			campaign_questions(cs, seat, int(ai.pending_offer)),
			func(a): ai.advice.merge(a, true))
	return _inflight.has(seat)


## A question with one option is not a question, so a list of one is left out and the
## heuristic takes it. When nothing is worth asking `ask` never fires, and the AI acts
## on the same frame it would have anyway.
func campaign_questions(cs, seat: int, offer_from := 0) -> Dictionary:
	var out := {}

	var techs := {}
	for name: StringName in cs.learnable(seat):
		var spec: Dictionary = Rules.TECHS[name]
		techs[String(name)] = "%s tree, costs %d research: %s" % [
			spec["tree"], int(spec["cost"]), JSON.stringify(spec["effect"])]
	if techs.size() > 1:
		out["tech"] = {
			"type": "choice",
			"instructions": ("Which of these should be researched now? Research is a single"
				+ " pool shared by both trees, so a tech taken in one is a tech not taken"
				+ " in the other."),
			"criteria": techs,
		}

	var purse := int(cs.gold.get(seat, 0))
	var builds := {}
	for name: StringName in Rules.STRUCTURES:
		var cost: int = cs.cost_of(seat, name)
		if cost > purse:
			continue
		var spec: Dictionary = Rules.STRUCTURES[name]
		builds[String(name)] = "costs %d of our %d gold, earns %d gold %d food %d research a turn%s%s" % [
			cost, purse, int(spec["gold"]), int(spec["food"]), int(spec["research"]),
			"" if spec["unlocks"].is_empty() else ", and lets our towns raise " + _names(spec["unlocks"]),
			"" if float(spec["defense"]) == 0.0 else ", and a defender on that hex shrugs off %d percent of the damage" % int(float(spec["defense"]) * 100.0),
		]
	if builds.size() > 1:
		out["build"] = {
			"type": "choice",
			"instructions": ("Which structure should go up this turn? Only one a turn, on"
				+ " land one of this player's towns already works. It stands on the map"
				+ " where a raider can burn it, so it is not a safe purchase."),
			"criteria": builds,
		}

	var home := _home_tile(cs, seat)
	var prizes := {}
	for s: Dictionary in cs.settlements:
		if int(s["owner"]) == seat:
			continue
		var tile := int(s["tile"])
		var garrison = cs.army_at(tile)
		prizes[str(tile)] = "%s, %s, %d hexes from our army%s%s" % [
			str(s["name"]),
			"unowned" if int(s["owner"]) == 0 else "held by player %d" % int(s["owner"]),
			Campaign.hex_distance(home, tile) if home >= 0 else -1,
			"" if cs.structure_at(tile) == &"" else ", with a %s on it" % String(cs.structure_at(tile)),
			"" if garrison == null else ", defended by %d men" % Campaign.army_men(garrison),
		]
	if prizes.size() > 1:
		out["target"] = {
			"type": "choice",
			"instructions": ("Which settlement should this player's armies march on? Walls"
				+ " cut the damage a defender takes in a battle fought on their hex, so a"
				+ " walled town costs more to take than a further one without them."),
			"criteria": prizes,
		}

	# A NOUL: a yes-or-no about a state, answered as the probability the statement is
	# true. The first question here that is not a `choice`, and it is the right shape --
	# there is no list of options to pick from, and the number the model returns IS its
	# confidence rather than carrying one alongside.
	#
	# Asked only when somebody is actually waiting, which is what keeps it from costing a
	# question on every turn of every campaign.
	# A NOUL against the unrest ceiling. The heuristic cannot see the tradeoff at all:
	# `_wants_a_settler` counts towns against a flat cap, where the real question is
	# whether this empire can govern another one.
	out["overextended"] = {
		"type": "noul",
		# Parenthesised as a whole before the %: bound to the last literal alone it is one
		# placeholder taking two arguments, which Godot reports at RUNTIME and not at
		# parse time -- so the question went out malformed and nothing said so.
		"instructions": ("Is this player holding more than it can govern? Every settlement"
			+ " past %d adds unrest to all of them each turn, unrest suppresses what a town"
			+ " pays and stops it growing, and a town pushed far enough throws its owner"
			+ " out. It holds %d.") % [Rules.UNREST_FREE_TOWNS, cs.settlements_of(seat)],
	}

	# A SCORE against ordered levels, which is the shape the third question type is for:
	# not which thing, and not yes or no, but how much.
	out["threat"] = {
		"type": "score",
		"instructions": ("How much danger is this player's territory in right now? This"
			+ " decides whether its armies dig in where they stand and whether walls go to"
			+ " the top of the building list."),
		"criteria": {
			"quiet": "nothing hostile is anywhere near anything of ours",
			"watchful": "somebody is moving toward us but nothing is upon us yet",
			"pressed": "there are enemies on our land or at our gates right now",
		},
	}

	if offer_from != 0:
		out["peace"] = {
			"type": "noul",
			"instructions": ("Player %d has offered this player peace. Accepting means"
				+ " neither side's armies can attack the other or take their towns until"
				+ " somebody declares war again. Is accepting the right move?") % offer_from,
		}

	return out


## Is there anything worth asking the charge question about? A side with no horse has no
## charge to time, and a question nobody can act on is a question not worth the tokens.
static func _has_horse(bs, seat: int) -> bool:
	for id in bs.sorted_ids():
		var r = bs.regiments[id]
		if r.owner_id == seat and r.is_alive() and r.is_cavalry():
			return true
	return false


## The enemy regiments worth naming, described by what actually decides which one to
## break: how close it is to going, and whether anybody is beside it.
static func _marks(bs, seat: int) -> Dictionary:
	var out := {}
	for id in bs.sorted_ids():
		var r = bs.regiments[id]
		if r.owner_id == seat or not r.is_alive():
			continue
		var alone := true
		for other_id in bs.sorted_ids():
			var o = bs.regiments[other_id]
			if o.owner_id == r.owner_id and o.id != r.id and o.is_alive() 					and o.pos.distance_to(r.pos) <= Rules.SHOULDER_RADIUS:
				alone = false
				break
		out[str(id)] = "%s, %d of %d men, morale %d of 100%s%s" % [
			String(r.kind), r.strength, r.max_strength, int(r.morale),
			", already breaking" if r.state == Regiment.State.ROUTING else "",
			", with nobody beside it" if alone else "",
		]
	return out


func campaign_state(cs, seat: int) -> String:
	var lines := PackedStringArray()
	lines.append("Turn %d. You advise player %d in a turn-based campaign on a hex map." % [
		int(cs.turn), seat])
	lines.append("Treasury: %d gold, %d food, %d research. Army upkeep is %d food a turn, and an army that is not fed deserts." % [
		int(cs.gold.get(seat, 0)), int(cs.food.get(seat, 0)),
		int(cs.research.get(seat, 0)), cs.upkeep_of(seat)])
	var known: Array = cs.techs_of(seat)
	lines.append("Researched so far: %s." % ("nothing" if known.is_empty() else _names(known)))

	var towns := PackedStringArray()
	for s: Dictionary in cs.settlements:
		if int(s["owner"]) == seat:
			towns.append("%s on tile %d" % [str(s["name"]), int(s["tile"])])
	lines.append("Our %d towns: %s." % [towns.size(), "none" if towns.is_empty() else ", ".join(towns)])

	for id in cs.sorted_army_ids():
		var a: Dictionary = cs.armies[id]
		if int(a["owner"]) != seat:
			continue
		lines.append("Our army %d stands on tile %d with %d regiments, %d men, %d moves left." % [
			int(id), int(a["tile"]), a["regiments"].size(), Campaign.army_men(a), int(a["move_left"])])

	for other in cs.gold:
		if other == seat:
			continue
		lines.append("Rival player %d holds %d towns and %d men." % [
			int(other), cs.settlements_of(other), cs.men_of(other)])
	return "\n".join(lines)


## StringNames printed straight out carry their &"" syntax into the prose, which is
## noise in something a model reads.
static func _names(list: Array) -> String:
	var out := PackedStringArray()
	for name in list:
		out.append(String(name))
	return ", ".join(out)


static func _home_tile(cs, seat: int) -> int:
	for id in cs.sorted_army_ids():
		if int(cs.armies[id]["owner"]) == seat:
			return int(cs.armies[id]["tile"])
	return -1


# --- battle ---------------------------------------------------------------

## One coarse question, asked when the fight CHANGES rather than on a clock. A 20 Hz sim
## cannot wait on a network call, so the answer always lands a few ticks after the state
## it was asked about -- fine for a posture, and not fine for a move order, which is why
## this is the only thing asked. Never gated on: the battle keeps flowing whatever the
## network does.
##
## Asking on a change rather than a timer is both faster and cheaper. A regiment breaking
## moves the shape on the next think, so the request starts a third of a second after it
## happened instead of up to two; and two lines merely grinding against each other send
## nothing at all, where the timer sent one every two seconds to be told the same thing.
func consider_battle(seat: int, bs, ai) -> void:
	# Nothing recorded while a question is already out, or a change arriving mid-flight
	# would be marked as asked-about and then never asked about.
	if bs == null or _inflight.has(seat):
		return
	var now := Time.get_ticks_msec()
	if _asked_at.has(seat) and now - int(_asked_at[seat]) < int(BATTLE_MIN_INTERVAL * 1000.0):
		return
	var shape := _shape(bs, seat)
	# A new battle restarts the tick counter, and its opening shape could coincidentally
	# equal the last fight's closing one, so a counter going backwards is news by itself.
	var seen: Array = _last_shape.get(seat, [])
	if not seen.is_empty() and bs.tick >= int(seen[0]) and str(seen[1]) == shape:
		return
	_last_shape[seat] = [bs.tick, shape]
	_asked_at[seat] = now
	var questions := {"posture": {
		"type": "choice",
		"instructions": ("How should this side fight over the next few seconds? Combat is"
			+ " frontage-limited: output scales with the number of files in contact, never"
			+ " with how many men a regiment has, so width buys output and depth buys"
			+ " endurance. A head-on tie cannot break itself -- it breaks by widening,"
			+ " wrapping a flank, relieving a tired regiment, or shooting it."),
		"criteria": {
			"commit": ("Close and fight. Right when we outnumber them, when their line is"
				+ " already bending, or when our archers have run out of arrows and are"
				+ " now just bad infantry."),
			"hold": ("Keep the distance and let the archers work. Right while we still have"
				+ " arrows and they have to come to us, since nobody looses on the move or"
				+ " in a melee."),
			"withdraw": ("Break off and pull back. Right when we are losing badly enough"
				+ " that keeping the men matters more than keeping the field."),
		},
	}}

	# Three more, in the SAME request. Every question in one request is evaluated in
	# parallel and costs only its own tokens, so the expensive thing is the round trip
	# and there is exactly one of those either way.

	# A NOUL: the charge is a one-off multiplier on a window of CHARGE_SECONDS, so WHEN
	# to spend it is the decision and there was no rule for it at all -- the horse went
	# in whenever the line did.
	if _has_horse(bs, seat):
		questions["charge"] = {
			"type": "noul",
			"instructions": ("Is now the moment to send the cavalry in? A charge multiplies"
				+ " damage several times over at the instant of impact and decays to"
				+ " nothing within a few seconds, and a braced formation takes most of it"
				+ " out. Spent early it is wasted on a line that is not yet committed;"
				+ " spent late there is nothing left to break."),
		}

	# A SCORE: how far to commit to going round, rather than whether to. The envelopment
	# is currently self-limiting by geometry alone -- a regiment wraps only if nobody is
	# in front of it -- with nothing weighing that against holding the line together.
	questions["envelop"] = {
		"type": "score",
		"instructions": ("How much of this side's line should be sent round the enemy flank"
			+ " rather than held in the line? Going round wins a head-on tie that cannot"
			+ " break itself, but a line that sends too much away is thinner everywhere and"
			+ " can be broken in the middle before the wrap lands."),
		"criteria": {
			"none": "hold everything in the line; the front is all that matters here",
			"some": "send whatever has nobody in front of it, and no more",
			"most": "commit heavily to the flank and accept a thinner centre",
		},
	}

	var marks := _marks(bs, seat)
	if marks.size() > 1:
		questions["mark"] = {
			"type": "choice",
			"instructions": ("Which enemy regiment should this side concentrate on? Breaking"
				+ " one regiment at the end of a line sends the panic down it, so the"
				+ " nearly-broken and the isolated are worth more than the biggest."),
			"criteria": marks,
		}

	ask(seat, "battle %.0fs" % (float(bs.tick) * Rules.TICK_DELTA), battle_state(bs, seat),
		questions, func(a): ai.advice["posture"] = a.get("posture", &"commit"))


func battle_state(bs, seat: int) -> String:
	var split := _sides(bs, seat)
	return "A real-time battle, %.0f seconds in.\n%s\n%s" % [
		float(bs.tick) * Rules.TICK_DELTA,
		_side("Ours", split[0]), _side("Theirs", split[1])]


## Everyone still standing, ours then theirs.
static func _sides(bs, seat: int) -> Array:
	var mine := []
	var foes := []
	for id in bs.sorted_ids():
		var r: Regiment = bs.regiments[id]
		if not r.is_alive():
			continue
		if r.owner_id == seat:
			mine.append(r)
		else:
			foes.append(r)
	return [mine, foes]


## One walk, two readers: the sentence Jev is sent, and the fingerprint that decides
## whether to send it at all.
static func _tally(rs: Array) -> Dictionary:
	var t := {"n": rs.size(), "men": 0, "paper": 0, "morale": 0.0,
		"fighting": 0, "routing": 0, "quiver": false, "kinds": {}}
	for r: Regiment in rs:
		t["men"] += r.strength
		t["paper"] += r.max_strength
		t["morale"] += r.morale
		if r.state == Regiment.State.FIGHTING:
			t["fighting"] += 1
		elif r.state == Regiment.State.ROUTING:
			t["routing"] += 1
		if r.can_shoot():
			t["quiver"] = true          # can_shoot already means there are arrows left
		t["kinds"][String(r.kind)] = int(t["kinds"].get(String(r.kind), 0)) + 1
	return t


static func _side(label: String, rs: Array) -> String:
	if rs.is_empty():
		return "%s: nobody left standing." % label
	var t := _tally(rs)
	return "%s: %d regiments (%s), %d of %d men, average morale %d percent, %d in melee, %d routing." % [
		label, int(t["n"]), str(t["kinds"]), int(t["men"]), int(t["paper"]),
		int(float(t["morale"]) / float(t["n"]) / Rules.MORALE_MAX * 100.0),
		int(t["fighting"]), int(t["routing"])]


## A quantised picture of the fight, and the whole reason this stopped being a poll.
##
## Position is deliberately absent. Regiments move every tick and movement on its own is
## not news -- keying on it would ask Jev constantly and be the 2-second timer again with
## extra steps. Men go in TENTHS, so a trickle of casualties is silence and a collapse is
## a change. What is left is the handful of things that actually change a stance: how
## many of us are left, how many are locked in, how many have broken, and whether the
## archers still have anything to shoot.
static func _shape(bs, seat: int) -> String:
	var split := _sides(bs, seat)
	var us := _tally(split[0])
	var them := _tally(split[1])
	return "%d/%d/%d/%d/%s|%d/%d/%d" % [
		_tenths(us), int(us["n"]), _share(us, "fighting"), _share(us, "routing"),
		"a" if us["quiver"] else "-",
		_tenths(them), int(them["n"]), _share(them, "routing")]


## How much of a side is doing this, in thirds, rather than how many regiments are.
##
## An exact count is too sharp for the same reason truncated tenths were: regiments join
## and leave a melee constantly -- the more so now the AI sends its spare ones round a
## flank, which took a 120s battle from 66 changes of this one field to 180 and made
## asking on change cost MORE than the two-second poll it replaced. What the question
## "commit, hold or withdraw?" needs is whether the line is barely touching, half in, or
## fully committed. It does not need to know the difference between two and three.
static func _share(t: Dictionary, field: String) -> int:
	var n := int(t["n"])
	return 0 if n <= 0 else roundi(float(int(t[field])) / float(n) * 2.0)


## Rounded, not truncated. Truncating makes full strength a knife edge -- 120 of 120 is
## exactly ten tenths, so the first man to fall moves the bucket and every skirmish reads
## as news. Rounding puts the boundary in the middle of each tenth, where it belongs.
static func _tenths(t: Dictionary) -> int:
	var paper := int(t["paper"])
	return 0 if paper <= 0 else roundi(float(t["men"]) / float(paper) * 10.0)
