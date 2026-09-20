extends RefCounted
## M22: a campaign that survives the host being closed.

const Save := preload("res://net/save.gd")
const Snapshot := preload("res://net/snapshot.gd")
const Campaign := preload("res://sim/campaign_state.gd")
const Rules := preload("res://sim/rules.gd")

const OLD := [7001, 7002]
const NEW := [31, 4242]


func _played(seats := OLD):
	var cs = Campaign.generate(seats, 771)
	cs.gold[seats[0]] = 4321
	cs.food[seats[1]] = 99
	cs.set_ready(seats[0], true)
	cs.end_turn()
	return cs


# --- seats, which is the whole problem ------------------------------------

func test_a_save_restores_every_empire_to_the_right_player(t) -> void:
	# Peer ids are random per session, so loading has to re-point the empires at whoever
	# has actually turned up. Getting this wrong hands one player another's empire, and
	# nothing else in the game would notice.
	var before = _played()
	var towns_before: int = before.settlements_of(OLD[0])
	var men_before: int = before.men_of(OLD[0])
	var gold_before: int = before.gold[OLD[0]]

	var file = Save.of(before, OLD)
	var after = file.restore(NEW)
	t.ok(after != null, "restores")
	if after == null:
		return

	t.eq(after.settlements_of(NEW[0]), towns_before, "seat one's towns went to player one")
	t.eq(after.men_of(NEW[0]), men_before)
	t.eq(after.gold[NEW[0]], gold_before)
	t.eq(after.settlements_of(OLD[0]), 0, "and nothing is still pointed at the old id")
	t.eq(after.men_of(OLD[0]), 0)


func test_the_second_seat_is_not_given_the_first_ones_empire(t) -> void:
	var before = _played()
	before.gold[OLD[0]] = 11111
	before.gold[OLD[1]] = 22222
	var after = Save.of(before, OLD).restore(NEW)
	t.eq(after.gold[NEW[0]], 11111)
	t.eq(after.gold[NEW[1]], 22222, "seats are filled in order, not shuffled")


func test_neutral_ground_stays_neutral(t) -> void:
	var before = _played()
	var neutral_before: int = before.settlements_of(0)
	var after = Save.of(before, OLD).restore(NEW)
	t.eq(after.settlements_of(0), neutral_before, "nobody inherits the free towns")


func test_a_save_for_a_different_number_of_players_is_refused(t) -> void:
	var file = Save.of(_played(), OLD)
	t.eq(file.restore([1]), null, "too few at the table")
	t.eq(file.restore([1, 2, 3]), null, "too many")


# --- the rest of the campaign survives ------------------------------------

func test_the_map_and_the_turn_come_back(t) -> void:
	var before = _played()
	before.gold[OLD[0]] = 100000
	var tile := -1
	for i in before.improvements.size():
		if before.can_improve(OLD[0], i, &"farm"):
			tile = i
			break
	if tile >= 0:
		before.improve(OLD[0], tile, &"farm")

	var after = Save.of(before, OLD).restore(NEW)
	t.eq(after.turn, before.turn)
	t.eq(after.terrain, before.terrain)
	t.eq(after.improvements, before.improvements)
	if tile >= 0:
		t.eq(after.improvement_at(tile), &"farm", "the land keeps what was done to it")


func test_armies_keep_their_regiments_and_their_wounds(t) -> void:
	var before = _played()
	var army_id: int = before.sorted_army_ids()[0]
	before.armies[army_id]["regiments"][0][1] = 17
	var after = Save.of(before, OLD).restore(NEW)
	t.eq(after.armies[army_id]["regiments"][0][1], 17,
		"a battered regiment is still battered after a reload")


# --- storage --------------------------------------------------------------

func test_a_save_round_trips_through_bytes(t) -> void:
	var file = Save.of(_played(), OLD)
	var back = Save.from_bytes(file.to_bytes())
	t.ok(back != null)
	if back == null:
		return
	t.eq(back.seats, file.seats)
	t.eq(back.turn, file.turn)
	t.eq(back.campaign, file.campaign)
	t.ok(back.restore(NEW) != null)


func test_a_save_survives_a_file(t) -> void:
	var file = Save.of(_played(), OLD)
	var path: String = file.save("user://saves/test_round_trip.sav")
	t.ok(not path.is_empty(), "written")
	var back = Save.load_from(path)
	t.ok(back != null, "read back")
	if back != null:
		t.eq(back.seats, OLD)
		t.ok(back.restore(NEW) != null)
	DirAccess.remove_absolute(path)


func test_a_broken_save_is_refused_rather_than_crashed(t) -> void:
	t.eq(Save.from_bytes(PackedByteArray()), null, "empty")
	t.eq(Save.from_bytes(var_to_bytes("nope")), null, "not an array")
	t.eq(Save.from_bytes(var_to_bytes([99, PackedByteArray(), [1, 2], 3])), null, "wrong version")
	t.eq(Save.from_bytes(var_to_bytes([Save.VERSION, PackedByteArray(), [], 3])), null, "nobody playing")
	t.eq(Save.from_bytes(var_to_bytes([Save.VERSION, PackedByteArray(), [5, 5], 3])), null,
		"two seats with the same id is not a game")
	t.eq(Save.from_bytes(var_to_bytes([Save.VERSION, PackedByteArray([1, 2, 3]), [1, 2], 3])), null,
		"a campaign that will not decode is no save at all")
	t.eq(Save.load_from("user://saves/there_is_no_such_file.sav"), null)


func test_an_empty_save_writes_nothing(t) -> void:
	var file = Save.new()
	t.eq(file.save("user://saves/should_not_exist.sav"), "")
	t.ok(not FileAccess.file_exists("user://saves/should_not_exist.sav"))
