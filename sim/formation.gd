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
