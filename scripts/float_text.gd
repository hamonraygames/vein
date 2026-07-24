extends Node2D
## A number popping out of the Heart and fading — the Notcoin/Hamster Kombat
## confirmation language applied to fuel gain: every delivery gets an
## immediate, legible "how much", not just a fuel line that rises too slowly
## to read as a consequence of the specific thing that just landed.
##
## Drifts outward along `dir` rather than always straight up — a delivery that
## lands on the Heart's rim reads as coming FROM the Heart along that same
## radius, not floating off in a fixed screen direction unrelated to where it
## spawned.
##
## Self-contained and self-freeing, same pattern as BurstScene.

const LIFE := 0.8
const RISE := 38.0

var _text := ""
var _col := Color.WHITE
var _size := 16
var _dir := Vector2.UP
var _t := 0.0
var _font: Font
## True for spawn_cross() — draws a vector "+" cross instead of a string.
## Text relies on the fallback font having the glyph; a game-drawn shape
## can't come out as a missing-character box and matches the rest of the
## game's vector language (every in-world mark is a shape, never a glyph).
var _cross := false


func spawn(text: String, at: Vector2, col: Color, size := 16, dir := Vector2.UP) -> void:
	_text = text
	_col = col
	_size = size
	_dir = dir if dir != Vector2.ZERO else Vector2.UP
	_font = ThemeDB.fallback_font
	_cross = false
	position = at
	z_index = 25


## A wrong-delivery mark: "X read as a rejection, not the right shape — it
## should be a cross." Same pop/rise/fade timing as a text mark, just a
## drawn "+" instead of a string.
func spawn_cross(at: Vector2, col: Color, size := 16, dir := Vector2.UP) -> void:
	_col = col
	_size = size
	_dir = dir if dir != Vector2.ZERO else Vector2.UP
	_cross = true
	position = at
	z_index = 25


func _process(delta: float) -> void:
	_t += delta
	if _t >= LIFE:
		queue_free()
		return
	queue_redraw()


func _draw() -> void:
	var t := _t / LIFE
	# Ease-out: quick pop, slow drift — read as a jolt, not a gentle rise.
	var eased := 1.0 - (1.0 - t) * (1.0 - t)
	var offset := _dir * RISE * eased
	var col := _col
	col.a = _col.a * (1.0 - t)

	if _cross:
		var half := float(_size) * 0.32
		var w := maxf(2.2, float(_size) * 0.16)
		draw_line(offset - Vector2(half, 0.0), offset + Vector2(half, 0.0), col, w, true)
		draw_line(offset - Vector2(0.0, half), offset + Vector2(0.0, half), col, w, true)
		return

	if _font == null:
		return
	var sw := _font.get_string_size(_text, HORIZONTAL_ALIGNMENT_LEFT, -1, _size).x
	draw_string(_font, offset - Vector2(sw * 0.5, 0.0), _text,
		HORIZONTAL_ALIGNMENT_LEFT, -1, _size, col)
