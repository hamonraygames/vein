extends Control
## The retry prompt is a fresh Heart, already pulsing faintly. No button, no
## label — tapping anywhere on the death screen starts the next run.

const R := 26.0

var t := 0.0


func _process(delta: float) -> void:
	# Unscaled: this keeps beating at rest even though the run's time_scale died
	# with it.
	t += delta
	queue_redraw()


func _draw() -> void:
	var c := Vector2(size.x * 0.5, size.y * 0.62)
	var swell := pow(maxf(0.0, sin(t * 1.5)), 3.0)
	var r := R * (1.0 + swell * 0.13)

	var pts := PackedVector2Array()
	for i in 6:
		var a := TAU * (float(i) / 6.0) - PI * 0.5
		pts.append(c + Vector2(cos(a), sin(a)) * r)
	pts.append(pts[0])

	var fill := Palette.HEART
	fill.a = 0.05 + swell * 0.16
	draw_colored_polygon(pts, fill)

	var line := Palette.HEART
	line.a = 0.30 + swell * 0.35
	draw_polyline(pts, line, 2.0, true)
