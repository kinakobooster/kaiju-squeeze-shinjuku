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


## Waits until growth, shake and the camera tilt have settled so screen positions stay valid.
## A hand is held up at the bottom of the screen meanwhile (reaching tilts the camera down),
## then taken away so the next hand starts fresh.
func settle() -> void:
	var vp := root.get_visible_rect().size
	var parked := [hand(Vector2(vp.x * 0.5, vp.y * 1.05), 1.0, 1)]
	while absf(main.eye - main.eye_target) > 0.02 or main.shake > 0.0 or main.look_down < 0.995:
		t += 1.0 / 60.0
		feed(parked)
		await process_frame
	for i in 2:
		t += 1.0 / 60.0
		feed([])
		await process_frame


## Long strides carry us far; put the kaiju back among the small buildings of Kabukicho.
func teleport_to_town() -> void:
	main.speed = 0.0
	main.player.position = Vector3(352, 0, -484)
	main.player.rotation.y = PI * 0.5


## Like find_target, but walks forward (thumbs-up pumping) until something is in reach.
func reach_target(crushable: bool) -> Dictionary:
	var vp := root.get_visible_rect().size
	for attempt in 8:
		await settle()
		var tg := find_target(crushable)
		if not tg.is_empty():
			return tg
		await frames(0.8, func(k):
			var y := 0.5 + 0.18 * sin(k * TAU * 2.0)
			return [hand(Vector2(vp.x * 0.3, vp.y * y), 0.0, -1, 0.17, true),
					hand(Vector2(vp.x * 0.7, vp.y * y), 0.0, 1, 0.17, true)])
		await frames(0.6, func(_k): return [])
	return {}


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
	check(main.game_state == "title" and main.title_label.visible, "starts on the title screen")
	var vp_t := root.get_visible_rect().size
	await frames(3.0, func(k):
		var y := 0.5 + 0.18 * sin(k * TAU * 5.0)
		return [hand(Vector2(vp_t.x * 0.3, vp_t.y * y), 0.0, -1, 0.17, true),
				hand(Vector2(vp_t.x * 0.7, vp_t.y * y), 0.0, 1, 0.17, true)])
	check(main.game_state == "play", "walking with both thumbs up starts the game")
	await frames(1.0, idle)

	# --- fast fist = サクッ
	var tg := await reach_target(true)
	check(not tg.is_empty(), "found a crushable target")
	var pos: Vector2 = tg.get("pos", Vector2.ZERO)
	var before: int = main.score_count
	await frames(0.8, func(_k): return [hand(pos, 1.0, 1)])
	check(main.city._hover.has(main.ctl[1]["target"]) and main.ctl[1]["target"] >= 0,
			"aimed building is highlighted (target %d)" % main.ctl[1]["target"])
	await frames(0.1, func(k): return [hand(pos, 1.0 - k, 1)])
	await frames(0.4, func(_k): return [hand(pos, 0.0, 1)])
	check(main.score_count >= before + 1 and main.banner.text.begins_with("サクッ"),
			"fast fist crushes with サクッ (banner: %s)" % main.banner.text.split("\n")[0])
	await frames(0.6, func(_k): return [hand(pos, 1.0, 1)])

	# --- slow fist = グジュウ, and the building deforms on the way
	tg = await reach_target(true)
	pos = tg.get("pos", Vector2.ZERO)
	before = main.score_count
	await frames(0.8, func(_k): return [hand(pos, 1.0, 1)])
	await frames(0.8, func(k): return [hand(pos, 1.0 - 0.6 * k, 1)])
	check(not main.active_ids.is_empty() and main.closure > 0.3 and main.closure < 0.97,
			"half-closed fist half-crushes (closure %.2f)" % main.closure)
	await frames(1.0, func(k): return [hand(pos, 0.4 - 0.4 * k, 1)])
	await frames(0.3, func(_k): return [hand(pos, 0.0, 1)])
	check(main.score_count >= before + 1 and main.banner.text.begins_with("グジュウ"),
			"slow fist crushes with グジュウ (banner: %s)" % main.banner.text.split("\n")[0])
	await frames(0.6, func(_k): return [hand(pos, 1.0, 1)])

	# --- slap towards the screen
	tg = await reach_target(true)
	pos = tg.get("pos", Vector2.ZERO)
	before = main.score_count
	await frames(0.5, func(_k): return [hand(pos, 1.0, 1)])
	await frames(0.15, func(k): return [hand(pos, 1.0, 1, 0.17 + 0.15 * k)])
	await frames(0.3, func(_k): return [hand(pos, 1.0, 1, 0.32)])
	check(main.score_count >= before + 1 and (main.banner.text.begins_with("バチーン") or main.banner.text.begins_with("ドドド")),
			"slap crushes (banner: %s)" % main.banner.text.split("\n")[0])
	await frames(0.6, func(_k): return [hand(pos, 1.0, 1)])

	# --- an open palm keeps growing and covers more and more buildings
	tg = await reach_target(true)
	pos = tg.get("pos", Vector2.ZERO)
	await frames(0.5, func(_k): return [hand(pos, 1.0, 1)])
	var early: int = main.ctl[1]["targets"].size()
	await frames(2.5, func(_k): return [hand(pos, 1.0, 1)])
	var late: int = main.ctl[1]["targets"].size()
	check(main.input.hands[1].charge > 0.95 and late > early and main.city._hover.size() >= late,
			"held open, the hand grows and every building under it shivers (%d -> %d)" % [early, late])
	await frames(0.3, idle)

	# --- two-finger pinch
	tg = await reach_target(true)
	pos = tg.get("pos", Vector2.ZERO)
	before = main.score_count
	await frames(0.8, func(_k): return [hand(pos, 1.0, 1)])
	await frames(0.6, func(k): return [hand(pos, 1.0, 1, 0.17, false, k)])
	await frames(0.3, func(_k): return [hand(pos, 1.0, 1, 0.17, false, 1.0)])
	check(main.score_count >= before + 1 and main.banner.text.begins_with("プチッ"),
			"pinching with two fingers crushes with プチッ (banner: %s)" % main.banner.text.split("\n")[0])
	await frames(0.5, func(_k): return [hand(pos, 1.0, 1)])

	# --- once big, one slap flattens a whole patch of small buildings
	main.eye_target = 120.0
	var big := await reach_target(true)
	before = main.score_count
	var spot: Vector2 = big.get("pos", root.get_visible_rect().size * 0.5)
	await frames(0.5, func(_k): return [hand(spot, 1.0, 1)])
	await frames(0.15, func(k): return [hand(spot, 1.0, 1, 0.17 + 0.15 * k)])
	await frames(0.3, func(_k): return [hand(spot, 1.0, 1, 0.32)])
	check(main.score_count >= before + 2 and main.banner.text.begins_with("ドドド"),
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
		for s2 in main.bead_sites:
			zara = zara or s2["cool"] > 0.0
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
	tg = await reach_target(true)
	if not tg.is_empty():
		before = main.score_count
		await frames(1.0, func(_k): return [hand(tg["pos"], 0.0, 1, 0.17, true)])
		check(main.score_count == before and main.active_ids.is_empty(), "thumbs-up does not destroy")

	# --- bead pile left behind rattles when stroked
	check(main.bead_sites.size() >= 3, "crushed lots are full of beads (%d piles)" % main.bead_sites.size())

	# --- items
	main.speed = 0.0
	main.active_item = ""
	if main.item_node:
		main.item_node.queue_free()
		main.item_node = null
	main.item_timer = 0.0
	await frames(0.05, idle)
	check(main.item_node != null, "an item appears (%s)" % main.item_kind)
	main.item_kind = "smile"
	main._pick_item()
	check(main.active_item == "smile", "picking it up activates it")
	await settle()
	var mid := root.get_visible_rect().size * 0.5
	var frozen0 := 0
	for b in main.city.buildings:
		frozen0 += 1 if b.get("frozen", false) else 0
	main.input.injected_face = JSON.stringify({"t": 1, "jaw": 0.0, "smile": 0.9, "x": 0.5, "y": 0.5})
	await frames(1.0, idle)
	main.input.injected_face = ""
	var frozen1 := 0
	for b in main.city.buildings:
		frozen1 += 1 if b.get("frozen", false) else 0
	check(frozen1 > frozen0, "smiling freezes buildings (%d frozen)" % (frozen1 - frozen0))
	# squeeze a frozen one: シャリシャリ
	var ice := await reach_target(true)
	if ice.is_empty():
		print("SKIP  no building within reach to freeze")
	else:
		main.city.freeze(ice["id"])
		pos = ice["pos"]
		await frames(0.8, func(_k): return [hand(pos, 1.0, 1)])
		await frames(0.1, func(k): return [hand(pos, 1.0 - k, 1)])
		await frames(0.4, func(_k): return [hand(pos, 0.0, 1)])
		check(main.banner.text.begins_with("シャリシャリ"), "squeezing a frozen building goes シャリシャリ (banner: %s)" % main.banner.text.split("\n")[0])
	await frames(0.5, idle)

	main.active_item = "beam"
	main.active_time = 10.0
	teleport_to_town()
	await settle()
	before = main.score_count
	main.input.injected_face = JSON.stringify({"t": 1, "jaw": 0.9, "smile": 0.0, "x": 0.5, "y": 0.62})
	await frames(2.0, idle)
	check(main.beam_mesh.visible and main.score_count > before, "open mouth fires the beam and buildings pop into stars (%d)" % (main.score_count - before))
	main.input.injected_face = ""
	await frames(0.3, idle)
	check(not main.beam_mesh.visible, "closing the mouth stops the beam")

	main.active_item = "midas"
	main.active_time = 10.0
	main.speed = 0.0
	before = main.score_count
	var p_m: Vector3 = main.player.position
	await frames(2.5, func(k): return [pump.call(k, 0.3, -1), pump.call(k, 0.7, 1)])
	check(main.player.position.distance_to(p_m) > 60.0 and main.score_count > before,
			"midas: fast walking turns everything it hits to gold (%.0fm, %d)" % [main.player.position.distance_to(p_m), main.score_count - before])
	main.active_item = "claw"
	main.active_time = 10.0
	await frames(0.2, func(_k): return [hand(mid, 1.0, 1)])
	check(main.silhouette.claw_scale > 1.0 and main.reach(1.5) > main.reach(), "claws grow and swings reach 1.5x")
	main.active_item = ""
	await frames(0.3, idle)

	# --- stomping when big (heading east: the Midas run already cleared the way west)
	teleport_to_town()
	main.player.rotation.y = -PI * 0.5
	main.eye_target = 150.0
	await settle()
	before = main.score_count
	await frames(3.0, func(k): return [pump.call(k, 0.3, -1), pump.call(k, 0.7, 1)])
	check(main.score_count > before, "a big kaiju stomps small buildings just by walking (%d)" % (main.score_count - before))

	print("DONE  failures=%d" % failures)
	quit(1 if failures > 0 else 0)
