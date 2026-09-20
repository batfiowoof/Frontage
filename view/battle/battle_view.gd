extends Node2D
## The battlefield. Draws Net.battle and turns clicks into orders.
##
## Bodies are a single MultiMeshInstance2D filled from a float buffer: the soldiers
## are render-time offsets around a regiment, with no logic and no identity, so there
## is nothing to iterate per man except geometry.

const Rules := preload("res://sim/rules.gd")
const Regiment := preload("res://sim/regiment.gd")
const BattleState := preload("res://sim/battle_state.gd")
const Formation := preload("res://sim/formation.gd")
const Colors := preload("res://view/colors.gd")
const Bodies := preload("res://view/battle/bodies.gd")

const BODY_SIZE := 4.0
const PICK_RADIUS := 46.0
const EDGE_MARGIN := 24.0
const EDGE_SPEED := 900.0
const KEY_SPEED := 900.0
const FLOATS_PER_INSTANCE := 12          # 8 transform + 4 colour

var selected: PackedInt32Array = []

var _camera: Camera2D
var _bodies: MultiMeshInstance2D
var _men := Bodies.new()
var _status: Label
var _hint: Label
var _frames: Array = []                  # [{state, at_ms}] for interpolation
var _drag_select_from := Vector2.INF
var _order_from := Vector2.INF
var _panning := false
var _formation_bar: HBoxContainer


func _ready() -> void:
	_build_camera()
	_build_bodies()
	_build_hud()
	Net.battle_updated.connect(_on_battle_updated)
	Net.news.connect(func(text: String) -> void: _hint.text = text)


func _build_camera() -> void:
	_camera = Camera2D.new()
	_camera.zoom = Vector2(0.75, 0.75)
	add_child(_camera)
	_camera.make_current()


func _build_bodies() -> void:
	var quad := QuadMesh.new()
	quad.size = Vector2(BODY_SIZE, BODY_SIZE)
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_2D
	mm.use_colors = true
	mm.mesh = quad
	_bodies = MultiMeshInstance2D.new()
	_bodies.multimesh = mm
	add_child(_bodies)


func _build_hud() -> void:
	var layer := CanvasLayer.new()
	add_child(layer)
	_status = Label.new()
	_status.position = Vector2(12, 8)
	_status.add_theme_font_size_override("font_size", 18)
	layer.add_child(_status)
	_hint = Label.new()
	_hint.set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
	_hint.position = Vector2(12, -64)
	layer.add_child(_hint)

	_formation_bar = HBoxContainer.new()
	_formation_bar.set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
	_formation_bar.position = Vector2(12, -34)
	layer.add_child(_formation_bar)
	for shape: StringName in Rules.FORMATIONS:
		var b := Button.new()
		b.text = String(shape)
		b.pressed.connect(_on_formation.bind(shape))
		_formation_bar.add_child(b)


# --- what we are drawing --------------------------------------------------

func _on_battle_updated(bs) -> void:
	# The server mutates one BattleState in place, so keeping references to it would
	# give a list of identical objects. It also has the truth at 20 Hz and nothing to
	# smooth over, so only a client interpolates.
	if Net.is_server():
		return
	_frames.append({"state": bs, "at": Time.get_ticks_msec()})
	while _frames.size() > 4:
		_frames.pop_front()


## Regiment positions and facings to draw this frame, as {id: {pos, facing, ...}}.
## A client renders INTERP_DELAY_MS in the past and slides between the two snapshots
## that bracket that moment, so 10 Hz of packets look like continuous movement.
func _display_state() -> Dictionary:
	if Net.is_server():
		return _pose_of(Net.battle, null, 0.0)
	if _frames.is_empty():
		return {}
	var at := Time.get_ticks_msec() - Rules.INTERP_DELAY_MS
	var older: Dictionary = _frames[0]
	var newer: Dictionary = _frames[_frames.size() - 1]
	for i in range(_frames.size() - 1):
		if _frames[i]["at"] <= at and _frames[i + 1]["at"] >= at:
			older = _frames[i]
			newer = _frames[i + 1]
			break
	var span: float = float(newer["at"] - older["at"])
	var alpha := 0.0 if span <= 0.0 else clampf((at - older["at"]) / span, 0.0, 1.0)
	return _pose_of(older["state"], newer["state"], alpha)


## Which edges each regiment is currently taking hits on, worked out from the mirror
## we already hold. Nothing new goes on the wire for this: it decides which men fall and
## which way the block is eaten, and that is decoration.
##
## ponytail: O(n^2) over the pairs, twice a frame. Fold it into one pass a snapshot if a
## battle ever gets big enough for it to show.
static func _engagements(state) -> Dictionary:
	var out := {}
	var ids: Array = state.sorted_ids()
	for i in ids.size():
		var d = state.regiments[ids[i]]
		if not d.is_alive():
			continue
		for j in range(i + 1, ids.size()):
			var e = state.regiments[ids[j]]
			if not e.is_alive() or e.owner_id == d.owner_id:
				continue
			if BattleState.gap_between(d, e) > Rules.CONTACT_GAP:
				continue
			_note(out, d.id, BattleState.side_of(d, e), e.pos)
			_note(out, e.id, BattleState.side_of(e, d), d.pos)
	return out


static func _note(out: Dictionary, id: int, side: int, at: Vector2) -> void:
	if not out.has(id):
		out[id] = {"sides": [], "threats": PackedVector2Array()}
	if not out[id]["sides"].has(side):
		out[id]["sides"].append(side)
	out[id]["threats"].append(at)


func _pose_of(a, b, alpha: float) -> Dictionary:
	var out := {}
	if a == null:
		return out
	var fights := _engagements(a)
	for id in a.sorted_ids():
		var r = a.regiments[id]
		var pos: Vector2 = r.pos
		var facing: float = r.facing
		if b != null and b.regiments.has(id):
			var n = b.regiments[id]
			pos = r.pos.lerp(n.pos, alpha)
			facing = lerp_angle(r.facing, n.facing, alpha)
		out[id] = {
			"pos": pos, "facing": facing, "owner": r.owner_id, "kind": r.kind,
			"strength": r.strength, "max_strength": r.max_strength,
			"morale": r.morale, "stamina": r.stamina, "width": r.width, "state": r.state,
			"formation": r.formation, "reforming": r.reforming, "spacing": r.spacing(),
			"hits": fights[id]["sides"] if fights.has(id) else [],
			"threats": fights[id]["threats"] if fights.has(id) else PackedVector2Array(),
		}
	return out


func _process(delta: float) -> void:
	_move_camera(delta)
	var pose := _display_state()
	_fill_bodies(pose, delta)
	queue_redraw()
	_update_hud(pose)


func _fill_bodies(pose: Dictionary, delta: float) -> void:
	var buffer := _men.build(pose, Net.player_ids(), delta)
	var mm: MultiMesh = _bodies.multimesh
	var count := buffer.size() / Bodies.FLOATS_PER_INSTANCE
	mm.instance_count = count
	if count > 0:
		mm.set_buffer(buffer)


func _draw() -> void:
	var pose := _display_state()
	var seating: Array = Net.player_ids()
	for id in pose:
		var p: Dictionary = pose[id]
		var half: float = Formation.frontage(p["max_strength"], p["width"]) + 10.0
		var centre: Vector2 = _men.centre_of(id, p["pos"])

		if id in selected:
			draw_arc(centre, half + 6.0, 0, TAU, 32, Color.WHITE, 2.0)
			var nose := centre + Vector2(cos(p["facing"]), sin(p["facing"])) * (half + 14.0)
			draw_line(centre, nose, Color.WHITE, 2.0)

		# Strength above, morale below: the two numbers a player actually steers by.
		var bar := Vector2(half * 2.0, 4.0)
		var top := centre - Vector2(half, half + 16.0)
		var fraction: float = float(p["strength"]) / maxf(1.0, float(p["max_strength"]))
		draw_rect(Rect2(top, bar), Color(0, 0, 0, 0.5))
		draw_rect(Rect2(top, Vector2(bar.x * fraction, bar.y)), Colors.of_owner(p["owner"], seating))
		var morale: float = clampf(p["morale"] / Rules.MORALE_MAX, 0.0, 1.0)
		draw_rect(Rect2(top + Vector2(0, 5), bar), Color(0, 0, 0, 0.5))
		draw_rect(Rect2(top + Vector2(0, 5), Vector2(bar.x * morale, bar.y)),
			Color("d8c66a") if morale > 0.35 else Color("c25b3a"))

		# Stamina, thinner and below: you need to see which of your regiments is
		# spent, because relieving it is the way to break a locked line.
		var stamina: float = clampf(p["stamina"], 0.0, 1.0)
		draw_rect(Rect2(top + Vector2(0, 10), Vector2(bar.x, 3.0)), Color(0, 0, 0, 0.5))
		draw_rect(Rect2(top + Vector2(0, 10), Vector2(bar.x * stamina, 3.0)),
			Color("6fa8c9") if stamina > 0.3 else Color("8a6fc9"))

	if _drag_select_from != Vector2.INF:
		var box := Rect2(_drag_select_from, get_global_mouse_position() - _drag_select_from).abs()
		draw_rect(box, Color(1, 1, 1, 0.12))
		draw_rect(box, Color.WHITE, false, 1.0)

	if _order_from != Vector2.INF:
		# The drag that sets a facing, drawn as the line the regiment will face along.
		draw_line(_order_from, get_global_mouse_position(), Color("9fd8a0"), 2.0)


func _update_hud(pose: Dictionary) -> void:
	var mine := 0
	var theirs := 0
	for id in pose:
		if pose[id]["owner"] == Net.my_id():
			mine += int(pose[id]["strength"])
		else:
			theirs += int(pose[id]["strength"])
	_status.text = "your men %d      theirs %d      %d selected" % [mine, theirs, selected.size()]

	_formation_bar.visible = not selected.is_empty()
	if selected.is_empty() or not pose.has(selected[0]):
		_hint.text = "drag to select, right-click to move, right-drag to set the facing"
		return
	var lead: Dictionary = pose[selected[0]]
	var busy: float = lead["reforming"]
	_hint.text = "%s, %d across%s      [ and ] change the frontage" % [
		lead["formation"], int(lead["width"]),
		"      RE-FORMING %.0fs" % busy if busy > 0.0 else ""]
	for b: Button in _formation_bar.get_children():
		b.disabled = busy > 0.0
		b.modulate = Color("9fd8a0") if StringName(b.text) == lead["formation"] else Color.WHITE


# --- camera ---------------------------------------------------------------

func _move_camera(delta: float) -> void:
	var drift := Vector2.ZERO
	if Input.is_key_pressed(KEY_A) or Input.is_key_pressed(KEY_LEFT):
		drift.x -= 1.0
	if Input.is_key_pressed(KEY_D) or Input.is_key_pressed(KEY_RIGHT):
		drift.x += 1.0
	if Input.is_key_pressed(KEY_W) or Input.is_key_pressed(KEY_UP):
		drift.y -= 1.0
	if Input.is_key_pressed(KEY_S) or Input.is_key_pressed(KEY_DOWN):
		drift.y += 1.0

	# Edge scroll, but only when the window has the mouse -- otherwise alt-tabbing
	# away leaves the camera sliding off the map.
	var size := get_viewport_rect().size
	var m := get_viewport().get_mouse_position()
	if Rect2(Vector2.ZERO, size).has_point(m):
		if m.x < EDGE_MARGIN:
			drift.x -= 1.0
		elif m.x > size.x - EDGE_MARGIN:
			drift.x += 1.0
		if m.y < EDGE_MARGIN:
			drift.y -= 1.0
		elif m.y > size.y - EDGE_MARGIN:
			drift.y += 1.0

	if drift != Vector2.ZERO:
		_camera.position += drift.normalized() * (KEY_SPEED if drift.length() > 1.4 else EDGE_SPEED) * delta / _camera.zoom.x
	_camera.position = _camera.position.clamp(
		Vector2(-Rules.BATTLE_HALF_EXTENT, -Rules.BATTLE_HALF_EXTENT),
		Vector2(Rules.BATTLE_HALF_EXTENT, Rules.BATTLE_HALF_EXTENT))


# --- input ----------------------------------------------------------------

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		match event.button_index:
			MOUSE_BUTTON_MIDDLE:
				_panning = event.pressed
			MOUSE_BUTTON_WHEEL_UP:
				if event.pressed:
					_camera.zoom = (_camera.zoom * 1.1).clampf(0.25, 3.0)
			MOUSE_BUTTON_WHEEL_DOWN:
				if event.pressed:
					_camera.zoom = (_camera.zoom / 1.1).clampf(0.25, 3.0)
			MOUSE_BUTTON_LEFT:
				if event.pressed:
					_drag_select_from = get_global_mouse_position()
				else:
					_finish_selection()
			MOUSE_BUTTON_RIGHT:
				if event.pressed:
					_order_from = get_global_mouse_position()
				else:
					_finish_order()
	elif event is InputEventMouseMotion and _panning:
		_camera.position -= event.relative / _camera.zoom
	elif event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_BRACKETRIGHT:
			_widen(2)
		elif event.keycode == KEY_BRACKETLEFT:
			_widen(-2)


func _on_formation(shape: StringName) -> void:
	if not selected.is_empty():
		Net.order_set_formation(selected, shape, 0)


## Frontage by the bracket keys. Total War drags a unit wider with the mouse, but the
## right button is already spending its drag on the facing you arrive at.
func _widen(by: int) -> void:
	if selected.is_empty():
		return
	var pose := _display_state()
	for id in selected:
		if pose.has(id):
			Net.order_set_formation(PackedInt32Array([id]), pose[id]["formation"],
				clampi(int(pose[id]["width"]) + by, Rules.MIN_WIDTH, Rules.MAX_WIDTH))


func _finish_selection() -> void:
	var from := _drag_select_from
	var to := get_global_mouse_position()
	_drag_select_from = Vector2.INF
	if from == Vector2.INF:
		return
	var pose := _display_state()
	var picked := PackedInt32Array()
	if from.distance_to(to) < 6.0:
		# A click takes the nearest regiment, not everything under a zero-size box.
		var best := -1
		var best_distance := PICK_RADIUS
		for id in pose:
			if pose[id]["owner"] != Net.my_id():
				continue
			var d: float = pose[id]["pos"].distance_to(to)
			if d < best_distance:
				best_distance = d
				best = id
		if best >= 0:
			picked.append(best)
	else:
		var box := Rect2(from, to - from).abs()
		for id in pose:
			if pose[id]["owner"] == Net.my_id() and box.has_point(pose[id]["pos"]):
				picked.append(id)
	selected = picked


## Right-click moves. Dragging while you do it sets the facing, so you can decide
## which way a regiment meets what is coming -- the whole point of the flank.
func _finish_order() -> void:
	var from := _order_from
	var to := get_global_mouse_position()
	_order_from = Vector2.INF
	if from == Vector2.INF or selected.is_empty():
		return
	var pose := _display_state()
	var facing := (to - from).angle() if from.distance_to(to) > 12.0 else 0.0
	var explicit := from.distance_to(to) > 12.0

	# Spread the selection into a line across the facing rather than piling every
	# regiment onto one point. One order per regiment: the wire format carries a
	# single target, and a right-click is not a hot path.
	var across := Vector2(cos(facing + PI / 2.0), sin(facing + PI / 2.0))
	var n := selected.size()
	for i in n:
		var id: int = selected[i]
		if not pose.has(id):
			continue
		var spread: float = Formation.frontage(pose[id]["strength"], pose[id]["width"]) * 2.4
		var slot := across * (float(i) - float(n - 1) * 0.5) * spread
		var target: Vector2 = from + slot
		var face: float = facing if explicit else (target - pose[id]["pos"]).angle()
		Net.order_battle_move(PackedInt32Array([id]), target, face)
