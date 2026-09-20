extends Node
## Root node. Owns which screen you are looking at, and nothing else.

const CampaignView := preload("res://view/campaign/campaign_view.gd")
const BattleView := preload("res://view/battle/battle_view.gd")

var _screen: Node = null
var _lobby: CanvasLayer
var _status: Label
var _roster: Label
var _address: LineEdit
var _start: Button
var _add_ai: Button
var _autostart := false
var _demo_battle := false


func _ready() -> void:
	Net.players_changed.connect(_refresh_lobby)
	Net.campaign_updated.connect(_on_campaign)
	Net.battle_updated.connect(_on_battle)
	Net.connection_failed.connect(func() -> void: _say("could not reach that host"))
	Net.server_left.connect(_on_server_left)
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
		elif args[i] == "--ai" and i + 1 < args.size():
			for n in int(args[i + 1]):
				Net.add_ai()
			_autostart = true


## Deal the campaign as soon as somebody else turns up.
func _check_autostart() -> void:
	if not (_autostart and Net.is_server() and Net.players.size() >= 2):
		return
	if _demo_battle and Net.battle == null and Net.campaign == null:
		Net.start_campaign()
		Net.start_demo_battle()
	elif Net.campaign == null:
		Net.start_campaign()


func _build_lobby() -> void:
	_lobby = CanvasLayer.new()
	add_child(_lobby)

	var centre := CenterContainer.new()
	centre.set_anchors_preset(Control.PRESET_FULL_RECT)
	_lobby.add_child(centre)

	var box := VBoxContainer.new()
	box.custom_minimum_size = Vector2(340, 0)
	box.add_theme_constant_override("separation", 8)
	centre.add_child(box)

	var title := Label.new()
	title.text = "Campaign & Battle"
	title.add_theme_font_size_override("font_size", 28)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(title)

	var host := Button.new()
	host.text = "Host"
	host.pressed.connect(_on_host)
	box.add_child(host)

	_address = LineEdit.new()
	_address.text = "127.0.0.1"
	_address.placeholder_text = "host address"
	box.add_child(_address)

	var join := Button.new()
	join.text = "Join"
	join.pressed.connect(_on_join)
	box.add_child(join)

	_add_ai = Button.new()
	_add_ai.text = "Add AI opponent"
	_add_ai.visible = false
	_add_ai.pressed.connect(func() -> void:
		Net.add_ai()
		_refresh_lobby())
	box.add_child(_add_ai)

	_start = Button.new()
	_start.text = "Start Campaign"
	_start.visible = false
	_start.pressed.connect(func() -> void: Net.start_campaign())
	box.add_child(_start)

	_status = Label.new()
	_status.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(_status)

	_roster = Label.new()
	_roster.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
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
	var names := PackedStringArray()
	for id: int in Net.player_ids():
		names.append("player %d%s" % [id, "  (you)" if id == Net.my_id() else ""])
	_roster.text = "\n".join(names)


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


func _on_server_left() -> void:
	if _screen != null:
		_screen.queue_free()
		_screen = null
	_lobby.visible = true
	_say("the host has gone")
	_refresh_lobby()
