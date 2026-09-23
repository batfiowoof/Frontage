extends Node2D
## The campaign map. Draws Net.campaign and turns clicks into orders.
##
## It never touches the world: every click becomes an order that goes to the server
## and comes back as a snapshot. On the host that round trip is a function call, but
## it is the same function call a remote client's order makes.
##
## Four layers, bottom to top: the ground (a shader, redrawn only when the map changes),
## what grows on it, the fog, and then this node -- borders, towns, armies, the route.
## The HUD is its own Control in hud.gd and owns none of the selection.

const Rules := preload("res://sim/rules.gd")
const Campaign := preload("res://sim/campaign_state.gd")
const Colors := preload("res://view/colors.gd")
const Hex := preload("res://view/campaign/hex.gd")
const Art := preload("res://view/ui/art.gd")
const Hud := preload("res://view/campaign/hud.gd")
const TERRAIN_SHADER := preload("res://view/shaders/terrain.gdshader")
const FOG_SHADER := preload("res://view/shaders/fog.gdshader")

const TILE := Rules.HEX_SIZE * 2.0
const DRAG_BUTTONS := [MOUSE_BUTTON_MIDDLE, MOUSE_BUTTON_RIGHT]
## Keyboard pan, in SCREEN pixels a second, so it feels the same at every zoom.
## No edge scroll here, unlike the battle: the campaign HUD lives along the top and the
## bottom, and reaching for End Turn would send the map sliding out from under the cursor.
const PAN_SPEED := 700.0
## What grows on each kind of ground, and how much of it. Seeded by tile index, so a hex
## looks the same every time and on every machine.
const DECOR := {
	Campaign.Terrain.FOREST: [[&"tree_pine", &"tree_round", &"tree_small"], 4, 0.42],
	Campaign.Terrain.HILLS: [[&"rock_pile", &"bush"], 2, 0.4],
	Campaign.Terrain.MOUNTAIN: [[&"rock_big", &"rock_pile"], 2, 0.62],
	Campaign.Terrain.PLAINS: [[&"bush"], 1, 0.28],
}
## Sprites from a cheerful pack, pulled toward the map's own muted palette.
const DECOR_TINT := Color(0.78, 0.8, 0.7)

var selected_army := -1
var selected_tile := -1
## Regiment indices picked for a new army, and whether the next click places it. The HUD
## sets these and the click handler spends them.
var detaching := PackedInt32Array()
var placing_detachment := false

var _camera: Camera2D
var _hud: Hud
var _ground: Node2D
var _decor: Node2D
var _fog: Node2D
var _dragging := false
var _hovered := -1
## Territory, worked out once a snapshot rather than once a frame: [from, to, colour].
var _borders: Array = []
var _claims := {}                          # tile -> owner, for the faint wash of colour


func _ready() -> void:
	_build_camera()
	_ground = _layer(-3, TERRAIN_SHADER, _draw_ground)
	_decor = _layer(-2, null, _draw_decor)
	_fog = _layer(-1, FOG_SHADER, _draw_fog)
	var hud_layer := CanvasLayer.new()
	add_child(hud_layer)
	_hud = Hud.new(self)
	hud_layer.add_child(_hud)
	Net.campaign_updated.connect(func(_cs) -> void: changed())
	changed()


func _layer(z: int, shader: Shader, painter: Callable) -> Node2D:
	var n := Node2D.new()
	n.z_index = z
	if shader != null:
		var m := ShaderMaterial.new()
		m.shader = shader
		n.material = m
	n.draw.connect(painter)
	add_child(n)
	return n


func _build_camera() -> void:
	_camera = Camera2D.new()
	_camera.position = Hex.map_centre()
	_camera.zoom = Vector2(0.85, 0.85)
	add_child(_camera)
	_camera.make_current()


## Something moved: a snapshot landed, or the selection changed. Everything that is
## worked out rather than drawn is worked out here.
func changed() -> void:
	_work_out_borders()
	_ground.queue_redraw()
	_decor.queue_redraw()
	_fog.queue_redraw()
	queue_redraw()
	_hud.refresh()


# --- input ----------------------------------------------------------------

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		if event.button_index in DRAG_BUTTONS:
			_dragging = event.pressed
		elif event.button_index == MOUSE_BUTTON_WHEEL_UP and event.pressed:
			_zoom(1.1)
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN and event.pressed:
			_zoom(1.0 / 1.1)
		elif event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
			_on_click(_tile_under_mouse())
	elif event is InputEventMouseMotion and _dragging:
		_camera.position -= event.relative / _camera.zoom
	elif event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_T:
			_hud.toggle_research()
		elif event.keycode == KEY_ESCAPE:
			if not _hud.close_overlay():
				selected_army = -1
				selected_tile = -1
				_clear_detachment()
			changed()


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
	if drift != Vector2.ZERO:
		_camera.position += drift.normalized() * PAN_SPEED * delta / _camera.zoom.x
	_clamp_camera()


## The map is finite and the camera was not: dragging far enough left the window looking
## at empty space with nothing to steer by and no way back but more dragging. Done here
## every frame rather than at each of the three places that move the camera -- a drag, a
## zoom and a key -- because a zoom out past the edge has to pull the view back in too.
##
## Clamped so the MAP fills the window, not so the camera centre stays on the map: at
## 0.35 zoom half a screen is most of the map, so an axis the window already covers is
## simply centred.
func _clamp_camera() -> void:
	var half := get_viewport_rect().size * 0.5 / _camera.zoom
	var b := Hex.map_bounds()
	var lo := b.position + half
	var hi := b.end - half
	var mid := b.get_center()
	_camera.position = Vector2(
		mid.x if lo.x >= hi.x else clampf(_camera.position.x, lo.x, hi.x),
		mid.y if lo.y >= hi.y else clampf(_camera.position.y, lo.y, hi.y))


func _zoom(factor: float) -> void:
	_camera.zoom = (_camera.zoom * factor).clampf(0.35, 2.5)


func _tile_under_mouse() -> int:
	return Hex.at(get_global_mouse_position())


## Left click selects. A tile with your army selects the army; otherwise the tile, which
## puts its town or its ground in the HUD. Clicking elsewhere with an army selected is an
## order to march -- the only mouse gesture that changes the world.
func _on_click(tile: int) -> void:
	var cs = Net.campaign
	if cs == null or tile < 0:
		return
	var me: int = Net.my_id()
	var army = cs.army_at(tile)

	# Waiting to be told where the detachment marches to.
	if placing_detachment and selected_army >= 0:
		Net.order_split(selected_army, detaching, tile)
		_clear_detachment()
		changed()
		return

	# Shift-click one of yours to fold the selected army into it. A combine idiom, and
	# it leaves ordinary selection alone.
	if Input.is_key_pressed(KEY_SHIFT) and army != null and army["owner"] == me \
			and selected_army >= 0 and army["id"] != selected_army:
		Net.order_merge(selected_army, army["id"])
		selected_army = army["id"]
		selected_tile = tile
		_clear_detachment()
		changed()
		return

	if army != null and army["owner"] == me:
		if army["id"] != selected_army:
			_clear_detachment()
		selected_army = army["id"]
		selected_tile = tile
	elif selected_army >= 0 and cs.armies.has(selected_army):
		Net.order_army_move(selected_army, tile)
	else:
		selected_army = -1
		selected_tile = tile
		_clear_detachment()
	changed()


func _clear_detachment() -> void:
	detaching = PackedInt32Array()
	placing_detachment = false


func _process(delta: float) -> void:
	_move_camera(delta)
	var tile := _tile_under_mouse()
	if tile != _hovered:
		_hovered = tile
		_hud.hover(tile)
		queue_redraw()
	elif selected_army >= 0:
		queue_redraw()       # the selection ring breathes


# --- working out ------------------------------------------------------------

## Whose each hex is: a town's own, or the nearest town working it. A line goes wherever
## that changes -- the single biggest thing a strategy map needs to be read at a glance,
## and the old one had nothing but coloured squares to go on.
func _work_out_borders() -> void:
	_borders = []
	_claims = {}
	var cs = Net.campaign
	if cs == null:
		return
	var seating: Array = Net.player_ids()
	for i in cs.terrain.size():
		var o := _claim(cs, i)
		if o != 0:
			_claims[i] = o
	var corners := Hex.corners()
	for i: int in _claims:
		var at := Hex.centre(i)
		for k in 6:
			var a := at + corners[k]
			var b := at + corners[(k + 1) % 6]
			# The hex across this edge, found by stepping over it rather than by a
			# direction table -- odd-r parity is exactly the thing that gets that wrong.
			var across := Hex.at(at + ((a + b) * 0.5 - at) * 2.0)
			if across >= 0 and _claims.get(across, 0) == _claims[i]:
				continue
			# Pulled a little inside, so two neighbours' borders sit side by side.
			var inset := (at - (a + b) * 0.5).normalized() * 2.0
			_borders.append([a + inset * 0.6, b + inset * 0.6, Colors.of_owner(_claims[i], seating)])


func _claim(cs, tile: int) -> int:
	var s = cs.settlement_at(tile)
	if s != null:
		return int(s["owner"])
	var worked = cs.working_settlement(tile)
	return 0 if worked == null else int(worked["owner"])


# --- drawing ------------------------------------------------------------------

func _draw_ground() -> void:
	var cs = Net.campaign
	if cs == null:
		return
	var uvs := PackedVector2Array()
	for c in Hex.corners():
		uvs.append(c / (Rules.HEX_SIZE * 2.0) + Vector2(0.5, 0.5))
	for i in cs.terrain.size():
		var tint := Colors.of_terrain(cs.terrain[i])
		if cs.terrain[i] == Campaign.Terrain.WATER:
			tint.a = 0.98                  # the shader's flag for "this one ripples"
		var shade := PackedColorArray([tint, tint, tint, tint, tint, tint])
		_ground.draw_polygon(Hex.polygon(i), shade, uvs)


func _draw_decor() -> void:
	var cs = Net.campaign
	if cs == null:
		return
	var me: int = Net.my_id()
	for i in cs.terrain.size():
		var spec: Array = DECOR.get(cs.terrain[i], [])
		if spec.is_empty() or cs.settlement_at(i) != null or cs.structure_at(i) != &"":
			continue
		var rng := RandomNumberGenerator.new()
		rng.seed = i * 7919 + 17
		var count: int = spec[1] if cs.terrain[i] != Campaign.Terrain.PLAINS else int(rng.randf() < 0.3)
		var size: float = Rules.HEX_SIZE * float(spec[2]) * 2.0
		var at := Hex.centre(i)
		var spots := []
		for n in count:
			spots.append(at + Vector2(rng.randf_range(-0.5, 0.5), rng.randf_range(-0.45, 0.4)) * Rules.HEX_SIZE)
		# Back to front, so the nearer tree stands in front of the one behind it.
		spots.sort_custom(func(a: Vector2, b: Vector2) -> bool: return a.y < b.y)
		var dim := DECOR_TINT if cs.can_see(me, i) else DECOR_TINT.darkened(0.3)
		for spot: Vector2 in spots:
			var tex := Art.sprite(spec[0][rng.randi() % spec[0].size()])
			if tex != null:
				_decor.draw_texture_rect(tex, Rect2(spot - Vector2(size * 0.5, size * 0.8), Vector2(size, size)), false, dim)


func _draw_fog() -> void:
	var cs = Net.campaign
	if cs == null:
		return
	var me: int = Net.my_id()
	for i in cs.terrain.size():
		if not cs.can_see(me, i):
			_fog.draw_colored_polygon(Hex.polygon(i), Color.WHITE)


func _draw() -> void:
	var cs = Net.campaign
	if cs == null:
		return
	var seating: Array = Net.player_ids()
	var me: int = Net.my_id()
	var font := Art.font(false, true)

	# Whose land is whose: a faint wash, and a hard line where it changes hands.
	for i: int in _claims:
		if cs.can_see(me, i):
			var wash := Colors.of_owner(_claims[i], seating)
			wash.a = 0.13
			draw_colored_polygon(Hex.polygon(i), wash)
	for b: Array in _borders:
		draw_line(b[0], b[1], b[2], 3.0, true)

	var focus = cs.settlement_at(selected_tile) if selected_tile >= 0 and selected_army < 0 else null
	if focus != null and int(focus["owner"]) == me:
		# The fields this town works, since that is what a build button here reaches.
		for i in cs.terrain.size():
			var worked = cs.working_settlement(i)
			if worked != null and worked["tile"] == focus["tile"]:
				_outline(i, Color(Colors.SELECT, 0.45), 1.5)
	if selected_tile >= 0 and selected_army < 0:
		_outline(selected_tile, Colors.SELECT, 2.5)
	if _hovered >= 0:
		_outline(_hovered, Color(1, 1, 1, 0.35), 1.5)

	_draw_roads(cs, me)
	for i in cs.terrain.size():
		var made := cs.structure_at(i)
		if made != &"" and made != &"road" and made != &"walls" and cs.can_see(me, i):
			_badge(Hex.centre(i) + Vector2(0, Rules.HEX_SIZE * 0.1), Art.structure_icon(made),
				Colors.of_structure(made), Rules.HEX_SIZE * 0.34)

	for s: Dictionary in cs.settlements:
		_draw_settlement(cs, s, seating, font)

	# armies_visible_to and not sorted_army_ids: the same call the wire filter makes, so
	# the host's window hides exactly what a joined client was never sent. A separate
	# view-side rule here would be the listen-server bug the whole design is built to
	# avoid -- two rules that agree today.
	for a: Dictionary in cs.armies_visible_to(me):
		_draw_army(cs, a, seating, font)

	_draw_route(cs, me)


func _outline(tile: int, colour: Color, width: float) -> void:
	var shape := Hex.polygon(tile)
	draw_polyline(shape + PackedVector2Array([shape[0]]), colour, width, true)


## A structure: its picture on a dark disc, ringed in its own colour.
func _badge(at: Vector2, icon: Texture2D, ring: Color, radius: float) -> void:
	draw_circle(at, radius, Color(0.08, 0.07, 0.05, 0.82))
	draw_arc(at, radius, 0, TAU, 20, ring, 1.5, true)
	if icon != null:
		var s := radius * 1.3
		draw_texture_rect(icon, Rect2(at - Vector2(s, s) * 0.5, Vector2(s, s)), false, ring)


## A road is worth nothing alone and everything as a chain, so it is drawn as the chain:
## a track from each road hex to every road or town beside it.
func _draw_roads(cs, me: int) -> void:
	for i in cs.terrain.size():
		if cs.structure_at(i) != &"road" or not cs.can_see(me, i):
			continue
		var at := Hex.centre(i)
		var joined := false
		for n in cs.adjacent(i):
			if cs.structure_at(n) == &"road" or cs.settlement_at(n) != null:
				draw_line(at, (at + Hex.centre(n)) * 0.5, Color("6b5a44"), 5.0, true)
				draw_line(at, (at + Hex.centre(n)) * 0.5, Color("a08a68"), 2.5, true)
				joined = true
		if not joined:
			draw_circle(at, 4.0, Color("a08a68"))


func _draw_settlement(cs, s: Dictionary, seating: Array, font: Font) -> void:
	var owner := int(s["owner"])
	var colour := Colors.of_owner(owner, seating) if owner != 0 else Colors.NEUTRAL
	var at := Hex.centre(s["tile"])
	var pop := Campaign.pop_of(s)
	var sprite: StringName = &"castle" if pop >= 5 else &"keep" if pop >= 3 else &"house"
	var size := Rules.HEX_SIZE * (1.15 + 0.06 * minf(pop, 8.0))

	if cs.structure_at(s["tile"]) == &"walls":
		draw_arc(at, Rules.HEX_SIZE * 0.78, 0, TAU, 32, Color("3a342c"), 5.0, true)
		draw_arc(at, Rules.HEX_SIZE * 0.78, 0, TAU, 32, Color("b8b0a0"), 3.0, true)
	var tex := Art.sprite(sprite)
	if tex != null:
		draw_texture_rect(tex, Rect2(at - Vector2(size * 0.5, size * 0.62), Vector2(size, size)), false,
			Color(0.9, 0.88, 0.82))
	else:
		draw_rect(Rect2(at - Vector2(12, 12), Vector2(24, 24)), colour)

	# The name plate: who holds it, what it is called, how many live there.
	var text: String = s["name"]
	var fs := 13
	var wide := font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
	var plate := Rect2(at + Vector2(-wide * 0.5 - 7, Rules.HEX_SIZE * 0.42), Vector2(wide + 14, 17))
	draw_rect(plate, Color(0.07, 0.06, 0.05, 0.88))
	draw_rect(Rect2(plate.position, Vector2(4, plate.size.y)), colour)
	draw_rect(plate, Color(colour, 0.9), false, 1.0)
	draw_string(font, plate.position + Vector2(9, 13), text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, Colors.TEXT)
	# How many live there, on a disc at the end of the plate.
	var disc := plate.position + Vector2(plate.size.x + 7, plate.size.y * 0.5)
	draw_circle(disc, 8.5, Color(0.07, 0.06, 0.05, 0.92))
	draw_arc(disc, 8.5, 0, TAU, 16, colour, 1.5, true)
	var n := str(pop)
	draw_string(font, disc + Vector2(-font.get_string_size(n, HORIZONTAL_ALIGNMENT_LEFT, -1, 11).x * 0.5, 4),
		n, HORIZONTAL_ALIGNMENT_LEFT, -1, 11, Colors.GOLD)

	# How much they mind you, as a bar under the plate that fills toward revolt -- the
	# one about to go is the one you can see from across the map.
	var anger := Campaign.unrest_of(s)
	if anger > 0:
		var bar := Rect2(plate.position + Vector2(0, plate.size.y + 1), Vector2(plate.size.x, 3))
		draw_rect(bar, Color(0, 0, 0, 0.6))
		draw_rect(Rect2(bar.position, Vector2(bar.size.x * float(anger) / float(Rules.UNREST_REVOLT), 3)), Colors.BAD)


## An army as a disc in its owner's colour, carrying the kind it has most of, with how
## many regiments on a badge and what it is doing between turns on another.
func _draw_army(cs, a: Dictionary, seating: Array, font: Font) -> void:
	var centre := Hex.centre(a["tile"])
	if cs.settlement_at(a["tile"]) != null:
		centre += Vector2(Rules.HEX_SIZE * 0.42, -Rules.HEX_SIZE * 0.4)   # beside the town
	var colour := Colors.of_owner(a["owner"], seating)
	var r := Rules.HEX_SIZE * 0.5
	var chosen: bool = a["id"] == selected_army

	draw_circle(centre + Vector2(0, r * 0.35), r * 1.05, Color(0, 0, 0, 0.35))   # its shadow
	if chosen:
		var breathe := 0.55 + 0.45 * sin(Time.get_ticks_msec() * 0.005)
		draw_arc(centre, r * 1.4, 0, TAU, 32, Color(Colors.SELECT, breathe), 3.0, true)
	draw_circle(centre, r + 2.5, Color(0.06, 0.05, 0.04))
	draw_circle(centre, r, colour)
	draw_arc(centre, r - 2.0, 0, TAU, 28, colour.lightened(0.35), 1.5, true)
	var lead := Art.kind_icon(_lead_kind(a))
	if lead != null:
		draw_texture_rect(lead, Rect2(centre - Vector2(r, r) * 0.62, Vector2(r, r) * 1.24), false, Color(0.08, 0.06, 0.05, 0.92))

	var badge := centre + Vector2(r * 0.85, r * 0.8)
	draw_circle(badge, 8.0, Color(0.07, 0.06, 0.05))
	draw_arc(badge, 8.0, 0, TAU, 16, colour, 1.5, true)
	var count := str(a["regiments"].size())
	draw_string(font, badge + Vector2(-font.get_string_size(count, HORIZONTAL_ALIGNMENT_LEFT, -1, 11).x * 0.5, 4),
		count, HORIZONTAL_ALIGNMENT_LEFT, -1, 11, Colors.TEXT)

	# What it is doing between turns. A dug-in or hidden army looks exactly like a
	# marching one otherwise, and both of them gave up a turn to be that way.
	var posted := Campaign.stance_of(a)
	if posted != Campaign.Stance.MARCH:
		var tag := centre + Vector2(-r * 0.9, -r * 0.85)
		draw_circle(tag, 8.0, Color(0.07, 0.06, 0.05))
		var icon := Art.stance_icon(posted)
		if icon != null:
			draw_texture_rect(icon, Rect2(tag - Vector2(6, 6), Vector2(12, 12)), false, Colors.GOLD)


static func _lead_kind(a: Dictionary) -> StringName:
	var counts := {}
	var best: StringName = &""
	for r: Array in a["regiments"]:
		counts[r[0]] = counts.get(r[0], 0) + 1
		if best == &"" or counts[r[0]] > counts[best]:
			best = r[0]
	return best


## The route the selected army would take, so marching is not guesswork: dashes within
## this turn's reach, fainter beyond it, and a numbered marker wherever a turn runs out.
func _draw_route(cs, me: int) -> void:
	if selected_army < 0 or not cs.armies.has(selected_army):
		return
	var a: Dictionary = cs.armies[selected_army]
	var from: int = a["tile"]
	var to := _tile_under_mouse()
	if to < 0 or to == from:
		return
	var left: int = a["move_left"]
	var stride := maxi(1, Campaign.move_points(a))
	var prev := Hex.centre(from)
	var walked := 0
	var font := Art.font(false, true)
	for step: int in cs.path(from, to):
		var here := Hex.centre(step)
		walked += 1
		var now := walked <= left
		draw_dashed_line(prev, here, Colors.ORDER if now else Color(Colors.ORDER, 0.35), 3.0, 8.0)
		if walked == left or (walked > left and (walked - left) % stride == 0):
			var turns := 1 + (0 if walked <= left else ceili(float(walked - left) / float(stride)))
			draw_circle(here, 9.0, Color(0.07, 0.06, 0.05, 0.9))
			draw_string(font, here + Vector2(-4, 5), str(turns), HORIZONTAL_ALIGNMENT_LEFT, -1, 12, Colors.ORDER)
		prev = here

	# What waits at the end: somebody to fight, or just ground.
	var enemy = cs.army_at(to)
	var town = cs.settlement_at(to)
	var hostile: bool = (enemy != null and enemy["owner"] != me) or (town != null and town["owner"] != me)
	var mark := Art.icon(&"sword" if hostile else &"flag_triangle")
	if mark != null:
		draw_texture_rect(mark, Rect2(Hex.centre(to) - Vector2(11, 30), Vector2(22, 22)), false,
			Colors.BAD if hostile else Colors.ORDER)
