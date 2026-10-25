// Kaiju shadow projected straight down onto anything (ground, roofs, walls).
// Positions come from global shader parameters set every frame by main.gd.
global uniform vec4 kaiju_body;  // x, z, yaw, size (eye height)
global uniform vec4 kaiju_hand_l;  // x, z, size (0 = hidden), openness
global uniform vec4 kaiju_hand_r;
global uniform float kaiju_yaw;

float ks_capsule(vec2 p, vec2 a, vec2 b, float r) {
	vec2 pa = p - a, ba = b - a;
	float h = clamp(dot(pa, ba) / dot(ba, ba), 0.0, 1.0);
	return length(pa - ba * h) - r;
}

// p in body space: x right, y forward, unit = eye height
float ks_body(vec2 p) {
	float d = length((p - vec2(0.0, 0.35)) / vec2(0.42, 0.6)) - 1.0;
	d = min(d, length(p - vec2(0.0, 1.15)) - 0.27);  // head (in front)
	d = min(d, ks_capsule(p, vec2(0.0, -0.2), vec2(0.15, -0.75), 0.1));  // tail
	d = min(d, ks_capsule(p, vec2(-0.35, 0.5), vec2(-0.55, 0.85), 0.09));  // arms
	d = min(d, ks_capsule(p, vec2(0.35, 0.5), vec2(0.55, 0.85), 0.09));
	for (int i = 0; i < 4; i++) {  // back spikes
		vec2 c = vec2(0.0, 0.75 - float(i) * 0.25);
		d = min(d, ks_capsule(p, c, c + vec2(0.12, -0.05), 0.03));
		d = min(d, ks_capsule(p, c, c + vec2(-0.12, -0.05), 0.03));
	}
	return d;
}

// p in hand space: x right, y forward (away from us), unit = hand size
float ks_hand(vec2 p, float open) {
	float d = length(p) - 0.32;
	float len = mix(0.15, 0.62, open);
	float spread = mix(0.12, 0.32, open);
	for (int i = 0; i < 4; i++) {
		float a = (float(i) - 1.5) * spread;
		vec2 dir = vec2(sin(a), cos(a));
		vec2 base = dir * 0.24;
		vec2 tip = base + dir * len;
		d = min(d, ks_capsule(p, base, tip, 0.075));
		d = min(d, ks_capsule(p, tip, tip + dir * 0.13, 0.022));  // claw
	}
	d = min(d, ks_capsule(p, vec2(-0.2, 0.05), vec2(-0.2, 0.05) + vec2(-0.85, 0.4) * len * 0.8, 0.07));
	d = min(d, ks_capsule(p, vec2(0.0, -0.1), vec2(0.0, -1.6), 0.2));  // arm reaching back to us
	return d;
}

vec2 ks_local(vec2 w, vec2 origin, float scale) {
	vec2 q = (w - origin) / scale;
	float c = cos(kaiju_yaw), s = sin(kaiju_yaw);
	// forward for yaw: (-sin, -cos) in x/z; right: (cos, -sin)
	return vec2(q.x * c - q.y * s, -q.x * s - q.y * c);
}

// 0 = lit, 1 = fully in the kaiju's shadow
float kaiju_shadow(vec3 world) {
	vec2 w = world.xz;
	float d = ks_body(ks_local(w, kaiju_body.xy, kaiju_body.w));
	float sh = 1.0 - smoothstep(-0.02, 0.02, d);
	if (kaiju_hand_l.z > 0.0) {
		float dh = ks_hand(ks_local(w, kaiju_hand_l.xy, kaiju_hand_l.z), kaiju_hand_l.w);
		sh = max(sh, 1.0 - smoothstep(-0.03, 0.03, dh));
	}
	if (kaiju_hand_r.z > 0.0) {
		float dh = ks_hand(ks_local(w, kaiju_hand_r.xy, kaiju_hand_r.z), kaiju_hand_r.w);
		sh = max(sh, 1.0 - smoothstep(-0.03, 0.03, dh));
	}
	return sh;
}

const vec3 KAIJU_SHADOW_TINT = vec3(0.68, 0.56, 0.86);
