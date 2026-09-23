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
const Art := preload("res://view/ui/art.gd")
const Hud := preload("res://view/battle/hud.gd")
const GRASS_SHADER := preload("res://view/shaders/grass.gdshader")

const BODY_SIZE := 4.0
## Where the dot stops being solid and becomes its own outline, and how dark that gets.
const DOT_RIM := 0.68
const DOT_RIM_SHADE := 0.45
const PICK_RADIUS := 46.0
## The banner above each regiment, in SCREEN pixels -- it holds its size however far you
## zoom out, which is the whole point of it. A regiment's own footprint is a world-space
## thing and shrinks to nothing; the banner is what you can always hit.
const BANNER_W := 26.0
const BANNER_H := 30.0
const BANNER_LIFT := 6.0                   # screen px between the bars and the flag
## Past this, a facing change is an about-face rather than a wheel: it is not interpolated
## and bodies.gd relabels the men instead of swinging them round.
const ABOUT_FACE := deg_to_rad(150.0)
## The boundary line, in SCREEN pixels, for the same reason the banner is.
const FIELD_EDGE_W := 3.0
## The wall, in WORLD units -- unlike the field edge and the banner, because a wall is a
## real thing standing on the ground with a real thickness and men stand against it.
const WALL_W := 14.0
const EDGE_MARGIN := 24.0
const EDGE_SPEED := 900.0
const KEY_SPEED := 900.0
const FLOATS_PER_INSTANCE := 12          # 8 transform + 4 colour

var selected: PackedInt32Array = []

var _camera: Camera2D
var _bodies: MultiMeshInstance2D
var _ghosts: MultiMeshInstance2D          # the right-drag preview, as the men themselves
var _men := Bodies.new()
var _hud: Hud
var _frames: Array = []                  # [{state, at_ms}] for interpolation
var _drag_select_from := Vector2.INF
var _order_from := Vector2.INF
var _panning := false
var _groups := {}                        # slot -> PackedInt32Array, view-side only


func _ready() -> void:
	_build_camera()
	_build_field()
	_build_bodies()
	var layer := CanvasLayer.new()
	add_child(layer)
	_hud = Hud.new(self)
	layer.add_child(_hud)
	Net.battle_updated.connect(_on_battle_updated)


func _build_camera() -> void:
	_camera = Camera2D.new()
	_camera.zoom = Vector2(0.75, 0.75)
	add_child(_camera)
	_camera.make_current()


func _build_bodies() -> void:
	_bodies = _dots()
	add_child(_bodies)
	# Ghosts under the living men, so an order to stand where they already are still
	# shows the men and not their ghosts.
	_ghosts = _dots()
	_ghosts.modulate = Color(Colors.ORDER, 0.55)
	_ghosts.show_behind_parent = true
	add_child(_ghosts)


func _dots() -> MultiMeshInstance2D:
	var quad := QuadMesh.new()
	quad.size = Vector2(BODY_SIZE, BODY_SIZE)
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_2D
	mm.use_colors = true
	mm.mesh = quad
	var out := MultiMeshInstance2D.new()
	out.multimesh = mm
	out.texture = _dot()
	return out


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


## The ground, under everything: one rectangle the size of the field with a grass
## shader on it. Its own node so the shader touches nothing else, and z -1 so the men,
## the woods and the banners all stand on it.
func _build_field() -> void:
	var field := Node2D.new()
	field.z_index = -1
	var m := ShaderMaterial.new()
	m.shader = GRASS_SHADER
	m.set_shader_parameter("half_extent", Rules.BATTLE_HALF_EXTENT)
	var grain := NoiseTexture2D.new()
	grain.seamless = true
	grain.generate_mipmaps = true
	grain.noise = FastNoiseLite.new()
	grain.noise.frequency = 0.012
	grain.noise.fractal_octaves = 4
	m.set_shader_parameter("noise", grain)
	field.material = m
	field.draw.connect(func() -> void:
		var e := Rules.BATTLE_HALF_EXTENT + 400.0
		field.draw_rect(Rect2(Vector2(-e, -e), Vector2(e, e) * 2.0), Color.WHITE))
	add_child(field)


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
	var e: Vector2 = foe.extent()
	out[id]["shapes"].append(Vector3(e.x, e.y, foe.facing))


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
	_fill_ghosts(pose)
	queue_redraw()
	_hud.update(pose, selected, _groups)


## Which regiments to pick out, and how. The men ARE the highlight: a box round a block
## says nothing about which way it faces or what shape it is standing in, and the old
## outlines were most of what made the field read as rectangles.
func _tints(pose: Dictionary) -> Dictionary:
	var out := {}
	var idle := _drag_select_from == Vector2.INF and _order_from == Vector2.INF
	if idle:
		var hovered := pick_at(pose, get_global_mouse_position(), Net.my_id(), true,
			_camera.zoom.x, _centres(pose))
		if hovered >= 0:
			out[hovered] = Color(1, 1, 1, 0.25)
	for id in selected:
		if not pose.has(id):
			continue
		out[id] = Color(Colors.SELECT, 0.45)
		# Who it has been told to deal with.
		var mark := int(pose[id].get("focus", -1))
		if mark >= 0 and pose.has(mark):
			out[mark] = Color(1, 1, 1, 0.45)
		# What its bows can reach: bright if the line is clear, dark if one of ours is
		# standing in it. A ring round each of them used to say the same thing less plainly.
		if range_of_kind(pose[id]["kind"]) > 0.0 and int(pose[id].get("ammo", 0)) > 0:
			var reachable := targets_in_reach(Net.battle, id)
			for enemy in reachable:
				if not out.has(enemy):
					out[enemy] = Color(Colors.GOLD, 0.45) if reachable[enemy] else Color(0, 0, 0, 0.35)
	return out


## The right-drag preview: every man of every selected regiment, where he would stand.
## From the same plan_order rows the order is sent from, so the ghost cannot lie.
func _fill_ghosts(pose: Dictionary) -> void:
	var mm: MultiMesh = _ghosts.multimesh
	if _order_from == Vector2.INF:
		mm.instance_count = 0
		return
	var places := PackedVector2Array()
	for row: Dictionary in _plan_order(_order_from, get_global_mouse_position()):
		places.append_array(Bodies.ghost_places(pose[row["id"]], row))
	mm.instance_count = places.size()
	for i in places.size():
		mm.set_instance_transform_2d(i, Transform2D(0.0, places[i]))
		mm.set_instance_color(i, Color.WHITE)


func _fill_bodies(pose: Dictionary, delta: float) -> void:
	var buffer := _men.build(pose, Net.player_ids(), delta, _tints(pose))
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
		var ring := Color(0.55, 0.55, 0.55, 0.3) if spent else Color(Colors.GOLD, 0.5)
		draw_arc(p["pos"], reach, 0.0, TAU, 72, ring, 1.5 / _camera.zoom.x)
		# Which of them it can actually hit is shown on the men themselves: see _tints.


func _draw() -> void:
	var pose := _display_state()
	_draw_field()
	_draw_features()
	_draw_walls()
	_draw_reach(pose)
	var zoom := _camera.zoom.x
	# Who each selected regiment has been told to deal with. An attack order that cannot
	# be seen is an attack order you cannot tell you gave: the target's men are tinted,
	# and this is the line between them.
	for id in selected:
		if not pose.has(id):
			continue
		var mark := int(pose[id].get("focus", -1))
		if mark >= 0 and pose.has(mark):
			draw_dashed_line(_men.centre_of(id, pose[id]["pos"]), _men.centre_of(mark, pose[mark]["pos"]),
				Color(Colors.BAD, 0.8), 2.0 / zoom, 10.0 / zoom)

	# Banners last, so nothing is drawn across a flag.
	for id in pose:
		_draw_banner(pose[id], _men.centre_of(id, pose[id]["pos"]), id in selected)

	if _drag_select_from != Vector2.INF:
		var box := Rect2(_drag_select_from, get_global_mouse_position() - _drag_select_from).abs()
		draw_rect(box, Color(Colors.SELECT, 0.1))
		draw_rect(box, Colors.SELECT, false, 1.0 / zoom)

	if _order_from != Vector2.INF:
		# The drag that sets a facing, and the order it would give: every regiment's real
		# footprint where it would stand, turned the way it would face. Frontage is what
		# decides the fight, so it should not be invisible until after you have committed.
		var mouse := get_global_mouse_position()
		draw_line(_order_from, mouse, Colors.ORDER, 2.0 / zoom)
		for row: Dictionary in _plan_order(_order_from, mouse):
			_draw_ghost(row)


## The edge of the world. Orders have always been clamped to it (`Orders.clamp_to_field`)
## and so has the camera, but nothing drew it, so a regiment sent past the boundary simply
## stopped short for no reason a player could see. The grass itself is the field layer's
## shader; this is only the line.
##
## A constant thickness on SCREEN, like the banner: a hairline at the zoomed-out end is
## exactly where you most need to know which way the edge is.
func _draw_field() -> void:
	var e := Rules.BATTLE_HALF_EXTENT
	var field := Rect2(Vector2(-e, -e), Vector2(e, e) * 2.0)
	draw_rect(field, Color(0.1, 0.08, 0.05, 0.9), false, (FIELD_EDGE_W + 2.0) / _camera.zoom.x)
	draw_rect(field, Colors.TRIM, false, FIELD_EDGE_W / _camera.zoom.x)


## Woods, hills and marsh. They have been on the wire and deciding fights since the ground
## went in, and nothing drew them: a regiment slowed and hidden by a wood stood on the
## same flat grass as one in the open. Scattered from the feature row itself, so the same
## field is dressed the same way on every machine and every frame.
func _draw_features() -> void:
	if Net.battle == null:
		return
	for f: Array in Net.battle.features:
		var at := Vector2(f[1], f[2])
		var r := float(f[3])
		var rng := RandomNumberGenerator.new()
		rng.seed = hash(Vector3(f[1], f[2], f[3]))
		match int(f[0]):
			Rules.GROUND_WOOD:
				for k in 4:
					draw_circle(at, r * (1.0 - 0.06 * k), Color(0.1, 0.17, 0.08, 0.12))
				var trees := clampi(int(r * r / 500.0), 10, 60)
				var spots := []
				for n in trees:
					var d := sqrt(rng.randf()) * r * 0.9
					spots.append(at + Vector2.from_angle(rng.randf() * TAU) * d)
				spots.sort_custom(func(a: Vector2, b: Vector2) -> bool: return a.y < b.y)
				for spot: Vector2 in spots:
					var tex := Art.sprite([&"tree_pine", &"tree_round", &"tree_small"][rng.randi() % 3])
					# Small, against a man four units across, so the men in a wood can still be read.
					var size := rng.randf_range(20.0, 30.0)
					if tex != null:
						draw_texture_rect(tex, Rect2(spot - Vector2(size * 0.5, size * 0.85), Vector2(size, size)),
							false, Color(0.62, 0.72, 0.58))
			Rules.GROUND_HILL:
				draw_circle(at, r, Color(0.55, 0.47, 0.28, 0.22))
				draw_circle(at + Vector2(-r, -r) * 0.18, r * 0.7, Color(1.0, 0.95, 0.75, 0.07))
				for k in range(1, 4):
					draw_arc(at, r * (1.0 - 0.24 * k), 0, TAU, 48, Color(0.25, 0.19, 0.1, 0.28), 2.0, true)
				draw_arc(at, r, 0, TAU, 64, Color(0.25, 0.19, 0.1, 0.35), 2.0, true)
			Rules.GROUND_MARSH:
				draw_circle(at, r, Color(0.2, 0.3, 0.28, 0.4))
				for n in 7:
					var pool := at + Vector2.from_angle(rng.randf() * TAU) * sqrt(rng.randf()) * r * 0.7
					draw_circle(pool, rng.randf_range(12.0, 30.0), Color(0.22, 0.36, 0.42, 0.55))
				for n in 26:
					var reed := at + Vector2.from_angle(rng.randf() * TAU) * sqrt(rng.randf()) * r * 0.92
					draw_line(reed, reed + Vector2(rng.randf_range(-2.0, 2.0), -9.0), Color(0.5, 0.52, 0.3, 0.8), 1.5)


## The town's walls: a stone line with merlons along it and a tower at each end. A
## segment that is being worked on darkens and cracks as the breach opens, and is gone
## once it is through -- the only cue the attacker has that the ram is doing anything,
## and the only cue the defender has that it is time to put somebody in the gap.
##
## Read from Net.battle rather than the interpolated pose: a wall does not move, and the
## pose carries regiments only.
func _draw_walls() -> void:
	if Net.battle == null:
		return
	for w: Array in Net.battle.walls:
		var open: float = clampf(float(w[4]), 0.0, 1.0)
		var a := Vector2(w[0], w[1])
		var b := Vector2(w[2], w[3])
		if open >= 1.0:
			# Rubble where it stood, so the gap reads as a breach and not as open ground.
			draw_dashed_line(a, b, Color(0.4, 0.37, 0.32, 0.6), WALL_W * 0.5, 14.0)
			continue
		var stone := Color(0.7, 0.67, 0.6).lerp(Color(0.36, 0.3, 0.26), open)
		draw_line(a, b, Color(0.12, 0.1, 0.08), WALL_W + 5.0, true)
		draw_line(a, b, stone, WALL_W, true)
		var along := (b - a).normalized()
		var across := Vector2(-along.y, along.x)
		var length := a.distance_to(b)
		var step := 0.0
		while step < length:
			draw_rect(Rect2(a + along * step - Vector2(3, 3), Vector2(6, 6)), stone.darkened(0.25))
			step += 16.0
		if open > 0.25:
			var rng := RandomNumberGenerator.new()
			rng.seed = hash(Vector2(w[0], w[1]))
			for n in int(open * 10.0):
				var at := a + along * rng.randf() * length
				draw_line(at - across * WALL_W * 0.5, at + across * WALL_W * 0.4 + along * 6.0,
					Color(0.1, 0.08, 0.06, 0.8), 1.5)
		for end: Vector2 in [a, b]:
			draw_circle(end, WALL_W * 0.95, Color(0.12, 0.1, 0.08))
			draw_circle(end, WALL_W * 0.8, stone)


## The flag above a regiment: what it is, how it is holding up, and something big enough
## to click. A shattered regiment has none, which is how you can tell.
##
## Morale across the top and strength along the bottom, the two numbers a player steers
## by. They used to be three bars in world space over every regiment, which is most of
## why the field read as cluttered; stamina is on the regiment's card now.
func _draw_banner(p: Dictionary, centre: Vector2, is_selected: bool) -> void:
	var zoom := _camera.zoom.x
	var rect := banner_rect(p, centre, zoom)
	if rect.size.x <= 0.0:
		return
	var unit := 1.0 / maxf(zoom, 0.01)
	var routing: bool = int(p["state"]) == Regiment.State.ROUTING

	# The pole, then the cloth in a dark frame.
	draw_line(Vector2(centre.x, rect.end.y), Vector2(centre.x, centre.y - rect.size.y * 0.1),
		Color(0.12, 0.1, 0.08, 0.8), 1.5 * unit)
	var cloth := Color.WHITE if routing else Colors.of_owner(int(p["owner"]), Net.player_ids())
	draw_rect(rect.grow(1.0 * unit), Color(0.08, 0.07, 0.06, 0.92))
	draw_rect(rect.grow(-1.0 * unit), cloth)
	draw_rect(rect.grow(-1.0 * unit), Colors.SELECT if is_selected else Color(Colors.TRIM_BRIGHT, 0.8),
		false, (2.0 if is_selected else 1.0) * unit)

	var inner := rect.grow(-2.0 * unit)
	var morale: float = clampf(float(p["morale"]) / Rules.MORALE_MAX, 0.0, 1.0)
	var band := Rect2(inner.position, Vector2(inner.size.x, 3.5 * unit))
	draw_rect(band, Color(0, 0, 0, 0.5))
	draw_rect(Rect2(band.position, Vector2(band.size.x * morale, band.size.y)), Colors.of_morale(morale))
	var strength: float = clampf(float(p["strength"]) / maxf(1.0, float(p["max_strength"])), 0.0, 1.0)
	var foot := Rect2(inner.position + Vector2(0, inner.size.y - 3.0 * unit), Vector2(inner.size.x, 3.0 * unit))
	draw_rect(foot, Color(0, 0, 0, 0.5))
	draw_rect(Rect2(foot.position, Vector2(foot.size.x * strength, foot.size.y)), Colors.TEXT)

	# ...and what it is. A routing regiment shows a bare white flag instead.
	if routing:
		return
	var icon := Art.kind_icon(p["kind"])
	var s := minf(inner.size.x, inner.size.y - 8.0 * unit) * 0.86
	var mid := inner.get_center()
	if icon != null:
		draw_texture_rect(icon, Rect2(mid - Vector2(s, s) * 0.5, Vector2(s, s)), false, Color(0.08, 0.07, 0.06, 0.9))


func _draw_ghost(row: Dictionary) -> void:
	var at: Vector2 = row["target"]
	var ahead := Vector2.from_angle(row["face"])
	var across := Vector2(-ahead.y, ahead.x)
	var half_d: float = row["half_depth"]
	var zoom := _camera.zoom.x

	# The men themselves are the ghost (_fill_ghosts). This is only where they come from,
	# and an arrowhead ahead of the front rank so which way they will face is not a guess.
	var tip := at + ahead * (half_d + 20.0)
	draw_colored_polygon(PackedVector2Array([tip, at + ahead * (half_d + 4.0) - across * 9.0,
		at + ahead * (half_d + 4.0) + across * 9.0]), Colors.ORDER)
	draw_dashed_line(row["from"], at, Color(Colors.ORDER, 0.4), 1.5 / zoom, 8.0 / zoom)

	# Where an archer would reach from there, which is most of why you move one.
	var reach: float = row.get("reach", 0.0)
	if reach > 0.0:
		draw_arc(at, reach, 0.0, TAU, 72, Color(Colors.GOLD, 0.35), 1.5 / zoom)


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
	# ...and not while it is over the HUD: the unit cards sit inside the edge margin, and
	# reaching for one slid the field out from under it.
	if Rect2(Vector2.ZERO, size).has_point(m) and get_viewport().gui_get_hovered_control() == null:
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
			widen(2)
		elif event.keycode == KEY_BRACKETLEFT:
			widen(-2)
		elif event.keycode == KEY_G:
			toggle_stance(Regiment.Stance.GUARD)
		elif event.keycode == KEY_H:
			toggle_stance(Regiment.Stance.SKIRMISH)
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
func toggle_stance(bit: int) -> void:
	if selected.is_empty():
		return
	var pose := _display_state()
	var lead: int = selected[0]
	var now := int(pose[lead]["stance"]) if pose.has(lead) else 0
	Net.order_stance(selected, (now & ~bit) if (now & bit) else (now | bit))


# --- what the HUD asks of it ------------------------------------------------

## A card clicked: that regiment alone, or added to what is already selected.
func select_from_card(id: int, add: bool) -> void:
	if not add:
		selected = PackedInt32Array([id])
	elif not id in selected:
		selected.append(id)


func look_at_regiment(id: int) -> void:
	var pose := _display_state()
	if pose.has(id):
		look_at_point(_men.centre_of(id, pose[id]["pos"]))


func look_at_point(at: Vector2) -> void:
	_camera.position = at


## What the camera can see, in world units, for the box on the minimap.
func visible_world() -> Rect2:
	var half := get_viewport_rect().size * 0.5 / _camera.zoom
	return Rect2(_camera.position - half, half * 2.0)


func dressing(id: int) -> float:
	return _men.dressing(id)


func set_formation(shape: StringName) -> void:
	if not selected.is_empty():
		Net.order_set_formation(selected, shape, 0)


## Frontage by the bracket keys. Total War drags a unit wider with the mouse, but the
## right button is already spending its drag on the facing you arrive at.
func widen(by: int) -> void:
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
	var zoom := _camera.zoom.x
	var picked := PackedInt32Array()
	# A CLICK in pixels, not in world units. The threshold was 6.0 world units, which at
	# the zoomed-out end is a pixel and a half -- a small wobble of the mouse turned every
	# click into a box-select.
	if from.distance_to(to) * zoom < 6.0:
		var best := pick_at(pose, to, Net.my_id(), true, zoom, _centres(pose))
		if best >= 0:
			picked.append(best)
	else:
		var box := Rect2(from, to - from).abs()
		var centres := _centres(pose)
		for id in pose:
			if pose[id]["owner"] != Net.my_id():
				continue
			# Its men, not its centre point: a regiment whose whole line is inside the box
			# but whose centre is a few units outside it used to be left behind.
			if box.has_point(centres.get(id, pose[id]["pos"])) or box.has_point(pose[id]["pos"]):
				picked.append(id)
	selected = picked


## Where each regiment is DRAWN, which is the mean of its living men and not the sim's
## centre point. Picking used one and drawing the other, so at half strength the block you
## could see sat forward of the circle you had to click.
func _centres(pose: Dictionary) -> Dictionary:
	var out := {}
	for id in pose:
		out[id] = _men.centre_of(id, pose[id]["pos"])
	return out


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
		# The SHAPE's extent, so a square packs as a square and a wedge as its widest rank.
		var e := Formation.extent(Formation.shape_of(StringName(p.get("formation", &"line"))),
			int(p["max_strength"]), w, spacing_of(p))
		var half := e.y
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
			"half_depth": Formation.extent(Formation.shape_of(StringName(p.get("formation", &"line"))),
				int(p["max_strength"]), w, spacing_of(p)).x,
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
	return pick_at(pose, at, Net.my_id(), false, _camera.zoom.x, _centres(pose))


## What is under this point: a regiment of `my_id`'s if `want_mine`, otherwise anybody
## else's. Static, and it takes a pose, so it tests headless the way plan_order does.
##
## Three tests in order of how deliberate the click is -- the banner, then the regiment's
## real footprint, then a circle as a last resort. It used to be the circle alone, at
## PICK_RADIUS 46 world units around the sim's centre point, and a 20-file line is 66.5
## units to its shoulder: **the wings of your own line were not clickable at all**, and a
## 40-file line offered only the middle third of itself.
static func pick_at(pose: Dictionary, at: Vector2, my_id: int, want_mine: bool,
		zoom: float, centres := {}) -> int:
	var best := -1
	var best_score := INF
	for id in pose:
		var p: Dictionary = pose[id]
		if (int(p["owner"]) == my_id) != want_mine:
			continue
		var centre: Vector2 = centres.get(id, p["pos"])

		if banner_rect(p, centre, zoom).has_point(at):
			return id                      # you aimed at the flag; nothing beats that

		# Inside the block it is standing in, measured the way the sim measures it.
		var spacing := spacing_of(p)
		var e := Bodies.extent_of(p)
		var half_w := e.y
		var half_d := e.x
		var local := (at - centre).rotated(-float(p["facing"]))
		if absf(local.x) <= half_d and absf(local.y) <= half_w:
			var depth := maxf(absf(local.x) / maxf(half_d, 0.001),
				absf(local.y) / maxf(half_w, 0.001))
			if depth < best_score:
				best_score = depth
				best = id
		elif best_score == INF:
			var d := centre.distance_to(at)
			if d < PICK_RADIUS and d + 1000.0 < best_score:
				best_score = d + 1000.0    # only if nothing was actually hit
				best = id
	return best


## The flag above a regiment, in WORLD space but a constant size on screen. Returns an
## empty rect for a shattered regiment: Total War takes the banner away entirely, and it
## is the clearest way to say "this one is never coming back".
static func banner_rect(p: Dictionary, centre: Vector2, zoom: float) -> Rect2:
	if int(p.get("routs", 0)) >= Rules.ROUTS_BEFORE_SHATTERED:
		return Rect2()
	var w := BANNER_W / maxf(zoom, 0.01)
	var h := BANNER_H / maxf(zoom, 0.01)
	var half := Bodies.extent_of(p).y + 10.0
	var bottom := centre.y - half - 16.0 - BANNER_LIFT / maxf(zoom, 0.01)
	return Rect2(centre.x - w * 0.5, bottom - h, w, h)


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
