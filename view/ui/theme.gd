extends RefCounted
## The look of every Control in the game, built once and hung on the root window so
## nothing has to ask for it. Code rather than a .tres, like the rest of view/: it is
## reviewable, and the palette it reads is Colors, not a second copy of it.

const Colors := preload("res://view/colors.gd")
const Art := preload("res://view/ui/art.gd")

const BODY_SIZE := 16
const HEADING_SIZE := 20


static var _shared: Theme


## The one Theme everybody uses. A theme on the root window reaches popups and tooltips
## but stops at a CanvasLayer, so each HUD root sets this on itself as well.
static func shared() -> Theme:
	if _shared == null:
		_shared = build()
	return _shared


static func build() -> Theme:
	var t := Theme.new()
	t.default_font = Art.font()
	t.default_font_size = BODY_SIZE

	for type in ["Label", "Button", "LineEdit", "TooltipLabel", "CheckBox"]:
		t.set_color("font_color", type, Colors.TEXT)
	t.set_color("font_shadow_color", "Label", Color(0, 0, 0, 0.6))
	t.set_constant("shadow_offset_x", "Label", 1)
	t.set_constant("shadow_offset_y", "Label", 1)

	# Headings are a Label type variation, so a caller says what a line IS and not what
	# size and face it wants.
	t.add_type("Heading")
	t.set_type_variation("Heading", "Label")
	t.set_font("font", "Heading", Art.font(true))
	t.set_font_size("font_size", "Heading", HEADING_SIZE)
	t.set_color("font_color", "Heading", Colors.GOLD)
	t.add_type("Dim")
	t.set_type_variation("Dim", "Label")
	t.set_color("font_color", "Dim", Colors.TEXT_DIM)
	t.set_font_size("font_size", "Dim", 14)

	t.set_stylebox("panel", "PanelContainer", panel())
	t.set_stylebox("panel", "PopupPanel", panel())
	t.set_stylebox("panel", "TooltipPanel", panel(Colors.PANEL_DEEP, Colors.TRIM_BRIGHT, 6))
	t.set_font_size("font_size", "TooltipLabel", 15)

	t.set_stylebox("normal", "Button", box(Color("2a2118"), Colors.TRIM))
	t.set_stylebox("hover", "Button", box(Color("3a2d1f"), Colors.TRIM_BRIGHT))
	t.set_stylebox("pressed", "Button", box(Color("4a3822"), Colors.GOLD))
	t.set_stylebox("hover_pressed", "Button", box(Color("4a3822"), Colors.GOLD))
	t.set_stylebox("disabled", "Button", box(Color("1c1712"), Color("4a3d2c")))
	t.set_stylebox("focus", "Button", StyleBoxEmpty.new())
	t.set_color("font_hover_color", "Button", Colors.GOLD)
	t.set_color("font_pressed_color", "Button", Colors.GOLD)
	t.set_color("font_hover_pressed_color", "Button", Colors.GOLD)
	t.set_color("font_disabled_color", "Button", Color("6e6352"))
	t.set_color("icon_normal_color", "Button", Colors.TEXT)
	t.set_color("icon_hover_color", "Button", Colors.GOLD)
	t.set_color("icon_pressed_color", "Button", Colors.GOLD)
	t.set_color("icon_hover_pressed_color", "Button", Colors.GOLD)
	t.set_color("icon_disabled_color", "Button", Color("5a5044"))
	t.set_constant("h_separation", "Button", 6)
	t.set_constant("icon_max_width", "Button", 22)

	# The one button that ends your turn or starts a fight: bigger, and gold-edged.
	t.add_type("BigButton")
	t.set_type_variation("BigButton", "Button")
	t.set_font("font", "BigButton", Art.font(true))
	t.set_font_size("font_size", "BigButton", 18)
	t.set_stylebox("normal", "BigButton", box(Color("3b2a16"), Colors.GOLD, 2, 10))
	t.set_stylebox("hover", "BigButton", box(Color("5a3f1e"), Color("ffe3a0"), 2, 10))
	t.set_stylebox("pressed", "BigButton", box(Color("6a4a22"), Color("ffe3a0"), 2, 10))
	t.set_stylebox("disabled", "BigButton", box(Color("241c14"), Color("5a4a34"), 2, 10))

	t.set_stylebox("normal", "LineEdit", box(Color("16120e"), Colors.TRIM))
	t.set_stylebox("focus", "LineEdit", box(Color("16120e"), Colors.GOLD))

	t.set_stylebox("background", "ProgressBar", box(Color(0, 0, 0, 0.55), Color(0, 0, 0, 0), 0, 1))
	t.set_stylebox("fill", "ProgressBar", box(Colors.GOOD, Color(0, 0, 0, 0), 0, 1))
	t.set_constant("separation", "HBoxContainer", 6)
	t.set_constant("separation", "VBoxContainer", 6)
	return t


## A panel: dark, translucent, a bronze hairline and a soft drop shadow.
static func panel(bg := Colors.PANEL, edge := Colors.TRIM, pad := 10) -> StyleBoxFlat:
	var s := box(bg, edge, 1, pad)
	s.shadow_color = Colors.SHADOW
	s.shadow_size = 6
	s.shadow_offset = Vector2(0, 2)
	return s


static func box(bg: Color, edge: Color, border := 1, pad := 6) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = bg
	s.border_color = edge
	s.set_border_width_all(border)
	s.set_corner_radius_all(4)
	s.content_margin_left = pad + 2
	s.content_margin_right = pad + 2
	s.content_margin_top = pad
	s.content_margin_bottom = pad
	s.anti_aliasing = true
	return s
