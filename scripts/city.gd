class_name City
extends Node3D
## Shinjuku built from OSM footprints (data/city.json).
## Buildings are merged into chunk meshes; one that gets squeezed is detached into its own
## finely tessellated mesh so the vertex shader can deform it.

const CHUNK := 160.0
const CELL := 20.0
const BUILDING_SHADER := preload("res://shaders/building.gdshader")
const GROUND_SHADER := preload("res://shaders/ground.gdshader")

const FACADES: Array[Color] = [  # sweets-shop pastels
	Color(0.62, 0.86, 1.0), Color(1.0, 0.7, 0.85), Color(1.0, 0.93, 0.55),
	Color(0.7, 0.95, 0.8), Color(0.82, 0.74, 1.0), Color(1.0, 0.8, 0.65),
]
const GLASS: Array[Color] = [Color(0.55, 0.8, 1.0), Color(0.78, 0.7, 1.0), Color(1.0, 0.68, 0.88)]
const JUICES: Array[Color] = [
	Color(1.0, 0.45, 0.05), Color(0.55, 0.95, 0.15), Color(0.65, 0.2, 0.85),
	Color(0.95, 0.15, 0.3), Color(1.0, 0.85, 0.1), Color(0.35, 0.18, 0.08),
]

## Each: {name, h, poly: PackedVector2Array, center: Vector2, radius, area, rect: Rect2,
##        chunk: Vector2i, color, juice, alive, damage}
var buildings: Array[Dictionary] = []
var _mesh_cache: Array = []  # per building: [verts, normals, uv, uv2, colors]
var _chunk_members := {}  # Vector2i -> Array[int]
var _chunk_nodes := {}  # Vector2i -> MeshInstance3D
var _cells := {}  # Vector2i -> PackedInt32Array
var _detached := {}  # id -> MeshInstance3D (dented/squeezing building)
var _chunk_mat: ShaderMaterial
var _hover := [-1, -1]
var _hover_chunks := {}


func load_city(path: String) -> void:
	var data: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(path))
	_chunk_mat = ShaderMaterial.new()
	_chunk_mat.shader = BUILDING_SHADER
	_build_ground(data)
	var list: Array = data["buildings"]
	for i in list.size():
		_add_building(i, list[i])
	for key in _chunk_members:
		_rebuild_chunk(key)


func _add_building(id: int, b: Dictionary) -> void:
	var flat: Array = b["p"]
	var poly := PackedVector2Array()
	for k in range(0, flat.size(), 2):
		poly.append(Vector2(flat[k], flat[k + 1]))
	var center := Vector2.ZERO
	for p in poly:
		center += p
	center /= poly.size()
	var radius := 0.0
	var rect := Rect2(poly[0], Vector2.ZERO)
	for p in poly:
		radius = maxf(radius, p.distance_to(center))
		rect = rect.expand(p)
	var h: float = b["h"]
	var rng := RandomNumberGenerator.new()
	rng.seed = id * 7919 + 13
	var color: Color = (GLASS[rng.randi() % GLASS.size()] if h > 60.0 and rng.randf() < 0.7
			else FACADES[rng.randi() % FACADES.size()])
	color = color.lightened(rng.randf_range(-0.05, 0.12))
	var info := {
		"name": b["n"], "h": h, "poly": poly, "center": center, "radius": radius,
		"area": absf(_poly_area(poly)), "rect": rect, "color": color,
		"juice": JUICES[rng.randi() % JUICES.size()], "alive": true, "damage": 0.0,
		"chunk": Vector2i(floori(center.x / CHUNK), floori(center.y / CHUNK)),
	}
	buildings.append(info)
	_mesh_cache.append(_build_arrays(id, info, Vector2.ZERO, 1, 1e9))
	if not _chunk_members.has(info["chunk"]):
		_chunk_members[info["chunk"]] = []
	_chunk_members[info["chunk"]].append(id)
	var c0 := Vector2i(floori(rect.position.x / CELL), floori(rect.position.y / CELL))
	var c1 := Vector2i(floori(rect.end.x / CELL), floori(rect.end.y / CELL))
	for cx in range(c0.x, c1.x + 1):
		for cz in range(c0.y, c1.y + 1):
			var key := Vector2i(cx, cz)
			if not _cells.has(key):
				_cells[key] = PackedInt32Array()
			_cells[key].append(id)


static func _poly_area(poly: PackedVector2Array) -> float:
	var a := 0.0
	for i in poly.size():
		var p := poly[i]
		var q := poly[(i + 1) % poly.size()]
		a += p.x * q.y - q.x * p.y
	return a * 0.5


## Builds non-indexed triangle arrays for a building. `origin` is subtracted from positions,
## walls are split into `rows` bands and edges longer than `max_seg` metres are subdivided.
func _build_arrays(id: int, info: Dictionary, origin: Vector2, rows: int, max_seg: float) -> Array:
	var poly: PackedVector2Array = info["poly"]
	var h: float = info["h"]
	var col: Color = info["color"]
	var v := PackedVector3Array()
	var n := PackedVector3Array()
	var uv := PackedVector2Array()
	var uv2 := PackedVector2Array()
	var c := PackedColorArray()
	var wall_uv2 := Vector2(id, 0.0)
	var along := 0.0
	for i in poly.size():
		var a := poly[i] - origin
		var b := poly[(i + 1) % poly.size()] - origin
		var d := b - a
		var seg_len := d.length()
		if seg_len < 0.01:
			continue
		var normal := Vector3(d.y, 0.0, -d.x).normalized()
		var segs := maxi(1, ceili(seg_len / max_seg))
		for s in segs:
			var p0 := a.lerp(b, float(s) / segs)
			var p1 := a.lerp(b, float(s + 1) / segs)
			var u0 := along + seg_len * s / segs
			var u1 := along + seg_len * (s + 1) / segs
			for r in rows:
				var y0 := h * r / rows
				var y1 := h * (r + 1) / rows
				var q0 := Vector3(p0.x, y0, p0.y)
				var q1 := Vector3(p1.x, y0, p1.y)
				var q2 := Vector3(p1.x, y1, p1.y)
				var q3 := Vector3(p0.x, y1, p0.y)
				for q in [q0, q1, q2, q0, q2, q3]:
					v.append(q)
					uv.append(Vector2(u0 if q == q0 or q == q3 else u1, q.y))
					n.append(normal)
					uv2.append(wall_uv2)
					c.append(col)
		along += seg_len
	var local := PackedVector2Array()
	for p in poly:
		local.append(p - origin)
	var tris := Geometry2D.triangulate_polygon(local)
	var roof_uv2 := Vector2(id, 1.0)
	for k in tris.size():
		var p := local[tris[k]]
		v.append(Vector3(p.x, h, p.y))
		n.append(Vector3.UP)
		uv.append(p)
		uv2.append(roof_uv2)
		c.append(col)
	return [v, n, uv, uv2, c]


static func _arrays_to_mesh(parts: Array) -> ArrayMesh:
	var v := PackedVector3Array()
	var n := PackedVector3Array()
	var uv := PackedVector2Array()
	var uv2 := PackedVector2Array()
	var c := PackedColorArray()
	for part in parts:
		v.append_array(part[0])
		n.append_array(part[1])
		uv.append_array(part[2])
		uv2.append_array(part[3])
		c.append_array(part[4])
	var mesh := ArrayMesh.new()
	if v.is_empty():
		return mesh
	var arr := []
	arr.resize(Mesh.ARRAY_MAX)
	arr[Mesh.ARRAY_VERTEX] = v
	arr[Mesh.ARRAY_NORMAL] = n
	arr[Mesh.ARRAY_TEX_UV] = uv
	arr[Mesh.ARRAY_TEX_UV2] = uv2
	arr[Mesh.ARRAY_COLOR] = c
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
	return mesh


func _rebuild_chunk(key: Vector2i) -> void:
	var parts := []
	for id in _chunk_members[key]:
		if buildings[id]["alive"] and not _detached.has(id):
			parts.append(_mesh_cache[id])
	var mi: MeshInstance3D = _chunk_nodes.get(key)
	if mi == null:
		mi = MeshInstance3D.new()
		mi.material_override = _chunk_mat.duplicate()
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(mi)
		_chunk_nodes[key] = mi
	mi.mesh = _arrays_to_mesh(parts)


# --- ground, roads, rails, parks ----------------------------------------------------------

func _build_ground(data: Dictionary) -> void:
	var ground := MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = Vector2(6000, 6000)
	ground.mesh = plane
	var gm := ShaderMaterial.new()
	gm.shader = GROUND_SHADER
	gm.set_shader_parameter("use_vertex_color", false)
	gm.set_shader_parameter("albedo", Color(0.78, 0.74, 0.9))
	ground.material_override = gm
	add_child(ground)
	_add_flat_polys(data["parks"], 0.04, Color(0.6, 0.92, 0.7))
	_add_flat_polys(data["water"], 0.05, Color(0.55, 0.85, 1.0))
	_add_ribbons(data["roads"], 0.08, Color(0.86, 0.82, 0.95), Color(1.0, 0.75, 0.88))
	var rails := []
	for r in data["rails"]:
		rails.append({"w": 7.0, "p": r["p"]})
	_add_ribbons(rails, 0.1, Color(0.95, 0.78, 0.6), Color(1.0, 1.0, 1.0))


func _add_flat_polys(list: Array, y: float, col: Color) -> void:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	st.set_normal(Vector3.UP)
	st.set_color(col)
	for item in list:
		var flat: Array = item["p"]
		var poly := PackedVector2Array()
		for k in range(0, flat.size(), 2):
			poly.append(Vector2(flat[k], flat[k + 1]))
		var tris := Geometry2D.triangulate_polygon(poly)
		for k in tris:
			st.add_vertex(Vector3(poly[k].x, y, poly[k].y))
	_add_flat_mesh(st)


func _add_ribbons(list: Array, y: float, col: Color, line_col: Color) -> void:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	st.set_normal(Vector3.UP)
	for item in list:
		var flat: Array = item["p"]
		var w: float = item["w"] * 0.5
		for k in range(0, flat.size() - 2, 2):
			var a := Vector2(flat[k], flat[k + 1])
			var b := Vector2(flat[k + 2], flat[k + 3])
			if a.distance_to(b) < 0.01:
				continue
			var side := (b - a).normalized().orthogonal()
			_quad(st, a, b, side * w, y, col)
			if w > 4.0:  # centre line on bigger roads
				_quad(st, a, b, side * 0.3, y + 0.02, line_col)
	_add_flat_mesh(st)


static func _quad(st: SurfaceTool, a: Vector2, b: Vector2, s: Vector2, y: float, col: Color) -> void:
	st.set_color(col)
	var p := [a + s, b + s, b - s, a - s]
	for k in [0, 1, 2, 0, 2, 3]:
		st.add_vertex(Vector3(p[k].x, y, p[k].y))


func _add_flat_mesh(st: SurfaceTool) -> void:
	var mi := MeshInstance3D.new()
	mi.mesh = st.commit()
	var m := ShaderMaterial.new()
	m.shader = GROUND_SHADER
	mi.material_override = m
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mi)


# --- picking ------------------------------------------------------------------------------

## Marches along a ray and returns {id, point} of the first building hit, or {} if none.
func pick(origin: Vector3, dir: Vector3, max_dist: float) -> Dictionary:
	var step := 3.0
	var t := 0.0
	while t < max_dist:
		var p := origin + dir * t
		if p.y < 0.0:
			return {}
		var cell := Vector2i(floori(p.x / CELL), floori(p.z / CELL))
		if _cells.has(cell):
			var q := Vector2(p.x, p.z)
			for id in _cells[cell]:
				var b: Dictionary = buildings[id]
				if not b["alive"] or p.y > effective_height(id):
					continue
				if b["rect"].grow(1.0).has_point(q) and Geometry2D.is_point_in_polygon(q, b["poly"]):
					return {"id": id, "point": p}
		t += step
	return {}


func effective_height(id: int) -> float:
	return buildings[id]["h"] * (1.0 - buildings[id]["damage"] * 0.35)


func set_hover(a: int, b: int, strength: float) -> void:
	_hover = [a, b]
	var want := {}
	for id in _hover:
		if id >= 0:
			want[buildings[id]["chunk"]] = true
	for key in _hover_chunks.keys() + want.keys():
		var mi: MeshInstance3D = _chunk_nodes.get(key)
		if mi == null:
			continue
		var m: ShaderMaterial = mi.material_override
		var on := want.has(key)
		m.set_shader_parameter("hl_a", a if on else -1)
		m.set_shader_parameter("hl_b", b if on else -1)
		m.set_shader_parameter("hl_strength", strength if on else 0.0)
	_hover_chunks = want
	for id in _detached:
		var dm: ShaderMaterial = _detached[id].material_override
		var on: bool = id == a or id == b
		dm.set_shader_parameter("hl_a", id if on else -1)
		dm.set_shader_parameter("hl_strength", strength if on else 0.0)


## Returns the deformable mesh for a building, detaching it from its chunk on first use.
func detach(id: int) -> MeshInstance3D:
	if _detached.has(id):
		return _detached[id]
	var b: Dictionary = buildings[id]
	var mi := MeshInstance3D.new()
	var rows := clampi(int(b["h"] / 3.0), 8, 40)
	var max_seg := clampf(b["radius"] / 4.0, 2.0, 8.0)
	mi.mesh = _arrays_to_mesh([_build_arrays(id, b, b["center"], rows, max_seg)])
	var m := ShaderMaterial.new()
	m.shader = BUILDING_SHADER
	m.set_shader_parameter("bheight", b["h"])
	m.set_shader_parameter("juice_color", b["juice"])
	mi.material_override = m
	mi.position = Vector3(b["center"].x, 0.0, b["center"].y)
	add_child(mi)
	_detached[id] = mi
	_rebuild_chunk(b["chunk"])
	return mi


func destroy(id: int) -> void:
	var b: Dictionary = buildings[id]
	b["alive"] = false
	if _detached.has(id):
		_detached[id].queue_free()
		_detached.erase(id)
	_rebuild_chunk(b["chunk"])


## Pushes a point out of tall building footprints (the camera should not end up inside towers).
func push_out(p: Vector2, min_h: float, pad: float) -> Vector2:
	var cell := Vector2i(floori(p.x / CELL), floori(p.y / CELL))
	for dx in range(-3, 4):
		for dz in range(-3, 4):
			var key := cell + Vector2i(dx, dz)
			if not _cells.has(key):
				continue
			for id in _cells[key]:
				var b: Dictionary = buildings[id]
				if not b["alive"] or effective_height(id) < min_h:
					continue
				var c: Vector2 = b["center"]
				var r: float = b["radius"] * 0.8 + pad
				var d := p - c
				if d.length() < r:
					p = c + (d.normalized() if d.length() > 0.01 else Vector2.RIGHT) * r
	return p
