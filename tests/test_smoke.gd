extends RefCounted


func test_harness_reports_pass(t) -> void:
	t.eq(2 + 2, 4)
	t.ok(true, "true should be true")
	t.near(0.1 + 0.2, 0.3)
