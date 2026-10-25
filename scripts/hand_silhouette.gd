class_name HandSilhouette
extends Node2D
## Draws the hands as a solid white mask inside a SubViewport; the composite shader
## turns it into the milky kaiju hand. Coordinates arrive in screen pixels.

const BONES := [
	[0, 1, 2, 3, 4], [5, 6, 7, 8], [9, 10, 11, 12], [13, 14, 15, 16], [17, 18, 19, 20],
]
const PALM := [0, 1, 2, 5, 9, 13, 17]

var hands: Array = []  # Array[HandInput.Hand]
var scale_factor := 0.5  # SubViewport resolution / screen resolution


## The big lie: a hand pushed towards the camera grows in the image, but we draw it smaller,
## as if it had travelled further into the city (displayed size ~ 1 / camera size).
static func draw_scale(h: HandInput.Hand, screen_h: float) -> float:
	var ref := screen_h * 0.17
	return clampf(pow(ref / maxf(h.size, 1.0), 2.0), 0.3, 2.2)


func _process(_dt: float) -> void:
	queue_redraw()


func _draw() -> void:
	for h in hands:
		var pts := PackedVector2Array()
		for p in h.pts:
			pts.append(p * scale_factor)
		var ds := draw_scale(h, get_viewport_rect().size.y / scale_factor)
		var c: Vector2 = h.palm * scale_factor
		for i in pts.size():
			pts[i] = c + (pts[i] - c) * ds
		var s: float = h.size * scale_factor * ds
		var w := s * 0.42
		# palm
		var palm := PackedVector2Array()
		for i in PALM:
			palm.append(pts[i])
		palm = Geometry2D.convex_hull(palm)
		var grown := Geometry2D.offset_polygon(palm, w * 0.55)
		for poly in grown:
			draw_colored_polygon(poly, Color.WHITE)
		# fingers: tapering capsules with claws
		for chain in BONES:
			for k in chain.size() - 1:
				var a := pts[chain[k]]
				var b := pts[chain[k + 1]]
				var t0 := 1.0 - 0.1 * float(k)
				var t1 := 1.0 - 0.1 * float(k + 1)
				draw_circle(a, w * 0.5 * t0, Color.WHITE)
				_capsule(a, b, w * t0, w * t1)
			var tip := pts[chain[-1]]
			var prev := pts[chain[-2]]
			var d := (tip - prev).normalized()
			var cw := w * 0.22
			var base := tip + d * w * 0.15
			draw_colored_polygon(PackedVector2Array([
				base + d.orthogonal() * cw, tip + d * w * 0.95, base - d.orthogonal() * cw]), Color.WHITE)


func _capsule(a: Vector2, b: Vector2, wa: float, wb: float) -> void:
	var d := (b - a)
	if d.length() < 0.5:
		return
	var n := d.normalized().orthogonal()
	draw_colored_polygon(PackedVector2Array([
		a + n * wa * 0.5, b + n * wb * 0.5, b - n * wb * 0.5, a - n * wa * 0.5]), Color.WHITE)
	draw_circle(b, wb * 0.5, Color.WHITE)
