extends RefCounted
## Where a regiment walks to get where it was sent.
##
## A regiment used to walk straight at its target, and everything that stood in the way was
## a separate patch: a slide along a shore, a turn toward the nearest bridge, a wall that
## simply stopped it, and other regiments not avoided at all. This is one rule for all of
## them: a grid of what nobody can stand on, searched when -- and only when -- the straight
## line is not clear.
##
## `AStarGrid2D` is the engine's own, and it is `RefCounted`, so the sim stays pure: no
## node, no tree. The search runs in C++, and the same inputs give the same path, so a
## replay rebuilds exactly the walk that was recorded. The path itself is server-side state
## like `pace`: not on the wire, empty in any snapshot, rebuilt from the orders.

const Rules := preload("res://sim/rules.gd")
const Regiment := preload("res://sim/regiment.gd")

## A cell's width. A regiment is a hundred-odd units across, so this is plenty fine for
## where one can go, and the whole field is 120x120.
const CELL := 20.0
const N := int(Rules.BATTLE_HALF_EXTENT * 2.0 / CELL)
## How close to a wall a regiment's centre may come. The gate is 110 wide, which leaves
## four cells of it open.
const WALL_PAD := CELL

## Searches actually run, for tests to measure -- like Jev's `requests`, nothing that plays
## reads it. An open field should cost none.
var searches := 0

var _grid := AStarGrid2D.new()
var _signature := ""
var _has_water := false


func _init() -> void:
	_grid.region = Rect2i(0, 0, N, N)
	_grid.cell_size = Vector2(CELL, CELL)
	# Points come back as cell centres in world space.
	_grid.offset = Vector2.ONE * (-Rules.BATTLE_HALF_EXTENT + CELL * 0.5)
	_grid.diagonal_mode = AStarGrid2D.DIAGONAL_MODE_ONLY_IF_NO_OBSTACLES
	_grid.default_compute_heuristic = AStarGrid2D.HEURISTIC_OCTILE
	_grid.default_estimate_heuristic = AStarGrid2D.HEURISTIC_OCTILE
	_grid.update()


static func cell_of(p: Vector2) -> Vector2i:
	var e := Rules.BATTLE_HALF_EXTENT
	return Vector2i(clampi(int(floor((p.x + e) / CELL)), 0, N - 1),
		clampi(int(floor((p.y + e) / CELL)), 0, N - 1))


static func centre_of(c: Vector2i) -> Vector2:
	var e := Rules.BATTLE_HALF_EXTENT
	return Vector2(-e + (float(c.x) + 0.5) * CELL, -e + (float(c.y) + 0.5) * CELL)


# --- what nobody can stand on ---------------------------------------------------------

## Water (with its WATER_CLEAR margin, bridges open, by the sim's own `wet`) and the walls
## still standing. Built once, and again only when a wall segment comes down: the features
## never change mid-battle and a breach only matters the moment it is through.
func _ensure_static(bs) -> void:
	var sig := str(bs.features.size())
	for w: Array in bs.walls:
		sig += "1" if bs.standing(w) else "0"
	if sig == _signature:
		return
	_signature = sig
	_grid.fill_solid_region(_grid.region, false)
	_has_water = false
	var e := Rules.BATTLE_HALF_EXTENT
	for f: Array in bs.features:
		var kind := int(f[0])
		if kind == Rules.GROUND_LAKE:
			_has_water = true
			var reach := float(f[3]) + Rules.WATER_CLEAR
			_mark(bs, Rect2(float(f[1]) - reach, float(f[2]) - reach, reach * 2.0, reach * 2.0))
		elif kind == Rules.GROUND_RIVER:
			_has_water = true
			var band := float(f[3]) + Rules.WATER_CLEAR + Rules.RIVER_BEND + CELL
			var mid := float(f[1])
			_mark(bs, Rect2(mid - band, -e, band * 2.0, e * 2.0))
	for w: Array in bs.walls:
		if not bs.standing(w):
			continue
		var a := Vector2(w[0], w[1])
		var b := Vector2(w[2], w[3])
		var box := Rect2(a, Vector2.ZERO).expand(b).grow(WALL_PAD + CELL)
		for c in _cells_in(box):
			if bs._distance_to_segment(centre_of(c), a, b) < WALL_PAD:
				_grid.set_point_solid(c, true)


## Every cell in `box` takes the sim's own answer for whether it is water, so the grid and
## `wet()` cannot disagree about where the river is.
func _mark(bs, box: Rect2) -> void:
	for c in _cells_in(box):
		if bs.wet(centre_of(c)):
			_grid.set_point_solid(c, true)


static func _cells_in(box: Rect2) -> Array:
	var out := []
	var lo := cell_of(box.position)
	var hi := cell_of(box.end)
	for y in range(lo.y, hi.y + 1):
		for x in range(lo.x, hi.x + 1):
			out.append(Vector2i(x, y))
	return out


# --- who is in the way ------------------------------------------------------------------

## The regiments this one has to go round, as [centre, facing, half-extent] rectangles.
##
## Standing and fighting ones, friend and foe, that its side can SEE; not the moving (two marching blocks pass,
## and a plan against somebody who is walking away is out of date by the time it is
## walked), not routers, not the enemy it was told to deal with, and not one it is already
## standing in or has been sent into -- or a regiment could never be ordered into the slot
## beside its neighbour.
##
## Each is grown by the mover's own half-FRONTAGE and the contact gap: the larger of its
## two half-extents, so the mover's block clears it whichever way it faces, and the gap so
## a march past an enemy does not graze into a fight it was not sent to.
static func _blocks(bs, r) -> Array:
	var out := []
	var pad: float = r.extent().y + Rules.CONTACT_GAP
	for id in bs.sorted_ids():
		var o = bs.regiments[id]
		if o.id == r.id or o.id == r.focus or not o.is_alive():
			continue
		# Marching past is not in the way -- unless it has stopped to let somebody by, in
		# which case it is standing, and the somebody is us.
		if (o.state == Regiment.State.MOVING and not o.waiting) or o.state == Regiment.State.ROUTING:
			continue
		# ...and not through the fog. The path goes to its owner's screen, where a bend
		# round nothing would give away the men in the wood -- and the men marching do not
		# know they are there either. They walk into them, which is what an ambush is.
		if not bs.visible_to(r.owner_id, o):
			continue
		var e: Vector2 = o.extent()
		var blk := [o.pos, o.facing, Vector2(e.x + pad, e.y + pad)]
		if _inside(r.target, blk):
			continue
		# Already inside his margin -- close beside him, or stopped short of a friend who
		# is waiting for it -- the margin shrinks to leave it just outside rather than the
		# whole block being dropped. Dropped, a regiment standing near a friend planned
		# straight through him.
		if _inside(r.pos, blk):
			var local: Vector2 = (r.pos - o.pos).rotated(-o.facing)
			var room := minf(e.x + pad - absf(local.x), e.y + pad - absf(local.y)) + 1.0
			if room >= pad:
				continue                       # inside the block itself: tangled, walk apart
			blk[2] = Vector2(e.x + pad - room, e.y + pad - room)
		out.append(blk)
	return out


static func _inside(p: Vector2, blk: Array) -> bool:
	var local: Vector2 = (p - blk[0]).rotated(-float(blk[1]))
	var half: Vector2 = blk[2]
	return absf(local.x) <= half.x and absf(local.y) <= half.y


## Does the segment a-b pass through this rectangle? The slab test, in its own frame.
static func _hits(a: Vector2, b: Vector2, blk: Array) -> bool:
	var p: Vector2 = (a - blk[0]).rotated(-float(blk[1]))
	var q: Vector2 = (b - blk[0]).rotated(-float(blk[1]))
	var half: Vector2 = blk[2]
	var lo := 0.0
	var hi := 1.0
	var d := q - p
	for axis in 2:
		var start := p[axis]
		var span := d[axis]
		if absf(span) < 0.0001:
			if absf(start) > half[axis]:
				return false
			continue
		var t0 := (-half[axis] - start) / span
		var t1 := (half[axis] - start) / span
		if t0 > t1:
			var swap := t0
			t0 = t1
			t1 = swap
		lo = maxf(lo, t0)
		hi = minf(hi, t1)
		if lo > hi:
			return false
	return true


## Nothing in the way between a and b: no wall crossed, no water under the line, nobody
## standing across it. The grid is only the quick filter for water; `wet` decides.
func _clear(bs, a: Vector2, b: Vector2, blocks: Array) -> bool:
	if bs.crosses_a_wall(a, b):
		return false
	for blk: Array in blocks:
		if _hits(a, b, blk):
			return false
	if not _has_water:
		return true
	# Every quarter cell: at half a cell the line cut the corner where a bridge meets the
	# bank, and a regiment walked into the margin and wedged there.
	var n := int(a.distance_to(b) / (CELL * 0.25)) + 1
	for k in range(1, n + 1):
		var p := a.lerp(b, float(k) / float(n))
		if _grid.is_point_solid(cell_of(p)) and bs.wet(p):
			return false
	return true


# --- the plan ---------------------------------------------------------------------------

## The waypoints from where `r` stands to its target, not including where it stands. The
## target itself when it can be reached; otherwise the nearest point that can, on this
## side of whatever is in the way -- the shore of a lake, the outside of a wall.
func plan(bs, r) -> PackedVector2Array:
	_ensure_static(bs)
	var blocks := _blocks(bs, r)
	var to: Vector2 = r.target
	var column: float = bs.column_reach(r)
	var river = bs._river()
	# A straight line is enough -- unless it crosses the river, which a clear line can only
	# do diagonally over a bridge, or starts on one. Both need the centreline.
	var crosses: bool = river != null and _bank(bs, river, r.pos) != _bank(bs, river, to)
	if not crosses and _clear(bs, r.pos, to, blocks):
		if river == null or bs.bridge_at(r.pos, column) == null:
			return PackedVector2Array([to])
		var along := _portals(bs, [r.pos, to], column)
		return _pull(bs, along[0], along[1], blocks)

	searches += 1
	var stamped := _stamp(blocks)
	var from := cell_of(r.pos)
	var from_was := _grid.is_point_solid(from)
	_grid.set_point_solid(from, false)          # standing in a margin: you can walk out
	var goal := _reachable(to, r.pos)
	var raw := _grid.get_point_path(from, cell_of(goal), true)
	_grid.set_point_solid(from, from_was)
	for c: Vector2i in stamped:
		_grid.set_point_solid(c, false)

	if raw.size() < 2:
		return PackedVector2Array([goal])
	var pts := [r.pos]
	for i in range(1, raw.size()):
		pts.append(raw[i])
	if cell_of(goal) == cell_of(raw[raw.size() - 1]):
		pts[pts.size() - 1] = goal
	var anchors := _portals(bs, pts, column)
	return _pull(bs, anchors[0], anchors[1], blocks)


## Stamp the standing regiments into the grid for one search. Returns the cells it set,
## so exactly those are cleared again -- water and walls underneath are left alone.
func _stamp(blocks: Array) -> Array:
	var out := []
	for blk: Array in blocks:
		var half: Vector2 = blk[2]
		var radius := half.length()
		for c in _cells_in(Rect2(blk[0] - Vector2.ONE * radius, Vector2.ONE * radius * 2.0)):
			if not _grid.is_point_solid(c) and _inside(centre_of(c), blk):
				_grid.set_point_solid(c, true)
				out.append(c)
	return out


## The target, or the nearest open point on the line back from it toward where we are.
func _reachable(to: Vector2, from: Vector2) -> Vector2:
	var p := to
	var step := (from - to).normalized() * CELL * 0.5
	for i in int(to.distance_to(from) / (CELL * 0.5)) + 1:
		if not _grid.is_point_solid(cell_of(p)):
			return p
		p += step
	return from


## Put every river crossing on its bridge's CENTRELINE: the entry and exit at each end of
## the planks, marked as anchors the string-pull may not cut. A* can only cross on a
## bridge, but anywhere on it -- and a column whose centre is off the middle of the planks
## hangs its outer files over the water.
##
## `column` is half the column's length: the entry and exit stand that far beyond the
## ends of the planks, so the whole column is on the centreline before its front reaches
## the water and until its rear has left it.
func _portals(bs, pts: Array, column: float) -> Array:
	var river = bs._river()
	var out := []
	var anchor := []
	if river == null:
		for i in pts.size():
			out.append(pts[i])
			anchor.append(i == 0 or i == pts.size() - 1)
		return [out, anchor]
	# The planks AND the column's length beyond each end: a re-plan made on the approach,
	# already past where the entry would stand, must not be sent back to it.
	var i := 0
	while i < pts.size():
		var br = bs.bridge_at(pts[i], column)
		if br == null:
			out.append(pts[i])
			anchor.append(i == 0 or i == pts.size() - 1)
			i += 1
			continue
		var j := i
		while j < pts.size() and bs.bridge_at(pts[j], column) == br:
			j += 1
		var before: Vector2 = pts[maxi(0, i - 1)]
		var after: Vector2 = pts[mini(pts.size() - 1, j)]
		# Crossing, or already standing on the planks: either way it leaves by an end of the
		# bridge along the centreline. A re-plan made past the middle used to cut straight
		# for the target, off the side of the planks and into the water margin.
		if i == 0 or _bank(bs, river, before) != _bank(bs, river, after):
			var dir := 1.0 if after.x >= before.x else -1.0
			if i == 0:
				# Already on the planks: on to the centreline, not back to the entry --
				# re-planning mid-crossing sent it back to the start of the bridge, and it
				# paced there for the rest of the battle.
				out.append(pts[0])
				anchor.append(true)
				out.append(Vector2(pts[0].x + dir * 10.0, float(br[2])))
			else:
				out.append(Vector2(float(br[1]) - dir * (Rules.BRIDGE_HALF_LENGTH + column), float(br[2])))
			anchor.append(true)
			out.append(Vector2(float(br[1]) + dir * (Rules.BRIDGE_HALF_LENGTH + column), float(br[2])))
			anchor.append(true)
			if j >= pts.size():
				out.append(pts[pts.size() - 1])
				anchor.append(true)
		else:
			for k in range(i, j):
				out.append(pts[k])
				anchor.append(k == 0 or k == pts.size() - 1)
		i = j
	return [out, anchor]


static func _bank(bs, river: Array, p: Vector2) -> bool:
	return p.x >= bs.river_x(river, p.y)


## Keep only the corners: from each kept point, walk on while the next is still in plain
## view. Never past an anchor. Returns the waypoints after the first point.
func _pull(bs, pts: Array, anchor: Array, blocks: Array) -> PackedVector2Array:
	var out := PackedVector2Array()
	var a := 0
	while a < pts.size() - 1:
		var j := a + 1
		while j + 1 < pts.size() and not anchor[j] and _clear(bs, pts[a], pts[j + 1], blocks):
			j += 1
		out.append(pts[j])
		a = j
	return out
