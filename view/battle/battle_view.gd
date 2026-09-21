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
## Where the dot stops being solid and becomes its own outline, and how dark that gets.
const DOT_RIM := 0.68
const DOT_RIM_SHADE := 0.45
const PICK_RADIUS := 46.0
## Past this, a facing change is an about-face rather than a wheel: it is not interpolated
## and bodies.gd relabels the men instead of swinging them round.
const ABOUT_FACE := deg_to_rad(150.0)
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
var _quit: Button
var _quit_armed := false
var _groups := {}                        # slot -> PackedInt32Array, view-side only


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
	_bodies.texture = _dot()
	add_child(_bodies)


## A man, as a round dot with a dark rim.
##
## Bare quads are a GRID, not men: four units across on a seven-unit pitch is 57% filled
## laterally, and at the default zoom that is a 3px square 5px from its neighbour, which
## the eye joins into one slab. The rim is what does the work -- it gives every man his
## own outline, so two touching dots still read as two.
##
## The instance colour multiplies this, so white stays the team colour and the rim comes
## out as a darker shade of it rather than a black ring round everybody.
static func _dot(size := 16) -> ImageTexture:
	var img := Image.create(size, size, true, Image.FORMAT_RGBA8)
	var mid := float(size) * 0.5
	for y in size:
		for x in size:
			var d := Vector2(float(x) + 0.5 - mid, float(y) + 0.5 - mid).length() / mid
			# Solid to RIM_AT, darker out to the edge, then gone. The last few percent
			# fade rather than cut, which is the whole of the antialiasing.
			var shade := 1.0 if d < DOT_RIM else DOT_RIM_SHADE
			img.set_pixel(x, y, Color(shade, shade, shade,
				clampf(smoothstep(1.0, 0.86, d), 0.0, 1.0)))
	# 1920 dots minified to three pixels shimmer badly without these.
	img.generate_mipmaps()
	return ImageTexture.create_from_image(img)


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

	# Giving up is a button rather than a key, and it asks twice. It ends the battle for
	# everybody on your side and costs you the field and a share of the men; that is not
	# something to lose to a mistyped bracket.
	_quit = Button.new()
	_quit.text = "give up the field"
	_quit.set_anchors_preset(Control.PRESET_BOTTOM_RIGHT)
	_quit.position = Vector2(-160, -34)
	_quit.pressed.connect(_on_give_up)
	layer.add_child(_quit)


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
			_note(out, d.id, BattleState.side_of(d, e), e)
			_note(out, e.id, BattleState.side_of(e, d), d)
	return out


## Where the enemy is AND how much room he takes up. The men bend their line round him,
## and a block is wide and shallow -- 133 across against 45 deep -- so going round him at
## a constant distance from his CENTRE would walk them straight through his flanks. The
## footprint is derived from the mirror like everything else here and stays off the wire.
static func _note(out: Dictionary, id: int, side: int, foe) -> void:
	if not out.has(id):
		out[id] = {"sides": [], "threats": PackedVector2Array(),
			"shapes": PackedVector3Array()}
	if not out[id]["sides"].has(side):
		out[id]["sides"].append(side)
	out[id]["threats"].append(foe.pos)
	out[id]["shapes"].append(Vector3(
		Formation.half_depth(foe.max_strength, foe.width, foe.spacing()),
		Formation.frontage(foe.max_strength, foe.width, foe.spacing()),
		foe.facing))


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
			# An about-face happens in a single tick and costs no rotation at all, so
			# there is nothing to interpolate: easing across it would sweep the block
			# through ninety degrees, which is the exact thing it exists to avoid.
			facing = n.facing if absf(angle_difference(r.facing, n.facing)) > ABOUT_FACE \
				else lerp_angle(r.facing, n.facing, alpha)
		out[id] = {
			"pos": pos, "facing": facing, "owner": r.owner_id, "kind": r.kind,
			"strength": r.strength, "max_strength": r.max_strength,
			"morale": r.morale, "stamina": r.stamina, "width": r.width, "state": r.state,
			"formation": r.formation, "reforming": r.reforming, "spacing": r.spacing(),
			"ammo": r.ammo, "focus": r.focus, "engaged_with": r.engaged_with,
			"stance": r.stance,
			"hits": fights[id]["sides"] if fights.has(id) else [],
			"threats": fights[id]["threats"] if fights.has(id) else PackedVector2Array(),
			"shapes": fights[id]["shapes"] if fights.has(id) else PackedVector3Array(),
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


## Which enemies a shooter could actually hit right now, as id -> is the line clear.
##
## A range ring on its own would lie: nobody shoots through their own line, so half of
## what falls inside the circle may be unshootable. The ring says how far, this says
## whether -- and the second one is what you are really asking when you select archers.
static func targets_in_reach(state, shooter_id: int) -> Dictionary:
	var out := {}
	if state == null:
		return out
	var shooter = state.get_regiment(shooter_id)
	if shooter == null or shooter.range_of() <= 0.0:
		return out
	var everyone: Array = state.regiments.values()
	for id in state.sorted_ids():
		var e = state.regiments[id]
		if not e.is_alive() or e.owner_id == shooter.owner_id:
			continue
		if shooter.pos.distance_to(e.pos) > shooter.range_of():
			continue
		out[id] = BattleState.line_is_clear(shooter, e, everyone)
	return out


## How far a regiment of this kind can shoot, or 0 if it has nothing to shoot with.
static func range_of_kind(kind: StringName) -> float:
	return float(Rules.KINDS.get(kind, {}).get("range", 0.0))


func _draw_reach(pose: Dictionary) -> void:
	for id in selected:
		if not pose.has(id):
			continue
		var p: Dictionary = pose[id]
		var reach := range_of_kind(p["kind"])
		if reach <= 0.0:
			continue

		# Grey once the quiver is empty: the reach is still true and no longer useful.
		var spent: bool = int(p.get("ammo", 0)) <= 0
		var ring := Color(0.55, 0.55, 0.55, 0.3) if spent else Color(0.85, 0.78, 0.42, 0.5)
		draw_arc(p["pos"], reach, 0.0, TAU, 72, ring, 1.5)
		if spent:
			continue

		var reachable := targets_in_reach(Net.battle, id)
		for mark in reachable:
			if not pose.has(mark):
				continue
			var at: Vector2 = pose[mark]["pos"]
			var half: float = Formation.frontage(pose[mark]["max_strength"], pose[mark]["width"]) + 16.0
			if reachable[mark]:
				draw_arc(at, half, 0.0, TAU, 28, Color("d8c66a"), 2.0)
			else:
				# In range, but one of ours is standing in the way.
				draw_arc(at, half, 0.0, TAU, 28, Color(0.76, 0.36, 0.23, 0.55), 1.5)
				draw_line(p["pos"], at, Color(0.76, 0.36, 0.23, 0.3), 1.0)


func _draw() -> void:
	var pose := _display_state()
	var seating: Array = Net.player_ids()
	_draw_reach(pose)
	for id in pose:
		var p: Dictionary = pose[id]
		var half: float = Formation.frontage(p["max_strength"], p["width"]) + 10.0
		var centre: Vector2 = _men.centre_of(id, p["pos"])

		if id in selected:
			draw_arc(centre, half + 6.0, 0, TAU, 32, Color.WHITE, 2.0)
			var nose := centre + Vector2(cos(p["facing"]), sin(p["facing"])) * (half + 14.0)
			draw_line(centre, nose, Color.WHITE, 2.0)
			# Who it has been told to deal with. An attack order that cannot be seen is
			# an attack order you cannot tell you gave.
			var mark := int(p.get("focus", -1))
			if mark >= 0 and pose.has(mark):
				var at: Vector2 = _men.centre_of(mark, pose[mark]["pos"])
				draw_line(centre, at, Color(0.78, 0.36, 0.23, 0.75), 2.0)
				draw_arc(at, 20.0, 0, TAU, 20, Color("c25b3a"), 2.0)

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
		# The drag that sets a facing, and the order it would give: every regiment's real
		# footprint where it would stand, turned the way it would face. Frontage is what
		# decides the fight, so it should not be invisible until after you have committed.
		var mouse := get_global_mouse_position()
		draw_line(_order_from, mouse, Color("9fd8a0"), 2.0)
		for row: Dictionary in _plan_order(_order_from, mouse):
			_draw_ghost(row)


func _draw_ghost(row: Dictionary) -> void:
	var at: Vector2 = row["target"]
	var ahead := Vector2.from_angle(row["face"])
	var across := Vector2(-ahead.y, ahead.x)
	var half_w: float = row["half_width"]
	var half_d: float = row["half_depth"]

	var corners := PackedVector2Array([
		at + ahead * half_d - across * half_w,
		at + ahead * half_d + across * half_w,
		at - ahead * half_d + across * half_w,
		at - ahead * half_d - across * half_w,
	])
	draw_colored_polygon(corners, Color(0.62, 0.85, 0.63, 0.13))
	draw_polyline(corners + PackedVector2Array([corners[0]]), Color("9fd8a0"), 1.5)
	# A nose on the front rank, so which way it faces is not a guess.
	draw_line(at, at + ahead * (half_d + 22.0), Color("cfeecf"), 2.0)
	draw_line(row["from"], at, Color(0.62, 0.85, 0.63, 0.35), 1.0)

	# Where an archer would reach from there, which is most of why you move one.
	var reach: float = row.get("reach", 0.0)
	if reach > 0.0:
		draw_arc(at, reach, 0.0, TAU, 72, Color(0.85, 0.78, 0.42, 0.35), 1.5)


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
		_hint.text = ("drag to select, right-click to move, right-DRAG to draw the line"
			+ "      ctrl+1-9 remembers a group, 1-9 recalls it")
		return
	var lead: Dictionary = pose[selected[0]]
	var busy: float = lead["reforming"]
	# Changing frontage costs nothing and gates nothing, but it is not instant to look
	# at -- the men walk into their new files. The clock is the client's, from the mirror.
	var dressing: float = _men.dressing(selected[0])
	var quiver: int = lead.get("ammo", 0)
	var reach := range_of_kind(lead["kind"])
	var stance := int(lead.get("stance", 0))
	_hint.text = "%s, %d across%s%s%s      [ ] frontage   G guard   H skirmish   right-click an enemy to attack it" % [
		lead["formation"], int(lead["width"]),
		"      %d volleys left, range %.0f" % [quiver, reach] if quiver > 0 else "",
		("      RE-FORMING %.0fs" % busy if busy > 0.0
			else "      RE-DRESSING %.0fs" % dressing if dressing > 0.0 else ""),
		"      %s" % " ".join(_stance_names(stance)) if stance != 0 else ""]
	for b: Button in _formation_bar.get_children():
		b.disabled = busy > 0.0
		b.modulate = Color("9fd8a0") if StringName(b.text) == lead["formation"] else Color.WHITE


static func _stance_names(mask: int) -> PackedStringArray:
	var out := PackedStringArray()
	if mask & Regiment.Stance.GUARD:
		out.append("GUARDING")
	if mask & Regiment.Stance.SKIRMISH:
		out.append("SKIRMISHING")
	return out


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
		elif event.keycode == KEY_G:
			_toggle_stance(Regiment.Stance.GUARD)
		elif event.keycode == KEY_H:
			_toggle_stance(Regiment.Stance.SKIRMISH)
		elif event.keycode >= KEY_1 and event.keycode <= KEY_9:
			_control_group(event.keycode - KEY_1, event.ctrl_pressed)


## Ctrl+1..9 remembers this selection, 1..9 brings it back. View only: a control group
## is a note about what you are looking at, not a fact about the world, so nothing here
## goes near an order or the wire.
func _control_group(slot: int, assign: bool) -> void:
	if assign:
		_groups[slot] = selected.duplicate()
		return
	var remembered: PackedInt32Array = _groups.get(slot, PackedInt32Array())
	# Drop whoever has died since, or recalling an old group would select ghosts.
	var pose := _display_state()
	var alive := PackedInt32Array()
	for id in remembered:
		if pose.has(id):
			alive.append(id)
	selected = alive


## Guard and skirmish are toggles over the whole selection. Set from the FIRST selected
## regiment so a mixed selection lands somewhere predictable rather than each unit
## flipping to the opposite of whatever it happened to be.
func _toggle_stance(bit: int) -> void:
	if selected.is_empty():
		return
	var pose := _display_state()
	var lead: int = selected[0]
	var now := int(pose[lead]["stance"]) if pose.has(lead) else 0
	Net.order_stance(selected, (now & ~bit) if (now & bit) else (now | bit))


## Two presses. The first arms it and says so, the second sends it.
func _on_give_up() -> void:
	if not _quit_armed:
		_quit_armed = true
		_quit.text = "sure? this loses the field"
		return
	_quit_armed = false
	_quit.text = "give up the field"
	Net.order_forfeit()


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


## Where a right-drag would put everything, as one row per regiment.
##
## The preview and the order both come from here and neither works anything out on its
## own. That is the only way a preview stays honest: the moment the spread rule changes,
## the ghosts change with it rather than quietly lying about where the men will stand.
func _plan_order(from: Vector2, to: Vector2) -> Array:
	return plan_order(_display_state(), selected, from, to)


## The gap left between two neighbouring regiments in a line, so they are a line and
## not one block.
const SHOULDER := 16.0
## Below this a right-drag is a right-click: you meant "go there", not "form up along
## this".
const DRAG_IS_A_LINE := 24.0
## The deepest a DRAG may leave a regiment. Without a floor here, a short drag over
## several regiments derives MIN_WIDTH and orders each of them into a two-file conga line
## sixty ranks deep, which is not a formation and was never what the player drew. The
## column and square buttons still reach the extremes -- natural_width() does not come
## through this clamp -- so the drag owning the sane middle is the whole division.
const DRAG_MAX_RANKS := 12


## The arithmetic, with nothing of the scene tree in it, so it tests headless the way
## bodies.gd does.
##
## **The drag IS the line.** Where you press and where you release are the two ends of
## the formation, and the facing is perpendicular to it -- drag left to right and they
## face away from you, as they do in every game that does this.
##
## **And the drag sets their FRONTAGE, not the air between them.** Each regiment takes an
## equal share of the line you drew and stands that many files wide, so they end up
## shoulder to shoulder as one continuous line: long drag, thin wide regiments; short
## drag, deep blocks. The length used to become `extra`, slack inserted BETWEEN
## neighbours, which meant a long drag gave you the same blocks further apart -- and with
## one regiment selected it gave you nothing at all, because the slack was divided by
## n - 1 and a lone unit went to the press point however far you dragged.
##
## A regiment has a maximum frontage, so a drag longer than the men can stand in caps and
## centres instead of stretching. The ghost shows that by not growing, which is the answer
## to "why will it not spread further" -- it cannot.
static func plan_order(pose: Dictionary, chosen: PackedInt32Array, from: Vector2, to: Vector2) -> Array:
	var out := []
	if from == Vector2.INF or chosen.is_empty():
		return out

	var here := []
	for id in chosen:
		if pose.has(id):
			here.append(id)
	if here.is_empty():
		return out

	var span := from.distance_to(to)
	var drawn := span >= DRAG_IS_A_LINE
	# A drag draws the line and the facing falls out of it; a click says where to go and
	# each regiment turns toward its own destination.
	var along := (to - from).normalized() if drawn else Vector2.RIGHT
	var facing := along.rotated(-PI / 2.0).angle() if drawn else 0.0
	if not drawn:
		# No line to run along, so spread across the way they are travelling rather than
		# always along world +Y, which used to stack them into a column pointing nowhere.
		var travel := Vector2.ZERO
		for id: int in here:
			travel += from - pose[id]["pos"]
		along = (travel.normalized().rotated(PI / 2.0)) if travel.length() > 1.0 else Vector2.RIGHT

	# Left to right along the line as they already stand, so nobody is sent to the far
	# end and the columns do not march through each other on the way.
	here.sort_custom(func(a: int, b: int) -> bool:
		return pose[a]["pos"].dot(along) < pose[b]["pos"].dot(along))

	# Each regiment's share of the line it has to fill, which is what becomes its
	# frontage. Shoulders come off the top first: they are gaps between units, not room
	# for men, and with four regiments on a 40-unit drag they exceed the span outright.
	#
	# ponytail: equal shares, not shares weighted by headcount -- you drew a line and each
	# unit fills its part of it. Weight by max_strength if a mixed selection reads wrong.
	var share := maxf(0.0, span - SHOULDER * float(here.size() - 1)) / float(here.size())

	# Measure everybody: the slots have to be packed cumulatively by each regiment's OWN
	# frontage. Spacing every gap by one regiment's half-width put an archer and a cavalry
	# 42 units apart when they needed 84, and ordered them to stand inside one another.
	var halves := []
	var widths := []
	var needed := 0.0
	for id: int in here:
		var p: Dictionary = pose[id]
		var w := _files_for(p, share) if drawn else int(p["width"])
		widths.append(w)
		# max_strength, matching half_depth and the sim's own BattleState.reach(). Taken
		# from current strength the ghost shrank as a regiment bled, while the footprint
		# the sim actually tests against did not.
		var half := Formation.frontage(p["max_strength"], w, spacing_of(p))
		halves.append(half)
		needed += half * 2.0
	needed += SHOULDER * float(here.size() - 1)

	# The line is as long as the men can actually stand, centred on the drag. There is no
	# slack to distribute any more: the drag went into their FRONTAGE rather than into the
	# air between them, so when nothing caps out `needed` is the span you drew. Slack is
	# also what used to swallow the single-regiment case -- it was divided by n - 1.
	var centre := (from + to) * 0.5 if drawn else from
	var edge := -needed * 0.5

	for i in here.size():
		var id: int = here[i]
		var p: Dictionary = pose[id]
		var half: float = halves[i]
		var w: int = widths[i]
		var target: Vector2 = centre + along * (edge + half)
		edge += half * 2.0 + SHOULDER
		out.append({
			"id": id,
			"reach": range_of_kind(p["kind"]) if int(p.get("ammo", 0)) > 0 else 0.0,
			"target": target,
			"face": facing if drawn else (target - p["pos"]).angle(),
			"from": p["pos"],
			"width": w,
			"formation": p["formation"],
			"rewidth": w != int(p["width"]),
			"half_width": half,
			"half_depth": Formation.half_depth(p["max_strength"], w, spacing_of(p)),
		})
	return out


## How many files this regiment should stand in to fill `share` world units of the line.
## The inverse of Formation.frontage(), which is (width - 1) * FILE_SPACING * spacing.
##
## No deadband beyond "it actually changed" and no reforming clamp: set_width is free now
## and refuses nothing, so the honest answer is simply the frontage the drag asked for.
## Both guards existed only to keep an ordinary move-drag from spending six seconds.
static func _files_for(p: Dictionary, share: float) -> int:
	var men := int(p["max_strength"])
	# Never deeper than DRAG_MAX_RANKS, never wider than the sim itself would allow --
	# max_strength as well as MAX_WIDTH, matching Regiment.set_width, or the ghost
	# promises a frontage that comes back refused.
	var top := mini(Rules.MAX_WIDTH, men)
	# The floor yields to the ceiling, or a regiment big enough that DRAG_MAX_RANKS wants
	# more files than MAX_WIDTH allows would hand clampi a minimum above its maximum.
	var bottom := mini(maxi(Rules.MIN_WIDTH, ceili(float(men) / float(DRAG_MAX_RANKS))), top)
	return clampi(roundi(share / (Rules.FILE_SPACING * spacing_of(p))) + 1, bottom, top)


static func spacing_of(p: Dictionary) -> float:
	return float(p.get("spacing", 1.0))


## The enemy regiment under this point, or -1. Same radius as picking one of your own,
## so clicking a unit means the same thing whoever owns it.
func _enemy_at(at: Vector2) -> int:
	var pose := _display_state()
	var best := -1
	var best_distance := PICK_RADIUS
	for id in pose:
		if pose[id]["owner"] == Net.my_id():
			continue
		var d: float = pose[id]["pos"].distance_to(at)
		if d < best_distance:
			best_distance = d
			best = id
	return best


## Right-click moves. Right-DRAG draws the line itself -- press and release are the
## two ends of the formation and the facing is square to it, so you decide both the
## frontage and the way they meet what is coming.
func _finish_order() -> void:
	var from := _order_from
	var to := get_global_mouse_position()
	_order_from = Vector2.INF
	# Right-clicking an enemy is an attack order, not a walk to where it happens to be
	# standing. Anywhere else clears the mark, so calling a unit off is the same gesture
	# as sending it somewhere.
	if from != Vector2.INF and from.distance_to(to) < DRAG_IS_A_LINE and not selected.is_empty():
		var mark := _enemy_at(to)
		if mark >= 0:
			Net.order_focus(selected, mark)
			return
		Net.order_focus(selected, -1)
	# One order per regiment: the wire carries a single target, and a right-click is
	# not a hot path. The frontage rides along as a second order rather than a sixth
	# element on BATTLE_MOVE, because SET_FORMATION already carries a width and every
	# .rpl ever recorded decodes BATTLE_MOVE as exactly five elements.
	#
	# The formation goes out UNCHANGED on purpose: _set_formation only reaches set_width
	# when set_formation returned false, and asking for the shape it already has is what
	# makes it return false.
	for row: Dictionary in _plan_order(from, to):
		Net.order_battle_move(PackedInt32Array([row["id"]]), row["target"], row["face"])
		if row["rewidth"]:
			Net.order_set_formation(PackedInt32Array([row["id"]]), row["formation"], row["width"])
