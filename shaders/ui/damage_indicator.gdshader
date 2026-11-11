shader_type canvas_item;
render_mode unshaded, blend_premul_alpha;

uniform float crest_opacity : hint_range(0.0, 1.0, 0.01) = 0.38;
// Mip level used to soften the crest edge.
uniform float edge_softness : hint_range(0.0, 5.0, 0.05) = 2.4;
uniform float feather_opacity : hint_range(0.0, 1.0, 0.01) = 0.44;
// Length of the inward fade in atlas pixels.
uniform float feather_length : hint_range(0.0, 100.0, 1.0) = 96.0;

const int FEATHER_SAMPLES = 12;
varying vec4 marker_tint;

void vertex() {
	marker_tint = COLOR;
}

float atlas_edge_fade(vec2 uv, vec2 texel_size, float lod) {
	// Fade clamped mip samples over their footprint where artwork touches the atlas edge.
	vec2 distance_to_edge = min(uv, vec2(1.0) - uv);
	vec2 fade = smoothstep(vec2(0.0), texel_size * exp2(lod) * 0.5, distance_to_edge);
	return fade.x * fade.y;
}

#define MASK_AT(uv, lod) (textureLod(TEXTURE, uv, lod).a * atlas_edge_fade(uv, TEXTURE_PIXEL_SIZE, lod))

void fragment() {
	float footprint = length(vec2(dFdx(UV.y), dFdy(UV.y))) / TEXTURE_PIXEL_SIZE.y;
	float crest_lod = max(edge_softness, log2(max(1.0, footprint)));
	float mask = MASK_AT(UV, crest_lod);
	float feather = 0.0;

	if (feather_length > 0.0 && feather_opacity > 0.0) {
		// The sprite is authored pointing up, so positive texture Y faces the crosshair.
		vec2 inward = vec2(0.0, feather_length * TEXTURE_PIXEL_SIZE.y);
		for (int tap = 0; tap < FEATHER_SAMPLES; tap++) {
			float fraction = (float(tap) + 0.5) / float(FEATHER_SAMPLES);
			float sample_alpha = MASK_AT(UV - inward * fraction, crest_lod + 0.45 + fraction * 0.75);
			float weight = 1.0 - smoothstep(0.2, 1.0, fraction);
			feather += sample_alpha * weight;
		}
		// Compensate for spreading the narrow crest across a wider veil.
		feather = min(feather * (2.8 / float(FEATHER_SAMPLES)), 1.0) * feather_opacity;
	}
	float coverage = max(mask * crest_opacity, feather);
	COLOR = vec4(marker_tint.rgb, 1.0) * coverage * marker_tint.a;
}
