shader_type spatial;
render_mode cull_disabled;

#include "res://shaders/kaiju_shadow.gdshaderinc"

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
varying vec3 v_world;

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
	// the targeted building shivers in fear
	float hlv = (abs(UV2.x - hl_a) < 0.5 || abs(UV2.x - hl_b) < 0.5) ? hl_strength : 0.0;
	if (hlv > 0.0) {
		float up = clamp(VERTEX.y * 0.04, 0.0, 1.0);
		VERTEX.xz += vec2(sin(TIME * 53.0 + VERTEX.y * 0.3), cos(TIME * 61.0 + VERTEX.y * 0.27)) * 0.6 * up * hlv;
		VERTEX.y *= 1.0 + 0.04 * hlv;
	}
	v_world = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
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
		// rounded candy windows
		float round_win = 1.0 - smoothstep(0.26, 0.3, length((f - 0.5) * vec2(1.0, 1.2)));
		win = min(win, round_win) * (1.0 - smoothstep(0.35, 0.9, fwidth(cell.x) + fwidth(cell.y)));
		float lit = step(0.55, hash(id + vec2(v_seed * 0.137, v_seed * 0.071)));
		vec3 wc = mix(vec3(1.0, 0.95, 0.7), vec3(1.0, 0.85, 0.95), step(0.6, hash(id.yx + v_seed)));
		col = mix(base, mix(vec3(1.0), base, 0.35), win);
		emit = wc * win * lit * 0.6;
	} else {
		col = mix(base, vec3(1.0), 0.35);
	}
	float hl = (abs(v_seed - hl_a) < 0.5 || abs(v_seed - hl_b) < 0.5) ? 1.0 : 0.0;
	emit += vec3(1.0, 0.1, 0.15) * hl * hl_strength * 0.8;
	col = mix(col, vec3(1.0, 0.15, 0.2), hl * hl_strength * 0.7);
	float j = clamp(juice * v_band, 0.0, 0.85);
	col = mix(col, juice_color, j);
	emit += juice_color * j * 0.5;
	float sh = kaiju_shadow(v_world);
	ALBEDO = mix(col, col * KAIJU_SHADOW_TINT, sh);
	EMISSION = emit * (1.0 - sh * 0.6);
	ROUGHNESS = 0.85;
}
