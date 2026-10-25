class_name Boss
extends Node3D
## The 500m "alien of justice": lands three minutes in and boxes with the kaiju.
## The model is built 200 units tall and scaled up by SIZE.
## It always faces the player; punches are telegraphed (WINDUP), fly at the camera (STRIKE)
## and come back (RECOVER). main.gd decides guard / hit and drives the damage.

enum Phase { IDLE, WINDUP, STRIKE, RECOVER }

const HEIGHT := 200.0  # model units
const SIZE := 2.5  # model units -> metres (500m tall)
const WINDUP_TIME := 1.3
const STRIKE_TIME := 0.18
const RECOVER_TIME := 0.6

var hp := 100.0
var stunned := false
var squash := 0.0  # 0..1 while being crushed at the end
var phase := Phase.IDLE
var phase_t := 0.0
var punch_side := 1  # +1 = its fist on our right side of the screen
var punch_target := Vector3.ZERO  # world point the fist flies to (just in front of the camera)
var next_punch := 2.5
var windup := WINDUP_TIME  # this punch's wind-up (combo follow-ups are quicker)
var combo := false  # the next punch is the second half of a one-two
var hurt := 0.0  # flash when hit

var _rig := Node3D.new()
var _body := Node3D.new()
var _fists := {}  # side -> MeshInstance3D
var _arms := {}  # side -> MeshInstance3D
var _lamp: StandardMaterial3D
var _skin: StandardMaterial3D
var _pink: StandardMaterial3D
var _t := 0.0


func _ready() -> void:
	add_child(_rig)
	_rig.scale = Vector3.ONE * SIZE
	_rig.add_child(_body)
	_skin = _mat(Color(0.93, 0.93, 1.0), 0.0)
	var pink := _mat(Color(1.0, 0.62, 0.82), 0.0)
	_pink = pink
	for m in [_skin, _pink]:  # glows red while it can be grabbed
		m.emission_enabled = true
		m.emission = Color.BLACK
	var eye := _mat(Color(1.0, 0.95, 0.5), 2.2)
	_lamp = _mat(Color(0.5, 0.85, 1.0), 2.5)
	for x in [-16.0, 16.0]:  # legs
		_part(_capsule(12, 90), _skin, Vector3(x, 45, 0))
	_part(_capsule(32, 100), pink, Vector3(0, 115, 0))  # torso
	_part(_capsule(26, 70), _skin, Vector3(0, 112, -6))  # silver front panel
	_part(_sphere(26), _skin, Vector3(0, 178, 0))  # head
	for x in [-11.0, 11.0]:
		var e := _part(_sphere(9), eye, Vector3(x, 182, -21))
		e.scale = Vector3(1.0, 1.4, 0.5)
	_part(_sphere(6), _lamp, Vector3(0, 135, -30))  # chest lamp
	var ant := _part(_capsule(1.5, 26), pink, Vector3(0, 210, 0))
	ant.rotation_degrees.z = 8
	_part(_sphere(5), eye, Vector3(2, 224, 0))
	for side in [-1, 1]:
		_fists[side] = _part(_sphere(15), pink, Vector3.ZERO, _rig)
		_arms[side] = _part(_capsule(9, 1.0), _skin, Vector3.ZERO, _rig)


func _mat(c: Color, glow: float) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = c
	m.roughness = 0.35
	m.metallic = 0.25
	if glow > 0.0:
		m.emission_enabled = true
		m.emission = c
		m.emission_energy_multiplier = glow
	return m


static func _capsule(r: float, h: float) -> CapsuleMesh:
	var m := CapsuleMesh.new()
	m.radius = r
	m.height = maxf(h, r * 2.0)
	return m


static func _sphere(r: float) -> SphereMesh:
	var m := SphereMesh.new()
	m.radius = r
	m.height = r * 2.0
	return m


func _part(mesh: Mesh, mat: Material, pos: Vector3, parent: Node = null) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.material_override = mat
	mi.position = pos
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	(parent if parent else _body).add_child(mi)
	return mi


## Points in world space for hit tests (main.gd projects them to the screen).
func chest() -> Vector3:
	return _rig.global_transform * Vector3(0, 120 * (1.0 - squash * 0.6), 0)


func head() -> Vector3:
	return _rig.global_transform * Vector3(0, 180 * (1.0 - squash * 0.6), 0)


func hip() -> Vector3:
	return _rig.global_transform * Vector3(0, 60 * (1.0 - squash * 0.6), 0)


func fist_position(side: int) -> Vector3:
	return _fists[side].global_position


func start_punch(target: Vector3, side: int, windup_time := WINDUP_TIME) -> void:
	punch_side = side
	punch_target = target
	windup = windup_time
	phase = Phase.WINDUP
	phase_t = 0.0


## Advances the animation. Returns true on the frame the fist arrives (main checks the guard).
func tick(dt: float, camera_right: Vector3) -> bool:
	_t += dt
	phase_t += dt
	hurt = maxf(hurt - dt * 3.0, 0.0)
	var impact := false
	match phase:
		Phase.WINDUP:
			if phase_t >= windup:
				phase = Phase.STRIKE
				phase_t = 0.0
		Phase.STRIKE:
			if phase_t >= STRIKE_TIME:
				phase = Phase.RECOVER
				phase_t = 0.0
				impact = true
		Phase.RECOVER:
			if phase_t >= RECOVER_TIME:
				phase = Phase.IDLE
				phase_t = 0.0
	# body: bob in a boxing stance, kneel when stunned, flatten while being crushed
	var sink := 0.35 if stunned else 0.0
	_body.position.y = -HEIGHT * sink + sin(_t * 4.0) * 3.0 * (0.0 if stunned else 1.0)
	_body.rotation.z = sin(_t * 9.0) * 0.06 if stunned else 0.0
	var twist := 0.0
	var lean := 0.0
	match phase:
		Phase.WINDUP:  # rear way back, shoulders turned away
			var u := ease(phase_t / windup, 0.6)
			twist = punch_side * 0.55 * u
			lean = -0.18 * u
		Phase.STRIKE:
			var u := phase_t / STRIKE_TIME
			twist = lerpf(punch_side * 0.55, -punch_side * 0.35, u)
			lean = lerpf(-0.18, 0.12, u)
		Phase.RECOVER:
			var u := phase_t / RECOVER_TIME
			twist = lerpf(-punch_side * 0.35, 0.0, u)
			lean = lerpf(0.12, 0.0, u)
	_body.rotation.y = twist
	_body.rotation.x = lean
	_body.scale = Vector3(1.0 + squash * 0.7, 1.0 - squash * 0.6, 1.0 + squash * 0.7)
	# knocked out = ready to squeeze: it shivers red like the buildings under your hand
	var grab := (0.6 + 0.4 * sin(_t * 14.0)) if stunned else 0.0
	_body.position.x = sin(_t * 70.0) * 4.0 * hurt + (sin(_t * 53.0) * 2.5 + sin(_t * 79.0) * 1.5) * signf(grab)
	_body.position.z = sin(_t * 61.0) * 2.0 * signf(grab)
	var red := Color(1.0, 0.12, 0.18)
	var flash := Color(1.0, 0.55, 0.55) if hurt > 0.0 else Color(0.93, 0.93, 1.0)
	_skin.albedo_color = flash.lerp(red, grab * 0.75)
	_pink.albedo_color = Color(1.0, 0.62, 0.82).lerp(red, grab * 0.75)
	_skin.emission = red * grab * 0.6
	_pink.emission = red * grab * 0.6
	_lamp.albedo_color = Color(1.0, 0.3, 0.35) if hp < 30.0 and fmod(_t, 0.5) < 0.25 else Color(0.5, 0.85, 1.0)
	_lamp.emission = _lamp.albedo_color
	for side in [-1, 1]:
		var xf := _rig.global_transform
		var k := 1.0 - squash * 0.6
		var shoulder := xf * Vector3(-side * 38.0, (150.0 - HEIGHT * sink) * k, -5.0)
		var guard := xf * Vector3(-side * 26.0, (112.0 - HEIGHT * sink) * k, -45.0)
		var pulled := xf * Vector3(-side * 70.0, (195.0 - HEIGHT * sink) * k, 75.0)  # cocked way back
		var fist := guard
		if side == punch_side:
			match phase:
				Phase.WINDUP:  # haul the fist back over the shoulder, trembling
					var u := ease(phase_t / windup, 0.5)
					fist = guard.lerp(pulled, u) + camera_right * sin(_t * 40.0) * 5.0 * u
				Phase.STRIKE:
					fist = pulled.lerp(punch_target, ease(phase_t / STRIKE_TIME, 0.5))
				Phase.RECOVER:
					fist = punch_target.lerp(guard, ease(phase_t / RECOVER_TIME, 0.4))
		_fists[side].global_position = fist
		_place_arm(_arms[side], shoulder, fist)
	return impact


func _place_arm(arm: MeshInstance3D, a: Vector3, b: Vector3) -> void:
	var mid := (a + b) * 0.5
	var length := maxf(a.distance_to(b), 1.0)
	var up := (b - a).normalized()
	var side := up.cross(Vector3.FORWARD if absf(up.dot(Vector3.FORWARD)) < 0.9 else Vector3.RIGHT).normalized()
	var fwd := side.cross(up)
	arm.global_transform = Transform3D(Basis(side * SIZE, up * length / 18.0, fwd * SIZE), mid)
