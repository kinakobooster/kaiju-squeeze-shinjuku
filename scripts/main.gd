extends Node3D
## Kaiju Squeeze Shinjuku: crawl through Shinjuku with your webcam hands and squeeze buildings.
##
## Per hand: MOVE (pull the hand down the screen to crawl, one hand to turn)
##   -> open palm held still = AIM (pick a building under the palm)
##   -> close the fist = GRIP (squeeze it). Open again = back to MOVE.
## Two fists on the same building, or two open palms pressing together around one, squeeze
## it between the hands.

enum State { MOVE, AIM, GRIP }

const EYE_HEIGHT := 115.0
const REACH := 520.0
const FORWARD_K := 70.0
const TURN_K := 1.9
const TURN_SIGN := 1.0  # +1: paddling with the right hand turns right
const MAX_SPEED := 110.0
const SQUEEZE_RATE := 0.42
const AREA_LIMIT := Rect2(-1150, -1050, 2300, 2100)

var city: City
var input: HandInput
var sfx: Sfx
var player := Node3D.new()
var cam := Camera3D.new()
var silhouette: HandSilhouette
var hand_vp: SubViewport
var hand_rect: TextureRect
var ui: Control
var hud: Label
var help: Label
var status_label: Label
var banner: Label
var loading: Label

var ctl := {}  # side -> {state, still, target, hit, act, stroking}
var speed := 0.0
var yaw_vel := 0.0
var shake := 0.0
var bob := 0.0
var ready_to_play := false

# active squeeze
var active_id := -1
var active_node: MeshInstance3D
var progress := 0.0
var grip_y := 0.5
var size_factor := 1.0
var size_pitch := 1.0
var pressure := 0.0
var prev_pressure := 0.0
var two_hand := false
var press_target := -1
var press_d0 := 0.0
var relaxing := {}  # id -> {node, cur, target, jig}
var juice_fx: CPUParticles3D
var debris_fx: CPUParticles3D

var score_count := 0
var score_height := 0.0
var banner_time := 0.0
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
				"act": 0.0, "stroking": false}
	await get_tree().process_frame
	await get_tree().process_frame
	city = City.new()
	add_child(city)
	city.load_city("res://data/city.json")
	juice_fx = _make_particles(SphereMesh.new(), 260, Color.WHITE, 7.0)
	debris_fx = _make_particles(BoxMesh.new(), 140, Color(0.5, 0.5, 0.5), 6.0)
	loading.visible = false
	ready_to_play = true


# --- setup --------------------------------------------------------------------------------

func _setup_world() -> void:
	var env := Environment.new()
	var sky_mat := ProceduralSkyMaterial.new()
	sky_mat.sky_top_color = Color(0.1, 0.12, 0.3)
	sky_mat.sky_horizon_color = Color(0.95, 0.5, 0.35)
	sky_mat.ground_horizon_color = Color(0.4, 0.25, 0.25)
	sky_mat.ground_bottom_color = Color(0.08, 0.08, 0.1)
	sky_mat.sun_angle_max = 20.0
	var sky := Sky.new()
	sky.sky_material = sky_mat
	env.background_mode = Environment.BG_SKY
	env.sky = sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.ambient_light_energy = 0.7
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	env.fog_enabled = true
	env.fog_mode = Environment.FOG_MODE_DEPTH
	env.fog_light_color = Color(0.55, 0.38, 0.42)
	env.fog_depth_begin = 250.0
	env.fog_depth_end = 1600.0
	env.fog_density = 1.0
	env.glow_enabled = true
	env.glow_intensity = 0.6
	env.glow_bloom = 0.05
	var we := WorldEnvironment.new()
	we.environment = env
	add_child(we)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-14, -100, 0)
	sun.light_color = Color(1.0, 0.72, 0.55)
	sun.light_energy = 1.1
	add_child(sun)
	add_child(player)
	player.position = Vector3(80, 0, 20)
	player.rotation.y = PI * 0.5  # face west, towards the skyscrapers of Nishi-Shinjuku
	cam.position.y = EYE_HEIGHT
	cam.rotation_degrees.x = -17.0
	cam.fov = 72.0
	cam.far = 3000.0
	cam.near = 1.0
	player.add_child(cam)


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
	help.text = ("両手を画面の下へ引く = 這って前進 ／ 片手だけ漕ぐ = 向きを変える\n"
			+ "手をパーにして止める = ビルを選ぶ ／ 握る = グジュウ〜っとスクイーズ ／ 離す = 移動に戻る\n"
			+ "両手で同じビルを握る or パーで挟み込む = 両手スクイーズ（速い！）\n"
			+ "[マウス] 左ボタン=握る  Shift=両手  Ctrl+Shift=挟む  WASD=移動  P=カメラ映像  H=ヘルプ")
	banner = _label(top, 54, Vector2.ZERO)
	banner.add_theme_font_override("font", font_big)
	banner.set_anchors_preset(Control.PRESET_TOP_WIDE)
	banner.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	banner.offset_top = 110
	banner.add_theme_color_override("font_color", Color(1.0, 0.85, 0.3))
	banner.add_theme_constant_override("outline_size", 16)
	banner.modulate.a = 0.0
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
	l.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.85))
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
	if not ready_to_play:
		return
	_update_hands(dt)
	_update_movement(dt)
	_update_squeeze(dt)
	_update_relaxing(dt)
	_update_camera(dt)
	if banner_time > 0.0:
		banner_time -= dt
		banner.modulate.a = clampf(banner_time, 0.0, 1.0)
		banner.scale = Vector2.ONE * (1.0 + maxf(banner_time - 2.2, 0.0) * 0.6)
	hud.text = "スクイーズ %d棟  ／  合計 %dm" % [score_count, int(score_height)]
	var hm: ShaderMaterial = hand_rect.material
	hm.set_shader_parameter("grip_glow", pressure if active_id >= 0 else 0.0)
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


func _ray(screen: Vector2) -> Dictionary:
	var o := cam.project_ray_origin(screen)
	var d := cam.project_ray_normal(screen)
	return city.pick(o, d, REACH)


func _update_hands(dt: float) -> void:
	for side in [-1, 1]:
		var c: Dictionary = ctl[side]
		var h: HandInput.Hand = input.hands.get(side)
		if h == null:
			c["state"] = State.MOVE
			c["target"] = -1
			c["still"] = 0.0
			continue
		var spd := h.vel.length()
		match c["state"]:
			State.MOVE:
				c["still"] = c["still"] + dt if (h.openness > 0.72 and spd < 0.9) else 0.0
				if c["still"] > 0.18:
					c["state"] = State.AIM
			State.AIM:
				var hit := _ray(h.palm)
				var t: int = hit.get("id", -1)
				if t != c["target"] and t >= 0:
					sfx.play(sfx.select, 1.0, -14.0)
				c["target"] = t
				c["hit"] = hit.get("point", Vector3.ZERO)
				if spd > 1.7:
					c["state"] = State.MOVE
					c["still"] = 0.0
				elif h.openness < 0.42:
					if t >= 0:
						c["state"] = State.GRIP
						_begin_squeeze(t, c["hit"])
					else:
						c["state"] = State.MOVE
			State.GRIP:
				if h.openness > 0.62:
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
		if c["state"] == State.AIM and c["target"] >= 0:
			hl.append(c["target"])
	if press_target >= 0:
		hl.append(press_target)
	hl.append(-1)
	hl.append(-1)
	city.set_hover(hl[0], hl[1], 0.6 + 0.4 * sin(Time.get_ticks_msec() * 0.012))


func _update_movement(dt: float) -> void:
	var pulls := {-1: 0.0, 1: 0.0}
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
		var pull := maxf(h.vel.y - 0.2, 0.0)
		pulls[side] = pull
		c["act"] = lerpf(c["act"], 1.0 if pull > 0.25 else 0.0, 1.0 - exp(-4.0 * dt))
		if pull > 0.7 and not c["stroking"]:
			c["stroking"] = true
		elif pull < 0.1 and c["stroking"]:
			c["stroking"] = false
			sfx.play(sfx.thud, randf_range(0.85, 1.1), -6.0)
			bob = 1.0
			shake = maxf(shake, 0.25)
	var both: bool = visible == 2 and ctl[-1]["act"] > 0.12 and ctl[1]["act"] > 0.12
	var fwd: float = (pulls[-1] + pulls[1]) * FORWARD_K
	var turn: float = (pulls[1] - pulls[-1]) * TURN_K * TURN_SIGN
	if not both:
		fwd *= 0.3
	else:
		turn *= 0.15
	if input.source == "mouse":
		var ax := Input.get_axis(&"ui_down", &"ui_up")
		if Input.is_key_pressed(KEY_W): ax = 1.0
		if Input.is_key_pressed(KEY_S): ax = -1.0
		fwd += ax * 120.0
		var tr := 0.0
		if Input.is_key_pressed(KEY_A) or Input.is_key_pressed(KEY_LEFT): tr = -1.0
		if Input.is_key_pressed(KEY_D) or Input.is_key_pressed(KEY_RIGHT): tr = 1.0
		turn += tr * 4.0
	speed = clampf(speed + fwd * dt, -MAX_SPEED * 0.4, MAX_SPEED)
	yaw_vel -= turn * dt
	speed *= exp(-1.4 * dt)
	yaw_vel *= exp(-3.0 * dt)
	player.rotation.y += yaw_vel * dt
	var forward := -player.global_basis.z
	var p := player.position + forward * speed * dt
	var p2 := city.push_out(Vector2(p.x, p.z), EYE_HEIGHT * 0.75, 25.0)
	p2.x = clampf(p2.x, AREA_LIMIT.position.x, AREA_LIMIT.end.x)
	p2.y = clampf(p2.y, AREA_LIMIT.position.y, AREA_LIMIT.end.y)
	player.position = Vector3(p2.x, 0.0, p2.y)


func _begin_squeeze(id: int, hit: Vector3) -> void:
	if id == active_id:
		return
	_end_squeeze()
	var b: Dictionary = city.buildings[id]
	active_id = id
	active_node = city.detach(id)
	relaxing.erase(id)
	progress = b["damage"]
	grip_y = clampf(hit.y / b["h"], 0.2, 0.8)
	size_factor = clampf(pow(b["h"] * sqrt(b["area"]) / 400.0, 0.4), 0.5, 3.0)
	size_pitch = clampf(1.25 - 0.22 * size_factor, 0.55, 1.2)
	var m: ShaderMaterial = active_node.material_override
	m.set_shader_parameter("grip_y", grip_y)
	shake = maxf(shake, 0.3)
	sfx.play(sfx.cracks.pick_random(), size_pitch, -2.0)


func _end_squeeze() -> void:
	if active_id < 0:
		return
	var b: Dictionary = city.buildings[active_id]
	b["damage"] = progress
	relaxing[active_id] = {"node": active_node, "cur": _visual_squeeze(), "target": progress * 0.45, "jig": 1.0}
	active_id = -1
	active_node = null
	pressure = 0.0


func _visual_squeeze() -> float:
	return clampf(progress * (0.5 + 0.5 * pressure) + pressure * 0.08, 0.0, 1.0)


func _update_squeeze(dt: float) -> void:
	var vp := get_viewport().get_visible_rect().size
	# two open palms pressing together around a building
	var press_pressure := 0.0
	var ha: HandInput.Hand = input.hands.get(-1)
	var hb: HandInput.Hand = input.hands.get(1)
	var both_aim: bool = ha != null and hb != null and ctl[-1]["state"] == State.AIM and ctl[1]["state"] == State.AIM
	if both_aim:
		var mid := (ha.palm + hb.palm) * 0.5
		var d := ha.palm.distance_to(hb.palm)
		var hit := _ray(mid)
		var t: int = hit.get("id", -1)
		if t != press_target or t < 0:
			press_target = t
			press_d0 = d
		else:
			press_d0 = maxf(press_d0, d)
			press_pressure = clampf((press_d0 - d) / maxf(press_d0 * 0.55, 1.0), 0.0, 1.0)
			if press_pressure > 0.12 and active_id != t:
				_begin_squeeze(t, hit["point"])
	else:
		press_target = -1

	if active_id < 0:
		sfx.update_squeeze(dt, false, 0.0, 0.0, 1.0, 0.0)
		return
	var grip_sum := 0.0
	var grippers := 0
	for side in [-1, 1]:
		var c: Dictionary = ctl[side]
		if c["state"] == State.GRIP and c["target"] == active_id:
			var h: HandInput.Hand = input.hands[side]
			grip_sum += clampf((0.62 - h.openness) / 0.45, 0.0, 1.0)
			grippers += 1
	var pressing := press_target == active_id and press_pressure > 0.0
	if grippers == 0 and not pressing:
		_end_squeeze()
		sfx.update_squeeze(dt, false, 0.0, 0.0, 1.0, 0.0)
		return
	two_hand = grippers == 2 or pressing
	pressure = grip_sum / grippers if grippers > 0 else press_pressure
	var pump := maxf(pressure - prev_pressure, 0.0) / maxf(dt, 1e-3)
	prev_pressure = pressure
	var rate := SQUEEZE_RATE * (0.15 + pressure) * (1.8 if two_hand else 1.0) / size_factor
	if pressure > 0.15:
		progress += rate * dt + pump * dt * 0.05 / size_factor
	var m: ShaderMaterial = active_node.material_override
	m.set_shader_parameter("squeeze", _visual_squeeze())
	m.set_shader_parameter("two_hand", 1.0 if two_hand else 0.0)
	m.set_shader_parameter("juice", progress)
	m.set_shader_parameter("jiggle", pressure * 0.15)
	var right := cam.global_basis.x
	m.set_shader_parameter("sq_dir", Vector2(right.x, right.z).normalized())
	shake = maxf(shake, 0.06 + 0.25 * pressure * progress)
	sfx.update_squeeze(dt, true, pressure, progress, size_pitch, pump)
	var b: Dictionary = city.buildings[active_id]
	var center := Vector3(b["center"].x, b["h"] * grip_y, b["center"].y)
	juice_fx.global_position = center
	juice_fx.emission_sphere_radius = b["radius"] * 0.5
	juice_fx.color = b["juice"]
	juice_fx.emitting = pressure > 0.25 and progress > 0.15
	juice_fx.amount_ratio = clampf(pressure * progress * 1.5, 0.1, 1.0)
	if progress >= 1.0:
		_burst(active_id)


func _burst(id: int) -> void:
	var b: Dictionary = city.buildings[id]
	var center := Vector3(b["center"].x, b["h"] * grip_y, b["center"].y)
	sfx.play_burst(size_pitch)
	sfx.update_squeeze(0.0, false, 0.0, 0.0, 1.0, 0.0)
	shake = 1.0 + size_factor * 0.3
	for fx in [juice_fx, debris_fx]:
		var one: CPUParticles3D = fx.duplicate()
		add_child(one)
		one.global_position = center
		one.emission_sphere_radius = b["radius"] * 0.8
		one.one_shot = true
		one.amount_ratio = 1.0
		one.explosiveness = 0.85
		one.initial_velocity_max = 80.0
		one.color = b["juice"] if fx == juice_fx else Color(0.55, 0.55, 0.55)
		one.emitting = true
		get_tree().create_timer(3.0).timeout.connect(one.queue_free)
	juice_fx.emitting = false
	_spawn_puddle(b)
	active_id = -1
	active_node = null
	city.destroy(id)
	score_count += 1
	score_height += b["h"]
	var bname: String = b["name"] if b["name"] != "" else "名もなきビル"
	banner.text = "グジュウゥ〜〜ッ!!\n%s  %dm" % [bname, int(b["h"])]
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
	var s := shake * shake * 3.0
	cam.position = Vector3(randf_range(-s, s), EYE_HEIGHT - sin(bob * PI) * 6.0 + randf_range(-s, s), 0)
	cam.rotation_degrees.z = -yaw_vel * 4.0


# --- overlay ------------------------------------------------------------------------------

func _draw_ui() -> void:
	var font := ThemeDB.fallback_font
	for side in [-1, 1]:
		var h: HandInput.Hand = input.hands.get(side)
		if h == null:
			continue
		var c: Dictionary = ctl[side]
		var r := h.size * 0.7
		match c["state"]:
			State.AIM:
				var col := Color(1.0, 0.6, 0.2) if c["target"] >= 0 else Color(0.5, 1.0, 0.6, 0.7)
				ui.draw_arc(h.palm, r, 0, TAU, 48, col, 4.0, true)
				if c["target"] >= 0:
					var b: Dictionary = city.buildings[c["target"]]
					var bname: String = b["name"] if b["name"] != "" else "ビル"
					ui.draw_string_outline(font, h.palm + Vector2(r + 10, 0), "%s %dm" % [bname, int(b["h"])],
							HORIZONTAL_ALIGNMENT_LEFT, -1, 22, 8, Color(0, 0, 0, 0.8))
					ui.draw_string(font, h.palm + Vector2(r + 10, 0), "%s %dm" % [bname, int(b["h"])],
							HORIZONTAL_ALIGNMENT_LEFT, -1, 22, Color(1, 0.85, 0.6))
			State.GRIP:
				var rr := r * (1.0 - 0.35 * pressure)
				ui.draw_arc(h.palm, rr, 0, TAU, 48, Color(1, 0.25, 0.2, 0.9), 5.0, true)
				if c["target"] == active_id:
					ui.draw_arc(h.palm, rr + 10, -PI * 0.5, -PI * 0.5 + TAU * clampf(progress, 0, 1), 48,
							Color(1, 0.9, 0.2), 8.0, true)
	var ha: HandInput.Hand = input.hands.get(-1)
	var hb: HandInput.Hand = input.hands.get(1)
	if ha != null and hb != null and press_target >= 0:
		ui.draw_dashed_line(ha.palm, hb.palm, Color(1, 0.6, 0.2, 0.8), 4.0, 16.0)
		ui.draw_circle((ha.palm + hb.palm) * 0.5, 8.0, Color(1, 0.6, 0.2))
