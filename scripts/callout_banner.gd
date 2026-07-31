extends Node2D
## A big, bold text slam for a Callout moment (combo streak, score milestone,
## narrow escape, a new best) — see callout.gd, the only thing that spawns
## this. Same self-contained, self-freeing pattern as float_text.gd/burst.gd,
## just louder: this is a rare, earned moment (callout.gd gates how often
## one fires), so it can afford to own the screen for under a second without
## reading as clutter the way something on every delivery would.

const POP_TIME := 0.14
const HOLD_TIME := 0.55
const FADE_TIME := 0.35
const LIFE := POP_TIME + HOLD_TIME + FADE_TIME
const SIZE := 46

var _text := ""
var _col := Color.WHITE
var _font: Font
var _t := 0.0


func spawn(text: String, at: Vector2, col: Color) -> void:
	_text = text
	_col = col
	_font = Palette.MONO_FONT
	position = at
	z_index = 40


func _process(delta: float) -> void:
	_t += delta
	if _t >= LIFE:
		queue_free()
		return
	queue_redraw()


## Big-to-normal overshoot on the way in (the "slam"), a steady hold, then a
## slight grow-and-fade on the way out — cheap to compute, no tween needed,
## same hand-rolled-easing approach float_text.gd/burst.gd already use.
func _draw() -> void:
	if _font == null:
		return
	var scale_mul := 1.0
	var alpha := 1.0
	if _t < POP_TIME:
		var p := _t / POP_TIME
		if p < 0.65:
			var q := p / 0.65
			scale_mul = lerpf(1.65, 0.92, 1.0 - (1.0 - q) * (1.0 - q))
		else:
			var q2 := (p - 0.65) / 0.35
			scale_mul = lerpf(0.92, 1.0, q2)
	elif _t < POP_TIME + HOLD_TIME:
		scale_mul = 1.0
	else:
		var p2 := (_t - POP_TIME - HOLD_TIME) / FADE_TIME
		alpha = 1.0 - p2
		scale_mul = 1.0 + p2 * 0.15

	var size := int(SIZE * scale_mul)
	var col := _col
	col.a = alpha
	var sw := _font.get_string_size(_text, HORIZONTAL_ALIGNMENT_LEFT, -1, size).x
	draw_string(_font, Vector2(-sw * 0.5, 0.0), _text, HORIZONTAL_ALIGNMENT_LEFT, -1, size, col)
