extends Node2D
## The campaign map. Draws Net.campaign and turns clicks into orders.
##
## It never touches the world: every click becomes an order that goes to the server
## and comes back as a snapshot. On the host that round trip is a function call, but
## it is the same function call a remote client's order makes.

const Rules := preload("res://sim/rules.gd")
const Campaign := preload("res://sim/campaign_state.gd")
const Colors := preload("res://view/colors.gd")
const Hex := preload("res://view/campaign/hex.gd")

const TILE := Rules.HEX_SIZE * 2.0
const DRAG_BUTTONS := [MOUSE_BUTTON_MIDDLE, MOUSE_BUTTON_RIGHT]

var selected_army := -1
var selected_tile := -1

var _camera: Camera2D
var _status: Label
var _players: Label
var _hint: Label
var _news: Label
var _end_turn: Button
var _recruit_bar: HBoxContainer
var _build_bar: HBoxContainer
var _improve_bar: HBoxContainer
var _improve_buttons := {}
var _recruit_buttons := {}
var _build_buttons := {}
var _dragging := false


func _ready() -> void:
	_build_camera()
	_build_hud()
	Net.campaign_updated.connect(_on_campaign_updated)
	Net.order_rejected.connect(_on_order_rejected)
	Net.news.connect(_on_news)
	_refresh()


func _build_camera() -> void:
	_camera = Camera2D.new()
	_camera.position = Hex.map_centre()
	_camera.zoom = Vector2(0.85, 0.85)
	add_child(_camera)
	_camera.make_current()


func _build_hud() -> void:
	var layer := CanvasLayer.new()
	add_child(layer)

	_status = Label.new()
	_status.position = Vector2(12, 8)
	_status.add_theme_font_size_override("font_size", 18)
	layer.add_child(_status)

	_players = Label.new()
	_players.position = Vector2(12, 34)
	layer.add_child(_players)

	_hint = Label.new()
	_hint.set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
	_hint.position = Vector2(12, -124)
	layer.add_child(_hint)

	_news = Label.new()
	_news.set_anchors_preset(Control.PRESET_CENTER_TOP)
	_news.position = Vector2(-260, 10)
	_news.custom_minimum_size = Vector2(520, 0)
	_news.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_news.add_theme_color_override("font_color", Color("ffd98a"))
	layer.add_child(_news)

	_recruit_bar = HBoxContainer.new()
	_recruit_bar.set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
	_recruit_bar.position = Vector2(12, -34)
	layer.add_child(_recruit_bar)
	for kind: StringName in Rules.KINDS:
		var b := Button.new()
		b.text = "%s  %dg" % [kind, Rules.KINDS[kind]["cost"]]
		b.pressed.connect(_on_recruit.bind(kind))
		_recruit_bar.add_child(b)
		_recruit_buttons[kind] = b

	_improve_bar = HBoxContainer.new()
	_improve_bar.set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
	_improve_bar.position = Vector2(12, -102)
	layer.add_child(_improve_bar)
	for name: StringName in Rules.IMPROVEMENTS:
		var b := Button.new()
		b.text = "%s  %dg" % [name, Rules.IMPROVEMENTS[name]["cost"]]
		b.pressed.connect(_on_improve.bind(name))
		_improve_bar.add_child(b)
		_improve_buttons[name] = b

	_build_bar = HBoxContainer.new()
	_build_bar.set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
	_build_bar.position = Vector2(12, -68)
	layer.add_child(_build_bar)
	for building: StringName in Rules.BUILDINGS:
		var b := Button.new()
		b.text = "build %s  %dg" % [building, Rules.BUILDINGS[building]["cost"]]
		b.pressed.connect(_on_build.bind(building))
		_build_bar.add_child(b)
		_build_buttons[building] = b

	_end_turn = Button.new()
	_end_turn.set_anchors_preset(Control.PRESET_BOTTOM_RIGHT)
	_end_turn.position = Vector2(-150, -40)
	_end_turn.custom_minimum_size = Vector2(138, 32)
	_end_turn.pressed.connect(_on_end_turn)
	layer.add_child(_end_turn)


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
	elif event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
		selected_army = -1
		selected_tile = -1
		_refresh()


func _zoom(factor: float) -> void:
	_camera.zoom = (_camera.zoom * factor).clampf(0.35, 2.5)


func _tile_under_mouse() -> int:
	return Hex.at(get_global_mouse_position())


## Left click selects. A tile with your army selects the army; otherwise a tile you
## own selects the settlement so you can recruit there. Clicking elsewhere with an
## army selected is an order to march — the only mouse gesture that changes the world.
func _on_click(tile: int) -> void:
	var cs = Net.campaign
	if cs == null or tile < 0:
		return
	var me: int = Net.my_id()
	var army = cs.army_at(tile)

	if army != null and army["owner"] == me:
		selected_army = army["id"]
		selected_tile = tile
	elif selected_army >= 0 and cs.armies.has(selected_army):
		Net.order_army_move(selected_army, tile)
	else:
		selected_army = -1
		selected_tile = tile
	_refresh()


func _on_recruit(kind: StringName) -> void:
	if selected_tile >= 0:
		Net.order_recruit(selected_tile, kind)


func _on_improve(name: StringName) -> void:
	if selected_tile >= 0:
		Net.order_improve(selected_tile, name)


func _on_build(building: StringName) -> void:
	if selected_tile >= 0:
		Net.order_build(selected_tile, building)


func _on_end_turn() -> void:
	var cs = Net.campaign
	if cs != null:
		Net.order_ready(not bool(cs.ready.get(Net.my_id(), false)))


func _on_order_rejected(_peer: int, reason: String) -> void:
	_hint.text = "refused: " + reason


func _on_news(text: String) -> void:
	_news.text = text


# --- drawing --------------------------------------------------------------

func _on_campaign_updated(_cs) -> void:
	_refresh()


func _refresh() -> void:
	queue_redraw()
	var cs = Net.campaign
	if cs == null:
		return
	var me: int = Net.my_id()
	var seating: Array = Net.player_ids()

	_status.text = "Turn %d      gold %d      food %d      upkeep %d" % [
		cs.turn, int(cs.gold.get(me, 0)), int(cs.food.get(me, 0)), cs.upkeep_of(me)]

	var lines := PackedStringArray()
	for id: int in seating:
		lines.append("%s  %s  (%d towns)" % [
			"you" if id == me else "player %d" % id,
			"ready" if bool(cs.ready.get(id, false)) else "thinking",
			cs.settlements_of(id)])
	_players.text = "\n".join(lines)

	var mine_ready := bool(cs.ready.get(me, false))
	_end_turn.text = "Waiting..." if mine_ready else "End Turn"

	var settlement = cs.settlement_at(selected_tile) if selected_tile >= 0 else null
	var mine_here: bool = settlement != null and settlement["owner"] == me
	_recruit_bar.visible = mine_here
	_build_bar.visible = mine_here

	var can_work := false
	if selected_tile >= 0 and settlement == null:
		var purse := int(cs.gold.get(me, 0))
		for name: StringName in _improve_buttons:
			var allowed: bool = cs.can_improve(me, selected_tile, name)
			can_work = can_work or allowed
			var button: Button = _improve_buttons[name]
			button.disabled = not allowed or purse < int(Rules.IMPROVEMENTS[name]["cost"])
			button.tooltip_text = "" if allowed else "not on this ground, or too far from a town"
	_improve_bar.visible = can_work
	if mine_here:
		var purse := int(cs.gold.get(me, 0))
		var available: Array = cs.recruitable_at(selected_tile)
		for kind: StringName in _recruit_buttons:
			var button: Button = _recruit_buttons[kind]
			var needs: StringName = Rules.KINDS[kind]["requires"]
			button.disabled = not available.has(kind) or purse < int(Rules.KINDS[kind]["cost"])
			button.tooltip_text = "" if available.has(kind) else "needs a %s here" % needs
		for building: StringName in _build_buttons:
			var button: Button = _build_buttons[building]
			var built: bool = settlement["buildings"].has(building)
			button.disabled = built or purse < int(Rules.BUILDINGS[building]["cost"])
			button.tooltip_text = "already built" if built else ""

	if selected_army >= 0 and cs.armies.has(selected_army):
		var a = cs.armies[selected_army]
		_hint.text = "army %d: %d regiments, %d moves left — click a tile to march" % [
			a["id"], a["regiments"].size(), a["move_left"]]
	elif selected_tile >= 0 and settlement == null:
		var made := cs.improvement_at(selected_tile)
		_hint.text = "tile %d: %s%s" % [selected_tile,
			Campaign.Terrain.keys()[cs.terrain[selected_tile]].to_lower(),
			", %s" % made if made != &"" else ""]
	elif mine_here:
		var built: String = ", ".join(PackedStringArray(settlement["buildings"])) if settlement["buildings"].size() > 0 else "nothing built"
		var income := Campaign.settlement_income(settlement)
		_hint.text = "%s — %s — +%dg +%d food per turn" % [
			settlement["name"], built, income["gold"], income["food"]]
	else:
		_hint.text = "click your army to select it"


func _draw() -> void:
	var cs = Net.campaign
	if cs == null:
		return
	var seating: Array = Net.player_ids()

	var outline := PackedColorArray()
	for i in cs.terrain.size():
		var shape := Hex.polygon(i)
		draw_colored_polygon(shape, Colors.of_terrain(cs.terrain[i]))
		draw_polyline(shape + PackedVector2Array([shape[0]]), Color(0, 0, 0, 0.14), 1.0)

		# What has been done to the land, as a dot in the middle of it.
		var made := cs.improvement_at(i)
		if made != &"":
			draw_circle(Hex.centre(i), Rules.HEX_SIZE * 0.22, Colors.of_improvement(made))
			draw_arc(Hex.centre(i), Rules.HEX_SIZE * 0.22, 0, TAU, 16, Color(0, 0, 0, 0.5), 1.5)

	for s: Dictionary in cs.settlements:
		var c := Colors.of_owner(s["owner"], seating)
		var at := Hex.centre(s["tile"])
		var box := Rules.HEX_SIZE * 0.62
		draw_rect(Rect2(at - Vector2(box, box) * 0.5, Vector2(box, box)), c)
		draw_rect(Rect2(at - Vector2(box, box) * 0.5, Vector2(box, box)), Color.BLACK, false, 2.0)
		# One pip per building, so a developed town looks different from a bare one.
		for i in s["buildings"].size():
			draw_rect(Rect2(at + Vector2(-box * 0.5 + float(i) * 5.0, box * 0.55), Vector2(4, 4)), Color.BLACK)

	for id in cs.sorted_army_ids():
		var a = cs.armies[id]
		var centre := Hex.centre(a["tile"])
		var c := Colors.of_owner(a["owner"], seating)
		draw_circle(centre, Rules.HEX_SIZE * 0.42, c)
		draw_arc(centre, Rules.HEX_SIZE * 0.42, 0, TAU, 24, Color.BLACK, 2.0)
		if a["id"] == selected_army:
			draw_arc(centre, Rules.HEX_SIZE * 0.6, 0, TAU, 28, Color.WHITE, 2.5)
		var font := ThemeDB.fallback_font
		draw_string(font, centre + Vector2(-5, 5), str(a["regiments"].size()),
			HORIZONTAL_ALIGNMENT_LEFT, -1, 16, Color.BLACK)

	# The route the selected army would take, so marching is not guesswork.
	if selected_army >= 0 and cs.armies.has(selected_army):
		var from: int = cs.armies[selected_army]["tile"]
		var to := _tile_under_mouse()
		if to >= 0 and to != from:
			var prev := Hex.centre(from)
			var left: int = cs.armies[selected_army]["move_left"]
			var walked := 0
			for step: int in cs.path(from, to):
				var here := Hex.centre(step)
				walked += 1
				draw_line(prev, here, Color.WHITE if walked <= left else Color(1, 1, 1, 0.3), 2.0)
				prev = here


func _process(_delta: float) -> void:
	if selected_army >= 0:
		queue_redraw()       # the route preview follows the mouse
