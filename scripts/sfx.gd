class_name Sfx
extends Node
## Layered squeeze audio. The wet loop only sounds while the fist is actually closing
## (closing slowly = a long "グジュー"), with juicy pops on top. Crushing fast gives a
## crisp "サクッ" instead, and slaps get their own crunch.

const VOICES := 12

var loop_player: AudioStreamPlayer
var ambience: AudioStreamPlayer
var pops: Array[AudioStream] = []
var cracks: Array[AudioStream] = []
var snaps: Array[AudioStream] = []
var squirts: Array[AudioStream] = []
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
		snaps.append(load("res://audio/snap%d.wav" % i))
	for i in 2:
		squirts.append(load("res://audio/squirt%d.wav" % i))
	loop_player = _make_loop(preload("res://audio/squeeze_loop.wav"))
	ambience = _make_loop(preload("res://audio/ambience.wav"))
	ambience.volume_db = -16.0
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


## Called every frame. closing = how fast the fist is closing (closure per second),
## closure 0..1 = how crushed the building is now, size_pitch < 1 for big buildings.
func update_squeeze(dt: float, active: bool, closing: float, closure: float, size_pitch: float) -> void:
	var target := clampf(0.15 + closing * 0.9, 0.0, 1.0) if active else 0.0
	_loop_vol = move_toward(_loop_vol, target, dt * (8.0 if target > _loop_vol else 3.0))
	if _loop_vol > 0.001:
		if not loop_player.playing:
			loop_player.play(randf() * 2.5)
		loop_player.volume_db = linear_to_db(_loop_vol) + 3.0
		# pressure building up: the squelch climbs as the building gives way
		loop_player.pitch_scale = clampf((0.85 + 0.55 * closure) * size_pitch, 0.4, 2.5)
	elif loop_player.playing:
		loop_player.stop()
	if not active:
		return
	var pop_rate := 1.5 + 30.0 * closing * (0.3 + closure)
	if randf() < pop_rate * dt:
		play(pops.pick_random(), randf_range(0.8, 1.7) * size_pitch, randf_range(-9.0, -3.0))
	if randf() < (0.4 + 3.0 * closing) * dt:
		play(cracks.pick_random(), randf_range(0.9, 1.4) * size_pitch, randf_range(-12.0, -6.0))


func stop_squeeze() -> void:
	update_squeeze(1.0, false, 0.0, 0.0, 1.0)


## Fast crush: crisp and fresh.
func play_snap(size_pitch: float) -> void:
	stop_squeeze()
	play(snaps.pick_random(), randf_range(0.95, 1.15) * size_pitch, 1.0)
	play(squirts.pick_random(), randf_range(1.0, 1.25) * size_pitch, -3.0)
	play(pops.pick_random(), randf_range(1.0, 1.5) * size_pitch, -5.0)


## Slow crush: the big wet finish.
func play_squish(size_pitch: float) -> void:
	stop_squeeze()
	play(burst, randf_range(0.95, 1.1) * size_pitch, 1.0)
	play(squirts.pick_random(), randf_range(0.85, 1.05) * size_pitch, -1.0)
	for i in 3:
		play(pops.pick_random(), randf_range(0.7, 1.2) * size_pitch, -5.0)


func play_slap(size_pitch: float) -> void:
	play(thud, randf_range(1.1, 1.3), 0.0)
	play(snaps.pick_random(), randf_range(0.85, 1.0) * size_pitch, 0.0)
	play(squirts.pick_random(), randf_range(0.9, 1.2) * size_pitch, -3.0)


## Building too big for us yet.
func play_hard() -> void:
	play(thud, randf_range(1.4, 1.6), -4.0)
	play(cracks.pick_random(), 0.6, -8.0)
