extends SceneTree
## Headless gameplay test: feeds synthetic hand landmarks through the camera code path.
## Run: godot --headless --path . --fixed-fps 60 --script tests/play_test.gd

const OPEN := HandInput.OPEN
const FIST := HandInput.FIST

var main: Node
var t := 0.0
var failures := 0


func _initialize() -> void:
	main = load("res://main.tscn").instantiate()
	root.add_child(main)
	_run.call_deferred()


## One synthetic hand whose palm sits at `palm` (screen pixels).
func hand(palm: Vector2, openness: float, side: int, size := 0.17, like := false, pinch := 0.0) -> Dictionary:
	var vp := root.get_visible_rect().size
	var pts: Array[Vector2] = []
	for k in 21:
		var q: Vector2 = HandInput.LIKE[k] if like else FIST[k].lerp(OPEN[k], openness)
		if pinch > 0.0 and (k == 4 or k == 8):
			q = q.lerp((OPEN[4] + OPEN[8]) * 0.5, pinch)
		pts.append(Vector2(q.x * side * 0.75, q.y) * size * vp.y)
	var c := (pts[0] + pts[5] + pts[9] + pts[13] + pts[17]) / 5.0
	var p := []
	for q in pts:
		var s := q - c + palm
		p.append_array([1.0 - s.x / vp.x, s.y / vp.y, 0.0])
	return {"p": p, "label": "Left" if side > 0 else "Right", "score": 0.9}


func feed(hands: Array) -> void:
	main.input.injected = JSON.stringify({"t": t, "hands": hands})


func frames(seconds: float, fn: Callable) -> void:
	var n := int(seconds * 60.0)
	for i in n:
		t += 1.0 / 60.0
		feed(fn.call(float(i) / maxf(n - 1, 1)))
		await process_frame


func check(ok: bool, what: String) -> void:
	print(("PASS  " if ok else "FAIL  ") + what)
	if not ok:
		failures += 1


## Waits until growth and camera shake have settled so screen positions stay valid.
func settle() -> void:
	while absf(main.eye - main.eye_target) > 0.02 or main.shake > 0.0:
		t += 1.0 / 60.0
		feed([])
		await process_frame


## A building we can see and pick at its middle; crushable or not.
func find_target(crushable: bool) -> Dictionary:
	var vp := root.get_visible_rect().size
	var best := {}
	for id in main.city.buildings.size():
		var b: Dictionary = main.city.buildings[id]
		if not b["alive"] or main._crushable(id) != crushable:
			continue
		var w := Vector3(b["center"].x, b["h"] * 0.5, b["center"].y)
		if main.cam.is_position_behind(w):
			continue
		var s: Vector2 = main.cam.unproject_position(w)
		if s.x < vp.x * 0.25 or s.x > vp.x * 0.75 or s.y < vp.y * 0.25 or s.y > vp.y * 0.8:
			continue
		var hit: Dictionary = main._ray(s)
		if hit.get("id", -1) == id:
			return {"id": id, "pos": s}
	return best


func _run() -> void:
	while not main.ready_to_play:
		feed([])
		await process_frame
	var idle := func(_k): return []
	await frames(0.5, idle)

	# --- fast fist = サクッ
	var tg := find_target(true)
	check(not tg.is_empty(), "found a crushable target")
	var pos: Vector2 = tg.get("pos", Vector2.ZERO)
	var before: int = main.score_count
	await frames(0.8, func(_k): return [hand(pos, 1.0, 1)])
	check(main.city._hover.has(main.ctl[1]["target"]) and main.ctl[1]["target"] >= 0,
			"aimed building is highlighted (target %d)" % main.ctl[1]["target"])
	await frames(0.1, func(k): return [hand(pos, 1.0 - k, 1)])
	await frames(0.4, func(_k): return [hand(pos, 0.0, 1)])
	check(main.score_count == before + 1 and main.banner.text.begins_with("サクッ"),
			"fast fist crushes with サクッ (banner: %s)" % main.banner.text.split("\n")[0])
	await frames(0.6, func(_k): return [hand(pos, 1.0, 1)])

	# --- slow fist = グジュウ, and the building deforms on the way
	await settle()
	tg = find_target(true)
	pos = tg.get("pos", Vector2.ZERO)
	before = main.score_count
	await frames(0.8, func(_k): return [hand(pos, 1.0, 1)])
	await frames(0.8, func(k): return [hand(pos, 1.0 - 0.6 * k, 1)])
	check(main.active_id >= 0 and main.closure > 0.3 and main.closure < 0.97,
			"half-closed fist half-crushes (closure %.2f)" % main.closure)
	await frames(1.0, func(k): return [hand(pos, 0.4 - 0.4 * k, 1)])
	await frames(0.3, func(_k): return [hand(pos, 0.0, 1)])
	check(main.score_count == before + 1 and main.banner.text.begins_with("グジュウ"),
			"slow fist crushes with グジュウ (banner: %s)" % main.banner.text.split("\n")[0])
	await frames(0.6, func(_k): return [hand(pos, 1.0, 1)])

	# --- slap towards the screen
	await settle()
	tg = find_target(true)
	pos = tg.get("pos", Vector2.ZERO)
	before = main.score_count
	await frames(0.5, func(_k): return [hand(pos, 1.0, 1)])
	await frames(0.15, func(k): return [hand(pos, 1.0, 1, 0.17 + 0.15 * k)])
	await frames(0.3, func(_k): return [hand(pos, 1.0, 1, 0.32)])
	check(main.score_count >= before + 1 and (main.banner.text.begins_with("バチーン") or main.banner.text.begins_with("ドドド")),
			"slap crushes (banner: %s)" % main.banner.text.split("\n")[0])
	await frames(0.6, func(_k): return [hand(pos, 1.0, 1)])

	# --- two-finger pinch
	await settle()
	tg = find_target(true)
	pos = tg.get("pos", Vector2.ZERO)
	before = main.score_count
	await frames(0.8, func(_k): return [hand(pos, 1.0, 1)])
	await frames(0.6, func(k): return [hand(pos, 1.0, 1, 0.17, false, k)])
	await frames(0.3, func(_k): return [hand(pos, 1.0, 1, 0.17, false, 1.0)])
	check(main.score_count == before + 1 and main.banner.text.begins_with("プチッ"),
			"pinching with two fingers crushes with プチッ (banner: %s)" % main.banner.text.split("\n")[0])
	await frames(0.5, func(_k): return [hand(pos, 1.0, 1)])

	# --- once big, one slap flattens a whole patch of small buildings
	main.eye_target = 120.0
	await settle()
	var vp0 := root.get_visible_rect().size
	before = main.score_count
	var spot := Vector2(vp0.x * 0.5, vp0.y * 0.6)
	await frames(0.5, func(_k): return [hand(spot, 1.0, 1)])
	await frames(0.15, func(k): return [hand(spot, 1.0, 1, 0.17 + 0.15 * k)])
	await frames(0.3, func(_k): return [hand(spot, 1.0, 1, 0.32)])
	check(main.score_count >= before + 3 and main.banner.text.begins_with("ドドド"),
			"big slap flattens many buildings at once (%d, banner: %s)" % [main.score_count - before, main.banner.text.split("\n")[0]])
	await frames(0.6, idle)

	await settle()
	var zara := false
	for site in main.bead_sites:
		var w := Vector3(site["center"].x, 1.0, site["center"].y)
		if main.cam.is_position_behind(w):
			continue
		var sp: Vector2 = main.cam.unproject_position(w)
		if not root.get_visible_rect().has_point(sp) or not main._ray(sp).is_empty():
			continue  # off screen or hidden behind a building
		if site["center"].distance_to(Vector2(main.player.position.x, main.player.position.z)) > main.reach():
			continue
		await frames(0.8, func(k): return [hand(sp + Vector2(sin(k * TAU * 3.0) * 60.0, 0.0), 1.0, 1)])
		for pop in main.popups:
			zara = zara or pop["text"] == "ざらざら！"
		if zara:
			break
	check(zara, "stroking a bead pile goes ざらざら")

	check(main.eye_target > main.EYE_START, "kaiju grows (eye target %.1fm)" % main.eye_target)

	# --- too tall to crush yet
	await settle()
	tg = find_target(false)
	if tg.is_empty():
		print("SKIP  no tall building in view")
	else:
		pos = tg["pos"]
		before = main.score_count
		await frames(0.8, func(_k): return [hand(pos, 1.0, 1)])
		await frames(0.1, func(k): return [hand(pos, 1.0 - k, 1)])
		await frames(0.3, func(_k): return [hand(pos, 0.0, 1)])
		check(main.score_count == before and main.hint.text.begins_with("かたい"),
				"tall building resists (hint: %s)" % main.hint.text)
	await frames(0.6, idle)

	# --- thumbs-up movement
	var vp := root.get_visible_rect().size
	var pump := func(k: float, x: float, side: int) -> Dictionary:
		var y := 0.5 + 0.18 * sin(k * TAU * 5.0)
		return hand(Vector2(vp.x * x, vp.y * y), 0.0, side, 0.17, true)
	await frames(0.3, func(_k): return [hand(Vector2(vp.x * 0.3, vp.y * 0.5), 0.0, -1, 0.17, true),
			hand(Vector2(vp.x * 0.7, vp.y * 0.5), 0.0, 1, 0.17, true)])
	check(main.input.hands[1].like and main.input.hands[-1].like, "thumbs-up is detected on both hands")
	var fwd: Vector3 = -main.player.global_basis.z
	var p0: Vector3 = main.player.position
	var yaw0: float = main.player.rotation.y
	await frames(3.0, func(k): return [pump.call(k, 0.3, -1), pump.call(k, 0.7, 1)])
	await frames(1.0, idle)
	var moved: float = (main.player.position - p0).dot(fwd)
	check(moved > 5.0, "pumping both thumbs walks forward (%.1fm)" % moved)
	check(absf(main.player.rotation.y - yaw0) < 0.05, "walking straight does not turn")
	check(main.cam.rotation_degrees.z == 0.0, "camera never rolls")

	yaw0 = main.player.rotation.y
	await frames(2.0, func(k): return [hand(Vector2(vp.x * (0.7 + 0.1 * sin(k * TAU * 6.0)), vp.y * 0.5), 0.0, 1, 0.17, true)])
	await frames(1.0, idle)
	var dyaw: float = main.player.rotation.y - yaw0
	check(dyaw < -0.2, "wiggling the right thumb turns right (%.2f rad)" % dyaw)
	yaw0 = main.player.rotation.y
	await frames(2.0, func(k): return [hand(Vector2(vp.x * (0.3 + 0.1 * sin(k * TAU * 6.0)), vp.y * 0.5), 0.0, -1, 0.17, true)])
	await frames(1.0, idle)
	dyaw = main.player.rotation.y - yaw0
	check(dyaw > 0.2, "wiggling the left thumb turns left (%.2f rad)" % dyaw)

	# a thumbs-up hand never grabs buildings
	await settle()
	tg = find_target(true)
	if not tg.is_empty():
		before = main.score_count
		await frames(1.0, func(_k): return [hand(tg["pos"], 0.0, 1, 0.17, true)])
		check(main.score_count == before and main.active_id < 0, "thumbs-up does not destroy")

	# --- bead pile left behind rattles when stroked
	check(main.bead_sites.size() >= 3, "crushed lots are full of beads (%d piles)" % main.bead_sites.size())

	print("DONE  failures=%d" % failures)
	quit(1 if failures > 0 else 0)
