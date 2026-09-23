extends RefCounted
## Every texture and font the views draw, loaded on first use and kept.
##
## load(), never preload(): `.godot/` is not in the repository, so a fresh clone has no
## import cache, and a const preload of an asset would stop the headless gates compiling
## view/ at all. Anything here may therefore come back null, and every caller draws
## something sensible without it -- a missing icon costs a picture, never the game.

const ICONS := "res://assets/icons/%s.svg"
const SPRITES := "res://assets/sprites/%s.png"

## What each thing is drawn as. One table, so a kind, a stance or a structure has the
## same picture on the map, on a card and on a button.
const KIND_ICON := {
	&"spear": &"chess_pawn",
	&"sword": &"sword",
	&"archer": &"bow",
	&"pike": &"chess_bishop",
	&"cavalry": &"chess_knight",
	&"settler": &"hand_hexagon",
	&"ram": &"resource_wood",
}
const STRUCTURE_ICON := {
	&"farm": &"resource_wheat",
	&"pasture": &"resource_apple",
	&"lumber": &"resource_lumber",
	&"mine": &"resource_iron",
	&"market": &"dollar",
	&"library": &"book_open",
	&"barracks": &"shield",
	&"walls": &"structure_wall",
	&"road": &"arrow_right_curve",
}
## By Campaign.Stance, in enum order: march, forced, fortify, ambush, besiege.
const STANCE_ICON := [&"pawn_right", &"pawn_skip", &"structure_tower", &"character_remove", &"structure_gate"]

static var _cache := {}


static func icon(name: StringName) -> Texture2D:
	return _load(ICONS % name)


static func sprite(name: StringName) -> Texture2D:
	return _load(SPRITES % name)


static func kind_icon(kind: StringName) -> Texture2D:
	return icon(KIND_ICON.get(kind, &"pawns"))


static func structure_icon(name: StringName) -> Texture2D:
	return icon(STRUCTURE_ICON.get(name, &"structure_house"))


static func stance_icon(stance: int) -> Texture2D:
	return icon(STANCE_ICON[clampi(stance, 0, STANCE_ICON.size() - 1)])


## Cinzel for headings, Alegreya Sans for everything you actually read. Falls back to the
## engine's own font rather than to nothing.
static func font(heading := false, bold := false) -> Font:
	var path := "res://assets/fonts/Cinzel.ttf" if heading \
		else "res://assets/fonts/AlegreyaSans-Bold.ttf" if bold \
		else "res://assets/fonts/AlegreyaSans-Regular.ttf"
	var f = _load(path)
	return f if f != null else ThemeDB.fallback_font


static func _load(path: String) -> Resource:
	if not _cache.has(path):
		_cache[path] = load(path) if ResourceLoader.exists(path) else null
	return _cache[path]
