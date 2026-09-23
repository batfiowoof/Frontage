extends RefCounted
## The handful of pieces both HUDs are assembled from. Static builders, no state: a
## widget that needs to change is handed back to the caller and updated there.

const Colors := preload("res://view/colors.gd")
const Art := preload("res://view/ui/art.gd")
const Rules := preload("res://sim/rules.gd")

const CARD := Vector2(58, 76)


static func label(text := "", variation := "") -> Label:
	var l := Label.new()
	l.text = text
	if variation != "":
		l.theme_type_variation = variation
	return l


## A square icon button. The tooltip is the only words it has, so it is not optional.
static func icon_button(icon: StringName, tip: String, size := 40) -> Button:
	var b := Button.new()
	b.icon = Art.icon(icon)
	b.expand_icon = true
	b.icon_alignment = HORIZONTAL_ALIGNMENT_CENTER
	b.custom_minimum_size = Vector2(size, size)
	b.add_theme_constant_override("icon_max_width", size - 12)
	b.tooltip_text = tip
	if b.icon == null:
		b.text = String(icon).left(2)
	return b


## An icon with a number beside it: the resource line along the top.
static func stat(icon: StringName, tip: String) -> Array:
	var row := HBoxContainer.new()
	row.tooltip_text = tip
	row.mouse_filter = Control.MOUSE_FILTER_PASS
	row.add_theme_constant_override("separation", 4)
	row.add_child(picture(Art.icon(icon), 20, Colors.GOLD))
	var value := label()
	row.add_child(value)
	return [row, value]


static func picture(tex: Texture2D, size: int, tint := Colors.TEXT) -> TextureRect:
	var r := TextureRect.new()
	r.texture = tex
	r.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	r.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	r.custom_minimum_size = Vector2(size, size)
	r.modulate = tint
	r.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return r


## A regiment as Total War shows one along the bottom of the screen: what it is, a bar
## for how many are left, and a band of colour for how it is holding up. The same card
## on the campaign map and on the field, filled by `fill_card`.
static func unit_card() -> Button:
	var card := Button.new()
	card.toggle_mode = true
	card.custom_minimum_size = CARD
	card.clip_contents = true
	var face := picture(null, 34)
	face.name = "Face"
	face.position = Vector2(CARD.x * 0.5 - 17, 8)
	card.add_child(face)
	var corner := label("", "Dim")
	corner.name = "Corner"
	corner.position = Vector2(4, 0)
	corner.add_theme_font_size_override("font_size", 12)
	card.add_child(corner)
	var count := label()
	count.name = "Count"
	count.add_theme_font_size_override("font_size", 13)
	count.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	count.position = Vector2(0, 42)
	count.size = Vector2(CARD.x, 16)
	card.add_child(count)
	# The bars are drawn rather than nodes: three of them on forty cards at 60 fps is a
	# lot of ProgressBars for what is four rectangles.
	card.draw.connect(func() -> void: _draw_card_bars(card))
	return card


## `strength` and `morale` are 0..1; a negative `morale` or `stamina` hides that bar,
## which is how a campaign card -- no fight, so nobody is frightened or tired -- leaves
## them off.
static func fill_card(card: Button, kind: StringName, count: String, strength: float,
		morale: float, stamina := -1.0, corner := "", tint := Colors.TEXT) -> void:
	var face: TextureRect = card.get_node("Face")
	face.texture = Art.kind_icon(kind)
	face.modulate = tint
	card.get_node("Count").text = count
	card.get_node("Corner").text = corner
	card.tooltip_text = String(kind)
	card.set_meta("bars", Vector3(strength, morale, stamina))
	card.queue_redraw()


static func _draw_card_bars(card: Button) -> void:
	var bars: Vector3 = card.get_meta("bars", Vector3(1, 1, -1))
	var w := card.size.x - 8.0
	var y := card.size.y - 16.0
	card.draw_rect(Rect2(4, y, w, 4), Color(0, 0, 0, 0.6))
	card.draw_rect(Rect2(4, y, w * clampf(bars.x, 0, 1), 4), Colors.TEXT)
	if bars.y >= 0.0:
		card.draw_rect(Rect2(4, y + 5, w, 4), Color(0, 0, 0, 0.6))
		card.draw_rect(Rect2(4, y + 5, w * clampf(bars.y, 0, 1), 4), Colors.of_morale(bars.y))
	if bars.z >= 0.0:
		card.draw_rect(Rect2(4, y + 10, w * clampf(bars.z, 0, 1), 2),
			Color("6fa8c9") if bars.z > 0.3 else Color("8a6fc9"))


## Words that arrive rather than being asked for: news, a refused order. They stack at
## the top middle and fade on their own, so nothing has to be dismissed.
static func toast(stack: VBoxContainer, text: String, tint := Colors.TEXT) -> void:
	var p := PanelContainer.new()
	p.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var l := label(text)
	l.add_theme_color_override("font_color", tint)
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	p.add_child(l)
	stack.add_child(p)
	while stack.get_child_count() > 4:
		stack.get_child(0).free()
	var fade := p.create_tween()
	fade.tween_interval(4.0)
	fade.tween_property(p, "modulate:a", 0.0, 0.8)
	fade.tween_callback(p.queue_free)


## The skeleton every HUD hangs on: a full-screen frame of top, middle and bottom rows,
## each split left / centre / right. Containers all the way down, so nothing is placed by
## a pixel offset and a 1080p window lays out the same as a 720p one.
##
## Returns {root, top_left, top_centre, top_right, bottom_left, bottom_centre,
## bottom_right}. Every row lets clicks through to the map except where something is.
static func frame() -> Dictionary:
	var root := MarginContainer.new()
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	for side in ["left", "right", "top", "bottom"]:
		root.add_theme_constant_override("margin_" + side, 8)
	var rows := VBoxContainer.new()
	rows.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(rows)
	var out := {"root": root}
	for row in ["top", "bottom"]:
		var line := HBoxContainer.new()
		line.mouse_filter = Control.MOUSE_FILTER_IGNORE
		line.alignment = BoxContainer.ALIGNMENT_CENTER
		for part in ["left", "centre", "right"]:
			var cell := HBoxContainer.new()
			cell.mouse_filter = Control.MOUSE_FILTER_IGNORE
			cell.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			cell.size_flags_vertical = Control.SIZE_SHRINK_BEGIN if row == "top" else Control.SIZE_SHRINK_END
			cell.alignment = {"left": BoxContainer.ALIGNMENT_BEGIN,
				"centre": BoxContainer.ALIGNMENT_CENTER, "right": BoxContainer.ALIGNMENT_END}[part]
			line.add_child(cell)
			out["%s_%s" % [row, part]] = cell
		rows.add_child(line)
		if row == "top":
			var gap := Control.new()
			gap.mouse_filter = Control.MOUSE_FILTER_IGNORE
			gap.size_flags_vertical = Control.SIZE_EXPAND_FILL
			rows.add_child(gap)
	return out
