class_name HandInput
extends Node
## Hand landmarks from the webcam (MediaPipe in JS, web build) or a mouse-driven fake hand.
## Exposes up to two Hand objects keyed by screen side (-1 left, +1 right).

class Hand:
	var side := 0
	var pts := PackedVector2Array()  # 21 landmarks in screen pixels (mirrored like a selfie)
	var palm := Vector2.ZERO
	var size := 100.0  # wrist -> middle MCP in pixels
	var openness := 1.0  # 0 = fist, 1 = open palm
	var vel := Vector2.ZERO  # screen heights per second
	var grow := 0.0  # relative hand-size change per second (> 0 = moving towards the screen)
	var close_speed := 0.0  # how fast the hand is closing (openness lost per second)
	var seen := 0.0  # seconds continuously tracked
	var like := false  # thumbs-up (いいね): the hand is used for moving, not destroying
	var like_score := 0.0
	var like_hold := 0.0

const FINGERS := [[5, 6, 8], [9, 10, 12], [13, 14, 16], [17, 18, 20]]

# Open-hand template (right hand on screen, unit = wrist->middle MCP, pointing up).
const OPEN := [
	Vector2(0, 0),
	Vector2(-0.35, -0.15), Vector2(-0.62, -0.4), Vector2(-0.82, -0.62), Vector2(-0.98, -0.82),
	Vector2(-0.32, -0.95), Vector2(-0.4, -1.35), Vector2(-0.45, -1.62), Vector2(-0.5, -1.86),
	Vector2(0, -1), Vector2(0, -1.45), Vector2(0, -1.76), Vector2(0, -2.02),
	Vector2(0.28, -0.93), Vector2(0.33, -1.33), Vector2(0.37, -1.6), Vector2(0.4, -1.83),
	Vector2(0.52, -0.8), Vector2(0.62, -1.1), Vector2(0.68, -1.31), Vector2(0.73, -1.5),
]
const FIST := [
	Vector2(0, 0),
	Vector2(-0.35, -0.15), Vector2(-0.45, -0.38), Vector2(-0.3, -0.62), Vector2(-0.08, -0.72),
	Vector2(-0.32, -0.95), Vector2(-0.34, -1.2), Vector2(-0.33, -1.0), Vector2(-0.3, -0.84),
	Vector2(0, -1), Vector2(0, -1.25), Vector2(0, -1.05), Vector2(0, -0.86),
	Vector2(0.28, -0.93), Vector2(0.3, -1.17), Vector2(0.3, -0.98), Vector2(0.28, -0.82),
	Vector2(0.52, -0.8), Vector2(0.55, -1.0), Vector2(0.54, -0.86), Vector2(0.5, -0.74),
]
# Thumbs-up: a sideways fist (fingers pointing right) with the thumb straight up.
const LIKE := [
	Vector2(0, 0),
	Vector2(0.15, -0.35), Vector2(0.15, -0.7), Vector2(0.15, -1.0), Vector2(0.15, -1.3),
	Vector2(0.95, -0.32), Vector2(1.2, -0.34), Vector2(1.0, -0.33), Vector2(0.84, -0.3),
	Vector2(1.0, 0), Vector2(1.25, 0), Vector2(1.05, 0), Vector2(0.86, 0),
	Vector2(0.93, 0.28), Vector2(1.17, 0.3), Vector2(0.98, 0.3), Vector2(0.82, 0.28),
	Vector2(0.8, 0.52), Vector2(1.0, 0.55), Vector2(0.86, 0.54), Vector2(0.74, 0.5),
]

var hands := {}  # side -> Hand
var source := "mouse"  # "camera" or "mouse"
var status := ""
var _status_timer := 0.0
var _is_web := OS.has_feature("web")
var _last_stamp := -1.0
var _mouse_open := 1.0
var _last_cam_time := 0.0
var _clock := 0.0
## Test hook: when set, used instead of window.kaijuHands (same JSON format).
var injected := ""
var _mouse_slap := 0.0


func _process(dt: float) -> void:
	var size := get_viewport().get_visible_rect().size
	_clock += dt
	if injected != "":
		source = "camera"
		_read_camera(dt, size, injected)
		return
	if _is_web:
		_status_timer -= dt
		if _status_timer <= 0.0:
			_status_timer = 0.5
			status = str(JavaScriptBridge.eval("window.kaijuStatus || ''", true))
		if status == "ready":
			source = "camera"
			_read_camera(dt, size, str(JavaScriptBridge.eval("window.kaijuHands || ''", true)))
			return
	source = "mouse"
	_read_mouse(dt, size)


func _read_camera(dt: float, size: Vector2, raw: String) -> void:
	if raw.is_empty():
		_age(dt)
		return
	var data = JSON.parse_string(raw)
	if typeof(data) != TYPE_DICTIONARY:
		return
	if data["t"] == _last_stamp:  # no new camera frame; keep extrapolating smoothly
		_age(dt)
		return
	_last_stamp = data["t"]
	var now := _clock
	var cam_dt := clampf(now - _last_cam_time, 0.01, 0.2)
	_last_cam_time = now
	var found := []
	for h in data["hands"]:
		var p: Array = h["p"]
		var pts := PackedVector2Array()
		var p3: Array[Vector3] = []
		for k in 21:
			var x: float = p[k * 3]
			var y: float = p[k * 3 + 1]
			var z: float = p[k * 3 + 2]
			pts.append(Vector2((1.0 - x) * size.x, y * size.y))
			p3.append(Vector3(x * 4.0 / 3.0, y, z * 4.0 / 3.0))
		# MediaPipe labels assume a mirrored image; on our mirrored view "Left" shows on the right.
		var side := 1 if h["label"] == "Left" else -1
		found.append({"pts": pts, "p3": p3, "side": side})
	if found.size() == 2:
		found.sort_custom(func(a, b): return a["pts"][9].x < b["pts"][9].x)
		found[0]["side"] = -1
		found[1]["side"] = 1
	elif found.size() == 1 and hands.size() == 1:
		var prev: Hand = hands.values()[0]
		if prev.palm.distance_to(found[0]["pts"][9]) < size.y * 0.3:
			found[0]["side"] = prev.side
	var seen_sides := {}
	for f in found:
		var o := 0.0
		var p3: Array[Vector3] = f["p3"]
		for fi in FINGERS:
			var ratio := p3[0].distance_to(p3[fi[2]]) / maxf(p3[0].distance_to(p3[fi[0]]), 1e-4)
			o += clampf((ratio - 1.15) / 0.6, 0.0, 1.0)
		_update_hand(f["side"], f["pts"], o / 4.0, cam_dt, size, 0.6)
		seen_sides[f["side"]] = true
	for side in hands.keys():
		if not seen_sides.has(side):
			hands.erase(side)


func _age(dt: float) -> void:
	for h in hands.values():
		h.seen += dt


func _read_mouse(dt: float, size: Vector2) -> void:
	var m := get_viewport().get_mouse_position()
	# left button closes slowly (グジュー), space closes in a snap (サクッ)
	var quick := Input.is_key_pressed(KEY_SPACE)
	var closing := Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT) or quick
	_mouse_open = move_toward(_mouse_open, 0.0 if closing else 1.0, dt * (14.0 if quick or not closing else 1.1))
	var hand_size := size.y * 0.2
	if Input.is_mouse_button_pressed(MOUSE_BUTTON_RIGHT):
		_mouse_slap = minf(_mouse_slap + dt * 6.0, 1.0)
	else:
		_mouse_slap = maxf(_mouse_slap - dt * 4.0, 0.0)
	hand_size *= 1.0 + _mouse_slap * 0.8
	var two := Input.is_key_pressed(KEY_SHIFT)
	var spread := Input.is_key_pressed(KEY_CTRL)
	var gap := size.y * (0.12 if spread else 0.2)
	var right_palm := m + Vector2(gap if two else 0.0, 0)
	var like := Input.is_key_pressed(KEY_T)
	_update_hand(1, _fake_pts(right_palm, hand_size, _mouse_open, 1.0, -0.15 if two else 0.0), _mouse_open if not like else 0.0, dt, size, 1.0)
	if two:
		var left_palm := m - Vector2(gap, 0)
		_update_hand(-1, _fake_pts(left_palm, hand_size, _mouse_open, -1.0, 0.15), _mouse_open if not like else 0.0, dt, size, 1.0)
	elif hands.has(-1):
		hands.erase(-1)


## Synthetic landmarks around a palm centre; rot tilts the hand (radians).
func _fake_pts(palm: Vector2, s: float, openness: float, mirror: float, rot: float) -> PackedVector2Array:
	var pts := PackedVector2Array()
	var wrist := palm + Vector2(0, s * 0.55)
	for k in 21:
		var q: Vector2 = LIKE[k] if Input.is_key_pressed(KEY_T) else FIST[k].lerp(OPEN[k], openness)
		q.x *= mirror
		pts.append(wrist + q.rotated(rot) * s)
	return pts


func _update_hand(side: int, pts: PackedVector2Array, openness: float, dt: float, size: Vector2, smooth: float) -> void:
	var h: Hand = hands.get(side)
	var palm := (pts[0] + pts[5] + pts[9] + pts[13] + pts[17]) / 5.0
	if h == null:
		h = Hand.new()
		h.side = side
		h.palm = palm
		h.openness = openness
		hands[side] = h
	var a := clampf(smooth, 0.0, 1.0)
	var new_vel := (palm - h.palm) / size.y / maxf(dt, 1e-3)
	var new_size := pts[0].distance_to(pts[9])
	var dt_safe := maxf(dt, 1e-3)
	var new_open := lerpf(h.openness, openness, a)
	if h.seen > 0.0:
		h.vel = h.vel.lerp(new_vel, a)
		h.grow = lerpf(h.grow, (new_size - h.size) / maxf(h.size, 1.0) / dt_safe, a)
		h.close_speed = lerpf(h.close_speed, (h.openness - new_open) / dt_safe, a)
	h.palm = h.palm.lerp(palm, a)
	h.openness = new_open
	h.pts = pts
	h.size = new_size
	h.seen += dt
	# thumbs-up with hysteresis and a short grace period (fast pumping blurs the camera image)
	h.like_score = lerpf(h.like_score, like_score(pts, h.openness), a)
	if h.like_score > 0.6:
		h.like = true
		h.like_hold = 0.25
	elif h.like_score < 0.3:
		h.like_hold -= dt
		if h.like_hold <= 0.0:
			h.like = false


## 0..1: fingers curled, thumb clearly the highest point of the hand and well away from the fist.
static func like_score(pts: PackedVector2Array, openness: float) -> float:
	if openness > 0.4:
		return 0.0
	var s := maxf(pts[0].distance_to(pts[9]), 1.0)
	var top := INF
	for k in 21:
		if k < 2 or k > 4:
			top = minf(top, pts[k].y)
	var up := (top - pts[4].y) / s
	var ext := pts[4].distance_to(pts[5]) / s
	return clampf((up - 0.05) / 0.3, 0.0, 1.0) * clampf((ext - 0.45) / 0.3, 0.0, 1.0)
