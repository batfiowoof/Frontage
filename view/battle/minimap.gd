extends Control
## The whole field in miniature: the ground, the walls, every regiment as a block in its
## colour, and the box the camera is looking at. Click or drag on it to look somewhere.
##
## Everything drawn here is already in the pose or on Net.battle; it adds nothing and
## sends nothing.

const Rules := preload("res://sim/rules.gd")
const Bodies := preload("res://view/battle/bodies.gd")
const Colors := preload("res://view/colors.gd")

const SIZE := 184.0
const GROUND := {
	Rules.GROUND_WOOD: Color(0.18, 0.3, 0.16, 0.9),
	Rules.GROUND_HILL: Color(0.55, 0.48, 0.32, 0.7),
	Rules.GROUND_MARSH: Color(0.24, 0.36, 0.36, 0.8),
	Rules.GROUND_LAKE: Color(0.2, 0.34, 0.5, 0.95),
	Rules.GROUND_BRIDGE: Color(0.55, 0.4, 0.24, 1.0),
}
const BattleState := preload("res://sim/battle_state.gd")

var view
var _pose := {}
var _selected := PackedInt32Array()
var _dragging := false


func _init(owner_view) -> void:
	view = owner_view
	custom_minimum_size = Vector2(SIZE, SIZE)
	tooltip_text = "click or drag to look there"


func update(pose: Dictionary, selected: PackedInt32Array) -> void:
	_pose = pose
	_selected = selected
	queue_redraw()


func _to_map(world: Vector2) -> Vector2:
	var e := Rules.BATTLE_HALF_EXTENT
	return (world + Vector2(e, e)) / (e * 2.0) * size


func _to_world(local: Vector2) -> Vector2:
	var e := Rules.BATTLE_HALF_EXTENT
	return local / size * (e * 2.0) - Vector2(e, e)


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		_dragging = event.pressed
		if event.pressed:
			view.look_at_point(_to_world(event.position))
		accept_event()
	elif event is InputEventMouseMotion and _dragging:
		view.look_at_point(_to_world(event.position))
		accept_event()


func _draw() -> void:
	var box := Rect2(Vector2.ZERO, size)
	draw_rect(box, Color("2f3a22"))
	var scale := size.x / (Rules.BATTLE_HALF_EXTENT * 2.0)
	var battle = Net.battle
	if battle != null:
		for f: Array in battle.features:
			if int(f[0]) == Rules.GROUND_RIVER:
				var line := PackedVector2Array()
				var y := -Rules.BATTLE_HALF_EXTENT
				while y <= Rules.BATTLE_HALF_EXTENT:
					line.append(_to_map(Vector2(BattleState.river_x(f, y), y)))
					y += 60.0
				draw_polyline(line, GROUND[Rules.GROUND_LAKE], maxf(2.0, float(f[3]) * 2.0 * scale))
				continue
			draw_circle(_to_map(Vector2(f[1], f[2])), float(f[3]) * scale, GROUND.get(int(f[0]), Color.TRANSPARENT))
		for w: Array in battle.walls:
			if float(w[4]) < 1.0:
				draw_line(_to_map(Vector2(w[0], w[1])), _to_map(Vector2(w[2], w[3])), Color("c8c0b0"), 2.0)

	var seating: Array = Net.player_ids()
	for id in _pose:
		var p: Dictionary = _pose[id]
		var e := Bodies.extent_of(p)
		var half_w := maxf(2.0, e.y * scale)
		var half_d := maxf(1.5, e.x * scale)
		var ahead := Vector2.from_angle(float(p["facing"]))
		var across := Vector2(-ahead.y, ahead.x)
		var at := _to_map(p["pos"])
		var corners := PackedVector2Array([
			at + ahead * half_d - across * half_w, at + ahead * half_d + across * half_w,
			at - ahead * half_d + across * half_w, at - ahead * half_d - across * half_w])
		draw_colored_polygon(corners, Colors.of_owner(int(p["owner"]), seating))
		if id in _selected:
			draw_polyline(corners + PackedVector2Array([corners[0]]), Colors.SELECT, 1.0)

	# What the camera can see, so the minimap says where you are as well as where they are.
	var seen: Rect2 = view.visible_world()
	draw_rect(Rect2(_to_map(seen.position), seen.size * scale).intersection(box), Colors.TEXT, false, 1.0)
	draw_rect(box, Colors.TRIM, false, 2.0)
