// Ground nobody of yours has been near: drifting cloud rather than a flat grey sheet.
// Translucent on purpose -- you can see the shape of the country, you cannot see who is
// standing in it -- and in world space, so neighbouring fogged hexes join seamlessly.
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
	for (int i = 0; i < 5; i++) {
		v += a * noise(p);
		// Turned as well as scaled, or every octave's lattice lines up and the
		// ground comes out in axis-aligned blocks.
		p = mat2(vec2(0.8, -0.6), vec2(0.6, 0.8)) * p * 2.1;
		a *= 0.5;
	}
	return v;
}

void fragment() {
	vec2 drift = vec2(TIME * 3.0, TIME * 1.2);
	float cloud = fbm((world + drift) * 0.012);
	vec3 c = mix(vec3(0.05, 0.05, 0.07), vec3(0.2, 0.2, 0.23), cloud);
	COLOR = vec4(c, 0.58 + 0.2 * cloud);
}
