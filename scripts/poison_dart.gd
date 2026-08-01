extends Node2D
## A visible poison dot travelling from a raging corrupted node to the
## neighbour it is about to turn — see game.gd's _tick_corruption. Without
## this, a neighbour just silently flipped to necrotic with a burst at ITS
## own position; nothing showed the ATTACK itself, only the aftermath. Same
## self-contained, self-freeing pattern as float_text.gd/burst.gd — draws in
## absolute world coordinates (vein_layer has no transform of its own, same
## assumption burst.gd already makes), not relative to `position`.

const TRAVEL_TIME := 0.22

var _from := Vector2.ZERO
var _to := Vector2.ZERO
var _t := 0.0


func spawn(from: Vector2, to: Vector2) -> void:
	_from = from
	_to = to
	z_index = 20


func _process(delta: float) -> void:
	_t += delta
	if _t >= TRAVEL_TIME:
		queue_free()
		return
	queue_redraw()


func _draw() -> void:
	var p := clampf(_t / TRAVEL_TIME, 0.0, 1.0)
	# Ease-in: a slow wind-up, a fast strike — reads as a lunge, not a dot
	# gliding evenly across.
	var eased := p * p
	var head := _from.lerp(_to, eased)
	var tail := _from.lerp(_to, maxf(0.0, eased - 0.14))
	draw_line(tail, head, Palette.VOID, 3.0, true)
	draw_circle(head, 4.5, Palette.VOID)
