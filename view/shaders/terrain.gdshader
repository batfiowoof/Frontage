// The campaign ground. Each hex arrives as a flat colour; this gives it texture, darkens
// it toward its own edge so neighbours read apart without a black outline round every
// one, and ripples the water.
//
// UV is the hex's own local position, corner at radius 1 (see campaign_view._ground_draw),
// and a COLOR alpha a touch under 1 marks water -- there is no other channel to say which
// terrain this is without a texture per kind.
shader_type canvas_item;

varying vec2 world;

void vertex() {
	world = (MODEL_MATRIX * vec4(VERTEX, 0.0, 1.0)).xy;
}

float hash(vec2 p) {
	return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
}

// Gradient noise, not value noise: value noise is flat at every lattice point, and the
// flats line up into axis-aligned blocks you can see across a whole field.
float corner(vec2 cell, vec2 f) {
	float a = hash(cell) * 6.2831853;
	return dot(vec2(cos(a), sin(a)), f);
}

float noise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	vec2 u = f * f * (3.0 - 2.0 * f);
	float n = mix(mix(corner(i, f), corner(i + vec2(1.0, 0.0), f - vec2(1.0, 0.0)), u.x),
		mix(corner(i + vec2(0.0, 1.0), f - vec2(0.0, 1.0)), corner(i + vec2(1.0, 1.0), f - vec2(1.0, 1.0)), u.x), u.y);
	return 0.5 + 0.75 * n;
}

float fbm(vec2 p) {
	float v = 0.0;
	float a = 0.5;
	for (int i = 0; i < 4; i++) {
		v += a * noise(p);
		// Turned as well as scaled, or every octave's lattice lines up and the
		// ground comes out in axis-aligned blocks.
		p = mat2(vec2(0.8, -0.6), vec2(0.6, 0.8)) * p * 2.03;
		a *= 0.5;
	}
	return v;
}

void fragment() {
	vec2 p = (UV - 0.5) * 2.0;
	// Pointy-top: the flat sides are vertical, so the edge is the larger of |x| and the
	// two slanted sides, normalised so the edge itself is 1.
	float edge = max(abs(p.x), abs(p.x) * 0.5 + abs(p.y) * 0.8660254) / 0.8660254;
	bool water = COLOR.a < 0.99;
	vec3 c = COLOR.rgb;
	float broad = fbm(world * 0.02);
	float fine = fbm(world * 0.22);
	c *= 0.8 + 0.34 * broad;
	c *= 0.92 + 0.16 * fine;
	if (water) {
		float swell = sin(world.x * 0.09 + world.y * 0.05 + TIME * 0.8 + broad * 6.0);
		c += vec3(0.05, 0.07, 0.08) * smoothstep(0.75, 1.0, swell);
	}
	c *= mix(1.0, 0.7, smoothstep(0.72, 1.0, edge));
	COLOR = vec4(c, 1.0);
}
