shader_type spatial;
render_mode cull_disabled;

#include "res://shaders/kaiju_shadow.gdshaderinc"

uniform bool use_vertex_color = true;
uniform vec4 albedo : source_color = vec4(1.0);

varying vec3 v_world;

void vertex() {
	v_world = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	vec3 col = use_vertex_color ? COLOR.rgb : albedo.rgb;
	float ring = kaiju_reach_ring(v_world);
	ALBEDO = mix(mix(col, col * KAIJU_SHADOW_TINT, kaiju_shadow(v_world)), KAIJU_REACH_COLOR, ring * 0.8);
	EMISSION = KAIJU_REACH_COLOR * ring * 0.4;
	ROUGHNESS = 1.0;
}
