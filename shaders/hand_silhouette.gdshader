shader_type canvas_item;

// Composites the white hand mask (SubViewport) as a dark kaiju silhouette
// with a glowing rim and a hint of scales.
uniform vec4 skin : source_color = vec4(0.035, 0.05, 0.045, 0.94);
uniform vec4 rim : source_color = vec4(0.35, 1.0, 0.55, 1.0);
uniform float grip_glow = 0.0;

void fragment() {
	vec2 px = TEXTURE_PIXEL_SIZE * 4.0;
	float a = texture(TEXTURE, UV).a;
	float n = 0.0;
	n += texture(TEXTURE, UV + vec2(px.x, 0.0)).a;
	n += texture(TEXTURE, UV - vec2(px.x, 0.0)).a;
	n += texture(TEXTURE, UV + vec2(0.0, px.y)).a;
	n += texture(TEXTURE, UV - vec2(0.0, px.y)).a;
	n += texture(TEXTURE, UV + px).a;
	n += texture(TEXTURE, UV - px).a;
	n += texture(TEXTURE, UV + vec2(px.x, -px.y)).a;
	n += texture(TEXTURE, UV + vec2(-px.x, px.y)).a;
	n /= 8.0;
	float edge = clamp((a - n) * 2.5, 0.0, 1.0);
	// staggered scale pattern
	vec2 g = UV / TEXTURE_PIXEL_SIZE / 14.0;
	g.x += step(1.0, mod(floor(g.y), 2.0)) * 0.5;
	float sc = length(fract(g) - vec2(0.5, 0.25));
	float scales = smoothstep(0.45, 0.55, sc) * 0.025;
	vec3 rimc = mix(rim.rgb, vec3(1.0, 0.35, 0.2), grip_glow);
	vec3 c = skin.rgb + scales + rimc * edge * 0.9;
	// see-through while squeezing so the squished building stays visible
	COLOR = vec4(c, a * mix(skin.a, 0.5, grip_glow) + edge * grip_glow * 0.4);
}
