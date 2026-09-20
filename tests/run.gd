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
	"res://tests/test_campaign.gd",
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


const SOURCE_DIRS := ["res://sim", "res://net", "res://view", "res://tests"]


func _gd_files(dir: String) -> PackedStringArray:
	var out := PackedStringArray()
	var d := DirAccess.open(dir)
	if d == null:
		return out
	for f in d.get_files():
		if f.ends_with(".gd"):
			out.append(dir.path_join(f))
	for sub in d.get_directories():
		out.append_array(_gd_files(dir.path_join(sub)))
	return out


## A test file can compile perfectly while something it preloads does not, which
## reads as a green run with a screen full of red. Check the whole tree.
func _check_everything_compiles(t: Check) -> void:
	t.where = "compile"
	for dir in SOURCE_DIRS:
		for path in _gd_files(dir):
			var script := load(path) as GDScript
			t.ok(script != null and script.can_instantiate(), "%s does not compile" % path)


func _initialize() -> void:
	var t := Check.new()
	_check_everything_compiles(t)
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
