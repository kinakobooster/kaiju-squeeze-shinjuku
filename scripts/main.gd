extends Node3D
## Kaiju Squeeze Shinjuku: crawl through Shinjuku with your webcam hands and squeeze buildings.
##
## Per hand: MOVE (drag the ground: down = forward, up = back, sideways = turn)
##   -> open palm held still = AIM (pick a building under the palm)
##   -> close the fist = GRIP. The building is crushed exactly as far as the fist is closed:
##      snap it shut for a crisp "サクッ", close slowly for a long "グジュー".
## Slapping towards the screen (or a very fast swipe) smashes the building under the palm.
## You start small; every crushed building makes you grow so you can take on taller ones.

enum State { MOVE, AIM, GRIP }

const EYE_START := 30.0
const EYE_MAX := 175.0
const CRUSH_RATIO := 1.6  # can crush buildings up to eye height * this
const FORWARD_K := 40.0
const TURN_DRAG := 1.1  # sideways hand motion drags the view around
const TURN_SIDE := 0.8  # one hand paddling vertically turns towards / away from its side
const MAX_SPEED := 110.0
const GRIP_OPEN := 0.7  # openness below this starts a grip
const FIST_OPEN := 0.12  # openness at which the building is fully crushed
const RELEASE_OPEN := 0.8
const SNAP_TIME := 0.3  # crushed faster than this = サクッ
const SLAP_GROW := 2.2  # hand size growth per second that counts as a slap
const SLAP_SPEED := 4.5  # screen heights per second that counts as a smash
const AREA_LIMIT := Rect2(-1150, -1050, 2300, 2100)

var city: City
var input: HandInput
var sfx: Sfx
var player := Node3D.new()
var cam := Camera3D.new()
var stars := Node3D.new()
var silhouette: HandSilhouette
var hand_vp: SubViewport
var hand_rect: TextureRect
var ui: Control
var hud: Label
var help: Label
var status_label: Label
var banner: Label
var hint: Label
var loading: Label

var ctl := {}  # side -> {state, still, target, hit, act, stroking, cool}
var speed := 0.0
var yaw_vel := 0.0
var shake := 0.0
var bob := 0.0
var eye := EYE_START
var eye_target := EYE_START
var ready_to_play := false
var clock := 0.0

# active squeeze
var active_id := -1
var active_node: MeshInstance3D
var closure := 0.0
var grip_start := 0.0
var grip_y := 0.5
var size_pitch := 1.0
var two_hand := false
var press_target := -1
var press_d0 := 0.0
var prev_press := 0.0
var relaxing := {}  # id -> {node, cur, target, jig}
var juice_fx: CPUParticles3D
var debris_fx: CPUParticles3D

var score_count := 0
var banner_time := 0.0
var hint_time := 0.0
var font_big: Font = preload("res://fonts/DelaGothicOne.ttf")


func _ready() -> void:
	_setup_world()
	_setup_ui()
	input = HandInput.new()
	add_child(input)
	sfx = Sfx.new()
	add_child(sfx)
	for side in [-1, 1]:
		ctl[side] = {"state": State.MOVE, "still": 0.0, "target": -1, "hit": Vector3.ZERO,
				"act": 0.0, "stroking": false, "cool": 0.0}
	await get_tree().process_frame
	await get_tree().process_frame
	city = City.new()
	add_child(city)
	city.load_city("res://data/city.json")
	juice_fx = _make_particles(SphereMesh.new(), 260, Color.WHITE, 6.0)
	debris_fx = _make_particles(BoxMesh.new(), 140, Color(0.5, 0.5, 0.5), 5.0)
	loading.visible = false
	ready_to_play = true


func crush_limit() -> float:
	return eye * CRUSH_RATIO


func reach() -> float:
	return 150.0 + eye * 3.5


# --- setup --------------------------------------------------------------------------------

func _setup_world() -> void:
	var env := Environment.new()
	var sky_mat := ProceduralSkyMaterial.new()
	sky_mat.sky_top_color = Color(0.22, 0.06, 0.55)
	sky_mat.sky_horizon_color = Color(0.98, 0.55, 0.92)
	sky_mat.sky_curve = 0.25
	sky_mat.ground_horizon_color = Color(0.75, 0.45, 0.85)
	sky_mat.ground_bottom_color = Color(0.2, 0.1, 0.3)
	sky_mat.sun_angle_max = 12.0
	var sky := Sky.new()
	sky.sky_material = sky_mat
	env.background_mode = Environment.BG_SKY
	env.sky = sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.ambient_light_energy = 0.9
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	env.tonemap_exposure = 1.15
	env.fog_enabled = true
	env.fog_mode = Environment.FOG_MODE_DEPTH
	env.fog_light_color = Color(0.85, 0.5, 0.92)
	env.fog_depth_begin = 350.0
	env.fog_depth_end = 1900.0
	env.fog_density = 1.0
	env.glow_enabled = true
	env.glow_intensity = 0.8
	env.glow_bloom = 0.08
	var we := WorldEnvironment.new()
	we.environment = env
	add_child(we)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-20, -100, 0)
	sun.light_color = Color(1.0, 0.8, 0.95)
	sun.light_energy = 1.0
	add_child(sun)
	add_child(player)
	player.position = Vector3(80, 0, 20)
	player.rotation.y = PI * 0.5  # face west, towards the skyscrapers of Nishi-Shinjuku
	cam.rotation_degrees.x = -17.0
	cam.fov = 72.0
	cam.far = 3000.0
	cam.near = 0.5
	player.add_child(cam)
	_setup_stars()


func _setup_stars() -> void:
	add_child(stars)
	var mesh := _star_mesh()
	var m := StandardMaterial3D.new()
	m.albedo_color = Color(1.0, 0.88, 0.3)
	m.emission_enabled = true
	m.emission = Color(1.0, 0.8, 0.2)
	m.emission_energy_multiplier = 1.8
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	m.set("disable_fog", true)
	var rng := RandomNumberGenerator.new()
	rng.seed = 2024
	for i in 70:
		var s := MeshInstance3D.new()
		s.mesh = mesh
		s.material_override = m
		s.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		var ang := rng.randf() * TAU
		var dist := rng.randf_range(450.0, 1300.0)
		var base := Vector3(cos(ang) * dist, rng.randf_range(170.0, 560.0), sin(ang) * dist)
		s.position = base
		s.scale = Vector3.ONE * rng.randf_range(16.0, 42.0)
		s.rotation = Vector3(0, rng.randf() * TAU, rng.randf_range(-0.4, 0.4))
		s.set_meta("base", base)
		s.set_meta("phase", rng.randf() * TAU)
		s.set_meta("spin", rng.randf_range(-0.6, 0.6))
		stars.add_child(s)


## A puffy five-pointed star, unit radius, extruded along Z.
static func _star_mesh() -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var ring: Array[Vector2] = []
	for k in 10:
		var r := 1.0 if k % 2 == 0 else 0.48
		var a := PI * 0.5 + TAU * k / 10.0
		ring.append(Vector2(cos(a), sin(a)) * r)
	var depth := 0.28
	for face in [1.0, -1.0]:
		st.set_normal(Vector3(0, 0, face))
		for k in 10:
			var p: Vector2 = ring[k]
			var q: Vector2 = ring[(k + 1) % 10]
			st.add_vertex(Vector3(0, 0, depth * face))
			st.add_vertex(Vector3(p.x, p.y, 0.05 * face))
			st.add_vertex(Vector3(q.x, q.y, 0.05 * face))
	for k in 10:
		var p: Vector2 = ring[k]
		var q: Vector2 = ring[(k + 1) % 10]
		var n := Vector3(q.y - p.y, p.x - q.x, 0).normalized()
		st.set_normal(n)
		for v in [Vector3(p.x, p.y, 0.05), Vector3(q.x, q.y, 0.05), Vector3(q.x, q.y, -0.05),
				Vector3(p.x, p.y, 0.05), Vector3(q.x, q.y, -0.05), Vector3(p.x, p.y, -0.05)]:
			st.add_vertex(v)
	return st.commit()


func _setup_ui() -> void:
	var layer := CanvasLayer.new()
	layer.layer = 1
	add_child(layer)
	hand_vp = SubViewport.new()
	hand_vp.transparent_bg = true
	hand_vp.disable_3d = true
	hand_vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	hand_vp.size = Vector2i(640, 360)
	silhouette = HandSilhouette.new()
	hand_vp.add_child(silhouette)
	layer.add_child(hand_vp)
	hand_rect = TextureRect.new()
	hand_rect.texture = hand_vp.get_texture()
	hand_rect.set_anchors_preset(Control.PRESET_FULL_RECT)
	hand_rect.stretch_mode = TextureRect.STRETCH_SCALE
	hand_rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	hand_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var hm := ShaderMaterial.new()
	hm.shader = preload("res://shaders/hand_silhouette.gdshader")
	hand_rect.material = hm
	layer.add_child(hand_rect)

	var top := CanvasLayer.new()
	top.layer = 2
	add_child(top)
	ui = Control.new()
	ui.set_anchors_preset(Control.PRESET_FULL_RECT)
	ui.mouse_filter = Control.MOUSE_FILTER_IGNORE
	ui.draw.connect(_draw_ui)
	top.add_child(ui)
	hud = _label(top, 26, Vector2(24, 18))
	status_label = _label(top, 18, Vector2(24, 58))
	help = _label(top, 17, Vector2(24, 0))
	help.anchor_top = 1.0
	help.anchor_bottom = 1.0
	help.offset_top = -150
	help.text = ("地面をつかんで引き寄せる = 前進（押し返すと後退・横に動かすと旋回）／ 片手で漕ぐ = その向きに曲がる\n"
			+ "パーで止める = ビルを選ぶ ／ 素早くグー = サクッ！ ／ ゆっくりグー = グジュウ〜 ／ 画面に向かって叩く = バチーン！\n"
			+ "両手で握る or パーで挟む = 両手スクイーズ ／ 潰すほど大きくなる！\n"
			+ "[マウス] 左長押し=ゆっくり握る  Space=素早く握る  右=叩く  Shift=両手  WASD=移動  P=カメラ映像  H=ヘルプ")
	banner = _label(top, 54, Vector2.ZERO)
	banner.add_theme_font_override("font", font_big)
	banner.set_anchors_preset(Control.PRESET_TOP_WIDE)
	banner.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	banner.offset_top = 110
	banner.add_theme_color_override("font_color", Color(1.0, 0.88, 0.3))
	banner.add_theme_color_override("font_outline_color", Color(0.35, 0.05, 0.45))
	banner.add_theme_constant_override("outline_size", 18)
	banner.modulate.a = 0.0
	hint = _label(top, 24, Vector2.ZERO)
	hint.set_anchors_preset(Control.PRESET_TOP_WIDE)
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	hint.offset_top = 60
	hint.modulate.a = 0.0
	loading = _label(top, 40, Vector2.ZERO)
	loading.add_theme_font_override("font", font_big)
	loading.set_anchors_preset(Control.PRESET_CENTER)
	loading.grow_horizontal = Control.GROW_DIRECTION_BOTH
	loading.grow_vertical = Control.GROW_DIRECTION_BOTH
	loading.text = "新宿を読み込み中…"


func _label(parent: Node, size: int, pos: Vector2) -> Label:
	var l := Label.new()
	l.position = pos
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_outline_color", Color(0.15, 0.02, 0.2, 0.85))
	l.add_theme_constant_override("outline_size", 8)
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	parent.add_child(l)
	return l


func _make_particles(mesh: PrimitiveMesh, amount: int, color: Color, size: float) -> CPUParticles3D:
	var p := CPUParticles3D.new()
	if mesh is BoxMesh:
		mesh.size = Vector3.ONE * size
	elif mesh is SphereMesh:
		mesh.radius = size * 0.5
		mesh.height = size
		mesh.radial_segments = 8
		mesh.rings = 4
	var m := StandardMaterial3D.new()
	m.vertex_color_use_as_albedo = true
	m.albedo_color = Color.WHITE
	m.emission_enabled = color != Color(0.5, 0.5, 0.5)
	m.emission = Color(0.3, 0.3, 0.3)
	mesh.material = m
	p.mesh = mesh
	p.amount = amount
	p.lifetime = 1.6
	p.emitting = false
	p.local_coords = false
	p.emission_shape = CPUParticles3D.EMISSION_SHAPE_SPHERE
	p.emission_sphere_radius = 10.0
	p.direction = Vector3.UP
	p.spread = 80.0
	p.initial_velocity_min = 15.0
	p.initial_velocity_max = 55.0
	p.gravity = Vector3(0, -70, 0)
	p.scale_amount_min = 0.5
	p.scale_amount_max = 1.6
	p.color = color
	add_child(p)
	return p


# --- main loop ----------------------------------------------------------------------------

func _process(dt: float) -> void:
	_update_status()
	silhouette.scale_factor = float(hand_vp.size.x) / get_viewport().get_visible_rect().size.x
	silhouette.hands = input.hands.values()
	_update_stars(dt)
	if not ready_to_play:
		return
	clock += dt
	eye = lerpf(eye, eye_target, 1.0 - exp(-1.5 * dt))
	_update_hands(dt)
	_update_movement(dt)
	_update_squeeze(dt)
	_update_relaxing(dt)
	_update_camera(dt)
	if banner_time > 0.0:
		banner_time -= dt
		banner.modulate.a = clampf(banner_time, 0.0, 1.0)
		banner.pivot_offset = banner.size * 0.5
		banner.scale = Vector2.ONE * (1.0 + maxf(banner_time - 2.2, 0.0) * 0.6)
	if hint_time > 0.0:
		hint_time -= dt
		hint.modulate.a = clampf(hint_time * 2.0, 0.0, 1.0)
	hud.text = "身長 %dm  ／  つぶせる高さ %dm まで  ／  スクイーズ %d棟" % [int(eye), int(crush_limit()), score_count]
	var hm: ShaderMaterial = hand_rect.material
	hm.set_shader_parameter("grip_glow", closure if active_id >= 0 else 0.0)
	ui.queue_redraw()


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_H:
			help.visible = not help.visible
		elif event.keycode == KEY_P and OS.has_feature("web"):
			JavaScriptBridge.eval("window.kaijuTogglePreview && window.kaijuTogglePreview()")


func _update_status() -> void:
	var s := input.status
	if input.source == "camera":
		status_label.text = "カメラ: 手をかざしてね" if input.hands.is_empty() else "カメラ: %d本の手を検出" % input.hands.size()
	elif s.begins_with("nocam"):
		status_label.text = "カメラが使えません（%s）→ マウスで遊べます" % s.substr(6)
	elif s == "model" or s == "loading":
		status_label.text = "手の検出モデルを読み込み中…（マウスでも遊べます）"
	elif s.begins_with("error"):
		status_label.text = "手の検出エラー: %s" % s.substr(6)
	else:
		status_label.text = "マウスモード"


func _update_stars(dt: float) -> void:
	stars.position = Vector3(player.position.x, 0.0, player.position.z)
	var t := Time.get_ticks_msec() / 1000.0
	for s in stars.get_children():
		var ph: float = s.get_meta("phase")
		var base: Vector3 = s.get_meta("base")
		s.position = base + Vector3(0, sin(t * 0.7 + ph) * 18.0, 0)
		s.rotation.y += float(s.get_meta("spin")) * dt
		s.rotation.z = sin(t * 0.5 + ph) * 0.35


func _ray(screen: Vector2) -> Dictionary:
	var o := cam.project_ray_origin(screen)
	var d := cam.project_ray_normal(screen)
	return city.pick(o, d, reach())


func _crushable(id: int) -> bool:
	return city.effective_height(id) <= crush_limit()


func _too_hard(id: int) -> void:
	var b: Dictionary = city.buildings[id]
	sfx.play_hard()
	shake = maxf(shake, 0.35)
	hint.text = "かたい！ %dmのビルには あと%dm 大きくならないと…" % [
		int(b["h"]), int(ceil(city.effective_height(id) / CRUSH_RATIO - eye))]
	hint_time = 2.0


func _update_hands(dt: float) -> void:
	for side in [-1, 1]:
		var c: Dictionary = ctl[side]
		var h: HandInput.Hand = input.hands.get(side)
		c["cool"] = maxf(c["cool"] - dt, 0.0)
		if h == null:
			c["state"] = State.MOVE
			c["target"] = -1
			c["still"] = 0.0
			continue
		var spd := h.vel.length()
		# slap towards the screen, or a very fast swipe, smashes whatever is under the palm
		if c["state"] != State.GRIP and c["cool"] <= 0.0 and h.seen > 0.3 \
				and (h.grow > SLAP_GROW or spd > SLAP_SPEED):
			var hit := _ray(h.palm)
			if not hit.is_empty():
				c["cool"] = 0.45
				if _crushable(hit["id"]):
					_crush(hit["id"], hit["point"], "slap")
				else:
					_too_hard(hit["id"])
				continue
		match c["state"]:
			State.MOVE:
				c["still"] = c["still"] + dt if (h.openness > 0.75 and spd < 0.9) else 0.0
				if c["still"] > 0.18:
					c["state"] = State.AIM
			State.AIM:
				var hit := _ray(h.palm)
				var t: int = hit.get("id", -1)
				if t != c["target"] and t >= 0:
					sfx.play(sfx.select, 1.0 if _crushable(t) else 0.6, -14.0)
				c["target"] = t
				c["hit"] = hit.get("point", Vector3.ZERO)
				if spd > 1.7:
					c["state"] = State.MOVE
					c["still"] = 0.0
				elif h.openness < GRIP_OPEN:
					if t >= 0 and _crushable(t):
						c["state"] = State.GRIP
						_begin_squeeze(t, c["hit"])
					else:
						if t >= 0 and c["cool"] <= 0.0:
							_too_hard(t)
							c["cool"] = 0.6
						c["state"] = State.MOVE
			State.GRIP:
				if h.openness > RELEASE_OPEN:
					c["state"] = State.MOVE
					c["still"] = 0.0
					c["target"] = -1
	# a second fist close to the one already squeezing joins in (squeezing between both hands)
	if active_id >= 0:
		for side in [-1, 1]:
			var c: Dictionary = ctl[side]
			var other: Dictionary = ctl[-side]
			if c["state"] == State.GRIP and c["target"] != active_id and other["state"] == State.GRIP \
					and other["target"] == active_id:
				var a: HandInput.Hand = input.hands[side]
				var b: HandInput.Hand = input.hands[-side]
				if a.palm.distance_to(b.palm) < get_viewport().get_visible_rect().size.y * 0.55:
					c["target"] = active_id
	var hl := []
	for side in [-1, 1]:
		var c: Dictionary = ctl[side]
		if c["state"] == State.AIM and c["target"] >= 0 and _crushable(c["target"]):
			hl.append(c["target"])
	if press_target >= 0:
		hl.append(press_target)
	hl.append(-1)
	hl.append(-1)
	city.set_hover(hl[0], hl[1], 0.6 + 0.4 * sin(Time.get_ticks_msec() * 0.012))


## Strokes count by how hard they are: a fast stroke beats the slow return stroke,
## so the direction you paddle decides where you go.
static func _power(v: float) -> float:
	var a := maxf(absf(v) - 0.25, 0.0)
	return signf(v) * a * a


func _update_movement(dt: float) -> void:
	var fwd := 0.0
	var drag := 0.0
	var side_turn := 0.0
	var visible := 0
	for side in [-1, 1]:
		var h: HandInput.Hand = input.hands.get(side)
		var c: Dictionary = ctl[side]
		if h == null:
			c["act"] = 0.0
			continue
		visible += 1
		if c["state"] != State.MOVE:
			continue
		var py := _power(h.vel.y)  # > 0: pulling the ground towards you
		var px := _power(h.vel.x)
		fwd += py
		drag += px
		side_turn += side * py
		var strength := absf(py) + absf(px)
		c["act"] = lerpf(c["act"], 1.0 if absf(py) > 0.1 else 0.0, 1.0 - exp(-4.0 * dt))
		if strength > 0.5 and not c["stroking"]:
			c["stroking"] = true
		elif strength < 0.05 and c["stroking"]:
			c["stroking"] = false
			sfx.play(sfx.thud, randf_range(0.85, 1.1) * clampf(60.0 / eye, 0.7, 1.6), -8.0)
			bob = 1.0
			shake = maxf(shake, 0.2)
	var both: bool = visible == 2 and ctl[-1]["act"] > 0.12 and ctl[1]["act"] > 0.12
	var k := eye / 115.0
	var fwd_acc := fwd * FORWARD_K * k * (1.0 if both else 0.4)
	# dragging the world to the right turns the view left (+yaw), like a touch screen
	var yaw_acc := drag * TURN_DRAG
	if not both:
		yaw_acc -= side_turn * TURN_SIDE  # right hand pulling = turn right, pushing = turn left
	if input.source == "mouse":
		var ax := 0.0
		if Input.is_key_pressed(KEY_W) or Input.is_key_pressed(KEY_UP): ax = 1.0
		if Input.is_key_pressed(KEY_S) or Input.is_key_pressed(KEY_DOWN): ax = -1.0
		fwd_acc += ax * 120.0 * k
		var tr := 0.0
		if Input.is_key_pressed(KEY_A) or Input.is_key_pressed(KEY_LEFT): tr = 1.0
		if Input.is_key_pressed(KEY_D) or Input.is_key_pressed(KEY_RIGHT): tr = -1.0
		yaw_acc += tr * 4.0
	speed = clampf(speed + fwd_acc * dt, -MAX_SPEED * 0.5 * k, MAX_SPEED * k)
	yaw_vel += yaw_acc * dt
	speed *= exp(-1.4 * dt)
	yaw_vel *= exp(-3.0 * dt)
	player.rotation.y += yaw_vel * dt
	var forward := -player.global_basis.z
	var p := player.position + forward * speed * dt
	var p2 := city.push_out(Vector2(p.x, p.z), eye * 0.75, eye * 0.2)
	p2.x = clampf(p2.x, AREA_LIMIT.position.x, AREA_LIMIT.end.x)
	p2.y = clampf(p2.y, AREA_LIMIT.position.y, AREA_LIMIT.end.y)
	player.position = Vector3(p2.x, 0.0, p2.y)


func _size_pitch(b: Dictionary) -> float:
	var size_factor := clampf(pow(b["h"] * sqrt(b["area"]) / 400.0, 0.4), 0.5, 3.0)
	return clampf(1.25 - 0.22 * size_factor, 0.55, 1.2)


func _begin_squeeze(id: int, hit: Vector3) -> void:
	if id == active_id:
		return
	_end_squeeze()
	var b: Dictionary = city.buildings[id]
	active_id = id
	active_node = city.detach(id)
	relaxing.erase(id)
	closure = 0.0
	grip_start = clock
	grip_y = clampf(hit.y / b["h"], 0.2, 0.8)
	size_pitch = _size_pitch(b)
	var m: ShaderMaterial = active_node.material_override
	m.set_shader_parameter("grip_y", grip_y)


func _end_squeeze() -> void:
	if active_id < 0:
		return
	var b: Dictionary = city.buildings[active_id]
	b["damage"] = maxf(b["damage"], closure)
	relaxing[active_id] = {"node": active_node, "cur": closure, "target": b["damage"] * 0.4, "jig": 1.0}
	active_id = -1
	active_node = null
	closure = 0.0
	juice_fx.emitting = false


func _update_squeeze(dt: float) -> void:
	# two open palms pressing together around a building
	var press := 0.0
	var ha: HandInput.Hand = input.hands.get(-1)
	var hb: HandInput.Hand = input.hands.get(1)
	var both_aim: bool = ha != null and hb != null and ctl[-1]["state"] == State.AIM and ctl[1]["state"] == State.AIM
	if both_aim:
		var mid := (ha.palm + hb.palm) * 0.5
		var d := ha.palm.distance_to(hb.palm)
		var hit := _ray(mid)
		var t: int = hit.get("id", -1)
		if t != press_target or t < 0 or not _crushable(t):
			press_target = t if t >= 0 and _crushable(t) else -1
			press_d0 = d
		else:
			press_d0 = maxf(press_d0, d)
			press = clampf((press_d0 - d) / maxf(press_d0 * 0.55, 1.0), 0.0, 1.0)
			if press > 0.08 and active_id != t:
				_begin_squeeze(t, hit["point"])
	else:
		press_target = -1

	if active_id < 0:
		sfx.update_squeeze(dt, false, 0.0, 0.0, 1.0)
		prev_press = 0.0
		return
	# the building is crushed exactly as far as the fist is closed
	var now_closure := 0.0
	var closing := 0.0
	var grippers := 0
	for side in [-1, 1]:
		var c: Dictionary = ctl[side]
		if c["state"] == State.GRIP and c["target"] == active_id:
			var h: HandInput.Hand = input.hands[side]
			now_closure = maxf(now_closure, clampf((GRIP_OPEN - h.openness) / (GRIP_OPEN - FIST_OPEN), 0.0, 1.0))
			closing = maxf(closing, h.close_speed / (GRIP_OPEN - FIST_OPEN))
			grippers += 1
	var pressing := press_target == active_id and press > 0.0
	if pressing:
		closing = maxf(closing, (press - prev_press) / maxf(dt, 1e-3))
		now_closure = maxf(now_closure, press)
	prev_press = press
	if grippers == 0 and not pressing:
		_end_squeeze()
		sfx.update_squeeze(dt, false, 0.0, 0.0, 1.0)
		return
	two_hand = grippers == 2 or pressing
	closing = maxf(closing, 0.0)
	closure = now_closure
	var m: ShaderMaterial = active_node.material_override
	m.set_shader_parameter("squeeze", closure * 0.95)
	m.set_shader_parameter("two_hand", 1.0 if two_hand else 0.0)
	m.set_shader_parameter("juice", closure)
	m.set_shader_parameter("jiggle", clampf(closing * 0.08, 0.0, 0.3))
	var right := cam.global_basis.x
	m.set_shader_parameter("sq_dir", Vector2(right.x, right.z).normalized())
	shake = maxf(shake, 0.05 + 0.2 * closure + 0.1 * clampf(closing, 0.0, 2.0))
	sfx.update_squeeze(dt, true, closing, closure, size_pitch)
	var b: Dictionary = city.buildings[active_id]
	juice_fx.global_position = Vector3(b["center"].x, b["h"] * grip_y, b["center"].y)
	juice_fx.emission_sphere_radius = b["radius"] * 0.5
	juice_fx.color = b["juice"]
	juice_fx.emitting = closing > 0.3 and closure > 0.2
	if closure >= 0.97:
		var elapsed := clock - grip_start
		_crush(active_id, juice_fx.global_position, "snap" if elapsed < SNAP_TIME else "squish")


## style: "snap" (fast fist), "squish" (slow fist) or "slap".
func _crush(id: int, at: Vector3, style: String) -> void:
	var b: Dictionary = city.buildings[id]
	var pitch := _size_pitch(b)
	match style:
		"snap":
			sfx.play_snap(pitch)
			shake = 0.8
			banner.text = "サクッ!!"
		"squish":
			sfx.play_squish(pitch)
			shake = 1.2
			banner.text = "グジュウゥ〜〜ッ!!"
		_:
			sfx.play_slap(pitch)
			shake = 1.0
			banner.text = "バチーン!!"
	var center := Vector3(b["center"].x, clampf(at.y, 2.0, b["h"]), b["center"].y)
	for fx in [juice_fx, debris_fx]:
		var one: CPUParticles3D = fx.duplicate()
		add_child(one)
		one.global_position = center
		one.emission_sphere_radius = b["radius"] * 0.7
		one.one_shot = true
		if style == "snap" and fx == juice_fx:
			one.amount = fx.amount / 2
		one.explosiveness = 1.0 if style != "squish" else 0.7
		one.initial_velocity_max = 110.0 if style != "squish" else 70.0
		one.color = b["juice"] if fx == juice_fx else Color(0.6, 0.55, 0.62)
		one.emitting = true
		get_tree().create_timer(3.0).timeout.connect(one.queue_free)
	if id == active_id:
		juice_fx.emitting = false
		active_id = -1
		active_node = null
		closure = 0.0
	relaxing.erase(id)
	_spawn_puddle(b)
	city.destroy(id)
	score_count += 1
	var bname: String = b["name"] if b["name"] != "" else "名もなきビル"
	banner.text += "\n%s  %dm" % [bname, int(b["h"])]
	var before := int(crush_limit())
	eye_target = minf(eye_target + 0.6 + b["h"] * 0.045, EYE_MAX)
	if int(eye_target * CRUSH_RATIO) / 25 > before / 25:
		hint.text = "おおきくなった！ %dmのビルまで潰せる！" % int(eye_target * CRUSH_RATIO)
		hint_time = 2.5
	banner_time = 3.0
	for side in [-1, 1]:
		if ctl[side]["target"] == id:
			ctl[side]["target"] = -1


func _spawn_puddle(b: Dictionary) -> void:
	var mi := MeshInstance3D.new()
	var cyl := CylinderMesh.new()
	cyl.top_radius = b["radius"] * 0.85
	cyl.bottom_radius = b["radius"] * 0.95
	cyl.height = 1.2
	mi.mesh = cyl
	var m := StandardMaterial3D.new()
	m.albedo_color = b["juice"].darkened(0.2)
	m.emission_enabled = true
	m.emission = b["juice"] * 0.25
	m.roughness = 0.15
	m.metallic = 0.3
	mi.material_override = m
	mi.position = Vector3(b["center"].x, 0.6, b["center"].y)
	add_child(mi)


func _update_relaxing(dt: float) -> void:
	for id in relaxing.keys():
		var r: Dictionary = relaxing[id]
		r["cur"] = lerpf(r["cur"], r["target"], 1.0 - exp(-5.0 * dt))
		r["jig"] = r["jig"] * exp(-2.5 * dt)
		var m: ShaderMaterial = r["node"].material_override
		m.set_shader_parameter("squeeze", r["cur"])
		m.set_shader_parameter("jiggle", r["jig"])
		if r["jig"] < 0.01:
			m.set_shader_parameter("jiggle", 0.0)
			relaxing.erase(id)


func _update_camera(dt: float) -> void:
	shake = maxf(shake - dt * 1.8, 0.0)
	bob = maxf(bob - dt * 3.0, 0.0)
	var s := shake * shake * 3.0 * clampf(eye / 80.0, 0.4, 1.5)
	cam.position = Vector3(randf_range(-s, s), eye - sin(bob * PI) * eye * 0.05 + randf_range(-s, s), 0)
	cam.rotation_degrees.z = -yaw_vel * 4.0
	# small kaiju looks up at the towers (and the stars); big kaiju looks down on the city
	cam.rotation_degrees.x = lerpf(-4.0, -17.0, clampf((eye - EYE_START) / 110.0, 0.0, 1.0))


# --- overlay ------------------------------------------------------------------------------

func _draw_ui() -> void:
	var font := ThemeDB.fallback_font
	for side in [-1, 1]:
		var h: HandInput.Hand = input.hands.get(side)
		if h == null:
			continue
		var c: Dictionary = ctl[side]
		if c["state"] != State.AIM:
			continue
		var r := h.size * 0.7
		var t: int = c["target"]
		var ok := t >= 0 and _crushable(t)
		var col := Color(1.0, 0.75, 0.25) if ok else (Color(0.6, 0.55, 0.7, 0.8) if t >= 0 else Color(0.35, 0.1, 0.5, 0.7))
		ui.draw_arc(h.palm, r, 0, TAU, 48, col, 4.0, true)
		if t >= 0:
			var b: Dictionary = city.buildings[t]
			var bname: String = b["name"] if b["name"] != "" else "ビル"
			var text := "%s %dm%s" % [bname, int(b["h"]), "" if ok else "（かたい！）"]
			var pos := h.palm + Vector2(r + 10, 0)
			ui.draw_string_outline(font, pos, text, HORIZONTAL_ALIGNMENT_LEFT, -1, 22, 8, Color(0.15, 0.02, 0.2, 0.85))
			ui.draw_string(font, pos, text, HORIZONTAL_ALIGNMENT_LEFT, -1, 22, col)
	var ha: HandInput.Hand = input.hands.get(-1)
	var hb: HandInput.Hand = input.hands.get(1)
	if ha != null and hb != null and press_target >= 0:
		ui.draw_dashed_line(ha.palm, hb.palm, Color(1, 0.75, 0.25, 0.8), 4.0, 16.0)
		ui.draw_circle((ha.palm + hb.palm) * 0.5, 8.0, Color(1, 0.75, 0.25))
