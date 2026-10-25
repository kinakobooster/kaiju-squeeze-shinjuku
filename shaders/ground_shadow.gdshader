shader_type spatial;
render_mode unshaded, blend_mix, depth_draw_never, cull_disabled, shadows_disabled;

// Soft shadow shapes drawn on a ground quad (UV 0..1, v = 0 is the far / forward end).
// kind 0 = kaiju body seen from above, kind 1 = hand with claws (openness spreads the fingers).
uniform int kind = 0;
uniform float openness = 1.0;
uniform vec4 color : source_color = vec4(0.25, 0.08, 0.4, 0.35);

float capsule(vec2 p, vec2 a, vec2 b, float r) {
	vec2 pa = p - a, ba = b - a;
	float h = clamp(dot(pa, ba) / dot(ba, ba), 0.0, 1.0);
	return length(pa - ba * h) - r;
}

float body(vec2 p) {
	float d = length(p / vec2(0.42, 0.55) - vec2(0.0, 0.25)) - 1.0;  // round torso
	d = min(d, (length(p - vec2(0.0, -0.62)) - 0.26));  // head
	d = min(d, capsule(p, vec2(0.0, 0.5), vec2(0.18, 0.95), 0.1));  // tail
	d = min(d, capsule(p, vec2(-0.35, 0.0), vec2(-0.55, -0.35), 0.09));  // arms
	d = min(d, capsule(p, vec2(0.35, 0.0), vec2(0.55, -0.35), 0.09));
	return d;
}

float hand(vec2 p) {
	float d = length(p - vec2(0.0, 0.25)) - 0.3;  // palm
	float len = mix(0.18, 0.62, openness);
	float spread = mix(0.12, 0.32, openness);
	for (int i = 0; i < 4; i++) {
		float a = (float(i) - 1.5) * spread;
		vec2 dir = vec2(sin(a), -cos(a));
		vec2 base = vec2(0.0, 0.25) + dir * 0.22;
		vec2 tip = base + dir * len;
		d = min(d, capsule(p, base, tip, 0.075));
		d = min(d, capsule(p, tip, tip + dir * 0.12, 0.025));  // claw
	}
	vec2 tdir = normalize(vec2(-0.9, -0.35));
	vec2 tb = vec2(-0.22, 0.32);
	d = min(d, capsule(p, tb, tb + tdir * len * 0.7, 0.07));  // thumb
	d = min(d, capsule(p, vec2(0.0, 0.4), vec2(0.0, 1.0), 0.17));  // wrist and arm
	return d;
}

void fragment() {
	vec2 p = UV * 2.0 - 1.0;
	float d = kind == 0 ? body(p) : hand(p);
	float a = 1.0 - smoothstep(-0.04, 0.03, d);
	ALBEDO = color.rgb;
	ALPHA = color.a * a;
}
