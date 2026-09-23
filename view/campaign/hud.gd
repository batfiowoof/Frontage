extends Control
## Everything on the campaign screen that is not the map.
##
## Three places and no more: the empire along the top, whatever you have selected along
## the bottom, and End Turn in the corner. The bottom panel is EMPTY until something is
## selected -- the old HUD kept seven bars stacked in one corner whether or not any of
## them applied, and four of them overlapped.
##
## It changes nothing itself. Every button is a Net.order_* call, exactly as the bars
## were, and the rules for when a button is live are the sim's own `can_*` questions.

const Rules := preload("res://sim/rules.gd")
const Campaign := preload("res://sim/campaign_state.gd")
const Colors := preload("res://view/colors.gd")
const Art := preload("res://view/ui/art.gd")
const Widgets := preload("res://view/ui/widgets.gd")
const TechTree := preload("res://view/campaign/tech_tree.gd")
const UiTheme := preload("res://view/ui/theme.gd")

const STANCES := [
	["march", "Walk, and be seen."],
	["forced march", "Further each turn, but the men arrive spent."],
	["fortify", "Stand and dig in: harder to beat on this hex. Costs the turn."],
	["ambush", "The enemy is not told you are here. Costs the turn."],
	["besiege", "Sit on a town and starve it out. Costs the turn, and needs a town under you."],
]

var view                                   # campaign_view.gd, for the selection
var _turn: Label
var _stats := {}                           # key -> Label
var _players: HBoxContainer
var _toasts: VBoxContainer
var _treaty: PanelContainer
var _treaty_text: Label
var _offer_from := 0
var _context: PanelContainer
var _hover: PanelContainer
var _hover_text: Label
var _end_turn: Button
var _waiting: Label
var _trees: TechTree
var _diplomacy: PopupMenu
var _diplomacy_seat := 0


func _init(owner_view) -> void:
	view = owner_view
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	theme = UiTheme.shared()
	var f := Widgets.frame()
	add_child(f["root"])
	_build_top(f["top_left"], f["top_right"])
	_build_news(f["top_centre"])
	_build_hover(f["bottom_left"])
	_context = PanelContainer.new()
	_context.visible = false
	f["bottom_centre"].add_child(_context)
	_build_end_turn(f["bottom_right"])
	_trees = TechTree.new()
	add_child(_trees)
	_diplomacy = PopupMenu.new()
	_diplomacy.id_pressed.connect(_on_diplomacy)
	add_child(_diplomacy)

	Net.peace_offered.connect(_on_peace_offered)
	Net.order_rejected.connect(func(_peer: int, reason: String) -> void:
		Widgets.toast(_toasts, "Refused: " + reason, Colors.BAD))
	Net.news.connect(func(text: String) -> void: Widgets.toast(_toasts, text, Colors.WARN))


# --- building -------------------------------------------------------------

func _build_top(left: Control, right: Control) -> void:
	var bar := PanelContainer.new()
	left.add_child(bar)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 18)
	bar.add_child(row)
	_turn = Widgets.label("", "Heading")
	row.add_child(_turn)
	for spec in [["gold", &"pouch", "Gold, and what a turn brings in"],
			["food", &"resource_wheat", "Food, and the surplus after the army has eaten"],
			["research", &"book_open", "Research, spent by both trees (T)"],
			["upkeep", &"pouch_remove", "Food the army eats each turn"]]:
		var s: Array = Widgets.stat(spec[1], spec[2])
		row.add_child(s[0])
		_stats[spec[0]] = s[1]

	var side := PanelContainer.new()
	right.add_child(side)
	var tools := HBoxContainer.new()
	side.add_child(tools)
	_players = HBoxContainer.new()
	tools.add_child(_players)
	var research := Widgets.icon_button(&"book_open", "Research (T)", 34)
	research.pressed.connect(toggle_research)
	tools.add_child(research)
	if Net.is_server():
		var save := Widgets.icon_button(&"notepad_write", "Save the campaign", 34)
		save.pressed.connect(func() -> void:
			var path: String = Net.save_campaign()
			Widgets.toast(_toasts, "Saved" if not path.is_empty() else "Could not save", Colors.GOOD))
		tools.add_child(save)


func _build_news(centre: Control) -> void:
	var column := VBoxContainer.new()
	column.mouse_filter = Control.MOUSE_FILTER_IGNORE
	centre.add_child(column)
	# Somebody wants to talk. The one thing up here that arrives rather than being asked
	# for AND needs an answer, so it does not fade.
	_treaty = PanelContainer.new()
	_treaty.visible = false
	column.add_child(_treaty)
	var row := HBoxContainer.new()
	_treaty.add_child(row)
	row.add_child(Widgets.picture(Art.icon(&"flag_triangle"), 24, Colors.TEXT))
	_treaty_text = Widgets.label()
	row.add_child(_treaty_text)
	for answer in [true, false]:
		var b := Button.new()
		b.text = "Accept" if answer else "Refuse"
		b.pressed.connect(func() -> void:
			if _offer_from != 0:
				Net.order_answer(_offer_from, answer)
				_offer_from = 0
			_treaty.visible = false)
		row.add_child(b)
	_toasts = VBoxContainer.new()
	_toasts.mouse_filter = Control.MOUSE_FILTER_IGNORE
	column.add_child(_toasts)


func _build_hover(left: Control) -> void:
	_hover = PanelContainer.new()
	_hover.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_hover.visible = false
	left.add_child(_hover)
	_hover_text = Widgets.label()
	_hover.add_child(_hover_text)


func _build_end_turn(right: Control) -> void:
	var column := VBoxContainer.new()
	column.alignment = BoxContainer.ALIGNMENT_END
	right.add_child(column)
	_waiting = Widgets.label("", "Dim")
	_waiting.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	column.add_child(_waiting)
	_end_turn = Button.new()
	_end_turn.theme_type_variation = "BigButton"
	_end_turn.custom_minimum_size = Vector2(170, 52)
	_end_turn.icon = Art.icon(&"hourglass")
	_end_turn.pressed.connect(func() -> void:
		var cs = Net.campaign
		if cs != null:
			Net.order_ready(not bool(cs.ready.get(Net.my_id(), false))))
	column.add_child(_end_turn)


# --- what the view asks of it ---------------------------------------------

func toggle_research() -> void:
	_trees.visible = not _trees.visible
	refresh()


## Esc closes the topmost thing first. True when there was something to close.
func close_overlay() -> bool:
	if _trees.visible:
		_trees.visible = false
		return true
	return false


func hover(tile: int) -> void:
	var cs = Net.campaign
	_hover.visible = cs != null and tile >= 0
	if not _hover.visible:
		return
	var me: int = Net.my_id()
	var lines := PackedStringArray([Campaign.Terrain.keys()[cs.terrain[tile]].capitalize()])
	var s = cs.settlement_at(tile)
	if s != null:
		lines.append("%s — %s" % [s["name"], _who(int(s["owner"]))])
	elif cs.can_see(me, tile):
		var made: StringName = cs.structure_at(tile)
		if made != &"":
			lines.append(String(made).capitalize())
		var worked = cs.working_settlement(tile)
		if worked != null:
			lines.append("worked by %s" % worked["name"])
	else:
		lines.append("unexplored")
	_hover_text.text = "\n".join(lines)


func _who(owner: int) -> String:
	if owner == 0:
		return "free"
	return "yours" if owner == Net.my_id() else "player %d" % owner


func refresh() -> void:
	var cs = Net.campaign
	if cs == null:
		return
	var me: int = Net.my_id()
	var civ: StringName = cs.civ_of(me)
	_turn.text = "%sTurn %d / %d" % [Rules.CIVS[civ]["name"] + "  ·  " if civ != &"" else "",
		cs.turn, Rules.TURN_LIMIT]
	var income: Dictionary = cs.income_of(me)
	var upkeep: int = cs.upkeep_of(me)
	_stat("gold", int(cs.gold.get(me, 0)), int(income["gold"]))
	_stat("food", int(cs.food.get(me, 0)), int(income["food"]) - upkeep)
	_stat("research", int(cs.research.get(me, 0)), int(income["research"]))
	_stats["upkeep"].text = str(upkeep)

	_refresh_players(cs, me)
	_trees.refresh(cs, me)

	var ready := bool(cs.ready.get(me, false))
	_end_turn.text = "Waiting..." if ready else "End Turn"
	var holding := 0
	for id: int in Net.player_ids():
		if not bool(cs.ready.get(id, false)):
			holding += 1
	_waiting.text = "waiting for %d" % holding if ready and holding > 0 else ""
	_refresh_context(cs, me)


func _stat(key: String, have: int, delta: int) -> void:
	var l: Label = _stats[key]
	l.text = "%d  %s%d" % [have, "+" if delta >= 0 else "", delta]
	l.add_theme_color_override("font_color", Colors.TEXT if delta >= 0 else Colors.BAD)


## One chip a seat: their colour, whether they have ended the turn, and war or peace.
## Built from the seating every time, because an AI can join after the HUD goes up.
func _refresh_players(cs, me: int) -> void:
	for c in _players.get_children():
		c.queue_free()
	var seating: Array = Net.player_ids()
	for id: int in seating:
		var b := Button.new()
		b.flat = true
		b.text = "%s %s" % ["You" if id == me else ("AI" if id < 0 else "P%d" % seating.find(id)),
			"✓" if bool(cs.ready.get(id, false)) else "…"]
		b.add_theme_color_override("font_color", Colors.of_owner(id, seating))
		if id != me:
			b.icon = Art.icon(&"sword" if cs.at_war(me, id) else &"flag_triangle")
			b.tooltip_text = "%s — %d towns\n%s. Click for diplomacy." % [
				"player %d" % id, cs.settlements_of(id), "At war" if cs.at_war(me, id) else "At peace"]
			b.pressed.connect(func() -> void: _open_diplomacy(cs, me, id, b))
		else:
			b.tooltip_text = "you — %d towns" % cs.settlements_of(id)
		_players.add_child(b)


func _open_diplomacy(cs, me: int, seat: int, from: Control) -> void:
	_diplomacy_seat = seat
	_diplomacy.clear()
	_diplomacy.add_item("Offer peace" if cs.at_war(me, seat) else "Declare war", 0)
	_diplomacy.position = Vector2i(from.get_screen_position() + Vector2(0, from.size.y + 4))
	_diplomacy.popup()


func _on_diplomacy(_id: int) -> void:
	if _diplomacy_seat != 0:
		Net.order_propose(_diplomacy_seat)


func _on_peace_offered(from_seat: int, to_seat: int) -> void:
	if to_seat != Net.my_id():
		return                             # somebody else is being asked
	_offer_from = from_seat
	_treaty_text.text = "Player %d offers peace" % from_seat
	_treaty.visible = true


# --- the bottom panel -----------------------------------------------------

## Rebuilt from scratch on every refresh. The campaign is turn-based and this runs on a
## click or a snapshot, so a dozen nodes is nothing, and there is no stale state to get
## wrong between an army and a settlement.
func _refresh_context(cs, me: int) -> void:
	# Deferred: a card toggling is itself what triggers this rebuild, and freeing the
	# node whose signal is still being emitted crashes.
	for c in _context.get_children():
		_context.remove_child(c)
		c.queue_free()
	var army = cs.armies.get(view.selected_army) if view.selected_army >= 0 else null
	var tile: int = view.selected_tile
	var town = cs.settlement_at(tile) if tile >= 0 else null
	var parts := HBoxContainer.new()
	parts.add_theme_constant_override("separation", 14)
	if army != null:
		parts.add_child(_part(func(body: VBoxContainer) -> void: _army_panel(body, cs, me, army)))
	# A garrisoned town is shown BESIDE its army: the army is what a click on the hex
	# selects, and recruiting into a town you are standing in has to stay one click away.
	if town != null and (army == null or int(town["owner"]) == me):
		if army != null:
			parts.add_child(VSeparator.new())
		parts.add_child(_part(func(body: VBoxContainer) -> void: _settlement_panel(body, cs, me, town)))
	elif army == null and tile >= 0 and cs.can_see(me, tile):
		parts.add_child(_part(func(body: VBoxContainer) -> void: _tile_panel(body, cs, me, tile)))
	if parts.get_child_count() == 0:
		parts.free()
		_context.visible = false
		return
	_context.add_child(parts)
	_context.visible = true


func _part(fill: Callable) -> VBoxContainer:
	var body := VBoxContainer.new()
	fill.call(body)
	return body


func _title(body: VBoxContainer, text: String, sub: String, tint := Colors.GOLD) -> void:
	var t := Widgets.label(text, "Heading")
	t.add_theme_color_override("font_color", tint)
	body.add_child(t)
	if sub != "":
		body.add_child(Widgets.label(sub, "Dim"))


func _army_panel(body: VBoxContainer, cs, me: int, a: Dictionary) -> void:
	var id: int = a["id"]
	var stance := Campaign.stance_of(a)
	_title(body, "%s%s" % [Campaign.general_name(id), "  " + "★".repeat(Campaign.renown_of(a)) if Campaign.renown_of(a) > 0 else ""],
		"%d regiments  ·  %d men  ·  %d moves left  ·  %s" % [a["regiments"].size(),
		Campaign.army_men(a), a["move_left"], STANCES[stance][0]],
		Colors.of_owner(a["owner"], Net.player_ids()))

	# The regiments. Toggling a card picks it to be split off -- the old detach bar,
	# which was a row of buttons labelled with nothing but the kind.
	var cards := HBoxContainer.new()
	cards.add_theme_constant_override("separation", 4)
	body.add_child(cards)
	var regiments: Array = a["regiments"]
	for i in regiments.size():
		var r: Array = regiments[i]
		var kind: StringName = r[0]
		var full := float(Rules.KINDS[kind]["strength"])
		var xp := int(r[2]) if r.size() > 2 else 0
		var card := Widgets.unit_card()
		var ranks := int(3.0 * clampf(float(xp) / Rules.VETERAN_KILLS, 0.0, 1.0))
		Widgets.fill_card(card, kind, str(r[1]), float(r[1]) / full, -1.0, -1.0, "›".repeat(ranks))
		card.set_meta("bars", Vector3(float(r[1]) / full, clampf(float(xp) / Rules.VETERAN_KILLS, 0, 1), -1))
		card.tooltip_text = "%s — %d of %d men, %d killed\nClick to pick for a new army" % [
			String(kind).capitalize(), r[1], int(full), xp]
		card.button_pressed = Array(view.detaching).has(i)
		card.toggled.connect(func(on: bool) -> void:
			var picked := Array(view.detaching)
			if on and not picked.has(i):
				picked.append(i)
			elif not on:
				picked.erase(i)
			view.detaching = PackedInt32Array(picked)
			view.placing_detachment = false
			view.changed())
		cards.add_child(card)

	var row := HBoxContainer.new()
	body.add_child(row)
	# What it does between turns.
	for s in STANCES.size():
		var b := Widgets.icon_button(Art.STANCE_ICON[s], "%s\n%s" % [STANCES[s][0].capitalize(), STANCES[s][1]], 36)
		b.toggle_mode = true
		b.button_pressed = s == stance
		b.pressed.connect(func() -> void:
			if s != stance:
				Net.order_army_stance(id, s)
			else:
				b.set_pressed_no_signal(true))
		row.add_child(b)
	row.add_child(VSeparator.new())

	# Split. Everything picked goes, and something always stays.
	var split := Widgets.icon_button(&"arrow_cross_divided", "", 36)
	var picking: int = view.detaching.size()
	split.disabled = picking == 0 or picking >= regiments.size()
	split.tooltip_text = "Split off the picked regiments\nthen click an empty hex beside the army" \
		if not split.disabled else "Pick some regiments above to split them off\n(one has to stay behind)"
	split.pressed.connect(func() -> void:
		view.placing_detachment = true
		view.changed())
	row.add_child(split)

	# Found. can_found is asked rather than reimplemented: the button has to be live
	# exactly when the order would be accepted, and there is one answer to that.
	var found := Widgets.icon_button(&"hand_hexagon", "", 36)
	found.disabled = not cs.can_found(me, id)
	found.tooltip_text = "Found a town here" if not found.disabled \
		else "Found a town: needs a settler, clear ground and room from other towns"
	found.pressed.connect(func() -> void: Net.order_found(id))
	row.add_child(found)

	# Burn what is under your feet, if it is not yours.
	var underfoot: StringName = cs.structure_at(a["tile"])
	var worked = cs.working_settlement(a["tile"])
	var raze := Widgets.icon_button(&"fire", "", 36)
	raze.disabled = underfoot == &"" or a["move_left"] <= 0 or (worked != null and worked["owner"] == me)
	raze.tooltip_text = "Burn the %s (ends the turn, pays loot)" % underfoot if not raze.disabled \
		else "Burn: stand on an enemy structure with moves left"
	raze.pressed.connect(func() -> void: Net.order_raze(id))
	row.add_child(raze)

	var hint := "Click a hex to march  ·  shift-click one of yours to merge"
	if view.placing_detachment:
		hint = "Click an empty hex beside the army to send %d regiment(s) there" % picking
	body.add_child(Widgets.label(hint, "Dim"))


func _settlement_panel(body: VBoxContainer, cs, me: int, s: Dictionary) -> void:
	var owner := int(s["owner"])
	var income := Campaign.settlement_income(s)
	_title(body, s["name"], "%s  ·  population %d  ·  +%d gold  +%d food  +%d research" % [
		_who(owner), Campaign.pop_of(s), income["gold"], income["food"], income["research"]],
		Colors.of_owner(owner, Net.player_ids()) if owner != 0 else Colors.GOLD)

	# How much they mind you, as a bar that fills toward revolt.
	var anger := Campaign.unrest_of(s)
	if anger > 0:
		var bar := ProgressBar.new()
		bar.max_value = Rules.UNREST_REVOLT
		bar.value = anger
		bar.show_percentage = false
		bar.custom_minimum_size = Vector2(0, 8)
		bar.add_theme_stylebox_override("fill", UiTheme.box(Colors.BAD, Color(0, 0, 0, 0), 0, 1))
		bar.tooltip_text = "Unrest %d of %d — at %d the town throws you out" % [anger, Rules.UNREST_REVOLT, Rules.UNREST_REVOLT]
		body.add_child(bar)

	if owner != me:
		return
	var purse := int(cs.gold.get(me, 0))
	var available: Array = cs.recruitable_at(s["tile"])
	# Recruit and build side by side rather than stacked, so the panel stays short enough
	# not to sit on top of the army it was opened for.
	var both := HBoxContainer.new()
	both.add_theme_constant_override("separation", 14)
	body.add_child(both)
	var raising := VBoxContainer.new()
	both.add_child(raising)
	raising.add_child(Widgets.label("Recruit", "Dim"))
	var recruits := HBoxContainer.new()
	recruits.add_theme_constant_override("separation", 3)
	raising.add_child(recruits)
	for kind: StringName in cs.roster_of(me):
		var spec: Dictionary = Rules.KINDS[kind]
		var b := _priced(Art.kind_icon(kind), int(spec["cost"]))
		b.disabled = not available.has(kind) or purse < int(spec["cost"])
		b.tooltip_text = "%s — %d men, %d gold, %d upkeep" % [String(kind).capitalize(),
			spec["strength"], spec["cost"], spec["upkeep"]]
		var tech: StringName = spec.get("tech", &"")
		if not available.has(kind) and tech != &"" and not cs.techs_of(me).has(tech):
			b.tooltip_text += "\nneeds %s researched" % String(tech).capitalize()
		elif not available.has(kind):
			b.tooltip_text += "\nneeds a %s on the land nearby" % spec["requires"]
		b.pressed.connect(func() -> void: Net.order_recruit(s["tile"], kind))
		recruits.add_child(b)
	var building := VBoxContainer.new()
	both.add_child(building)
	_build_row(building, cs, me, s["tile"])


func _tile_panel(body: VBoxContainer, cs, me: int, tile: int) -> void:
	var made: StringName = cs.structure_at(tile)
	_title(body, Campaign.Terrain.keys()[cs.terrain[tile]].capitalize(),
		String(made).capitalize() if made != &"" else "open ground")
	_build_row(body, cs, me, tile)


## What can go on this hex. Only what `placeable_at` allows is offered at all: nine
## greyed-out buttons on every hex is exactly the clutter this panel exists to remove.
func _build_row(body: VBoxContainer, cs, me: int, tile: int) -> void:
	var options: Array = cs.placeable_at(me, tile)
	if options.is_empty():
		return
	body.add_child(Widgets.label("Build", "Dim"))
	var row := HBoxContainer.new()
	body.add_child(row)
	var purse := int(cs.gold.get(me, 0))
	for name: StringName in options:
		var cost: int = cs.cost_of(me, name)
		var b := _priced(Art.structure_icon(name), cost)
		b.disabled = purse < cost
		var spec: Dictionary = Rules.STRUCTURES[name]
		var gives := PackedStringArray()
		for k in ["gold", "food", "research"]:
			if int(spec[k]) > 0:
				gives.append("+%d %s" % [spec[k], k])
		if not spec["unlocks"].is_empty():
			gives.append("raises %s" % ", ".join(PackedStringArray(spec["unlocks"])))
		if float(spec["defense"]) > 0.0:
			gives.append("defence %d%%" % int(float(spec["defense"]) * 100.0))
		b.tooltip_text = "%s — %d gold\n%s" % [String(name).capitalize(), cost, ", ".join(gives)]
		b.pressed.connect(func() -> void: Net.order_build(tile, name))
		row.add_child(b)


## An icon over a price, for anything that costs gold.
func _priced(icon: Texture2D, cost: int) -> Button:
	var b := Button.new()
	b.icon = icon
	b.expand_icon = true
	b.add_theme_constant_override("icon_max_width", 26)
	b.icon_alignment = HORIZONTAL_ALIGNMENT_CENTER
	b.vertical_icon_alignment = VERTICAL_ALIGNMENT_TOP
	b.text = str(cost)
	b.custom_minimum_size = Vector2(46, 54)
	return b
