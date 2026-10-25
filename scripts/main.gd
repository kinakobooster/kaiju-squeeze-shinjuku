extends Node3D
## Kaiju Squeeze Shinjuku: crawl through Shinjuku with your webcam hands and squeeze buildings.
##
## Thumbs-up (いいね) hands move you: both thumbs pumped up and down = walk forward,
## one thumb wiggled = turn towards that hand's side.
## Any other hand destroys: open palm held still = AIM (pick a building under the palm)
##   -> close the fist = GRIP. The building is crushed exactly as far as the fist is closed:
##      snap it shut for a crisp "サクッ", close slowly for a long "グジュー".
## Slapping towards the screen (or a very fast swipe) smashes the building under the palm.
## You start small; every crushed building makes you grow so you can take on taller ones.

enum State { MOVE, AIM, GRIP, PINCH }

const EYE_START := 30.0
const EYE_MAX := 175.0
const CRUSH_RATIO := 1.6  # can crush buildings up to eye height * this
const WALK_K := 130.0  # forward push per unit of thumbs-up pumping (long strides)
const TURN_K := 1.6  # turn rate per unit of one-thumb wiggling
const CAM_PITCH := -15.0
const MAX_SPEED := 160.0
const CHARGE_TIME := 2.5  # seconds for an open palm to grow to full size
const GRIP_OPEN := 0.7  # openness below this starts a grip
const FIST_OPEN := 0.12  # openness at which the building is fully crushed
const RELEASE_OPEN := 0.8
const SNAP_TIME := 0.3  # crushed faster than this = サクッ
const SLAP_GROW := 2.2  # hand size growth per second that counts as a slap
const SLAP_SPEED := 4.5  # screen heights per second that counts as a smash
const PINCH_OPEN := 0.75  # thumb-index gap (hand sizes) where a pinch starts
const PINCH_SHUT := 0.18  # gap at which the pinched building is crushed
const AREA_LIMIT := Rect2(-1150, -1050, 2300, 2100)
const BOSS_TIME := 180.0  # the alien of justice lands after three minutes
const EYE_MIN := 15.0  # shrink below this and the alien wins
const ITEMS := {
	"beam": {"name": "ビーム", "color": Color(1.0, 0.45, 0.8), "time": 15.0,
			"how": "口を大きく開けるとビーム！ 顔を動かして振り回せ"},
	"claw": {"name": "クロー", "color": Color(0.8, 0.95, 1.0), "time": 20.0,
			"how": "爪がのびた！ 腕を振るとリーチ1.5倍"},
	"midas": {"name": "ミダス", "color": Color(1.0, 0.8, 0.15), "time": 15.0,
			"how": "いいね移動が超高速！ ぶつかったビルは ぜんぶ金になる"},
	"smile": {"name": "スマイル", "color": Color(1.0, 0.88, 0.25), "time": 15.0,
			"how": "笑顔で 真ん中のビルが凍りつく！ 握るとしゃりしゃり"},
}
const GUARD_RADIUS := 0.2  # screen heights: an open palm this close to the incoming fist catches it

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
var bead_sites: Array[Dictionary] = []  # {center: Vector2, radius, node, cool, bounce}
var popups: Array[Dictionary] = []  # {text, pos, t}
var pitch := CAM_PITCH
var look_down := 0.0  # 0 = looking out over the city, 1 = looking down at our hands

# items
var item_node: Node3D
var item_kind := ""
var item_pos := Vector2.ZERO
var item_timer := 20.0
var active_item := ""
var active_time := 0.0
var beam_mesh: MeshInstance3D
var beam_heat := {}  # building id -> seconds under the beam
var smile_cool := 0.0
var stomp_cool := 0.0

# boss fight
var boss: Boss
var boss_timer := BOSS_TIME
var game_state := "title"  # title, play, boss, won, lost
var start_pos := Vector3.ZERO
var title_label: Label
var boss_crush := 0.0  # how far the knocked-out alien has been squeezed (0..1)
var gyuu_cool := 0.0
var boss_landing := false
var hit_flash := 0.0
var guard_flash := 0.0
var grab_ready := {-1: false, 1: false}
var end_time := 0.0
var restart_hold := 0.0
var end_label: Label
var eye := EYE_START
var eye_target := EYE_START
var ready_to_play := false
var clock := 0.0

# active squeeze
var active_ids: Array[int] = []  # the buildings being squeezed together
var active_nodes := {}  # id -> deformable MeshInstance3D
var closure := 0.0
var grip_start := 0.0
var grip_y := 0.5
var size_pitch := 1.0
var two_hand := false
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
	_setup_beam()
	loading.visible = false
	if OS.has_feature("web"):  # ?boss=10 brings the alien early (for trying the fight)
		var q := str(JavaScriptBridge.eval("location.search", true))
		var m := RegEx.create_from_string("boss=(\\d+)").search(q)
		if m:
			boss_timer = float(m.get_string(1))
	ready_to_play = true


func crush_limit() -> float:
	return eye * CRUSH_RATIO


func reach(mult := 1.0) -> float:
	return (16.0 + eye * 0.5) * mult


## Size of a hand's shadow (palm to fingertips is about 0.9 of this).
func hand_size() -> float:
	return eye * 0.18


# --- setup --------------------------------------------------------------------------------

func _setup_world() -> void:
	var env := Environment.new()
	var sky_mat := ProceduralSkyMaterial.new()
	sky_mat.sky_top_color = Color(0.45, 0.25, 0.85)
	sky_mat.sky_horizon_color = Color(1.0, 0.72, 0.95)
	sky_mat.sky_curve = 0.25
	sky_mat.ground_horizon_color = Color(0.75, 0.45, 0.85)
	sky_mat.ground_bottom_color = Color(0.2, 0.1, 0.3)
	sky_mat.sun_angle_max = 12.0
	var sky := Sky.new()
	sky.sky_material = sky_mat
	env.background_mode = Environment.BG_SKY
	env.sky = sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(1.0, 0.97, 1.0)
	env.ambient_light_energy = 0.55
	env.tonemap_mode = Environment.TONE_MAPPER_LINEAR
	env.fog_enabled = true
	env.fog_mode = Environment.FOG_MODE_DEPTH
	env.fog_light_color = Color(0.92, 0.78, 1.0)
	env.fog_depth_begin = 500.0
	env.fog_depth_end = 2400.0
	env.fog_density = 1.0
	env.glow_enabled = true
	env.glow_intensity = 0.8
	env.glow_bloom = 0.08
	var we := WorldEnvironment.new()
	we.environment = env
	add_child(we)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-20, -100, 0)
	sun.light_color = Color(1.0, 0.98, 0.95)
	sun.light_energy = 0.75
	add_child(sun)
	add_child(player)
	# start on the north edge of Shinjuku Gyoen, right next to a block of small buildings
	player.position = Vector3(762, 0, 148)
	player.rotation.y = 0.07  # facing north into the block, the station off to the left
	cam.rotation_degrees.x = CAM_PITCH
	cam.fov = 75.0
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
	help.text = ("両手でいいねして上下に振る = 前進 ／ 片手のいいねを揺らす = その手の方へ旋回\n"
			+ "パーで止める = 手のひらに魔眼が開き、手がだんだん大きくなる ／ 手の下のビルが全部赤く震える ／ 素早くグー = サクッ！ ／ ゆっくりグー = グジュウ〜 ／ 二本指でつまむ = プチッ！\n"
			+ "画面に向かって叩く = 手と腕の影の下をまとめてドドド！ ／ 両手で握る or パーで挟む = 両手スクイーズ ／ 潰すほど大きくなる\n"
			+ "[マウス] 左長押し=握る  Space=素早く握る  Q=つまむ  右=叩く  T=いいね  B=口を開ける  F=笑顔  WASD=移動  H=ヘルプ")
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
	hint.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	hint.offset_top = -200
	hint.offset_bottom = -160
	hint.modulate.a = 0.0
	loading = _label(top, 40, Vector2.ZERO)
	loading.add_theme_font_override("font", font_big)
	loading.set_anchors_preset(Control.PRESET_CENTER)
	loading.grow_horizontal = Control.GROW_DIRECTION_BOTH
	loading.grow_vertical = Control.GROW_DIRECTION_BOTH
	loading.text = "新宿を読み込み中…"
	end_label = _label(top, 44, Vector2.ZERO)
	end_label.add_theme_font_override("font", font_big)
	end_label.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	end_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	end_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	end_label.add_theme_color_override("font_outline_color", Color(0.35, 0.05, 0.45))
	end_label.add_theme_constant_override("outline_size", 18)
	end_label.visible = false
	title_label = _label(top, 46, Vector2.ZERO)
	title_label.add_theme_font_override("font", font_big)
	title_label.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	title_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	title_label.add_theme_color_override("font_color", Color(1.0, 0.9, 0.35))
	title_label.add_theme_color_override("font_outline_color", Color(0.35, 0.05, 0.45))
	title_label.add_theme_constant_override("outline_size", 18)
	title_label.text = "かいじゅう スクイーズ 新宿\n\n両手で いいね して\n上下に振って 前進で スタート！"


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
	_update_shadows_and_beads(dt)
	_update_boss(dt)
	_update_items(dt)
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
	if game_state == "play":
		hud.text += "  ／  宇宙人まで %d:%02d" % [int(boss_timer) / 60, int(boss_timer) % 60]
	silhouette.claw_scale = 3.0 if active_item == "claw" else 1.0
	var hm: ShaderMaterial = hand_rect.material
	hm.set_shader_parameter("grip_glow", closure if not active_ids.is_empty() else 0.0)
	ui.queue_redraw()


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_H:
			help.visible = not help.visible
		elif event.keycode == KEY_R and (game_state == "won" or game_state == "lost"):
			get_tree().reload_current_scene()
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


## The building under a screen point, if it is within arm's reach of our body.
func _ray(screen: Vector2) -> Dictionary:
	var o := cam.project_ray_origin(screen)
	var d := cam.project_ray_normal(screen)
	var hit := city.pick(o, d, eye * 3.0 + reach() * 2.0)
	if hit.is_empty():
		return hit
	var p: Vector3 = hit["point"]
	if Vector2(p.x - player.position.x, p.z - player.position.z).length() > reach():
		return {}
	return hit


func _crushable(id: int) -> bool:
	return city.effective_height(id) <= crush_limit()


func _too_hard(id: int) -> void:
	var b: Dictionary = city.buildings[id]
	sfx.play_hard()
	shake = maxf(shake, 0.35)
	hint.text = "かたい！ %dmのビルには あと%dm 大きくならないと…" % [
		int(b["h"]), int(ceil(city.effective_height(id) / CRUSH_RATIO - eye))]
	hint_time = 2.0


func _is_slap(h: HandInput.Hand, c: Dictionary) -> bool:
	return c["cool"] <= 0.0 and h.seen > 0.3 \
			and (h.grow > SLAP_GROW or (h.vel.length() > SLAP_SPEED and input.source == "camera"))


func _update_hands(dt: float) -> void:
	var lit: Array[int] = []
	for side in [-1, 1]:
		var c: Dictionary = ctl[side]
		var h: HandInput.Hand = input.hands.get(side)
		c["cool"] = maxf(c["cool"] - dt, 0.0)
		if h == null:
			_reset_hand(c)
			continue
		# where the hand's shadow is: slaps and items work there
		var tg := _hand_target(h)
		c["world"] = tg["world"]
		if h.like or game_state == "title":  # before the start, hands only walk
			_reset_hand(c)
			h.charge = move_toward(h.charge, 0.0, dt * 2.0)
			continue
		var spd := h.vel.length()
		if game_state != "play" and boss != null and _palm_on_boss(h.palm):
			_reset_hand(c)
			h.charge = move_toward(h.charge, 0.0, dt * 2.0)
			if not boss.stunned and _is_slap(h, c):
				c["cool"] = 0.35
				_hit_boss(h.palm)
			continue
		if game_state == "won" or game_state == "lost":
			continue
		# slapping flattens everything under the hand and arm shadow
		if c["state"] != State.GRIP and c["state"] != State.PINCH and _is_slap(h, c):
			c["cool"] = 0.45
			_slap(h, c, tg)
			continue
		match c["state"]:
			State.MOVE:
				h.charge = move_toward(h.charge, 0.0, dt * 2.0)
				c["still"] = c["still"] + dt if (h.openness > 0.75 and spd < 0.9) else 0.0
				if c["still"] > 0.18:
					c["state"] = State.AIM  # the eye in the palm opens
					c["pinch0"] = h.pinch
					sfx.play(sfx.freeze, 0.7, -12.0)
			State.AIM:
				# the open hand slowly grows; every building it covers shivers in fear
				h.charge = minf(h.charge + dt / CHARGE_TIME, 1.0)
				var ts := _cover_targets(h)
				if ts.size() > c["targets"].size():
					sfx.play(sfx.select, 0.8 + 0.04 * ts.size(), -16.0)
				c["targets"] = ts
				c["target"] = ts[0] if not ts.is_empty() else -1
				c["hit"] = tg["point"]
				lit.append_array(ts)
				c["pinch0"] = maxf(c.get("pinch0", 0.0), h.pinch)
				if spd > 1.7:
					_reset_hand(c)
				elif h.others_open > 0.8 and c["pinch0"] > PINCH_OPEN and h.pinch < PINCH_OPEN - 0.15:
					# thumb and index closing while the other fingers stay up = pinch
					if ts.is_empty():
						_reset_hand(c)
					else:
						c["state"] = State.PINCH
						_grab(ts, c["hit"])
				elif h.openness < GRIP_OPEN and h.others_open < 0.6:
					if ts.is_empty():
						_reset_hand(c)
					else:
						c["state"] = State.GRIP
						_grab(ts, c["hit"])
			State.GRIP:
				if h.openness > RELEASE_OPEN:
					_reset_hand(c)
			State.PINCH:
				if h.pinch > PINCH_OPEN + 0.1 or h.others_open < 0.3:
					_reset_hand(c)
	city.set_hover(lit, 0.6 + 0.4 * sin(Time.get_ticks_msec() * 0.012))


func _reset_hand(c: Dictionary) -> void:
	c["state"] = State.MOVE
	c["target"] = -1
	c["targets"] = [] as Array[int]
	c["still"] = 0.0


## Every crushable building under the (growing) hand on screen, nearest the palm first.
## The hand's reach grows with it.
func _cover_targets(h: HandInput.Hand) -> Array[int]:
	var vp := get_viewport().get_visible_rect().size
	var disp := h.size * HandSilhouette.draw_scale(h, vp.y)
	var up := (h.pts[9] - h.pts[0]).normalized()
	var center := h.palm + up * disp * 0.35
	var radius := disp * 1.15
	var me := Vector2(player.position.x, player.position.z)
	var found := []
	for id in city.buildings_in_capsule(me, me, reach(1.0 + 1.5 * h.charge)):
		if not _crushable(id):
			continue
		var b: Dictionary = city.buildings[id]
		var w := Vector3(b["center"].x, city.effective_height(id) * 0.5, b["center"].y)
		if cam.is_position_behind(w):
			continue
		var d := cam.unproject_position(w).distance_to(center)
		if d < radius:
			found.append([d, id])
	found.sort_custom(func(x, y): return x[0] < y[0])
	var out: Array[int] = []
	for f in found.slice(0, 30):
		out.append(f[1])
	return out


func _update_movement(dt: float) -> void:
	var likes: Array[HandInput.Hand] = []
	for side in [-1, 1]:
		var h: HandInput.Hand = input.hands.get(side)
		if h != null and h.like:
			likes.append(h)
	var fwd_acc := 0.0
	var yaw_acc := 0.0
	var k := eye / 115.0
	if likes.size() == 2:
		# both thumbs up, pumped up and down = marching forward
		var pump := (absf(likes[0].vel.y) + absf(likes[1].vel.y)) * 0.5
		fwd_acc = maxf(pump - 0.15, 0.0) * WALK_K * k
	elif likes.size() == 1:
		# one thumb wiggled = turn towards that hand's side (right hand -> right)
		var h := likes[0]
		var wiggle := maxf(h.vel.length() - 0.15, 0.0)
		yaw_acc = -h.side * minf(wiggle, 3.0) * TURN_K
	for side in [-1, 1]:
		var h: HandInput.Hand = input.hands.get(side)
		var c: Dictionary = ctl[side]
		var moving := h != null and h.like and absf(h.vel.y) > 0.6
		if moving and not c["stroking"]:
			c["stroking"] = true
		elif not moving and c["stroking"]:
			c["stroking"] = false
			if likes.size() == 2:  # a giant footstep, heard but not felt in the camera
				sfx.play(sfx.thud, randf_range(0.85, 1.1) * clampf(60.0 / eye, 0.7, 1.6), -10.0)
	if input.source == "mouse":
		var ax := 0.0
		if Input.is_key_pressed(KEY_W) or Input.is_key_pressed(KEY_UP): ax = 1.0
		if Input.is_key_pressed(KEY_S) or Input.is_key_pressed(KEY_DOWN): ax = -1.0
		fwd_acc += ax * 120.0 * k
		var tr := 0.0
		if Input.is_key_pressed(KEY_A) or Input.is_key_pressed(KEY_LEFT): tr = 1.0
		if Input.is_key_pressed(KEY_D) or Input.is_key_pressed(KEY_RIGHT): tr = -1.0
		yaw_acc += tr * 4.0
	var midas := active_item == "midas"
	if midas:
		fwd_acc *= 2.5
	var top_speed := MAX_SPEED * k * (2.5 if midas else 1.0)
	speed = clampf(speed + fwd_acc * dt, -top_speed * 0.5, top_speed)
	yaw_vel += yaw_acc * dt
	speed *= exp(-1.1 * dt)
	yaw_vel *= exp(-4.0 * dt)
	player.rotation.y += yaw_vel * dt
	var forward := -player.global_basis.z
	var p := player.position + forward * speed * dt
	var here := Vector2(player.position.x, player.position.z)
	var p2 := Vector2(p.x, p.z)
	if midas:  # nothing stops us: whatever we run into turns to gold
		var hit := city.buildings_in_capsule(here, p2, eye * 0.3)
		if not hit.is_empty():
			_gild(hit)
	else:
		p2 = city.push_out(p2, eye * 0.75, eye * 0.2)
	p2.x = clampf(p2.x, AREA_LIMIT.position.x, AREA_LIMIT.end.x)
	p2.y = clampf(p2.y, AREA_LIMIT.position.y, AREA_LIMIT.end.y)
	stomp_cool = maxf(stomp_cool - dt, 0.0)
	if absf(speed) > 3.0 and stomp_cool <= 0.0 and not midas:
		_stomp(here, p2)
	player.position = Vector3(p2.x, 0.0, p2.y)


func _size_pitch(b: Dictionary) -> float:
	var size_factor := clampf(pow(b["h"] * sqrt(b["area"]) / 400.0, 0.4), 0.5, 3.0)
	return clampf(1.25 - 0.22 * size_factor, 0.55, 1.2)


## Start squeezing a group, or add to the group already in a fist.
func _grab(ids: Array[int], hit: Vector3) -> void:
	if active_ids.is_empty():
		_begin_squeeze(ids, hit)
		return
	var extra: Array[int] = []
	for id in ids:
		if not active_ids.has(id):
			extra.append(id)
	var nodes := city.detach_many(extra)
	for id in extra:
		relaxing.erase(id)
		active_ids.append(id)
		active_nodes[id] = nodes[id]


func _begin_squeeze(ids: Array[int], hit: Vector3) -> void:
	_end_squeeze()
	active_ids.assign(ids.slice(0, 30))
	active_nodes = city.detach_many(active_ids)
	closure = 0.0
	grip_start = clock
	var biggest := active_ids[0]
	for id in active_ids:
		relaxing.erase(id)
		var b: Dictionary = city.buildings[id]
		var gy := clampf(hit.y / b["h"], 0.2, 0.8) if id == active_ids[0] else 0.5
		active_nodes[id].material_override.set_shader_parameter("grip_y", gy)
		if b["h"] * b["area"] > city.buildings[biggest]["h"] * city.buildings[biggest]["area"]:
			biggest = id
	grip_y = clampf(hit.y / city.buildings[active_ids[0]]["h"], 0.2, 0.8)
	size_pitch = _size_pitch(city.buildings[biggest])
	sfx.frozen = city.buildings[active_ids[0]].get("frozen", false)


func _end_squeeze() -> void:
	for id in active_ids:
		var b: Dictionary = city.buildings[id]
		if not b["alive"]:
			continue
		b["damage"] = maxf(b["damage"], closure)
		relaxing[id] = {"node": active_nodes[id], "cur": closure, "target": b["damage"] * 0.4, "jig": 1.0}
	active_ids.clear()
	active_nodes.clear()
	closure = 0.0
	juice_fx.emitting = false


func _update_squeeze(dt: float) -> void:
	if active_ids.is_empty():
		sfx.update_squeeze(dt, false, 0.0, 0.0, 1.0)
		return
	# the buildings are crushed exactly as far as the fist (or pinch) is closed
	var now_closure := 0.0
	var closing := 0.0
	var grippers := 0
	var pinching := false
	for side in [-1, 1]:
		var c: Dictionary = ctl[side]
		if c["state"] == State.GRIP:
			var h: HandInput.Hand = input.hands[side]
			now_closure = maxf(now_closure, clampf((GRIP_OPEN - h.openness) / (GRIP_OPEN - FIST_OPEN), 0.0, 1.0))
			closing = maxf(closing, h.close_speed / (GRIP_OPEN - FIST_OPEN))
			grippers += 1
		elif c["state"] == State.PINCH:
			var h: HandInput.Hand = input.hands[side]
			var pc := clampf((PINCH_OPEN - h.pinch) / (PINCH_OPEN - PINCH_SHUT), 0.0, 1.0)
			closing = maxf(closing, (pc - c.get("pinch_prev", pc)) / maxf(dt, 1e-3))
			c["pinch_prev"] = pc
			now_closure = maxf(now_closure, pc)
			grippers += 1
			pinching = true
	if grippers == 0:
		_end_squeeze()
		sfx.update_squeeze(dt, false, 0.0, 0.0, 1.0)
		return
	two_hand = grippers == 2 or pinching  # squeezed between two hands, or two fingers
	closing = maxf(closing, 0.0)
	closure = now_closure
	var right := cam.global_basis.x
	for id in active_ids:
		var m: ShaderMaterial = active_nodes[id].material_override
		m.set_shader_parameter("squeeze", closure * 0.95)
		m.set_shader_parameter("two_hand", 1.0 if two_hand else 0.0)
		m.set_shader_parameter("juice", closure)
		m.set_shader_parameter("jiggle", clampf(closing * 0.08, 0.0, 0.3))
		m.set_shader_parameter("sq_dir", Vector2(right.x, right.z).normalized())
	shake = maxf(shake, 0.05 + 0.2 * closure + 0.1 * clampf(closing, 0.0, 2.0))
	sfx.update_squeeze(dt, true, closing, closure, size_pitch)
	var b: Dictionary = city.buildings[active_ids[0]]
	juice_fx.global_position = Vector3(b["center"].x, b["h"] * grip_y, b["center"].y)
	juice_fx.emission_sphere_radius = b["radius"] * 0.5
	juice_fx.color = b["juice"]
	var sz := clampf(b["radius"] / 45.0, 0.08, 0.7)
	juice_fx.scale_amount_min = 0.5 * sz
	juice_fx.scale_amount_max = 1.4 * sz
	juice_fx.emitting = closing > 0.3 and closure > 0.2
	if closure >= 0.97:
		var elapsed := clock - grip_start
		var style := "pinch" if pinching else ("snap" if elapsed < SNAP_TIME else "squish")
		_crush_group(active_ids.duplicate(), style)


## Sound, shake and banner text for a crush style.
func _style_fx(style: String, pitch: float) -> String:
	match style:
		"ice":
			sfx.play_ice_burst()
			shake = 0.6
			return "シャリシャリ〜ッ!!"
		"snap":
			sfx.play_snap(pitch)
			shake = 0.8
			return "サクッ!!"
		"squish":
			sfx.play_squish(pitch)
			shake = 1.2
			return "グジュウゥ〜〜ッ!!"
		"pinch":
			sfx.play_snap(pitch * 1.3)
			shake = 0.4
			return "プチッ!!"
	sfx.play_slap(pitch)
	shake = 1.0
	return "バチーン!!"


## Everything in the fist goes at once.
func _crush_group(ids: Array[int], style: String) -> void:
	if ids.size() == 1:
		_crush(ids[0], juice_fx.global_position, style)
		return
	if city.buildings[ids[0]].get("frozen", false):
		style = "ice"
	banner.text = _style_fx(style, size_pitch) + "\n%d棟まとめて！" % ids.size()
	for i in mini(ids.size(), 6):  # a rumble behind the main crunch
		get_tree().create_timer(0.06 * (i + 1)).timeout.connect(func():
			sfx.play(sfx.pops.pick_random(), randf_range(0.7, 1.3), -6.0)
			sfx.play(sfx.thud, randf_range(1.0, 1.4), -10.0))
	var before := int(crush_limit())
	for i in ids.size():
		var b: Dictionary = city.buildings[ids[i]]
		relaxing.erase(ids[i])
		_spawn_beads(b)
		eye_target = minf(eye_target + (0.6 + b["h"] * 0.045) * 0.5, EYE_MAX)
		if i < 6:
			for fx in [juice_fx, debris_fx]:
				var one: CPUParticles3D = fx.duplicate()
				add_child(one)
				one.global_position = Vector3(b["center"].x, b["h"] * 0.5, b["center"].y)
				one.emission_sphere_radius = b["radius"] * 0.7
				one.one_shot = true
				one.explosiveness = 1.0 if style != "squish" else 0.7
				one.initial_velocity_max = 110.0 if style != "squish" else 70.0
				one.color = b["juice"] if fx == juice_fx else b["color"]
				var psz := clampf(b["radius"] / 45.0, 0.08, 0.7)
				one.scale_amount_min = 0.5 * psz
				one.scale_amount_max = 1.4 * psz
				one.emitting = true
				get_tree().create_timer(3.0).timeout.connect(one.queue_free)
	active_ids.clear()
	active_nodes.clear()
	closure = 0.0
	juice_fx.emitting = false
	city.destroy_many(ids)
	score_count += ids.size()
	if int(eye_target * CRUSH_RATIO) / 25 > before / 25:
		hint.text = "おおきくなった！ %dmのビルまで潰せる！" % int(eye_target * CRUSH_RATIO)
		hint_time = 2.5
	banner_time = 3.0
	for side in [-1, 1]:
		ctl[side]["target"] = -1
		ctl[side]["targets"] = [] as Array[int]


## style: "snap" (fast fist), "squish" (slow fist), "pinch" (two fingers) or "slap".
func _crush(id: int, at: Vector3, style: String) -> void:
	var b: Dictionary = city.buildings[id]
	var pitch := _size_pitch(b)
	if b.get("frozen", false) and style != "slap":
		style = "ice"
	banner.text = _style_fx(style, pitch)
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
		one.color = b["juice"] if fx == juice_fx else b["color"]
		var sz := clampf(b["radius"] / 45.0, 0.08, 0.7)  # droplets in proportion to the building
		one.scale_amount_min = 0.5 * sz
		one.scale_amount_max = 1.4 * sz
		one.emitting = true
		get_tree().create_timer(3.0).timeout.connect(one.queue_free)
	if active_ids.has(id):
		active_ids.erase(id)
		active_nodes.erase(id)
		if active_ids.is_empty():
			juice_fx.emitting = false
			closure = 0.0
	relaxing.erase(id)
	_spawn_beads(b)
	city.destroy(id)
	score_count += 1
	var bname: String = b["name"] if b["name"] != "" else "名もなきビル"
	banner.text += "\n%s  %dm" % [bname, int(b["h"])]
	var before := int(crush_limit())
	eye_target = minf(eye_target + (0.6 + b["h"] * 0.045) * 0.5, EYE_MAX)
	if int(eye_target * CRUSH_RATIO) / 25 > before / 25:
		hint.text = "おおきくなった！ %dmのビルまで潰せる！" % int(eye_target * CRUSH_RATIO)
		hint_time = 2.5
	banner_time = 3.0
	for side in [-1, 1]:
		if ctl[side]["target"] == id:
			ctl[side]["target"] = -1


## The empty lot fills with silver beads that rattle when you run a hand through them.
func _spawn_beads(b: Dictionary, tint := Color(0.92, 0.94, 1.0)) -> void:
	var poly: PackedVector2Array = b["poly"]
	var rect: Rect2 = b["rect"]
	var center: Vector2 = b["center"]
	var radius: float = b["radius"]
	var count := clampi(int(b["area"] / 5.0), 40, 450)
	var bead_r := clampf(sqrt(b["area"]) / 30.0, 0.7, 2.2)
	var sphere := SphereMesh.new()
	sphere.radius = bead_r
	sphere.height = bead_r * 2.0
	sphere.radial_segments = 10
	sphere.rings = 5
	var m := StandardMaterial3D.new()
	m.albedo_color = tint
	m.metallic = 0.8
	m.roughness = 0.1
	m.emission_enabled = true
	m.emission = tint * 0.65
	sphere.material = m
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.mesh = sphere
	mm.instance_count = count
	var rng := RandomNumberGenerator.new()
	var placed := 0
	var tries := 0
	while placed < count and tries < count * 20:
		tries += 1
		var q := Vector2(rng.randf_range(rect.position.x, rect.end.x), rng.randf_range(rect.position.y, rect.end.y))
		if not Geometry2D.is_point_in_polygon(q, poly):
			continue
		var heap := (1.0 - clampf(q.distance_to(center) / radius, 0.0, 1.0)) * sqrt(b["area"]) * 0.12
		var y := bead_r + rng.randf() * heap
		mm.set_instance_transform(placed, Transform3D(Basis.IDENTITY, Vector3(q.x - center.x, y, q.y - center.y)))
		placed += 1
	mm.visible_instance_count = placed
	var mi := MultiMeshInstance3D.new()
	mi.multimesh = mm
	mi.position = Vector3(center.x, 0.0, center.y)
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mi)
	bead_sites.append({"center": center, "radius": radius, "node": mi, "cool": 0.0, "bounce": 0.0})


## Where a hand is in the world: under the palm, but never further than the arm reaches.
## Its shadow falls there, and whatever building the shadow is on is what the hand acts on.
func _hand_target(h: HandInput.Hand, mult := 1.0) -> Dictionary:
	var o := cam.project_ray_origin(h.palm)
	var d := cam.project_ray_normal(h.palm)
	var hit := city.pick(o, d, eye * 3.0 + reach(mult) * 2.0)  # cast far; reach is applied on the ground
	var p: Vector3
	if not hit.is_empty():
		p = hit["point"]
	elif d.y < -0.01:
		p = o + d * (-o.y / d.y)
	else:
		p = o + Vector3(d.x, 0.0, d.z).normalized() * reach()
	var flat := Vector2(p.x - player.position.x, p.z - player.position.z)
	var id: int = hit.get("id", -1)
	if flat.length() > reach(mult):
		flat = flat.normalized() * reach(mult)
		id = -1
	var q := Vector2(player.position.x, player.position.z) + flat
	if id < 0:
		id = city.building_at(q)
	var y := p.y
	if id >= 0 and hit.get("id", -1) != id:
		y = city.effective_height(id) * 0.6
	return {"id": id, "world": Vector3(q.x, y, q.y), "point": Vector3(q.x, y, q.y)}


## Slap: every building we can crush under the hand and arm shadow goes at once.
func _slap(h: HandInput.Hand, c: Dictionary, tg: Dictionary) -> void:
	var claw := 1.5 if active_item == "claw" else 1.0  # long claws: swings reach further
	if claw > 1.0:
		tg = _hand_target(h, claw)
	var hs := hand_size() * claw
	var w: Vector3 = tg["world"]
	var a := Vector2(w.x, w.z)
	var back := (Vector2(player.position.x, player.position.z) - a).normalized()
	var arm_end := a + back * hs * 1.6
	var ids: Array[int] = []
	var hard := -1
	for id in city.buildings_in_capsule(a, arm_end, hs * 0.4):
		# the building under the palm, plus anything small next to us under the arm
		if id == tg["id"]:
			if _crushable(id):
				ids.append(id)
			else:
				hard = id
		elif city.effective_height(id) <= eye * 0.5:
			ids.append(id)
	if ids.is_empty():
		if hard >= 0:
			_too_hard(hard)
		return
	if ids.size() == 1:
		_crush(ids[0], Vector3(w.x, w.y, w.z), "slap")
		return
	_crush_many(ids, a)


func _any_active(ids: Array[int]) -> bool:
	for id in ids:
		if active_ids.has(id):
			return true
	return false


func _crush_many(ids: Array[int], at: Vector2) -> void:
	ids.sort_custom(func(x, y): return city.buildings[x]["center"].distance_to(at) < city.buildings[y]["center"].distance_to(at))
	if ids.size() > 30:
		ids = ids.slice(0, 30)
	if _any_active(ids):
		_end_squeeze()
	var grown := 0.0
	for i in ids.size():
		var b: Dictionary = city.buildings[ids[i]]
		relaxing.erase(ids[i])
		_spawn_beads(b)
		grown += (0.3 + b["h"] * 0.02) * 0.5
		if i < 6:  # a few bursts of confetti, not thirty
			var one: CPUParticles3D = debris_fx.duplicate()
			add_child(one)
			one.global_position = Vector3(b["center"].x, b["h"] * 0.5, b["center"].y)
			one.emission_sphere_radius = b["radius"] * 0.7
			one.one_shot = true
			one.explosiveness = 1.0
			one.initial_velocity_max = 90.0
			one.color = b["color"]
			var sz := clampf(b["radius"] / 45.0, 0.08, 0.7)
			one.scale_amount_min = 0.5 * sz
			one.scale_amount_max = 1.4 * sz
			one.emitting = true
			get_tree().create_timer(3.0).timeout.connect(one.queue_free)
	city.destroy_many(ids)
	score_count += ids.size()
	eye_target = minf(eye_target + grown, EYE_MAX)
	# ドドドドッ: a rumble of thuds and crunches
	for i in mini(ids.size(), 7):
		get_tree().create_timer(0.07 * i).timeout.connect(func():
			sfx.play(sfx.thud, randf_range(0.9, 1.4), -4.0)
			sfx.play(sfx.snaps.pick_random(), randf_range(0.9, 1.3), -6.0))
	shake = 1.3
	banner.text = "ドドドドッ!!\n%d棟まとめて！" % ids.size()
	banner_time = 3.0
	for side in [-1, 1]:
		if ids.has(ctl[side]["target"]):
			ctl[side]["target"] = -1


func _update_shadows_and_beads(dt: float) -> void:
	# shadows projected onto the city (shaders/kaiju_shadow.gdshaderinc): the body stretches
	# out in front of us and each hand's shadow shows where it can reach
	var rs := RenderingServer
	rs.global_shader_parameter_set(&"kaiju_yaw", player.rotation.y)
	var fwd := -player.global_basis.z
	rs.global_shader_parameter_set(&"kaiju_body", Vector4(player.position.x - fwd.x * eye * 0.35,
			player.position.z - fwd.z * eye * 0.35, 2.5 if active_item == "claw" else 1.0, eye))
	var grow := 0.0
	for h in input.hands.values():
		grow = maxf(grow, h.charge)
	rs.global_shader_parameter_set(&"kaiju_reach",
			Vector4(player.position.x, player.position.z, reach(1.0 + 1.5 * grow), look_down))
	for side in [-1, 1]:
		var h: HandInput.Hand = input.hands.get(side)
		var param := &"kaiju_hand_r" if side > 0 else &"kaiju_hand_l"
		if h == null:
			rs.global_shader_parameter_set(param, Vector4(0, 0, 0, 1))
			continue
		var w: Vector3 = ctl[side].get("world", Vector3.ZERO)
		var hs := hand_size() * (1.0 + 1.5 * h.charge)
		rs.global_shader_parameter_set(param, Vector4(w.x, w.z, hs, 0.15 if h.like else h.openness))
		# stroking a bead pile
		if h.vel.length() < 0.35:
			continue
		var w2 := Vector2(w.x, w.z)
		for site in bead_sites:
			if site["cool"] <= 0.0 and w2.distance_to(site["center"]) < site["radius"] + hs * 0.3:
				site["cool"] = 0.28
				site["bounce"] = 1.0
				sfx.play_beads(clampf(h.vel.length() / 2.0, 0.0, 1.0))
	for site in bead_sites:
		site["cool"] = maxf(site["cool"] - dt, 0.0)
		site["bounce"] = maxf(site["bounce"] - dt * 3.0, 0.0)
		var bounce: float = site["bounce"]
		site["node"].scale = Vector3(1.0, 1.0 + sin(bounce * PI * 3.0) * bounce * 0.4, 1.0)
	for pop in popups:
		pop["t"] += dt
	popups = popups.filter(func(pop): return pop["t"] < 0.9)


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
	shake = maxf(shake - dt * 2.5, 0.0)
	var s := shake * shake * 1.5 * clampf(eye / 80.0, 0.4, 1.5)
	var reaching := false
	for h in input.hands.values():
		reaching = reaching or not h.like
	var fighting := boss != null and game_state != "play"
	look_down = lerpf(look_down, 1.0 if reaching and not fighting else 0.0, 1.0 - exp(-2.5 * dt))
	cam.position = Vector3(randf_range(-s, s), eye + randf_range(-s, s), eye * 0.3 * look_down)
	var want := lerpf(CAM_PITCH, -35.0, look_down)
	if boss != null and game_state != "play":  # look the alien in the chest
		var flat := Vector2(boss.position.x - player.position.x, boss.position.z - player.position.z).length()
		want = clampf(rad_to_deg(atan2(boss.chest().y - eye, maxf(flat, 1.0))), CAM_PITCH, 42.0)
	pitch = lerpf(pitch, want, 1.0 - exp(-3.0 * dt)) if fighting else want
	cam.rotation_degrees = Vector3(pitch, 0.0, 0.0)


# --- boss fight ---------------------------------------------------------------------------

func punch_loss() -> float:
	return 6.0 + eye_target * 0.1


func _boss_distance() -> float:
	return 280.0 + eye * 0.5


func _update_boss(dt: float) -> void:
	hit_flash = maxf(hit_flash - dt * 2.0, 0.0)
	guard_flash = maxf(guard_flash - dt * 3.0, 0.0)
	match game_state:
		"title":
			title_label.modulate.a = 0.75 + 0.25 * sin(Time.get_ticks_msec() * 0.005)
			if start_pos == Vector3.ZERO:
				start_pos = player.position
			if player.position.distance_to(start_pos) > 12.0:
				game_state = "play"
				title_label.visible = false
				banner.text = "スタート！"
				banner_time = 2.0
				sfx.play_star_pop()
		"play":
			boss_timer -= dt
			if boss_timer <= 0.0:
				_spawn_boss()
		"boss":
			_fight(dt)
		_:
			end_time += dt
			if boss != null:
				boss.tick(dt, cam.global_basis.x)
			# both hands open and held up for a moment = play again
			var open := 0
			for h in input.hands.values():
				if h.openness > 0.8 and not h.like:
					open += 1
			restart_hold = restart_hold + dt if open == 2 and end_time > 2.0 else 0.0
			if restart_hold > 1.5:
				get_tree().reload_current_scene()


func _spawn_boss() -> void:
	game_state = "boss"
	boss = Boss.new()
	add_child(boss)
	var fwd := -player.global_basis.z
	var at := player.position + fwd * _boss_distance()
	boss.position = Vector3(at.x, 700.0, at.z)
	boss_landing = true
	_end_squeeze()
	banner.text = "身長500m せいぎの宇宙人が\nあらわれた！！"
	banner_time = 3.0
	hint.text = "パンチは 手の形に手を合わせてガード！ 叩いて反撃！ 大きいほど有利！"
	hint_time = 5.0


func _fight(dt: float) -> void:
	var to := Vector2(boss.position.x - player.position.x, boss.position.z - player.position.z)
	var dir := to.normalized() if to.length() > 1.0 else Vector2(-player.global_basis.z.x, -player.global_basis.z.z)
	if boss_landing:
		boss.position.y = move_toward(boss.position.y, 0.0, dt * 600.0)
		if boss.position.y <= 0.0:
			boss_landing = false
			shake = 1.5
			sfx.play(sfx.thud, 0.5, 4.0)
			sfx.play(sfx.burst, 0.6, -2.0)
			var foot := Vector2(boss.position.x, boss.position.z)
			for id in city.buildings.size():  # whatever it landed on is gone
				var b: Dictionary = city.buildings[id]
				if b["alive"] and foot.distance_to(b["center"]) < 45.0 * Boss.SIZE + b["radius"] * 0.5:
					city.destroy(id)
	else:
		var want := Vector2(player.position.x, player.position.z) + dir * _boss_distance()
		var cur := Vector2(boss.position.x, boss.position.z).lerp(want, 1.0 - exp(-0.8 * dt))
		boss.position = Vector3(cur.x, 0.0, cur.y)
	boss.look_at(Vector3(player.position.x, boss.position.y, player.position.z), Vector3.UP)
	# keep the alien in front of us
	var face := atan2(-dir.x, -dir.y)
	player.rotation.y = lerp_angle(player.rotation.y, face, 1.0 - exp(-2.5 * dt))
	var impact := boss.tick(dt, cam.global_basis.x)
	if boss_landing:
		return
	if boss.stunned:
		_crush_boss(dt)
		return
	if boss.phase == Boss.Phase.IDLE:
		boss.next_punch -= dt
		if boss.next_punch <= 0.0:
			var combo := boss.combo
			var side := -boss.punch_side if combo else (1 if randf() < 0.5 else -1)
			var cb := cam.global_basis
			var target := cam.global_position - cb.z * (eye * 0.5 + 15.0) + cb.x * side * eye * 0.22 - cb.y * eye * 0.06
			boss.start_punch(target, side, 0.65 if combo else Boss.WINDUP_TIME)
			boss.combo = false
			boss.next_punch = randf_range(0.6, 1.6) * (0.6 + 0.4 * boss.hp / 100.0)
	if impact:
		_resolve_punch()
		if randf() < 0.4:  # one-two: a quick second punch from the other side
			boss.combo = true
			boss.next_punch = 0.2


func _punch_spot() -> Vector2:
	return cam.unproject_position(boss.punch_target)


func _resolve_punch() -> void:
	var spot := _punch_spot()
	var vp := get_viewport().get_visible_rect().size
	for h in input.hands.values():
		if h.like or h.openness < 0.45:
			continue
		if h.palm.distance_to(spot) < vp.y * GUARD_RADIUS:
			guard_flash = 1.0
			shake = maxf(shake, 0.3)
			sfx.play(sfx.thud, 1.5, -2.0)
			sfx.play(sfx.snaps.pick_random(), 1.4, -6.0)
			popups.append({"text": "ガード！", "pos": spot, "t": 0.0})
			return
	# no hit points: every punch knocks height off you (bigger kaiju can take more punches)
	var loss := punch_loss()
	eye_target -= loss
	eye = minf(eye, eye_target + loss * 0.5)  # visibly shrink right away
	hit_flash = 1.0
	shake = 1.2
	sfx.play(sfx.thud, 0.8, 3.0)
	sfx.play(sfx.cracks.pick_random(), 0.7, 0.0)
	popups.append({"text": "ちぢんだ！ -%dm" % int(round(loss)), "pos": spot, "t": 0.0})
	if eye_target < EYE_MIN:
		_lose()


## Is this screen point on the alien's body? (head-to-hips capsule on screen)
func _palm_on_boss(p: Vector2) -> bool:
	if boss == null or boss_landing:
		return false
	var hip := boss.hip()
	for w in [boss.head(), hip]:
		if cam.is_position_behind(w):
			return false
	var a := cam.unproject_position(boss.head())
	var b := cam.unproject_position(hip)
	var c := cam.unproject_position(boss.chest())
	var r := c.distance_to(cam.unproject_position(boss.chest() + cam.global_basis.x * 45.0 * Boss.SIZE))
	return p.distance_to(Geometry2D.get_closest_point_to_segment(p, a, b)) < r


func _hit_boss(at: Vector2) -> void:
	var dmg := 1.6 * eye / 50.0
	if boss.phase == Boss.Phase.WINDUP:
		dmg *= 1.5  # counter while it winds up
	shake = maxf(shake, 0.6)
	sfx.play_slap(0.8)
	popups.append({"text": "バチーン！ -%d" % maxi(int(dmg), 1), "pos": at, "t": 0.0})
	_damage_boss(dmg)


func _damage_boss(dmg: float) -> void:
	boss.hp = maxf(boss.hp - dmg, 0.0)
	boss.hurt = 1.0
	if boss.hp <= 0.0 and not boss.stunned:
		boss.stunned = true
		boss.phase = Boss.Phase.IDLE
		banner.text = "ひざをついた！"
		banner_time = 2.0
		hint.text = "宇宙人の上でパーにしてから ギュッと握れ！"
		hint_time = 6.0


func _crush_boss(dt: float) -> void:
	var best := 0.0
	var closing := 0.0
	for side in [-1, 1]:
		var h: HandInput.Hand = input.hands.get(side)
		if h == null or h.like or not _palm_on_boss(h.palm):
			grab_ready[side] = false
			continue
		if h.openness > 0.6:
			grab_ready[side] = true
		if grab_ready[side]:
			best = maxf(best, clampf((GRIP_OPEN - h.openness) / (GRIP_OPEN - FIST_OPEN), 0.0, 1.0))
			closing = maxf(closing, h.close_speed / (GRIP_OPEN - FIST_OPEN))
	# every squeeze pushes it a bit further; it never springs all the way back
	closing = maxf(closing, 0.0)
	boss_crush = minf(boss_crush + closing * dt * 0.3, 1.0)
	boss.squash = clampf(boss_crush + best * 0.12, 0.0, 1.0)
	gyuu_cool = maxf(gyuu_cool - dt, 0.0)
	if closing > 0.4 and gyuu_cool <= 0.0:  # ぎゅう〜
		sfx.play(sfx.squish_long, randf_range(0.5, 0.6), 3.0)
		sfx.play(sfx.bottle, 0.55, -2.0)
		gyuu_cool = 1.1
	sfx.update_squeeze(dt, best > 0.02, closing, boss_crush, 0.45)
	shake = maxf(shake, best * 0.4 + closing * 0.1)
	if boss_crush >= 1.0:
		_win()


func _win() -> void:
	game_state = "won"
	sfx.play_squish(0.45)
	sfx.play(sfx.burst, 0.4, 4.0)
	shake = 2.0
	var c := Vector2(boss.position.x, boss.position.z)
	var poly := PackedVector2Array()
	for k in 16:
		poly.append(c + Vector2.from_angle(TAU * k / 16.0) * 75.0)
	var fake := {"poly": poly, "rect": Rect2(c - Vector2(75, 75), Vector2(150, 150)), "center": c,
			"radius": 75.0, "area": PI * 75.0 * 75.0, "juice": Color(1.0, 0.6, 0.85), "color": Color(0.93, 0.93, 1.0)}
	_spawn_beads(fake)
	for fx in [juice_fx, debris_fx]:
		var one: CPUParticles3D = fx.duplicate()
		add_child(one)
		one.global_position = boss.chest()
		one.emission_sphere_radius = 60.0
		one.one_shot = true
		one.explosiveness = 0.9
		one.initial_velocity_max = 160.0
		one.color = fake["juice"] if fx == juice_fx else fake["color"]
		one.emitting = true
		get_tree().create_timer(4.0).timeout.connect(one.queue_free)
	boss.queue_free()
	boss = null
	end_label.text = "勝利！！\nせいぎの宇宙人を スクイーズした！\n\nスクイーズ %d棟 ／ 身長 %dm\n\nRキー か 両手をパーで もう一度" % [score_count, int(eye)]
	end_label.add_theme_color_override("font_color", Color(1.0, 0.88, 0.3))
	end_label.visible = true


func _lose() -> void:
	game_state = "lost"
	end_label.text = "GAME OVER\n殴られて ちぢんでしまった…\n\nスクイーズ %d棟 ／ 身長 %dm\nもっと大きくなってから挑もう！\n\nRキー か 両手をパーで もう一度" % [score_count, int(eye)]
	end_label.add_theme_color_override("font_color", Color(0.75, 0.85, 1.0))
	end_label.visible = true


# --- stomping & items ---------------------------------------------------------------------

## Once we are big, walking flattens small buildings underfoot.
func _stomp(a: Vector2, b: Vector2) -> void:
	var ids: Array[int] = []
	for id in city.buildings_in_capsule(a, b, eye * 0.15):
		if city.effective_height(id) <= eye * 0.3:
			ids.append(id)
	if ids.is_empty():
		return
	stomp_cool = 0.15
	for id in ids:
		_spawn_beads(city.buildings[id])
		eye_target = minf(eye_target + (0.3 + city.buildings[id]["h"] * 0.02) * 0.5, EYE_MAX)
		if active_ids.has(id):
			_end_squeeze()
	city.destroy_many(ids)
	score_count += ids.size()
	sfx.play(sfx.thud, randf_range(0.7, 0.9), -3.0)
	sfx.play(sfx.snaps.pick_random(), randf_range(0.8, 1.0), -8.0)
	var vp := get_viewport().get_visible_rect().size
	popups.append({"text": "ふみっ！" if ids.size() == 1 else "ふみふみっ！ x%d" % ids.size(),
			"pos": Vector2(vp.x * 0.5 - 60, vp.y * 0.85), "t": 0.0})


func _gild(ids: Array[int]) -> void:
	if _any_active(ids):
		_end_squeeze()
	for i in ids.size():
		var b: Dictionary = city.buildings[ids[i]]
		relaxing.erase(ids[i])
		_spawn_beads(b, Color(1.0, 0.8, 0.25))
		eye_target = minf(eye_target + (0.6 + b["h"] * 0.045) * 0.5, EYE_MAX)
		if i < 4:
			var one: CPUParticles3D = debris_fx.duplicate()
			add_child(one)
			one.global_position = Vector3(b["center"].x, b["h"] * 0.5, b["center"].y)
			one.emission_sphere_radius = b["radius"] * 0.7
			one.one_shot = true
			one.explosiveness = 1.0
			one.initial_velocity_max = 100.0
			one.color = Color(1.0, 0.82, 0.25)
			var psz := clampf(b["radius"] / 45.0, 0.08, 0.7)
			one.scale_amount_min = 0.5 * psz
			one.scale_amount_max = 1.4 * psz
			one.emitting = true
			get_tree().create_timer(3.0).timeout.connect(one.queue_free)
	city.destroy_many(ids)
	score_count += ids.size()
	sfx.play_coin()
	sfx.play(sfx.thud, randf_range(0.9, 1.1), -6.0)
	var vp := get_viewport().get_visible_rect().size
	popups.append({"text": "キンキラ！" if ids.size() == 1 else "キンキラ！ x%d" % ids.size(),
			"pos": Vector2(vp.x * 0.5 - 80, vp.y * 0.45), "t": 0.0})


func _setup_beam() -> void:
	beam_mesh = MeshInstance3D.new()
	var cyl := CylinderMesh.new()
	cyl.top_radius = 1.0
	cyl.bottom_radius = 1.0
	cyl.height = 1.0
	cyl.radial_segments = 12
	beam_mesh.mesh = cyl
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.albedo_color = Color(1.0, 0.75, 0.95)
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.albedo_color.a = 0.85
	m.set("disable_fog", true)
	beam_mesh.material_override = m
	beam_mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	beam_mesh.visible = false
	add_child(beam_mesh)


func _update_items(dt: float) -> void:
	if game_state != "play" and game_state != "boss":
		sfx.set_beam(false, 0.0)
		beam_mesh.visible = false
		return
	if item_node == null and active_item == "":
		item_timer -= dt
		if item_timer <= 0.0:
			_spawn_item()
	elif item_node != null:
		var t := Time.get_ticks_msec() / 1000.0
		var ground := 0.0
		var under := city.building_at(item_pos)
		if under >= 0:
			ground = city.effective_height(under)
		item_node.position = Vector3(item_pos.x, ground + eye * (0.12 + sin(t * 3.0) * 0.03), item_pos.y)
		item_node.scale = Vector3.ONE * eye
		item_node.get_child(0).rotation.y += dt * 2.0
		var me := Vector2(player.position.x, player.position.z)
		var got := me.distance_to(item_pos) < eye * 0.3
		for side in [-1, 1]:
			if input.hands.has(side) and ctl[side].has("world"):
				var w: Vector3 = ctl[side]["world"]
				got = got or Vector2(w.x, w.z).distance_to(item_pos) < hand_size() * 0.8
		if got:
			_pick_item()
	if active_item == "":
		sfx.set_beam(false, 0.0)
		beam_mesh.visible = false
		return
	active_time -= dt
	if active_time <= 0.0:
		active_item = ""
		return
	match active_item:
		"beam":
			_update_beam(dt)
		"smile":
			_update_smile(dt)


func _spawn_item() -> void:
	item_kind = ITEMS.keys().pick_random()
	var info: Dictionary = ITEMS[item_kind]
	var fwd := Vector2(-player.global_basis.z.x, -player.global_basis.z.z).normalized()
	item_pos = Vector2(player.position.x, player.position.z) + fwd * eye * 0.55 \
			+ fwd.orthogonal() * randf_range(-0.2, 0.2) * eye
	item_node = Node3D.new()
	var orb := MeshInstance3D.new()
	orb.mesh = _star_mesh()
	orb.scale = Vector3.ONE * 0.07
	var m := StandardMaterial3D.new()
	m.albedo_color = info["color"]
	m.emission_enabled = true
	m.emission = info["color"]
	m.emission_energy_multiplier = 2.0
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	m.no_depth_test = true
	m.set("disable_fog", true)
	orb.material_override = m
	item_node.add_child(orb)
	var label := Label3D.new()
	label.text = info["name"]
	label.font = font_big
	label.font_size = 64
	label.pixel_size = 0.0012
	label.position.y = 0.12
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	label.no_depth_test = true
	label.modulate = info["color"]
	label.outline_modulate = Color(0.35, 0.05, 0.45)
	label.outline_size = 16
	item_node.add_child(label)
	add_child(item_node)
	popups.append({"text": "アイテム！", "pos": get_viewport().get_visible_rect().size * Vector2(0.45, 0.5), "t": 0.0})
	sfx.play_star_pop()


func _pick_item() -> void:
	if item_node == null:
		return
	active_item = item_kind
	var info: Dictionary = ITEMS[active_item]
	active_time = info["time"]
	item_node.queue_free()
	item_node = null
	item_timer = randf_range(25.0, 40.0)
	banner.text = "%s ゲット！" % info["name"]
	banner_time = 2.5
	hint.text = info["how"]
	hint_time = 4.0
	sfx.play_star_pop()
	sfx.play(sfx.freeze, 1.5, -6.0)


## Mouth open = beam from our mouth, aimed by moving the head. Buildings hit pop into stars.
func _update_beam(dt: float) -> void:
	var f: Dictionary = input.face
	var power: float = clampf((f["jaw"] - 0.3) / 0.4, 0.0, 1.0)
	var on: bool = f["seen"] and power > 0.0
	sfx.set_beam(on, power)
	beam_mesh.visible = on
	if not on:
		return
	var vp := get_viewport().get_visible_rect().size
	var c := vp * 0.5
	var aim: Vector2 = c + (f["pos"] - c) * 2.2  # small head moves sweep the whole view
	aim = aim.clamp(Vector2.ZERO, vp)
	var o := cam.project_ray_origin(aim)
	var d := cam.project_ray_normal(aim)
	var cb := cam.global_basis
	var start := cam.global_position - cb.y * eye * 0.06 - cb.z * eye * 0.08
	var end := o + d * 1500.0
	if boss != null and game_state == "boss" and not boss.stunned and _palm_on_boss(aim):
		end = boss.chest()
		_damage_boss(10.0 * dt)
	else:
		var hit := city.pick(o, d, 1500.0)
		if not hit.is_empty():
			end = hit["point"]
			var id: int = hit["id"]
			beam_heat[id] = beam_heat.get(id, 0.0) + dt
			if beam_heat[id] > 0.2:
				_star_burst(id)
	var axis := end - start
	var length := maxf(axis.length(), 1.0)
	var up := axis / length
	var side := up.cross(Vector3.UP if absf(up.y) < 0.95 else Vector3.RIGHT).normalized()
	var r := eye * 0.03 * (0.7 + 0.3 * sin(Time.get_ticks_msec() * 0.05)) * (0.5 + power * 0.5)
	beam_mesh.global_transform = Transform3D(Basis(side * r, up * length, side.cross(up) * r), start + axis * 0.5)


func _star_burst(id: int) -> void:
	var b: Dictionary = city.buildings[id]
	if active_ids.has(id):
		_end_squeeze()
	var stars_fx := CPUParticles3D.new()
	var mesh := _star_mesh()
	var m := StandardMaterial3D.new()
	m.albedo_color = Color(1.0, 0.88, 0.3)
	m.emission_enabled = true
	m.emission = Color(1.0, 0.8, 0.2)
	m.emission_energy_multiplier = 2.0
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	mesh.surface_set_material(0, m)
	stars_fx.mesh = mesh
	stars_fx.amount = 40
	stars_fx.lifetime = 1.8
	stars_fx.one_shot = true
	stars_fx.explosiveness = 1.0
	stars_fx.local_coords = false
	stars_fx.emission_shape = CPUParticles3D.EMISSION_SHAPE_SPHERE
	stars_fx.emission_sphere_radius = b["radius"] * 0.6
	stars_fx.direction = Vector3.UP
	stars_fx.spread = 70.0
	stars_fx.initial_velocity_min = 30.0
	stars_fx.initial_velocity_max = 90.0
	stars_fx.gravity = Vector3(0, -25, 0)
	stars_fx.angular_velocity_min = -360.0
	stars_fx.angular_velocity_max = 360.0
	var sz := clampf(b["radius"] / 6.0, 1.0, 8.0)
	stars_fx.scale_amount_min = sz * 0.5
	stars_fx.scale_amount_max = sz
	add_child(stars_fx)
	stars_fx.global_position = Vector3(b["center"].x, b["h"] * 0.5, b["center"].y)
	stars_fx.emitting = true
	get_tree().create_timer(2.5).timeout.connect(stars_fx.queue_free)
	relaxing.erase(id)
	beam_heat.erase(id)
	for fx in [juice_fx, debris_fx]:  # plus a burst of juice and confetti
		var one: CPUParticles3D = fx.duplicate()
		add_child(one)
		one.global_position = stars_fx.global_position
		one.emission_sphere_radius = b["radius"] * 0.7
		one.one_shot = true
		one.explosiveness = 1.0
		one.initial_velocity_max = 120.0
		one.color = b["juice"] if fx == juice_fx else b["color"]
		var psz := clampf(b["radius"] / 45.0, 0.08, 0.7)
		one.scale_amount_min = 0.5 * psz
		one.scale_amount_max = 1.4 * psz
		one.emitting = true
		get_tree().create_timer(3.0).timeout.connect(one.queue_free)
	city.destroy(id)
	score_count += 1
	eye_target = minf(eye_target + (0.6 + b["h"] * 0.045) * 0.5, EYE_MAX)
	sfx.play_beam_blast(_size_pitch(b))
	shake = maxf(shake, 0.5)
	popups.append({"text": "キラーン！", "pos": cam.unproject_position(stars_fx.global_position), "t": 0.0})


## Smiling freezes the building in the middle of the view.
func _update_smile(dt: float) -> void:
	smile_cool = maxf(smile_cool - dt, 0.0)
	var f: Dictionary = input.face
	if not f["seen"] or f["smile"] < 0.5 or smile_cool > 0.0:
		return
	var vp := get_viewport().get_visible_rect().size
	var hit := city.pick(cam.project_ray_origin(vp * 0.5), cam.project_ray_normal(vp * 0.5), 900.0)
	if hit.is_empty():
		return
	var id: int = hit["id"]
	if city.buildings[id].get("frozen", false):
		return
	city.freeze(id)
	smile_cool = 0.35
	sfx.play(sfx.freeze, randf_range(0.95, 1.1), -2.0)
	popups.append({"text": "カチーン！", "pos": cam.unproject_position(hit["point"]), "t": 0.0})


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
		var disp := h.size * HandSilhouette.draw_scale(h, ui.size.y)
		var up := (h.pts[9] - h.pts[0]).normalized()
		var ts: Array = c.get("targets", [])
		var look := Vector2.ZERO
		if not ts.is_empty():
			var b: Dictionary = city.buildings[ts[0]]
			var w := Vector3(b["center"].x, city.effective_height(ts[0]) * 0.5, b["center"].y)
			if not cam.is_position_behind(w):
				look = (cam.unproject_position(w) - h.palm).limit_length(1.0)
		_draw_magic_eye(h.palm + up * disp * 0.05, disp * 0.42, clampf(h.charge * 6.0, 0.0, 1.0), look, h.charge)
		if not ts.is_empty():
			var text := "%d棟 にぎれ！" % ts.size()
			var pos := h.palm + up * disp * 1.4 + Vector2(-60, 0)
			ui.draw_string_outline(font_big, pos, text, HORIZONTAL_ALIGNMENT_LEFT, -1, 28, 10, Color(0.35, 0.02, 0.15, 0.9))
			ui.draw_string(font_big, pos, text, HORIZONTAL_ALIGNMENT_LEFT, -1, 28, Color(1.0, 0.35, 0.45))
	for pop in popups:
		var a: float = 1.0 - pop["t"] / 0.9
		var pos: Vector2 = pop["pos"] - Vector2(0, pop["t"] * 60.0)
		ui.draw_string_outline(font_big, pos, pop["text"], HORIZONTAL_ALIGNMENT_LEFT, -1, 30, 10, Color(0.4, 0.2, 0.6, a))
		ui.draw_string(font_big, pos, pop["text"], HORIZONTAL_ALIGNMENT_LEFT, -1, 30, Color(0.95, 0.97, 1.0, a))
	if boss != null and game_state == "boss" and not boss_landing:
		var vp := ui.size
		if boss.phase == Boss.Phase.WINDUP or boss.phase == Boss.Phase.STRIKE:
			var spot := _punch_spot()
			var u := clampf(boss.phase_t / boss.windup, 0.0, 1.0) if boss.phase == Boss.Phase.WINDUP else 1.0
			var rr := vp.y * GUARD_RADIUS * (1.6 - 0.6 * u)
			var pulse := 0.5 + 0.5 * sin(Time.get_ticks_msec() * 0.03)
			# a hand-shaped target: put your hand on it to catch the punch
			var hand_col := Color(1.0, 0.3, 0.4, 0.5 + 0.5 * pulse)
			_draw_hand_outline(spot, vp.y * 0.17 * (1.3 - 0.3 * u), hand_col, 1 if spot.x > vp.x * 0.5 else -1)
			var label := "手を合わせてガード！"
			var lp := spot + Vector2(-120, -rr - 20)
			ui.draw_string_outline(font_big, lp, label, HORIZONTAL_ALIGNMENT_LEFT, -1, 26, 8, Color(0.4, 0.05, 0.2))
			ui.draw_string(font_big, lp, label, HORIZONTAL_ALIGNMENT_LEFT, -1, 26, Color(1.0, 0.85, 0.9))
		_draw_bar(Vector2(vp.x * 0.5 - 150, 128), "せいぎの宇宙人", boss.hp / 100.0, Color(1.0, 0.6, 0.8))
	if boss != null and boss.stunned and game_state == "boss" and not cam.is_position_behind(boss.chest()):
		var at := cam.unproject_position(boss.chest())
		var fs := int(90.0 + sin(Time.get_ticks_msec() * 0.012) * 12.0)
		var text := "握れ！！"
		var w := font_big.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
		ui.draw_string_outline(font_big, at - Vector2(w * 0.5, 0), text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, 20, Color(0.45, 0.05, 0.3))
		ui.draw_string(font_big, at - Vector2(w * 0.5, 0), text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, Color(1.0, 0.9, 0.3))
	if active_item != "":
		var info: Dictionary = ITEMS[active_item]
		var text := "%s  あと%d秒" % [info["name"], ceili(active_time)]
		var pos := Vector2(ui.size.x - 300, 40)
		ui.draw_string_outline(font_big, pos, text, HORIZONTAL_ALIGNMENT_LEFT, -1, 28, 10, Color(0.3, 0.05, 0.4))
		ui.draw_string(font_big, pos, text, HORIZONTAL_ALIGNMENT_LEFT, -1, 28, info["color"])
	if hit_flash > 0.0:
		ui.draw_rect(Rect2(Vector2.ZERO, ui.size), Color(1.0, 0.2, 0.3, hit_flash * 0.35))
	if guard_flash > 0.0:
		ui.draw_rect(Rect2(Vector2.ZERO, ui.size), Color(1.0, 1.0, 1.0, guard_flash * 0.25))


## The magic eye that opens in an open palm and glares at what it is about to crush.
func _draw_magic_eye(c: Vector2, w: float, open: float, look: Vector2, charge: float) -> void:
	var pulse := 0.5 + 0.5 * sin(Time.get_ticks_msec() * 0.01)
	ui.draw_arc(c, w * (1.25 + 0.1 * pulse), 0, TAU, 48, Color(1.0, 0.3, 0.6, 0.25 + 0.35 * charge), 6.0, true)
	var hgt := w * 0.55 * open
	var outline := Color(0.3, 0.02, 0.25)
	if hgt < 1.5:
		ui.draw_line(c - Vector2(w, 0), c + Vector2(w, 0), outline, 4.0, true)
		return
	var lid := PackedVector2Array()
	for i in 17:
		var t := -1.0 + 2.0 * i / 16.0
		lid.append(c + Vector2(t * w, -(1.0 - t * t) * hgt))
	for i in range(15, 0, -1):
		var t := -1.0 + 2.0 * i / 16.0
		lid.append(c + Vector2(t * w, (1.0 - t * t) * hgt))
	ui.draw_colored_polygon(lid, Color(1.0, 0.95, 0.97))
	var ir := minf(hgt * 0.85, w * 0.45)
	var ic := c + Vector2(look.x * w * 0.35, look.y * hgt * 0.25)
	ui.draw_circle(ic, ir, Color(0.85, 0.05, 0.4))
	ui.draw_circle(ic, ir * 0.7, Color(1.0, 0.35, 0.65))
	var slit := PackedVector2Array()
	for i in 16:
		var a := TAU * i / 16.0
		slit.append(ic + Vector2(cos(a) * ir * 0.16, sin(a) * ir * 0.8))
	ui.draw_colored_polygon(slit, Color(0.1, 0.0, 0.08))
	ui.draw_circle(ic + Vector2(-ir * 0.35, -ir * 0.4), ir * 0.15, Color(1, 1, 1, 0.9))
	lid.append(lid[0])
	ui.draw_polyline(lid, outline, 4.0, true)


## Outline of an open hand (same landmarks as the tracker) centred on its palm.
func _draw_hand_outline(palm: Vector2, size: float, col: Color, side: int) -> void:
	var pts: Array[Vector2] = []
	for q in HandInput.OPEN:
		pts.append(Vector2(q.x * side, q.y))
	var c := (pts[0] + pts[5] + pts[9] + pts[13] + pts[17]) / 5.0
	var to_screen := func(q: Vector2) -> Vector2: return palm + (q - c) * size
	var palm_poly := PackedVector2Array()
	for i in [0, 1, 5, 9, 13, 17]:
		palm_poly.append(to_screen.call(pts[i]))
	palm_poly.append(palm_poly[0])
	ui.draw_polyline(palm_poly, col, 5.0, true)
	for chain in [[1, 2, 3, 4], [5, 6, 7, 8], [9, 10, 11, 12], [13, 14, 15, 16], [17, 18, 19, 20]]:
		var line := PackedVector2Array()
		for i in chain:
			line.append(to_screen.call(pts[i]))
		ui.draw_polyline(line, col, 5.0, true)
		ui.draw_arc(line[-1], size * 0.1, 0, TAU, 16, col, 4.0, true)


func _draw_bar(pos: Vector2, label: String, v: float, col: Color) -> void:
	var w := 300.0
	ui.draw_rect(Rect2(pos, Vector2(w, 18)), Color(0.2, 0.05, 0.3, 0.6))
	ui.draw_rect(Rect2(pos, Vector2(w * clampf(v, 0.0, 1.0), 18)), col)
	ui.draw_rect(Rect2(pos, Vector2(w, 18)), Color(1, 1, 1, 0.8), false, 2.0)
	ui.draw_string_outline(font_big, pos + Vector2(0, -6), label, HORIZONTAL_ALIGNMENT_LEFT, -1, 18, 6, Color(0.3, 0.05, 0.4))
	ui.draw_string(font_big, pos + Vector2(0, -6), label, HORIZONTAL_ALIGNMENT_LEFT, -1, 18, Color.WHITE)
