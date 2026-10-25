shader_type spatial;
render_mode cull_disabled;

// UV  = (distance along the facade [m], height [m]) for windows.
// UV2 = (building id, roof flag).  COLOR.rgb = facade colour.

// Hover highlight (chunk meshes): building ids to glow.
uniform float hl_a = -1.0;
uniform float hl_b = -1.0;
uniform float hl_strength = 0.0;

// Squeeze deformation (only the detached, finely tessellated building uses these).
// Vertices are relative to the building centroid.
uniform float squeeze = 0.0;
uniform float grip_y = 0.5;
uniform float bheight = 30.0;
uniform vec2 sq_dir = vec2(1.0, 0.0);
uniform float two_hand = 0.0;
uniform float jiggle = 0.0;
uniform float juice = 0.0;
uniform vec3 juice_color : source_color = vec3(0.95, 0.35, 0.1);

varying float v_seed;
varying float v_roof;
varying vec2 v_wall;
varying float v_band;

float hash(vec2 p) {
	return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
}

void vertex() {
	v_seed = UV2.x;
	v_roof = UV2.y;
	v_wall = UV;
	float hy = clamp(VERTEX.y / bheight, 0.0, 1.0);
	float band = exp(-pow((hy - grip_y) / 0.28, 2.0));
	v_band = band;
	float amt = squeeze + jiggle;
	if (amt > 0.0001) {
		float s = squeeze * band;
		vec2 perp = vec2(-sq_dir.y, sq_dir.x);
		float a = dot(VERTEX.xz, sq_dir);
		float b = dot(VERTEX.xz, perp);
		// one hand: radial crush; two hands: flattened between the palms, oozing sideways
		float ka = mix(1.0 - 0.8 * s, 1.0 - 0.93 * s, two_hand);
		float kb = mix(1.0 - 0.8 * s, 1.0 + 0.6 * s, two_hand);
		// the mass that left the grip bulges out above and below it
		float bulge = 1.0 + squeeze * (1.0 - band) * 0.5;
		float wob = 1.0 + sin(TIME * 31.0 + VERTEX.y * 0.09) * 0.035 * squeeze
				+ sin(TIME * 13.0 + VERTEX.y * 0.05) * 0.18 * jiggle;
		a *= ka * bulge * wob;
		b *= kb * bulge * wob;
		VERTEX.xz = sq_dir * a + perp * b;
		VERTEX.y += squeeze * 0.28 * bheight * smoothstep(grip_y - 0.15, 1.0, hy);
	}
}

void fragment() {
	vec3 base = COLOR.rgb;
	vec3 col = base;
	vec3 emit = vec3(0.0);
	if (v_roof < 0.5) {
		vec2 cell = vec2(v_wall.x / 3.6, v_wall.y / 3.4);
		vec2 f = fract(cell);
		vec2 id = floor(cell);
		float win = step(0.16, f.x) * step(f.x, 0.84) * step(0.22, f.y) * step(f.y, 0.82);
		win *= 1.0 - smoothstep(0.35, 0.9, fwidth(cell.x) + fwidth(cell.y));
		float lit = step(0.6, hash(id + vec2(v_seed * 0.137, v_seed * 0.071)));
		vec3 wc = mix(vec3(1.0, 0.78, 0.48), vec3(0.72, 0.86, 1.0), step(0.6, hash(id.yx + v_seed)));
		col = mix(base, base * 0.3, win);
		emit = wc * win * lit * 1.15;
		// far-away facades still glimmer a bit instead of turning flat grey
		emit += wc * 0.08 * (1.0 - smoothstep(0.35, 0.9, fwidth(cell.x)));
	} else {
		col = base * 0.6;
	}
	float hl = (abs(v_seed - hl_a) < 0.5 || abs(v_seed - hl_b) < 0.5) ? 1.0 : 0.0;
	emit += vec3(1.0, 0.5, 0.15) * hl * hl_strength;
	col = mix(col, vec3(1.0, 0.6, 0.3), hl * hl_strength * 0.35);
	float j = clamp(juice * v_band, 0.0, 0.85);
	col = mix(col, juice_color, j);
	emit += juice_color * j * 0.5;
	ALBEDO = col;
	EMISSION = emit;
	ROUGHNESS = 0.85;
}
