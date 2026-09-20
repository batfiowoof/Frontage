extends SceneTree
## Run one AI-vs-AI battle offline and narrate it. Not a gate -- a diagnostic, for
## when a battle refuses to end and you need to see what everyone is actually doing.
##
##   godot --headless --script res://tests/battle_probe.gd

const Rules := preload("res://sim/rules.gd")
const BattleState := preload("res://sim/battle_state.gd")
const Regiment := preload("res://sim/regiment.gd")
const Orders := preload("res://net/orders.gd")
const Ai := preload("res://sim/ai.gd")

const LINE := [&"spear", &"sword", &"pike", &"archer", &"cavalry"]

const NAMES := {
	Regiment.State.IDLE: "idle",
	Regiment.State.MOVING: "moving",
	Regiment.State.FIGHTING: "FIGHTING",
	Regiment.State.ROUTING: "routing",
	Regiment.State.DEAD: "dead",
}


func _initialize() -> void:
	var bs = BattleState.new()
	for i in LINE.size():
		var y := (float(i) - float(LINE.size() - 1) * 0.5) * Rules.DEPLOY_SPACING
		bs.add(1, LINE[i], Vector2(-Rules.DEPLOY_SEPARATION * 0.5, y), 0.0)
		bs.add(2, LINE[i], Vector2(Rules.DEPLOY_SEPARATION * 0.5, y), PI)

	var brains := {1: Ai.new(1), 2: Ai.new(2)}
	var seconds := 0.0
	while seconds < Rules.BATTLE_TIME_LIMIT:
		for t in Rules.TICK_HZ:                       # one second of simulation
			bs.step()
			seconds += Rules.TICK_DELTA
		for seat in [1, 2]:
			for bytes: PackedByteArray in brains[seat].battle_orders(bs):
				_apply(bs, seat, bytes)
		if int(seconds) % 10 == 0:
			_report(bs, seconds)
		if bs.is_over():
			print("OVER at %.0fs, winner %d" % [seconds, bs.winner()])
			quit(0)
			return
	_report(bs, seconds)
	print("NEVER ENDED in %.0fs" % seconds)
	quit(1)


## Stand in for the server's order pipeline, ownership check and all.
func _apply(bs, sender: int, bytes: PackedByteArray) -> void:
	var order := Orders.decode(bytes)
	if order.is_empty() or order["type"] != Orders.Type.BATTLE_MOVE:
		return
	for id in order["ids"]:
		var r = bs.get_regiment(id)
		if r != null and r.owner_id == sender:
			r.order_move(order["target"], order["facing"])


func _report(bs, seconds: float) -> void:
	var lines := PackedStringArray()
	for id in bs.sorted_ids():
		var r: Regiment = bs.regiments[id]
		lines.append("%d:%s %s %d/%d @(%.0f,%.0f)" % [
			r.owner_id, r.kind, NAMES[r.state], r.strength, r.max_strength, r.pos.x, r.pos.y])
	print("%5.0fs  %s" % [seconds, "  ".join(lines)])
