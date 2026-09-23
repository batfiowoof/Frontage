extends Control
## Both research trees, full screen over a dimmed map, laid out by what needs what.
##
## A column per step of prerequisite depth, so a tech sits to the right of everything it
## needs and the lines between them only ever run forward. The rules are the sim's:
## `can_learn` decides what is clickable and `techs_of` what is known, exactly as the old
## button list read them.

const Rules := preload("res://sim/rules.gd")
const Colors := preload("res://view/colors.gd")
const Widgets := preload("res://view/ui/widgets.gd")
const Art := preload("res://view/ui/art.gd")

const NODE := Vector2(170, 44)
const STEP := Vector2(200, 58)

var _buttons := {}                       # tech -> Button
var _board: Control
var _built_for = null                    # the civ the board was laid out for


func _init() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	visible = false
	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.62)
	dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(dim)

	var centre := CenterContainer.new()
	centre.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	centre.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(centre)
	var panel := PanelContainer.new()
	centre.add_child(panel)
	var rows := VBoxContainer.new()
	panel.add_child(rows)

	var head := HBoxContainer.new()
	rows.add_child(head)
	var title := Widgets.label("Research", "Heading")
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(title)
	head.add_child(Widgets.label("one pool, two trees   ·   T or Esc to close", "Dim"))

	_board = Control.new()
	_board.draw.connect(_draw_links)
	rows.add_child(_board)


## Laid out per people, because each has techs nobody else can see: a hole in the tree
## where another civ's row would be is worse than a tree that is simply shaped differently.
func _build(civ: StringName) -> void:
	_built_for = civ
	for c in _board.get_children():
		c.queue_free()
	_buttons.clear()
	var extent := Vector2.ZERO
	var top := 0.0
	for tree: String in ["economy", "battle"]:
		var heading := Widgets.label(tree.capitalize(), "Heading")
		heading.position = Vector2(0, top)
		_board.add_child(heading)
		top += 32.0
		var in_column := {}
		for name: StringName in Rules.TECHS:
			if Rules.TECHS[name]["tree"] != tree:
				continue
			var own: StringName = Rules.TECHS[name].get("civ", &"")
			if own != &"" and own != civ:
				continue
			var col := _depth(name)
			var row: int = in_column.get(col, 0)
			in_column[col] = row + 1
			var b := Button.new()
			b.text = "%s   %d" % [String(name).capitalize(), Rules.TECHS[name]["cost"]]
			b.icon = Art.icon(&"book_open")
			b.expand_icon = true
			b.position = Vector2(col * STEP.x, top + row * STEP.y)
			b.size = NODE
			b.alignment = HORIZONTAL_ALIGNMENT_LEFT
			b.pressed.connect(func() -> void: Net.order_research(name))
			if own != &"":
				b.add_theme_color_override("font_color", Colors.GOLD)
			_board.add_child(b)
			_buttons[name] = b
			extent = extent.max(b.position + NODE)
		top = extent.y + 24.0
	_board.custom_minimum_size = extent


static func _depth(name: StringName) -> int:
	var deepest := 0
	for needed: StringName in Rules.TECHS[name]["needs"]:
		deepest = maxi(deepest, _depth(needed) + 1)
	return deepest


func refresh(cs, me: int) -> void:
	if not visible or cs == null:
		return
	if _built_for != cs.civ_of(me):
		_build(cs.civ_of(me))
	var known: Array = cs.techs_of(me)
	for name: StringName in _buttons:
		var b: Button = _buttons[name]
		var effect: Dictionary = Rules.TECHS[name]["effect"]
		var what := ", ".join(effect.keys().map(func(k): return "%s ×%s" % [k, effect[k]]))
		var own: StringName = Rules.TECHS[name].get("civ", &"")
		if own != &"":
			what = "%s only\n%s" % [Rules.CIVS[own]["name"], what]
		for kind: StringName in Rules.KINDS:
			if Rules.KINDS[kind].get("tech", &"") == name:
				what += "\nraises %s" % String(kind).capitalize()
		if known.has(name):
			b.disabled = true
			b.modulate = Colors.GOLD
			b.tooltip_text = "known\n" + what
			continue
		b.disabled = not cs.can_learn(me, name)
		var missing := []
		for needed: StringName in Rules.TECHS[name]["needs"]:
			if not known.has(needed):
				missing.append(String(needed))
		# Dim only what is locked behind another tech. Something merely too dear is the
		# next thing you are saving for, and should look like it.
		b.modulate = Color.WHITE if missing.is_empty() else Color(1, 1, 1, 0.45)
		b.tooltip_text = what + ("\nneeds %s" % ", ".join(missing) if not missing.is_empty()
			else "\nnot enough research yet" if b.disabled else "")
	_board.queue_redraw()


func _draw_links() -> void:
	for name: StringName in _buttons:
		var to: Button = _buttons[name]
		for needed: StringName in Rules.TECHS[name]["needs"]:
			if not _buttons.has(needed):
				continue
			var from: Button = _buttons[needed]
			var a := from.position + Vector2(NODE.x, NODE.y * 0.5)
			var b := to.position + Vector2(0, NODE.y * 0.5)
			var bend := (a.x + b.x) * 0.5
			var lit: bool = from.disabled and from.modulate == Colors.GOLD
			_board.draw_polyline(PackedVector2Array([a, Vector2(bend, a.y), Vector2(bend, b.y), b]),
				Colors.GOLD if lit else Colors.TRIM, 2.0)
