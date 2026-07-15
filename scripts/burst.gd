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
## Empty alpha means "use each dot's own resource colour" (a rupture, a cut).
## A boost pickup or wither passes one shared colour instead — those bits
## don't represent resources, so of_res(kind) would be meaningless for them.
var _override := Color(0, 0, 0, 0)
## Scales speed and lifetime. The run gets louder and more violent as it
## escalates, and a rupture late in a run should read as more dangerous than
## the first one — see game.gd's intensity-scaled call sites.
var _life := LIFE


func spawn(points: Array[Vector2], kinds: Array[int], run_seed: int,
		color_override := Color(0, 0, 0, 0), intensity := 0.0) -> void:
	_rng.seed = run_seed
	_override = color_override
	_life = LIFE * (1.0 + clampf(intensity, 0.0, 1.0) * 0.5)
	z_index = 12
	var speed_mul := 1.0 + clampf(intensity, 0.0, 1.0) * 0.9
	for i in points.size():
		var dir := Vector2.RIGHT.rotated(_rng.randf() * TAU)
		_bits.append({
			"p": points[i],
			"v": dir * _rng.randf_range(60.0, 190.0) * speed_mul,
			"kind": kinds[i],
		})


func _process(delta: float) -> void:
	_t += delta
	if _t >= _life or _bits.is_empty():
		queue_free()
		return
	for b in _bits:
		b.p += b.v * delta
		b.v *= 1.0 - minf(DRAG * delta, 1.0)
	queue_redraw()


func _draw() -> void:
	var fade := 1.0 - clampf(_t / _life, 0.0, 1.0)
	for b in _bits:
		var c: Color = _override if _override.a > 0.0 else Palette.of_res(b.kind)
		c.a = fade
		draw_circle(b.p, 3.4 * fade, c)
