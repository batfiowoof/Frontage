extends RefCounted
## Pure geometry.  Where the render-only soldier bodies sit inside a regiment.
##
## Local space: the regiment faces +X.  Ranks stack behind it along -X, men in a
## rank spread along Y.  The caller rotates by `facing` and adds `pos`.
## Soldiers have no logic and no identity — this is the only place they exist.

const Rules := preload("res://sim/rules.gd")


## Where the man standing in (file, depth) belongs, in the regiment's local space.
##
## Files are straight columns front to back. That is not a detail: a file was the
## fundamental unit of a real formation, and it is why a man's lateral place never
## shifts as the ranks behind him thin out. `offsets()` below re-centres a partial rear
## rank, which is the right answer for laying out a block from scratch and the wrong one
## for men who are standing somewhere already.
static func slot(file: int, depth: int, width: int, ranks: int, spacing := 1.0) -> Vector2:
	var x := (float(ranks - 1) * 0.5 - float(depth)) * Rules.RANK_SPACING * spacing
	var y := (float(file) - float(width - 1) * 0.5) * Rules.FILE_SPACING * spacing
	return Vector2(x, y)


## Offsets for `count` men in a formation `width` men wide, centred on (0, 0).
static func offsets(count: int, width: int) -> PackedVector2Array:
	var out := PackedVector2Array()
	if count <= 0:
		return out
	width = clampi(width, 1, count)
	var ranks := ceili(float(count) / float(width))
	out.resize(count)

	var i := 0
	for rank in ranks:
		# Men left to place in this rank — the last rank may be partial.
		var in_rank := mini(width, count - i)
		# Front rank sits forward of the centre, rear rank behind it.
		var x := (float(ranks - 1) * 0.5 - float(rank)) * Rules.RANK_SPACING
		for file in in_rank:
			var y := (float(file) - float(in_rank - 1) * 0.5) * Rules.FILE_SPACING
			out[i] = Vector2(x, y)
			i += 1
	return out


## How many files a regiment presents to its front. A regiment worn below its
## nominal width cannot fill its frontage any more and fights on a narrower one --
## which is the only way attrition reduces a unit's output under frontage-limited
## combat, and the reason a 120-man block and an 80-man block hit equally hard.
static func files_across(count: int, width: int) -> int:
	if count <= 0:
		return 0
	return clampi(width, 1, count)


## How many ranks deep it stands: what it turns to face when hit from the side,
## and the reason a deep formation endures where a wide one dies.
static func ranks_deep(count: int, width: int) -> int:
	if count <= 0:
		return 0
	return ceili(float(count) / float(clampi(width, 1, count)))


## Half the formation's depth: how far it reaches forward of its centre, which is
## where its front rank stands and therefore where it meets an enemy.
static func half_depth(count: int, width: int, spacing := 1.0) -> float:
	if count <= 0:
		return 0.0
	return float(ranks_deep(count, width) - 1) * Rules.RANK_SPACING * spacing * 0.5


## Half-width of the formation's frontage, used for contact and flank tests.
static func frontage(count: int, width: int, spacing := 1.0) -> float:
	if count <= 0:
		return 0.0
	return float(clampi(width, 1, count) - 1) * Rules.FILE_SPACING * spacing * 0.5


# --- shapes -----------------------------------------------------------------
#
# Everything above is a block. A formation's `shape` (Rules.FORMATIONS) can also be a
# wedge or a hollow square, and this is the ONE place that knows what either looks like:
# the sim's reach and files in contact, the men's slots and the order preview all come
# through here, so a shape cannot exist in the fight and not on the screen or the other
# way round.
#
#   block    the rectangle above
#   wedge    files set back the further they are from the middle, so it meets the enemy
#            with its point; see Rules.WEDGE_*
#   hollow   a square of four faces, SQUARE_RANKS deep, facing out


static func shape_of(formation: StringName) -> StringName:
	return Rules.FORMATIONS.get(formation, Rules.FORMATIONS[Rules.DEFAULT_FORMATION]).get("shape", &"block")


## How far back the end file of a wedge stands behind its point.
static func wedge_setback(width: int, spacing := 1.0) -> float:
	return float(maxi(1, width) - 1) * 0.5 * Rules.RANK_SPACING * spacing * Rules.WEDGE_SLOPE


## Men on each face of a hollow square.
static func per_face(count: int) -> int:
	return maxi(1, ceili(float(count) / float(4 * Rules.SQUARE_RANKS)))


## Half the side of a hollow square, to its outer rank. The faces are set out far enough
## that their end men do not stand in the next face's corner.
static func hollow_half(count: int, spacing := 1.0) -> float:
	return float(per_face(count) + 1) * 0.5 * Rules.FILE_SPACING * spacing


## (half its depth, half its frontage): how far it reaches toward its front and back,
## and toward a flank. Taken from `count` = max_strength by the sim, like the block's.
static func extent(shape: StringName, count: int, width: int, spacing := 1.0) -> Vector2:
	match shape:
		&"hollow":
			var l := hollow_half(count, spacing)
			return Vector2(l, l)
		&"wedge":
			return Vector2(half_depth(count, width, spacing) + wedge_setback(width, spacing) * 0.5,
				frontage(count, width, spacing))
	return Vector2(half_depth(count, width, spacing), frontage(count, width, spacing))


## Files it brings against something in front of it. A wedge starts with its point and
## brings the rest as it `bite`s in; a hollow square fights with one face.
static func front_files(shape: StringName, count: int, width: int, bite := 0.0) -> int:
	var across := files_across(count, width)
	match shape:
		&"wedge":
			return mini(across, int(round(lerpf(float(mini(Rules.WEDGE_POINT_FILES, across)), float(across), clampf(bite, 0.0, 1.0)))))
		&"hollow":
			return mini(across, per_face(count)) if count > 0 else 0
	return across


## Files it can turn toward something on its side or behind it.
static func side_files(shape: StringName, count: int, width: int) -> int:
	if shape == &"hollow":
		return per_face(count) if count > 0 else 0
	return ranks_deep(count, width)


## A shape that stands on the same ground turned 180 degrees, so it may about-face by
## relabelling. A wedge may not: its point would jump to the back.
static func symmetric(shape: StringName) -> bool:
	return shape != &"wedge"


## Where the man in (file, depth) stands, in the formation's local space (+X forward).
## `slot()` above for a block; the shaped equivalents for the others. File and depth keep
## their meaning in every shape -- the man behind still steps up when a man falls -- and
## only where that place IS changes.
static func shaped_slot(shape: StringName, file: int, depth: int, width: int, ranks: int,
		spacing := 1.0, count := -1) -> Vector2:
	match shape:
		&"wedge":
			var at := slot(file, depth, width, ranks, spacing)
			var out := absf(float(file) - float(width - 1) * 0.5)
			var back := out * Rules.RANK_SPACING * spacing * Rules.WEDGE_SLOPE
			return Vector2(at.x - back + wedge_setback(width, spacing) * 0.5, at.y)
		&"hollow":
			var men := count if count > 0 else width * ranks
			var s := depth * width + file
			var ring := s % Rules.SQUARE_RANKS
			var j := s / Rules.SQUARE_RANKS
			var face := j % 4
			var along := j / 4
			var p := per_face(men)
			var out := hollow_half(men, spacing) - float(ring) * Rules.RANK_SPACING * spacing
			var lateral := (float(along) - float(p - 1) * 0.5) * Rules.FILE_SPACING * spacing
			return Vector2(out, lateral).rotated(float(face) * PI * 0.5)
	return slot(file, depth, width, ranks, spacing)


## Which way the man in (file, depth) faces when nothing is threatening him, relative to
## his regiment's facing. Only a hollow square's men face anything but forward: out.
static func rest_facing(shape: StringName, file: int, depth: int, width: int) -> float:
	if shape != &"hollow":
		return 0.0
	var s := depth * width + file
	return float((s / Rules.SQUARE_RANKS) % 4) * PI * 0.5
