shader_type canvas_item;
// Tunnel vision over the 3D view: the middle bulges towards us (barrel bend), the edges
// fall into shadow, and the colours are pushed brighter.
// k must match LENS_K in scripts/main.gd, which maps hand positions through the same bend.

uniform sampler2D screen_tex : hint_screen_texture, filter_linear;
uniform float k = 0.22;
uniform float vignette = 0.8;
uniform float saturation = 1.45;
uniform float contrast = 1.08;
uniform float brightness = 1.06;

void fragment() {
	vec2 vp = 1.0 / SCREEN_PIXEL_SIZE;
	vec2 p = SCREEN_UV * vp;
	vec2 c = vp * 0.5;
	vec2 q = (p - c) / (vp.x * 0.5);
	vec2 s = c + (p - c) * ((1.0 - k) + k * dot(q, q));
	vec2 uv = clamp(s / vp, vec2(0.001), vec2(0.999));
	vec3 col = texture(screen_tex, uv).rgb;
	float l = dot(col, vec3(0.299, 0.587, 0.114));
	col = mix(vec3(l), col, saturation);
	col = (col - 0.5) * contrast + 0.5;
	col *= brightness;
	// a round tunnel: clear in the middle, darker towards the rim
	vec2 v = (p - c) / (vp.y * 0.5);
	float r = length(v * vec2(0.62, 1.0));
	col *= mix(1.0 - vignette, 1.0, smoothstep(1.3, 0.62, r));
	COLOR = vec4(clamp(col, 0.0, 1.0), 1.0);
}
