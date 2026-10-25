class_name Sfx
extends Node
## Layered squeeze audio: a sustained wet loop whose pitch rises with pressure,
## random bubble pops and concrete cracks on top, and a big burst at the end.

const VOICES := 10

var loop_player: AudioStreamPlayer
var ambience: AudioStreamPlayer
var pops: Array[AudioStream] = []
var cracks: Array[AudioStream] = []
var burst: AudioStream = preload("res://audio/burst.wav")
var thud: AudioStream = preload("res://audio/thud.wav")
var select: AudioStream = preload("res://audio/select.wav")
var _pool: Array[AudioStreamPlayer] = []
var _next := 0
var _loop_vol := 0.0


func _ready() -> void:
	for i in 4:
		pops.append(load("res://audio/pop%d.wav" % i))
	for i in 3:
		cracks.append(load("res://audio/crack%d.wav" % i))
	loop_player = _make_loop(preload("res://audio/squeeze_loop.wav"))
	ambience = _make_loop(preload("res://audio/ambience.wav"))
	ambience.volume_db = -14.0
	ambience.play()
	for i in VOICES:
		var p := AudioStreamPlayer.new()
		add_child(p)
		_pool.append(p)


func _make_loop(stream: AudioStreamWAV) -> AudioStreamPlayer:
	var s: AudioStreamWAV = stream.duplicate()
	s.loop_mode = AudioStreamWAV.LOOP_FORWARD
	s.loop_begin = 0
	s.loop_end = int(s.get_length() * s.mix_rate)
	var p := AudioStreamPlayer.new()
	p.stream = s
	p.volume_db = -80.0
	add_child(p)
	return p


func play(stream: AudioStream, pitch := 1.0, volume_db := 0.0) -> void:
	var p := _pool[_next]
	_next = (_next + 1) % _pool.size()
	p.stream = stream
	p.pitch_scale = clampf(pitch, 0.1, 4.0)
	p.volume_db = volume_db
	p.play()


## Called every frame. grip 0..1 (how hard the fist is closed), progress 0..1 (how squashed),
## size_pitch < 1 for big buildings, pump = grip increase speed (squeezing rhythmically).
func update_squeeze(dt: float, active: bool, grip: float, progress: float, size_pitch: float, pump: float) -> void:
	var target := (0.25 + 0.75 * grip) if active else 0.0
	_loop_vol = move_toward(_loop_vol, target, dt * (6.0 if active else 3.0))
	if _loop_vol > 0.001:
		if not loop_player.playing:
			loop_player.play()
		loop_player.volume_db = linear_to_db(_loop_vol) + 2.0
		# pressure building up: the squelch climbs as the building gives way
		loop_player.pitch_scale = clampf((0.7 + 0.6 * progress + 0.15 * grip) * size_pitch, 0.3, 2.5)
	elif loop_player.playing:
		loop_player.stop()
	if not active:
		return
	var pop_rate := 2.0 + 16.0 * grip * (0.3 + progress) + 50.0 * maxf(pump, 0.0)
	if randf() < pop_rate * dt:
		play(pops.pick_random(), randf_range(0.6, 1.4) * size_pitch, randf_range(-10.0, -3.0))
	var crack_rate := 0.6 + 4.0 * progress * grip
	if randf() < crack_rate * dt:
		play(cracks.pick_random(), randf_range(0.7, 1.2) * size_pitch, randf_range(-12.0, -5.0))


func play_burst(size_pitch: float) -> void:
	play(burst, randf_range(0.9, 1.05) * size_pitch, 2.0)
	for i in 3:
		play(pops.pick_random(), randf_range(0.5, 0.9) * size_pitch, -4.0)
