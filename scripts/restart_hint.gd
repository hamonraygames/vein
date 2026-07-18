extends Node2D
## A small, always-visible "tap to restart" icon in the corner. The death
## screen's own tap-anywhere-to-retry (see reheart.gd) only ever fires once
## a run is already over — this lets a run be abandoned and restarted at any
## time. Reuses the exact same pulsing-hexagon language as reheart.gd's
## full-screen prompt, just small and corner-anchored, so it reads as "the
## same verb, always available" rather than a new thing to learn.

const R := 13.0
const MARGIN := 30.0
## Slack added to R for hit-testing — a target this small needs a forgiving
## thumb radius or it just won't register on a phone.
const HIT_SLACK := 8.0

@onready var game: Node2D = get_parent()

var _t := 0.0


func _ready() -> void:
	z_index = 22


func _process(delta: float) -> void:
	_t += delta
	queue_redraw()


func _corner() -> Vector2:
	var vp: Vector2 = game.design_size() if game != null else Vector2(540.0, 1170.0)
	return Vector2(vp.x - MARGIN, MARGIN)


func _draw() -> void:
	var c := _corner()
	var swell := pow(maxf(0.0, sin(_t * 1.1)), 3.0)
	var r := R * (1.0 + swell * 0.12)

	var pts := PackedVector2Array()
	for i in 6:
		var a := TAU * (float(i) / 6.0) - PI * 0.5
		pts.append(c + Vector2(cos(a), sin(a)) * r)
	pts.append(pts[0])

	var fill := Palette.HEART
	fill.a = 0.05 + swell * 0.10
	draw_colored_polygon(pts, fill)

	var line := Palette.HEART
	line.a = 0.24 + swell * 0.22
	draw_polyline(pts, line, 1.6, true)


func hit(p: Vector2) -> bool:
	return p.distance_to(_corner()) <= R + HIT_SLACK
