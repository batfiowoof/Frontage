extends RefCounted

const Formation := preload("res://sim/formation.gd")
const Rules := preload("res://sim/rules.gd")


func _centroid(pts: PackedVector2Array) -> Vector2:
	var s := Vector2.ZERO
	for p in pts:
		s += p
	return s / float(pts.size())


func test_offsets_count_matches_men(t) -> void:
	t.eq(Formation.offsets(120, 12).size(), 120)
	t.eq(Formation.offsets(1, 12).size(), 1, "width wider than the unit")
	t.eq(Formation.offsets(0, 12).size(), 0)
	t.eq(Formation.offsets(-5, 12).size(), 0, "negative men")
	t.eq(Formation.offsets(37, 0).size(), 37, "zero width must not divide by zero")


func test_full_rectangle_is_centred(t) -> void:
	var c := _centroid(Formation.offsets(120, 12))   # 10 full ranks
	t.near(c.x, 0.0, 0.001, "ranks centred front-to-back")
	t.near(c.y, 0.0, 0.001, "files centred side-to-side")


func test_partial_last_rank_still_centred_sideways(t) -> void:
	var pts := Formation.offsets(37, 12)             # 3 full ranks + 1 man
	t.near(_centroid(pts).y, 0.0, 0.001, "each rank centres its own men")
	t.eq(pts[36].y, 0.0, "the lone man in the last rank sits on the axis")


func test_front_rank_is_ahead_of_rear_rank(t) -> void:
	var pts := Formation.offsets(24, 12)
	t.ok(pts[0].x > pts[23].x, "regiment faces +X, so rank 0 has the greater x")


func test_single_man_sits_at_origin(t) -> void:
	t.eq(Formation.offsets(1, 1)[0], Vector2.ZERO)


func test_frontage_scales_with_width(t) -> void:
	t.near(Formation.frontage(120, 12), 11.0 * Rules.FILE_SPACING * 0.5)
	t.eq(Formation.frontage(0, 12), 0.0)
