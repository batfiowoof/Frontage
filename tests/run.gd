extends SceneTree
## Headless test runner.  Register test files below; each is a RefCounted script
## whose `test_*(t)` methods receive a Check.  Exit code 0 means green.
##   godot --headless --script res://tests/run.gd

const TESTS := [
	"res://tests/test_smoke.gd",
	"res://tests/test_formation.gd",
	"res://tests/test_regiment.gd",
	"res://tests/test_battle_state.gd",
	"res://tests/test_snapshot.gd",
]


class Check extends RefCounted:
	var failures: PackedStringArray = []
	var count := 0
	var where := ""

	func ok(cond: bool, msg := "") -> void:
		count += 1
		if not cond:
			failures.append("%s: %s" % [where, msg])

	func eq(a, b, msg := "") -> void:
		count += 1
		if a != b:
			failures.append("%s: %s != %s  %s" % [where, a, b, msg])

	func near(a: float, b: float, eps := 0.0001, msg := "") -> void:
		count += 1
		if absf(a - b) > eps:
			failures.append("%s: %f !~ %f (eps %f)  %s" % [where, a, b, eps, msg])


func _initialize() -> void:
	var t := Check.new()
	for path in TESTS:
		var script := load(path) as GDScript
		if script == null or not script.can_instantiate():
			t.failures.append("%s: will not compile" % path)
			continue
		var obj: RefCounted = script.new()
		if obj == null:
			t.failures.append("%s: would not instantiate" % path)
			continue
		for m in script.get_script_method_list():
			var name: String = m.name
			if not name.begins_with("test_"):
				continue
			t.where = "%s::%s" % [path.get_file(), name]
			obj.call(name, t)

	if t.failures.is_empty():
		print("PASS  %d checks, %d files" % [t.count, TESTS.size()])
		quit(0)
	else:
		for f in t.failures:
			printerr("FAIL  " + f)
		printerr("FAILED  %d of %d checks" % [t.failures.size(), t.count])
		quit(1)
