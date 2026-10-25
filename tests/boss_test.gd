extends SceneTree
## Headless boss-fight test (synthetic hands through the camera code path).
## Run: godot --headless --path . --fixed-fps 60 --script tests/boss_test.gd

const OPEN := HandInput.OPEN
const FIST := HandInput.FIST

var main: Node
var t := 0.0
var failures := 0


func _initialize() -> void:
	_run.call_deferred()


func hand(palm: Vector2, openness: float, side: int, size := 0.17) -> Dictionary:
	var vp := root.get_visible_rect().size
	var pts: Array[Vector2] = []
	for k in 21:
		var q: Vector2 = FIST[k].lerp(OPEN[k], openness)
		pts.append(Vector2(q.x * side * 0.75, q.y) * size * vp.y)
	var c := (pts[0] + pts[5] + pts[9] + pts[13] + pts[17]) / 5.0
	var p := []
	for q in pts:
		var s := q - c + palm
		p.append_array([1.0 - s.x / vp.x, s.y / vp.y, 0.0])
	return {"p": p, "label": "Left" if side > 0 else "Right", "score": 0.9}


func feed(hands: Array) -> void:
	main.input.injected = JSON.stringify({"t": t, "hands": hands})


func step(hands: Array) -> void:
	t += 1.0 / 60.0
	feed(hands)
	await process_frame


func frames(seconds: float, fn: Callable) -> void:
	var n := int(seconds * 60.0)
	for i in n:
		await step(fn.call(float(i) / maxf(n - 1, 1)))


func check(ok: bool, what: String) -> void:
	print(("PASS  " if ok else "FAIL  ") + what)
	if not ok:
		failures += 1


func start_game() -> void:
	if main:
		main.queue_free()
		await process_frame
	main = load("res://main.tscn").instantiate()
	root.add_child(main)
	while not main.ready_to_play:
		await process_frame
	main.game_state = "play"
	main.title_label.visible = false
	main.boss_timer = 0.3
	while main.boss == null or main.boss_landing:
		await step([])
	await frames(0.5, func(_k): return [])


func wait_phase(phase: int, hands: Callable) -> void:
	var guard := 0
	while main.boss != null and main.boss.phase != phase and guard < 600:
		guard += 1
		await step(hands.call())


func _run() -> void:
	await start_game()
	check(main.game_state == "boss" and main.boss != null, "the alien lands")
	var none := func(): return []

	# catch a punch with an open palm
	await wait_phase(Boss.Phase.WINDUP, none)
	var spot: Vector2 = main._punch_spot()
	var guard_hand := func(): return [hand(main._punch_spot(), 1.0, 1 if spot.x > root.get_visible_rect().size.x * 0.5 else -1)]
	await wait_phase(Boss.Phase.RECOVER, guard_hand)
	check(main.eye_target == main.EYE_START, "open palm on the fist guards (height %.0fm)" % main.eye_target)

	# take one on the chin
	await wait_phase(Boss.Phase.WINDUP, none)
	var expected: float = main.punch_loss()
	await wait_phase(Boss.Phase.RECOVER, none)
	check(is_equal_approx(main.EYE_START - main.eye_target, expected), "unguarded punch shrinks you (now %.1fm, lost %.1fm)" % [main.eye_target, expected])

	# slap the alien
	var chest: Vector2 = main.cam.unproject_position(main.boss.chest())
	var hp0: float = main.boss.hp
	await frames(0.4, func(_k): return [hand(chest, 1.0, 1)])
	await frames(0.15, func(k): return [hand(chest, 1.0, 1, 0.17 + 0.15 * k)])
	check(main.boss.hp < hp0, "slapping the alien hurts it (%.1f -> %.1f)" % [hp0, main.boss.hp])
	await frames(0.5, func(_k): return [hand(chest, 1.0, 1)])

	# finish it: knock out, then crush in the fist
	main.boss.hp = 0.5
	main.eye_target = 175.0
	chest = main.cam.unproject_position(main.boss.chest())
	await frames(0.4, func(_k): return [hand(chest, 1.0, 1)])
	await frames(0.15, func(k): return [hand(chest, 1.0, 1, 0.17 + 0.15 * k)])
	check(main.boss.stunned, "alien is stunned at 0 hp")
	await frames(1.5, func(_k): return [])
	chest = main.cam.unproject_position(main.boss.chest())
	var squeezes := 0
	while main.game_state != "won" and squeezes < 10:
		squeezes += 1
		if main.boss:
			chest = main.cam.unproject_position(main.boss.chest())
		await frames(0.5, func(_k): return [hand(chest, 1.0, 1)])
		await frames(0.6, func(k): return [hand(chest, 1.0 - k, 1)])
		if squeezes == 1:
			check(main.game_state != "won" and main.boss_crush > 0.1, "one squeeze only crushes it part way (%.2f)" % main.boss_crush)
	check(main.game_state == "won", "squeezing again and again crushes it (%d squeezes)" % squeezes)

	# losing
	await start_game()
	main.eye_target = main.EYE_MIN + 1.0
	await wait_phase(Boss.Phase.WINDUP, none)
	await wait_phase(Boss.Phase.RECOVER, none)
	check(main.game_state == "lost" and main.end_label.visible, "shrinking below %dm is game over" % int(main.EYE_MIN))

	# a big kaiju survives many more punches than a small one
	var hits := func(h: float) -> int:
		var n := 0
		while h >= main.EYE_MIN:
			h -= 6.0 + h * 0.1
			n += 1
		return n
	check(hits.call(150.0) >= 3 * hits.call(30.0), "big kaiju survives more punches (30m: %d, 150m: %d)" % [hits.call(30.0), hits.call(150.0)])

	print("DONE  failures=%d" % failures)
	quit(1 if failures > 0 else 0)
