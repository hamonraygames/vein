extends Node2D
## A knife-slash streak along the actual swipe path that just cut a vein —
## see game.gd's _slice_check ("Fruit-Ninja style: any vein the swipe path
## actually crosses gets cut"). The cut itself already worked with no visual
## call-out; this is purely the "you just sliced that with a blade" read, so
## the gesture teaches itself instead of the player wondering why a line
## disappeared. Same self-contained, self-freeing pattern as burst.gd/
## poison_dart.gd — draws in absolute world coordinates, not relative to
## `position`.
##
## A bright core over a wider, dimmer glow, both fading fast — the same
## two-layer trick poison_dart.gd's head+tail uses to read as motion rather
## than a static mark.

const LIFE := 0.16

var _from := Vector2.ZERO
var _to := Vector2.ZERO
var _t := 0.0


func spawn(from: Vector2, to: Vector2) -> void:
	_from = from
	_to = to
	z_index = 22


func _process(delta: float) -> void:
	_t += delta
	if _t >= LIFE:
		queue_free()
		return
	queue_redraw()


func _draw() -> void:
	var fade := 1.0 - clampf(_t / LIFE, 0.0, 1.0)
	var glow := Palette.SCORE
	glow.a = fade * 0.35
	draw_line(_from, _to, glow, 9.0 * fade + 2.0, true)
	var core := Palette.SCORE
	core.a = fade
	draw_line(_from, _to, core, 2.6, true)
