shader_type canvas_item;

// Composites the white hand mask (SubViewport) as a milky, see-through kaiju hand
// with a soft pastel rim.
uniform vec4 skin : source_color = vec4(1.0, 0.98, 1.0, 0.42);
uniform vec4 rim : source_color = vec4(1.0, 0.75, 0.95, 1.0);
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
	vec3 rimc = mix(rim.rgb, vec3(1.0, 0.85, 0.4), grip_glow);
	vec3 c = mix(skin.rgb, rimc, edge);
	COLOR = vec4(c, a * mix(skin.a, 0.3, grip_glow) + edge * 0.55);
}
