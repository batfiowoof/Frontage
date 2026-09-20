extends RefCounted
## Who is which colour, and what the ground looks like. Shared by every view.

const Campaign := preload("res://sim/campaign_state.gd")

const NEUTRAL := Color(0.78, 0.76, 0.72)
const PLAYERS := [
	Color("c94f4f"),
	Color("4f7fc9"),
	Color("59a95e"),
	Color("c9a24f"),
]

const TERRAIN := {
	Campaign.Terrain.PLAINS: Color("8a9455"),
	Campaign.Terrain.FOREST: Color("46683f"),
	Campaign.Terrain.MOUNTAIN: Color("6b6661"),
	Campaign.Terrain.HILLS: Color("9a8b5c"),
	Campaign.Terrain.WATER: Color("3d6b86"),
}

const STRUCTURE := {
	&"farm": Color("d8c66a"),
	&"pasture": Color("b6cf7a"),
	&"lumber": Color("7a5a3a"),
	&"mine": Color("b9b2a6"),
	&"market": Color("d98c4a"),
	&"library": Color("8a7ecf"),
	&"barracks": Color("c25b3a"),
	&"walls": Color("cfcabc"),
}


static func of_structure(name: StringName) -> Color:
	return STRUCTURE.get(name, Color.MAGENTA)


## Colour by seat, not by peer id: peer ids are random 32-bit numbers, so hashing one
## into a hue gives a different colour every session and occasionally two identical ones.
static func of_owner(owner_id: int, seating: Array) -> Color:
	var seat := seating.find(owner_id)
	return NEUTRAL if seat < 0 else PLAYERS[seat % PLAYERS.size()]


static func of_terrain(t: int) -> Color:
	return TERRAIN.get(t, Color.MAGENTA)
