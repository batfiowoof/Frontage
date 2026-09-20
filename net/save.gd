extends RefCounted
## A campaign, kept.
##
## The snapshot codec already does nearly all of this. The part that is not obvious is
## that **peer ids are random and change every session**, so a save stores the SEATS --
## the owner ids in a stable order -- and loading maps them onto whoever has turned up
## this time. Get that wrong and somebody silently inherits another player's empire.

const Snapshot := preload("res://net/snapshot.gd")
const CampaignState := preload("res://sim/campaign_state.gd")

const VERSION := 1
const FOLDER := "user://saves"
const MAX_SEATS := 8

var campaign := PackedByteArray()
var seats := []                        # owner ids as they were, in a stable order
var turn := 0


static func of(cs, seating: Array):
	var s = new()
	s.campaign = Snapshot.encode_campaign(cs)
	s.seats = seating.duplicate()
	s.turn = cs.turn
	return s


func to_bytes() -> PackedByteArray:
	return var_to_bytes([VERSION, campaign, seats, turn])


## A save file comes from outside the program, so it gets checked like anything else.
static func from_bytes(data: PackedByteArray):
	if data.size() < 4:
		return null
	var d = bytes_to_var(data)
	if typeof(d) != TYPE_ARRAY or d.size() != 4:
		return null
	if typeof(d[0]) != TYPE_INT or d[0] != VERSION:
		return null
	if typeof(d[1]) != TYPE_PACKED_BYTE_ARRAY or typeof(d[2]) != TYPE_ARRAY:
		return null
	if typeof(d[3]) != TYPE_INT or d[3] < 0:
		return null
	if d[2].is_empty() or d[2].size() > MAX_SEATS:
		return null
	var seen := {}
	for owner in d[2]:
		if typeof(owner) != TYPE_INT or seen.has(owner):
			return null                    # two seats with the same id is not a game
		seen[owner] = true
	if Snapshot.decode_campaign(d[1]) == null:
		return null                        # a save whose campaign will not load is no save

	var s = new()
	s.campaign = d[1]
	s.seats = d[2]
	s.turn = d[3]
	return s


## Rebuild the campaign with `players` sitting in the saved seats, in order. Returns null
## if the table does not have the right number of chairs.
func restore(players: Array):
	if players.size() != seats.size():
		return null
	var cs = Snapshot.decode_campaign(campaign)
	if cs == null:
		return null
	var mapping := {}
	for i in seats.size():
		mapping[seats[i]] = players[i]
	cs.remap_owners(mapping)
	return cs


# --- storage --------------------------------------------------------------

func save(path := "") -> String:
	if campaign.is_empty():
		return ""
	if path.is_empty():
		path = "%s/campaign_turn_%d.sav" % [FOLDER, turn]
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		push_warning("[save] could not write %s" % path)
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


## The most recent save on disk, or "" if there are none.
static func newest() -> String:
	var dir := DirAccess.open(FOLDER)
	if dir == null:
		return ""
	var best := ""
	var best_time := -1
	for name in dir.get_files():
		if not name.ends_with(".sav"):
			continue
		var when := FileAccess.get_modified_time(FOLDER + "/" + name)
		if when > best_time:
			best_time = when
			best = FOLDER + "/" + name
	return best
