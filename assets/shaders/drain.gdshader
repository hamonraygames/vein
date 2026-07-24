shader_type canvas_item;
// Three feelings, one pass.
//
// `drain` desaturates from the edges inward — the player's periphery dies first,
// which reads as tunnel vision without ever drawing a vignette.
// `warm` is the rescue flash: everything surges gold when a starving heart is
// fed just in time.
// `death` is the final beat: once the grayscale drain finishes taking the
// color out, the screen settles to a flat, dark gray. No red, no flashing —
// just still and quiet.

uniform float drain : hint_range(0.0, 1.0) = 0.0;
uniform float warm : hint_range(0.0, 1.0) = 0.0;
uniform float death : hint_range(0.0, 1.0) = 0.0;
uniform sampler2D screen_tex : hint_screen_texture, repeat_disable, filter_linear;

void fragment() {
	vec3 c = texture(screen_tex, SCREEN_UV).rgb;
	float grey = dot(c, vec3(0.299, 0.587, 0.114));

	float d = clamp(length(SCREEN_UV - vec2(0.5)) * 1.7, 0.0, 1.0);
	float amt = clamp(drain * (0.30 + d * 1.1), 0.0, 1.0);
	vec3 col = mix(c, vec3(grey), amt);

	vec3 flashed = col * vec3(1.40, 1.10, 0.72) + vec3(0.06, 0.025, 0.0);
	col = mix(col, flashed, warm * 0.6);

	// Flat dark gray, no red tint and no pulsing — just still and quiet.
	vec3 bled = vec3(grey) * 0.18 + vec3(0.05);
	col = mix(col, bled, death * 0.88);

	COLOR = vec4(col, 1.0);
}
