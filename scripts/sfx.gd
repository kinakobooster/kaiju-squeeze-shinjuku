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
var beads: Array[AudioStream] = []
var burst: AudioStream = preload("res://audio/burst.wav")
var thud: AudioStream = preload("res://audio/thud.wav")
var select: AudioStream = preload("res://audio/select.wav")
var _pool: Array[AudioStreamPlayer] = []
var _next := 0
var _loop_vol := 0.0
# recorded squeezes (audio/samples): short ones for crushes, long ones layered under the grip
var squish_shorts: Array[AudioStream] = [
	preload("res://audio/samples/slime_squish.mp3"), preload("res://audio/samples/squish_short.mp3")]
var squish_long: AudioStream = preload("res://audio/samples/squish_long.mp3")
var layers: Array[AudioStreamPlayer] = []
# items
var beam_player: AudioStreamPlayer
var shari_player: AudioStreamPlayer
var star_pops: Array[AudioStream] = []
var ice_burst: AudioStream = preload("res://audio/ice_burst.wav")
var freeze: AudioStream = preload("res://audio/freeze.wav")
var frozen := false  # the building being squeezed is frozen: sparkly shari-shari instead of squish


func _ready() -> void:
	for i in 4:
		pops.append(load("res://audio/pop%d.wav" % i))
	for i in 3:
		cracks.append(load("res://audio/crack%d.wav" % i))
		snaps.append(load("res://audio/snap%d.wav" % i))
	for i in 2:
		squirts.append(load("res://audio/squirt%d.wav" % i))
	for i in 3:
		beads.append(load("res://audio/beads%d.wav" % i))
	loop_player = _make_loop(preload("res://audio/squeeze_loop.wav"))
	beam_player = _make_loop(preload("res://audio/beam_loop.wav"))
	shari_player = _make_loop(preload("res://audio/shari_loop.wav"))
	for i in 3:
		star_pops.append(load("res://audio/star_pop%d.wav" % i))
	for path in ["res://audio/samples/plastic_bottle.mp3", "res://audio/samples/squeeze_long.mp3"]:
		var mp3: AudioStreamMP3 = load(path).duplicate()
		mp3.loop = true
		var lp := AudioStreamPlayer.new()
		lp.stream = mp3
		lp.volume_db = -80.0
		add_child(lp)
		layers.append(lp)
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
	var wet_vol := 0.0 if frozen else _loop_vol
	if wet_vol > 0.001:
		if not loop_player.playing:
			loop_player.play(randf() * 2.5)
		loop_player.volume_db = linear_to_db(wet_vol) + 3.0
		# pressure building up: the squelch climbs as the building gives way
		loop_player.pitch_scale = clampf((0.85 + 0.55 * closure) * size_pitch, 0.4, 2.5)
	elif loop_player.playing:
		loop_player.stop()
	var ice_vol := _loop_vol if frozen else 0.0
	if ice_vol > 0.001:
		if not shari_player.playing:
			shari_player.play(randf() * 1.8)
		shari_player.volume_db = linear_to_db(ice_vol) + 2.0
		shari_player.pitch_scale = clampf(0.9 + 0.4 * closure, 0.5, 2.0)
	elif shari_player.playing:
		shari_player.stop()
	for lp in layers:
		if wet_vol > 0.001:
			if not lp.playing:  # start somewhere new each grip so it never sounds the same
				lp.play(randf() * maxf(lp.stream.get_length() - 1.0, 0.0))
			lp.volume_db = linear_to_db(wet_vol) - 2.0
			lp.pitch_scale = clampf((0.9 + 0.3 * closure) * size_pitch, 0.5, 2.0)
		elif lp.playing:
			lp.stop()
	if not active:
		return
	if frozen:
		if randf() < (1.0 + 6.0 * closing) * dt:
			play(freeze, randf_range(1.5, 2.6), randf_range(-16.0, -10.0))
		return
	if randf() < (0.3 + 2.5 * closing) * dt:
		play(squish_shorts.pick_random(), randf_range(0.8, 1.25) * size_pitch, randf_range(-8.0, -3.0))
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
	play(squish_shorts.pick_random(), randf_range(1.0, 1.2) * size_pitch, 0.0)
	play(squirts.pick_random(), randf_range(1.0, 1.25) * size_pitch, -3.0)
	play(pops.pick_random(), randf_range(1.0, 1.5) * size_pitch, -5.0)


## Slow crush: the big wet finish.
func play_squish(size_pitch: float) -> void:
	stop_squeeze()
	play(burst, randf_range(0.95, 1.1) * size_pitch, -2.0)
	play(squish_long, randf_range(0.9, 1.05) * size_pitch, 1.0)
	play(squirts.pick_random(), randf_range(0.85, 1.05) * size_pitch, -1.0)
	for i in 3:
		play(pops.pick_random(), randf_range(0.7, 1.2) * size_pitch, -5.0)


func play_slap(size_pitch: float) -> void:
	play(thud, randf_range(1.1, 1.3), 0.0)
	play(snaps.pick_random(), randf_range(0.85, 1.0) * size_pitch, 0.0)
	play(squish_shorts.pick_random(), randf_range(0.8, 1.0) * size_pitch, -2.0)
	play(squirts.pick_random(), randf_range(0.9, 1.2) * size_pitch, -3.0)


## Running a hand through a pile of silver beads.
func play_beads(intensity: float) -> void:
	play(beads.pick_random(), randf_range(0.85, 1.2), linear_to_db(clampf(0.4 + intensity * 0.6, 0.2, 1.0)))


func play_ice_burst() -> void:
	stop_squeeze()
	play(ice_burst, randf_range(0.95, 1.1), 1.0)
	play(freeze, randf_range(1.2, 1.5), -4.0)


func play_star_pop() -> void:
	play(star_pops.pick_random(), randf_range(0.9, 1.2), -1.0)


func set_beam(on: bool, power: float) -> void:
	if on and not beam_player.playing:
		beam_player.play()
	elif not on and beam_player.playing:
		beam_player.stop()
	beam_player.volume_db = linear_to_db(clampf(0.4 + power * 0.6, 0.1, 1.0)) - 2.0
	beam_player.pitch_scale = 0.9 + power * 0.3


## Building too big for us yet.
func play_hard() -> void:
	play(thud, randf_range(1.4, 1.6), -4.0)
	play(cracks.pick_random(), 0.6, -8.0)
