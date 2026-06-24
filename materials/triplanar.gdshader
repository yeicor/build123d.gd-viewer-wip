shader_type spatial;

uniform sampler2D albedo_tex : repeat_enable, filter_linear_mipmap, hint_default_white;
uniform sampler2D orm_tex : repeat_enable, filter_linear_mipmap, hint_default_white;
uniform float roughness : hint_range(0.0, 1.0) = 1.0;
uniform float metalness : hint_range(0.0, 1.0) = 0.0;
uniform float ao_strength : hint_range(0.0, 1.0) = 0.0;
uniform sampler2D normal_map : hint_normal, filter_linear_mipmap, repeat_enable;
uniform float normal_map_scale : hint_range(-15.0, 15.0) = 1.0;
uniform vec3 uv_scale = vec3(1.0);

group_uniforms uniplanar_settings;
uniform float blend_factor = 8.0;

varying vec3 my_pos;
varying vec3 my_normal;

vec3 triplanar_weights(vec3 n, float sharpness) {
	vec3 w = pow(abs(n), vec3(sharpness));
	return w / max(w.x + w.y + w.z, 1e-6);
}

vec4 triplanar_sample(sampler2D sam, vec3 normal, vec3 position, float sharpness) {
	vec3 w = triplanar_weights(normal, sharpness);

	float sx = normal.x < 0.0 ? -1.0 : 1.0;
	float sy = normal.y < 0.0 ? -1.0 : 1.0;
	float sz = normal.z < 0.0 ? -1.0 : 1.0;

	// X projection -> YZ plane
	vec2 uv_x = vec2(position.z * sx, position.y);
	// Y projection -> XZ plane
	vec2 uv_y = vec2(position.x * sy, position.z);
	// Z projection -> XY plane
	vec2 uv_z = vec2(position.x * sz, position.y);

	vec3 dpdx = dFdx(position);
	vec3 dpdy = dFdy(position);

	vec2 dx_x = vec2(dpdx.z * sx, dpdx.y);
	vec2 dy_x = vec2(dpdy.z * sx, dpdy.y);

	vec2 dx_y = vec2(dpdx.x * sy, dpdx.z);
	vec2 dy_y = vec2(dpdy.x * sy, dpdy.z);

	vec2 dx_z = vec2(dpdx.x * sz, dpdx.y);
	vec2 dy_z = vec2(dpdy.x * sz, dpdy.y);

	vec4 tx = textureGrad(sam, uv_x, dx_x, dy_x);
	vec4 ty = textureGrad(sam, uv_y, dx_y, dy_y);
	vec4 tz = textureGrad(sam, uv_z, dx_z, dy_z);

	return tx * w.x + ty * w.y + tz * w.z;
}

void vertex() {
	my_pos = VERTEX;
	my_normal = normalize(NORMAL);
}

void fragment() {
	vec3 p = my_pos * uv_scale;
	vec3 n = normalize(my_normal);

	vec3 albedo_sample = triplanar_sample(albedo_tex, n, p, blend_factor).rgb;
	ALBEDO *= albedo_sample * 0.3;
	ALBEDO *= COLOR.rgb;

	vec3 orm = triplanar_sample(orm_tex, n, p, blend_factor).rgb;
	ROUGHNESS = orm.g * roughness;
	METALLIC = orm.b * metalness;
	AO = orm.r;
	AO_LIGHT_AFFECT = ao_strength;

	vec3 nm = triplanar_sample(normal_map, n, p, blend_factor).rgb;
	NORMAL_MAP = nm;
	NORMAL_MAP_DEPTH = normal_map_scale;
}