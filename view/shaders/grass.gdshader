// The battlefield ground: grass with broad patches and fine grain, trodden toward the
// middle where the lines meet, and falling off into dark beyond the edge of the field so
// the boundary reads as the end of the world rather than a line drawn on more grass.
//
// The noise is a texture (battle_view._build_field makes it) rather than a hash in here:
// over a 2400-unit field the sin() hash runs out of precision on the GPU and the ground
// came out in hard-edged rectangles that no amount of octave-rotation removed.
shader_type canvas_item;

uniform float half_extent = 1200.0;
uniform sampler2D noise : repeat_enable, filter_linear_mipmap;

varying vec2 world;

void vertex() {
	world = (MODEL_MATRIX * vec4(VERTEX, 0.0, 1.0)).xy;
}

void fragment() {
	vec3 lush = vec3(0.27, 0.34, 0.17);
	vec3 dry = vec3(0.4, 0.4, 0.23);
	vec3 earth = vec3(0.33, 0.28, 0.19);
	float patches = texture(noise, world * 0.00035).r;
	float grain = texture(noise, world * 0.0045 + vec2(0.37, 0.61)).r;
	float fine = texture(noise, world * 0.02 + vec2(0.13, 0.29)).r;
	vec3 c = mix(lush, dry, smoothstep(0.25, 0.8, patches));
	c *= 0.84 + 0.2 * grain + 0.1 * fine;
	// Trodden ground where the armies deploy and meet.
	float middle = 1.0 - smoothstep(0.0, half_extent * 0.45, abs(world.y) * 0.3 + abs(world.x) * 0.25);
	c = mix(c, earth, middle * 0.3 * smoothstep(0.35, 0.75, grain));
	// Outside the field: fade to dark.
	vec2 over = max(abs(world) - vec2(half_extent), vec2(0.0));
	c *= 1.0 - smoothstep(0.0, 350.0, length(over)) * 0.85;
	COLOR = vec4(c, 1.0);
}
