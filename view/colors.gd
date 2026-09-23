extends RefCounted
## Who is which colour, what the ground looks like, and the tokens the whole HUD is
## painted from. Shared by every view.
##
## A literal colour anywhere else in view/ is a colour that will drift from this one --
## the same green used to be written out in four files, three different ways.

const Campaign := preload("res://sim/campaign_state.gd")

# --- the HUD --------------------------------------------------------------
## Dark umber panels with a bronze edge: Total War's campaign chrome, not a web page.
const PANEL := Color(0.09, 0.075, 0.06, 0.9)
const PANEL_DEEP := Color(0.05, 0.04, 0.035, 0.94)
const PANEL_HOVER := Color(0.17, 0.135, 0.1, 0.95)
const TRIM := Color("8a6b3d")
const TRIM_BRIGHT := Color("c9a25a")
const TEXT := Color("e8dcc0")
const TEXT_DIM := Color("9c8f78")
const GOLD := Color("e0b85a")
const GOOD := Color("8fc78a")
const WARN := Color("d8c66a")
const BAD := Color("d4553a")
## What you have picked, on the map and on the field. Warm, so it never reads as a team.
const SELECT := Color("f2d48a")
## An order about to be given: the ghosts, the route.
const ORDER := Color("9fd8a0")
const SHADOW := Color(0, 0, 0, 0.45)

const NEUTRAL := Color(0.72, 0.69, 0.63)
## Heraldic rather than primary: they have to sit on the terrain without shouting and
## still be told apart at a glance, in a dot four units across.
const PLAYERS := [
	Color("c0453b"),
	Color("3f72b8"),
	Color("4f9a58"),
	Color("d1a43f"),
]

const TERRAIN := {
	Campaign.Terrain.PLAINS: Color("8b9158"),
	Campaign.Terrain.FOREST: Color("4a6a3c"),
	Campaign.Terrain.MOUNTAIN: Color("77716a"),
	Campaign.Terrain.HILLS: Color("9d8a5c"),
	Campaign.Terrain.WATER: Color("355f7a"),
}

const STRUCTURE := {
	&"farm": Color("d8c66a"),
	&"pasture": Color("b6cf7a"),
	&"lumber": Color("a07a4a"),
	&"mine": Color("b9b2a6"),
	&"market": Color("d98c4a"),
	&"library": Color("9a8edf"),
	&"barracks": Color("d0694a"),
	&"walls": Color("cfcabc"),
	&"road": Color("a89e8c"),
}


## Morale as Total War shows it on a banner: green while it is healthy, yellow once
## something is eating it, red when the regiment is about to go.
static func of_morale(fraction: float) -> Color:
	if fraction > 0.6:
		return GOOD
	return WARN if fraction > 0.3 else BAD


static func of_structure(name: StringName) -> Color:
	return STRUCTURE.get(name, Color.MAGENTA)


## Colour by seat, not by peer id: peer ids are random 32-bit numbers, so hashing one
## into a hue gives a different colour every session and occasionally two identical ones.
static func of_owner(owner_id: int, seating: Array) -> Color:
	var seat := seating.find(owner_id)
	return NEUTRAL if seat < 0 else PLAYERS[seat % PLAYERS.size()]


static func of_terrain(t: int) -> Color:
	return TERRAIN.get(t, Color.MAGENTA)
