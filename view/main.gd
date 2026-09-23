extends Node
## Root node. Owns which screen you are looking at, and nothing else.

const CampaignView := preload("res://view/campaign/campaign_view.gd")
const BattleView := preload("res://view/battle/battle_view.gd")
const Replay := preload("res://net/replay.gd")
const Save := preload("res://net/save.gd")
const Colors := preload("res://view/colors.gd")
const UiTheme := preload("res://view/ui/theme.gd")
const Widgets := preload("res://view/ui/widgets.gd")

var _screen: Node = null
var _lobby: CanvasLayer
var _status: Label
var _roster: VBoxContainer
var _address: LineEdit
var _start: Button
var _add_ai: Button
var _load: Button
var _autostart := false
var _demo_battle := false
var _replay_path := ""
var _load_path := ""
var _over: CanvasLayer = null           # the end-of-campaign panel, once there is one


func _ready() -> void:
	# On the root window for tooltips and popups, which are windows of their own. The
	# screens hang it on their own roots too: it does not reach through a CanvasLayer.
	get_tree().root.theme = UiTheme.shared()
	RenderingServer.set_default_clear_color(Color("0d0b09"))
	Net.players_changed.connect(_refresh_lobby)
	Net.campaign_updated.connect(_on_campaign)
	Net.battle_updated.connect(_on_battle)
	Net.connection_failed.connect(func() -> void: _say("could not reach that host"))
	Net.server_left.connect(_on_server_left)
	Net.campaign_over.connect(_on_campaign_over)
	_build_lobby()

	# --host / --join <ip> / --autostart so two instances can be launched without
	# clicking through the lobby every time.
	var args := OS.get_cmdline_user_args()
	for i in args.size():
		if args[i] == "--host":
			_on_host()
		elif args[i] == "--join" and i + 1 < args.size():
			_address.text = args[i + 1]
			_on_join()
		elif args[i] == "--autostart":
			_autostart = true
		elif args[i] == "--demo-battle":
			_autostart = true
			_demo_battle = true
		elif args[i] == "--replay" and i + 1 < args.size():
			_replay_path = args[i + 1]
			_autostart = true
			_on_host()
		elif args[i] == "--load" and i + 1 < args.size():
			_load_path = args[i + 1]
			_autostart = true
		elif args[i] == "--shot" and i + 2 < args.size():
			# --shot <path> <seconds>: save what is on screen and quit. How a change to
			# the look is checked without somebody sitting at the window.
			var path := args[i + 1]
			get_tree().create_timer(float(args[i + 2])).timeout.connect(func() -> void:
				get_viewport().get_texture().get_image().save_png(path)
				get_tree().quit())
		elif args[i] == "--ai" and i + 1 < args.size():
			# BEFORE add_ai(), not after. add_ai() emits players_changed, which runs
			# _refresh_lobby -> _check_autostart, and that bails while _autostart is still
			# false. In solo no peer ever connects to fire the signal a second time, so
			# the flag was set just too late to ever be read and the campaign sat waiting
			# behind a button. --replay has always got this right, two arms above.
			_autostart = true
			for n in int(args[i + 1]):
				Net.add_ai()


## Deal the campaign as soon as somebody else turns up.
func _check_autostart() -> void:
	if not _replay_path.is_empty() and Net.is_server() and Net.battle == null:
		var r = Replay.load_from(_replay_path)
		_replay_path = ""
		if r == null:
			_say("that replay will not load")
		else:
			Net.play_replay(r)
		return
	if not (_autostart and Net.is_server() and Net.players.size() >= 2):
		return
	if not _load_path.is_empty() and Net.campaign == null:
		var wanted := _load_path
		_load_path = ""
		if not Net.load_campaign(wanted):
			_say("that save will not load")
		return
	if _demo_battle and Net.battle == null and Net.campaign == null:
		Net.start_campaign()
		Net.start_demo_battle()
	elif Net.campaign == null:
		Net.start_campaign()


func _build_lobby() -> void:
	_lobby = CanvasLayer.new()
	add_child(_lobby)
	var root := Control.new()
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.theme = UiTheme.shared()
	_lobby.add_child(root)

	# A dark vignette to sit the panel on, rather than the engine's grey.
	var back := TextureRect.new()
	back.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	back.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	var glow := GradientTexture2D.new()
	glow.fill = GradientTexture2D.FILL_RADIAL
	glow.fill_from = Vector2(0.5, 0.45)
	glow.fill_to = Vector2(1.1, 1.1)
	glow.gradient = Gradient.new()
	glow.gradient.set_color(0, Color("2e2418"))
	glow.gradient.set_color(1, Color("0a0806"))
	back.texture = glow
	root.add_child(back)

	var centre := CenterContainer.new()
	centre.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.add_child(centre)

	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", UiTheme.panel(Colors.PANEL, Colors.TRIM_BRIGHT, 24))
	centre.add_child(panel)
	var box := VBoxContainer.new()
	box.custom_minimum_size = Vector2(360, 0)
	box.add_theme_constant_override("separation", 10)
	panel.add_child(box)

	var title := Widgets.label("Campaign & Battle", "Heading")
	title.add_theme_font_size_override("font_size", 34)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(title)
	var sub := Widgets.label("host a table, or join one", "Dim")
	sub.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(sub)
	box.add_child(HSeparator.new())

	var host := Button.new()
	host.text = "Host"
	host.theme_type_variation = "BigButton"
	host.pressed.connect(_on_host)
	box.add_child(host)

	var joining := HBoxContainer.new()
	box.add_child(joining)
	_address = LineEdit.new()
	_address.text = "127.0.0.1"
	_address.placeholder_text = "host address"
	_address.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	joining.add_child(_address)
	var join := Button.new()
	join.text = "Join"
	join.custom_minimum_size = Vector2(90, 0)
	join.pressed.connect(_on_join)
	joining.add_child(join)

	_add_ai = Button.new()
	_add_ai.text = "Add AI opponent"
	_add_ai.visible = false
	_add_ai.pressed.connect(func() -> void:
		Net.add_ai()
		_refresh_lobby())
	box.add_child(_add_ai)

	_load = Button.new()
	_load.text = "Load last campaign"
	_load.visible = false
	_load.pressed.connect(func() -> void:
		var newest := Save.newest()
		if newest.is_empty():
			_say("no saved campaigns")
		elif not Net.load_campaign(newest):
			_say("that save does not fit this table")
		)
	box.add_child(_load)

	_start = Button.new()
	_start.text = "Start Campaign"
	_start.theme_type_variation = "BigButton"
	_start.visible = false
	_start.pressed.connect(func() -> void: Net.start_campaign())
	box.add_child(_start)

	_status = Widgets.label("", "Dim")
	_status.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(_status)

	_roster = VBoxContainer.new()
	box.add_child(_roster)


func _on_host() -> void:
	var err := Net.host()
	_say("listening on port %d" % Net.PORT if err == OK else "could not listen: %d" % err)
	_refresh_lobby()


func _on_join() -> void:
	var err := Net.join(_address.text.strip_edges())
	_say("connecting..." if err == OK else "could not connect: %d" % err)


func _say(text: String) -> void:
	_status.text = text


func _refresh_lobby() -> void:
	_check_autostart()
	# Solo start is allowed on purpose: it is the fastest way to check a change to
	# the map or the economy without launching a second process.
	_start.visible = Net.is_server() and Net.campaign == null
	_add_ai.visible = _start.visible
	_load.visible = _start.visible and not Save.newest().is_empty()
	for c in _roster.get_children():
		c.queue_free()
	var seating: Array = Net.player_ids()
	for id: int in seating:
		var row := HBoxContainer.new()
		var chip := ColorRect.new()
		chip.color = Colors.of_owner(id, seating)
		chip.custom_minimum_size = Vector2(14, 14)
		chip.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		row.add_child(chip)
		row.add_child(Widgets.label("%s%s" % ["AI %d" % -id if id < 0 else "Player %d" % id,
			"  (you)" if id == Net.my_id() else ""]))
		_roster.add_child(row)


## A battle takes over the screen while it lasts; the campaign comes back after.
## Players not involved watch rather than sitting on a frozen map wondering.
func _on_campaign(_cs) -> void:
	if Net.battle == null:
		_show(CampaignView, "CampaignView")


func _on_battle(bs) -> void:
	if bs == null:
		_show(CampaignView, "CampaignView")
	else:
		_show(BattleView, "BattleView")


func _show(script: GDScript, name: String) -> void:
	if _screen != null and _screen.name == name:
		return
	if _screen != null:
		_screen.queue_free()
	_lobby.visible = false
	_screen = script.new()
	_screen.name = name
	add_child(_screen)


## The campaign is decided. It goes here rather than in campaign_view because this node
## already owns which screen you are looking at, and the panel has to outlive the screen
## that was showing when it landed.
##
## The map stays underneath: knowing HOW it ended is most of what you want at the moment
## it does, and a full-screen curtain takes that away.
func _on_campaign_over(winner_id: int) -> void:
	if _over != null:
		return
	_over = CanvasLayer.new()
	add_child(_over)
	var colour := Colors.of_owner(winner_id, Net.player_ids())
	var top := CenterContainer.new()
	top.theme = UiTheme.shared()
	top.set_anchors_and_offsets_preset(Control.PRESET_TOP_WIDE)
	top.offset_top = 70
	_over.add_child(top)
	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", UiTheme.panel(Colors.PANEL_DEEP, colour, 20))
	top.add_child(panel)
	var box := VBoxContainer.new()
	box.custom_minimum_size = Vector2(380, 0)
	panel.add_child(box)
	var head := Widgets.label("Victory" if winner_id == Net.my_id() else "Defeat", "Heading")
	head.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	head.add_theme_font_size_override("font_size", 36)
	head.add_theme_color_override("font_color", colour)
	box.add_child(head)
	var sub := Widgets.label("%s � turn %d" % [
		"you have won" if winner_id == Net.my_id() else "player %d has won" % winner_id,
		Net.campaign.turn if Net.campaign != null else 0], "Dim")
	sub.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(sub)


func _on_server_left() -> void:
	if _screen != null:
		_screen.queue_free()
		_screen = null
	_lobby.visible = true
	_say("the host has gone")
	_refresh_lobby()


## F12 saves what is on screen to user://shots/. How a change to the look gets checked,
## and cheap enough to leave in.
func _input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_F12:
		DirAccess.make_dir_recursive_absolute("user://shots")
		var path := "user://shots/%s.png" % Time.get_datetime_string_from_system().replace(":", "-")
		get_viewport().get_texture().get_image().save_png(path)
		print("saved ", ProjectSettings.globalize_path(path))
