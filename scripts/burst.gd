extends Node2D
## A rupture: the dots that were in flight scatter and die.
##
## Deliberately short and violent. This is the game's jump-scare — the player
## must register it in peripheral vision, feel it in the hand, and know exactly
## which trunk they overloaded.

const LIFE := 0.85
const DRAG := 1.9

var _bits: Array[Dictionary] = []
var _t := 0.0
var _rng := RandomNumberGenerator.new()


func spawn(points: Array[Vector2], kinds: Array[int], run_seed: int) -> void:
	_rng.seed = run_seed
	z_index = 12
	for i in points.size():
		var dir := Vector2.RIGHT.rotated(_rng.randf() * TAU)
		_bits.append({
			"p": points[i],
			"v": dir * _rng.randf_range(60.0, 190.0),
			"kind": kinds[i],
		})


func _process(delta: float) -> void:
	_t += delta
	if _t >= LIFE or _bits.is_empty():
		queue_free()
		return
	for b in _bits:
		b.p += b.v * delta
		b.v *= 1.0 - minf(DRAG * delta, 1.0)
	queue_redraw()


func _draw() -> void:
	var fade := 1.0 - clampf(_t / LIFE, 0.0, 1.0)
	for b in _bits:
		var c: Color = Palette.of_res(b.kind)
		c.a = fade
		draw_circle(b.p, 3.4 * fade, c)
