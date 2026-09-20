extends RefCounted
## Where a hex sits on the screen, and which hex a click landed in.
##
## Pointy-top hexes in odd-r offset coordinates: odd rows are pushed half a hex to the
## right. The campaign stores them row by row exactly as it stored squares, so this file
## is the whole of the difference as far as anything outside the map is concerned.

const Rules := preload("res://sim/rules.gd")
const Campaign := preload("res://sim/campaign_state.gd")

const SIZE := Rules.HEX_SIZE
const WIDTH := SIZE * 1.7320508             # sqrt(3), centre to centre across a row
const ROW_STEP := SIZE * 1.5                # centre to centre between rows


static func centre(tile: int) -> Vector2:
	var col := Campaign.tile_x(tile)
	var row := Campaign.tile_y(tile)
	return Vector2(WIDTH * (float(col) + 0.5 * float(row & 1)), ROW_STEP * float(row))


## The six corners of a hex at the origin, ready to be offset by `centre`.
static func corners() -> PackedVector2Array:
	var out := PackedVector2Array()
	for i in 6:
		var angle := deg_to_rad(60.0 * float(i) - 90.0)
		out.append(Vector2(cos(angle), sin(angle)) * SIZE)
	return out


static func polygon(tile: int) -> PackedVector2Array:
	var at := centre(tile)
	var out := PackedVector2Array()
	for c in corners():
		out.append(at + c)
	return out


## Which hex a point is in, or -1 if it is off the map. Rounding in cube coordinates is
## the only way to get this right -- dividing by the row height and flooring puts clicks
## in the wrong hex along every slanted edge, which is most of them.
static func at(point: Vector2) -> int:
	var q := (point.x * 0.5773502693 - point.y * 0.3333333333) / SIZE   # 1/sqrt(3), 1/3
	var r := (point.y * 0.6666666667) / SIZE
	var rounded := _round_axial(q, r)
	var row: int = rounded.y
	var col: int = rounded.x + int((row - (row & 1)) / 2.0)
	return Campaign.idx(col, row) if Campaign.in_bounds(col, row) else -1


static func _round_axial(q: float, r: float) -> Vector2i:
	var x := q
	var z := r
	var y := -x - z
	var rx := roundf(x)
	var ry := roundf(y)
	var rz := roundf(z)
	var dx := absf(rx - x)
	var dy := absf(ry - y)
	var dz := absf(rz - z)
	if dx > dy and dx > dz:
		rx = -ry - rz
	elif dy > dz:
		ry = -rx - rz
	else:
		rz = -rx - ry
	return Vector2i(int(rx), int(rz))


## The middle of the whole map, for parking the camera.
static func map_centre() -> Vector2:
	return Vector2(WIDTH * float(Rules.MAP_W) * 0.5, ROW_STEP * float(Rules.MAP_H) * 0.5)
