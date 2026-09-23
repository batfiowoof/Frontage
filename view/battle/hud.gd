extends Control
## Everything on the battle screen that is not the field.
##
## Total War's layout, because it works: your regiments as cards along the bottom, what
## the selection can be told to do just above them, how the fight is going across the
## top, the field in miniature bottom-left, and the one irreversible button bottom-right.
##
## Anything that acts on the selection is a call into battle_view, which turns it into the
## same orders the keys and the mouse send. Only Begin and Give up -- which are about the
## whole side, not a regiment -- go to Net themselves.

const Rules := preload("res://sim/rules.gd")
const Regiment := preload("res://sim/regiment.gd")
const BattleState := preload("res://sim/battle_state.gd")
const Colors := preload("res://view/colors.gd")
const Art := preload("res://view/ui/art.gd")
const Widgets := preload("res://view/ui/widgets.gd")
const Minimap := preload("res://view/battle/minimap.gd")
const UiTheme := preload("res://view/ui/theme.gd")

const FORMATION_HINTS := {
	&"line": "Line — balanced; the default",
	&"column": "Column — narrow and quick on the march; bad if caught",
	&"square": "Square — no flank or rear to take, but few files and slow",
	&"wedge": "Wedge — hits harder on a narrower front",
	&"loose": "Loose — stands nearly twice as wide; poor in a melee, hard to shoot",
	&"shield": "Shield wall — heavy frontal protection, braced, very slow to turn",
}

var view                                   # battle_view.gd
var _clock: Label
var _balance: Control
var _phase: Label
var _toasts: VBoxContainer
var _orders: PanelContainer
var _orders_text: Label
var _formations := {}                      # shape -> Button
var _guard: Button
var _skirmish: Button
var _cards: HBoxContainer
var _card_of := {}                         # regiment id -> Button
var _begin: Button
var _quit: Button
var _quit_armed := false
var _minimap: Minimap
var _mine := 0
var _theirs := 0
var _mine_colour := Colors.NEUTRAL
var _theirs_colour := Colors.NEUTRAL


func _init(owner_view) -> void:
	view = owner_view
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	theme = UiTheme.shared()
	var f := Widgets.frame()
	add_child(f["root"])
	_build_top(f["top_centre"])
	_build_bottom(f["bottom_centre"])
	_minimap = Minimap.new(view)
	f["bottom_left"].add_child(_minimap)
	_build_corner(f["bottom_right"])
	Net.news.connect(func(text: String) -> void: Widgets.toast(_toasts, text, Colors.WARN))


func _build_top(centre: Control) -> void:
	var column := VBoxContainer.new()
	column.mouse_filter = Control.MOUSE_FILTER_IGNORE
	centre.add_child(column)
	var panel := PanelContainer.new()
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	column.add_child(panel)
	var rows := VBoxContainer.new()
	panel.add_child(rows)
	var line := HBoxContainer.new()
	line.alignment = BoxContainer.ALIGNMENT_CENTER
	rows.add_child(line)
	_phase = Widgets.label("", "Heading")
	line.add_child(_phase)
	_clock = Widgets.label()
	line.add_child(_clock)
	# The balance of power: our men against theirs, as one bar in the two colours.
	_balance = Control.new()
	_balance.custom_minimum_size = Vector2(360, 10)
	_balance.draw.connect(_draw_balance)
	rows.add_child(_balance)
	_toasts = VBoxContainer.new()
	_toasts.mouse_filter = Control.MOUSE_FILTER_IGNORE
	column.add_child(_toasts)


func _build_bottom(centre: Control) -> void:
	var column := VBoxContainer.new()
	column.alignment = BoxContainer.ALIGNMENT_END
	centre.add_child(column)

	# What the selection can be told to do. Hidden while nothing is selected.
	_orders = PanelContainer.new()
	_orders.visible = false
	_orders.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	column.add_child(_orders)
	var rows := VBoxContainer.new()
	_orders.add_child(rows)
	var bar := HBoxContainer.new()
	rows.add_child(bar)
	for shape: StringName in Rules.FORMATIONS:
		var b := Button.new()
		b.toggle_mode = true
		b.custom_minimum_size = Vector2(46, 40)
		b.tooltip_text = FORMATION_HINTS.get(shape, String(shape))
		var ratio: float = Rules.FORMATIONS[shape]["width"]
		b.draw.connect(func() -> void: _draw_formation_glyph(b, ratio, shape))
		b.pressed.connect(func() -> void: view.set_formation(shape))
		bar.add_child(b)
		_formations[shape] = b
	bar.add_child(VSeparator.new())
	var narrower := Widgets.icon_button(&"arrow_right_curve", "Narrower and deeper  [", 40)
	narrower.text = "−"
	narrower.icon = null
	narrower.pressed.connect(func() -> void: view.widen(-2))
	bar.add_child(narrower)
	var wider := Widgets.icon_button(&"arrow_right_curve", "Wider and shallower  ]", 40)
	wider.text = "+"
	wider.icon = null
	wider.pressed.connect(func() -> void: view.widen(2))
	bar.add_child(wider)
	bar.add_child(VSeparator.new())
	_guard = Widgets.icon_button(&"shield", "Guard — hold this ground, do not chase  (G)", 40)
	_guard.toggle_mode = true
	_guard.pressed.connect(func() -> void: view.toggle_stance(Regiment.Stance.GUARD))
	bar.add_child(_guard)
	_skirmish = Widgets.icon_button(&"arrow_reserve", "Skirmish — archers back away from anything closing  (H)", 40)
	_skirmish.toggle_mode = true
	_skirmish.pressed.connect(func() -> void: view.toggle_stance(Regiment.Stance.SKIRMISH))
	bar.add_child(_skirmish)
	_orders_text = Widgets.label("", "Dim")
	_orders_text.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	rows.add_child(_orders_text)

	_cards = HBoxContainer.new()
	_cards.alignment = BoxContainer.ALIGNMENT_CENTER
	_cards.add_theme_constant_override("separation", 3)
	column.add_child(_cards)


func _build_corner(right: Control) -> void:
	var column := VBoxContainer.new()
	column.alignment = BoxContainer.ALIGNMENT_END
	right.add_child(column)
	# Arranging the line. Where the give-up button goes, because they are never both
	# useful at once: you cannot give up a battle that has not started.
	_begin = Button.new()
	_begin.text = "Begin battle"
	_begin.theme_type_variation = "BigButton"
	_begin.icon = Art.icon(&"sword")
	_begin.custom_minimum_size = Vector2(190, 52)
	_begin.pressed.connect(func() -> void:
		Net.order_deployed()
		_begin.disabled = true)
	column.add_child(_begin)
	# Giving up asks twice. It ends the battle for everybody on your side and costs you
	# the field and a share of the men; that is not something to lose to a stray click.
	_quit = Widgets.icon_button(&"flag_square", "Give up the field", 44)
	_quit.text = "Give up"
	_quit.icon_alignment = HORIZONTAL_ALIGNMENT_LEFT
	_quit.custom_minimum_size = Vector2(130, 44)
	_quit.pressed.connect(_on_give_up)
	column.add_child(_quit)


func _on_give_up() -> void:
	if not _quit_armed:
		_quit_armed = true
		_quit.text = "Sure?"
		_quit.add_theme_color_override("font_color", Colors.BAD)
		return
	_quit_armed = false
	_quit.text = "Give up"
	_quit.remove_theme_color_override("font_color")
	Net.order_forfeit()


# --- every frame ----------------------------------------------------------

func update(pose: Dictionary, selected: PackedInt32Array, groups: Dictionary) -> void:
	var me: int = Net.my_id()
	var seating: Array = Net.player_ids()
	_mine = 0
	_theirs = 0
	for id in pose:
		if int(pose[id]["owner"]) == me:
			_mine += int(pose[id]["strength"])
			_mine_colour = Colors.of_owner(me, seating)
		else:
			_theirs += int(pose[id]["strength"])
			_theirs_colour = Colors.of_owner(int(pose[id]["owner"]), seating)
	_balance.queue_redraw()
	_balance.tooltip_text = "your men %d, theirs %d" % [_mine, _theirs]

	var battle = Net.battle
	var arranging: bool = battle != null and battle.phase == BattleState.Phase.DEPLOY
	var seconds := float(battle.tick) * Rules.TICK_DELTA if battle != null else 0.0
	if arranging:
		var left := maxf(0.0, Rules.DEPLOY_SECONDS - seconds)
		var waiting: bool = bool(battle.ready.get(me, false))
		_phase.text = "Deploy"
		_clock.text = "%ds%s" % [int(left), "  ·  waiting for the other side" if waiting else "  ·  set out your line in your own half"]
		_begin.disabled = waiting
	else:
		_phase.text = "Battle"
		_clock.text = "%d:%02d" % [int(seconds) / 60, int(seconds) % 60]
	_begin.visible = arranging
	_quit.visible = not arranging

	_update_cards(pose, selected, groups, me)
	_update_orders(pose, selected)
	_minimap.update(pose, selected)


func _draw_balance() -> void:
	var r := Rect2(Vector2.ZERO, _balance.size)
	_balance.draw_rect(r, Color(0, 0, 0, 0.6))
	var total := maxf(1.0, float(_mine + _theirs))
	var split := r.size.x * float(_mine) / total
	_balance.draw_rect(Rect2(r.position, Vector2(split, r.size.y)), _mine_colour)
	_balance.draw_rect(Rect2(r.position + Vector2(split, 0), Vector2(r.size.x - split, r.size.y)), _theirs_colour)
	_balance.draw_line(Vector2(r.size.x * 0.5, -2), Vector2(r.size.x * 0.5, r.size.y + 2), Colors.TEXT, 1.0)
	_balance.draw_rect(r, Colors.TRIM, false, 1.0)


## One card per living regiment of ours, kept in id order so a card does not jump about
## as others die. Built when the set of regiments changes, refilled every frame.
func _update_cards(pose: Dictionary, selected: PackedInt32Array, groups: Dictionary, me: int) -> void:
	var ours := []
	for id in pose:
		if int(pose[id]["owner"]) == me:
			ours.append(id)
	ours.sort()
	if ours != _card_of.keys():
		for c in _cards.get_children():
			c.queue_free()
		_card_of = {}
		for id: int in ours:
			var card := Widgets.unit_card()
			card.gui_input.connect(func(e: InputEvent) -> void: _on_card_input(e, id))
			card.focus_mode = Control.FOCUS_NONE
			_cards.add_child(card)
			_card_of[id] = card
	var slot_of := {}
	for slot in groups:
		for id in groups[slot]:
			slot_of[id] = slot + 1
	for id: int in ours:
		var p: Dictionary = pose[id]
		var card: Button = _card_of[id]
		var routing: bool = int(p["state"]) == Regiment.State.ROUTING
		var ammo := int(p.get("ammo", 0))
		Widgets.fill_card(card, p["kind"],
			"%d%s" % [int(p["strength"]), "  ➶%d" % ammo if ammo > 0 else ""],
			float(p["strength"]) / maxf(1.0, float(p["max_strength"])),
			clampf(float(p["morale"]) / Rules.MORALE_MAX, 0.0, 1.0),
			clampf(float(p["stamina"]), 0.0, 1.0),
			str(slot_of[id]) if slot_of.has(id) else "",
			Colors.BAD if routing else Colors.TEXT)
		card.set_pressed_no_signal(id in selected)
		card.tooltip_text = "%s — %d of %d men%s\nclick to select, ctrl-click to add, double-click to look" % [
			String(p["kind"]).capitalize(), int(p["strength"]), int(p["max_strength"]),
			"\nROUTING" if routing else ""]


func _on_card_input(e: InputEvent, id: int) -> void:
	if not (e is InputEventMouseButton and e.pressed and e.button_index == MOUSE_BUTTON_LEFT):
		return
	if e.double_click:
		view.look_at_regiment(id)
	view.select_from_card(id, e.ctrl_pressed or e.shift_pressed)
	accept_event()


func _update_orders(pose: Dictionary, selected: PackedInt32Array) -> void:
	var lead_id := -1
	for id in selected:
		if pose.has(id):
			lead_id = id
			break
	_orders.visible = lead_id >= 0
	if lead_id < 0:
		return
	var lead: Dictionary = pose[lead_id]
	var busy: float = lead["reforming"]
	for shape: StringName in _formations:
		var b: Button = _formations[shape]
		b.set_pressed_no_signal(shape == lead["formation"])
		b.disabled = busy > 0.0
	var stance := int(lead.get("stance", 0))
	_guard.set_pressed_no_signal((stance & Regiment.Stance.GUARD) != 0)
	_skirmish.set_pressed_no_signal((stance & Regiment.Stance.SKIRMISH) != 0)
	_skirmish.visible = view.range_of_kind(lead["kind"]) > 0.0

	# Changing frontage costs nothing and gates nothing, but it is not instant to look
	# at -- the men walk into their new files. The clock is the client's, from the mirror.
	var dressing: float = view.dressing(lead_id)
	var quiver := int(lead.get("ammo", 0))
	var parts := PackedStringArray(["%s, %d files" % [String(lead["formation"]).capitalize(), int(lead["width"])]])
	if selected.size() > 1:
		parts.append("%d selected" % selected.size())
	if quiver > 0:
		parts.append("%d volleys, range %.0f" % [quiver, view.range_of_kind(lead["kind"])])
	if busy > 0.0:
		parts.append("re-forming %.0fs" % busy)
	elif dressing > 0.0:
		parts.append("re-dressing %.0fs" % dressing)
	parts.append("right-click an enemy to attack it")
	_orders_text.text = "   ·   ".join(parts)


## A formation, drawn as the shape it makes: a block of dots as wide as the formation
## stands for a twelve-file regiment, since a word is what the old bar used and a shape
## is what the choice actually is.
func _draw_formation_glyph(b: Button, ratio: float, shape: StringName) -> void:
	var files := clampi(roundi(9.0 * ratio), 2, 10)
	var ranks := clampi(roundi(18.0 / float(files)), 2, 6)
	var pitch := minf(26.0 / float(files), 20.0 / float(ranks))
	var origin := b.size * 0.5 - Vector2(files - 1, ranks - 1) * pitch * 0.5
	var ink := Colors.GOLD if b.button_pressed else Colors.TEXT
	if b.disabled:
		ink = Color(ink, 0.35)
	for f in files:
		for r in ranks:
			var at := origin + Vector2(f, r) * pitch
			if shape == &"wedge" and absf(f - (files - 1) * 0.5) > float(r) + 0.6:
				continue
			b.draw_circle(at, maxf(1.2, pitch * 0.3), ink)
