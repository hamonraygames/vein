extends Control
## Minimal custom in-game keyboard — lowercase letters, digits, and a small
## special set (`_ - .`), matching exactly what the server's name-uniqueness
## check accepts (see server/leaderboard/submit.js's cleanName). Replaces the
## old native LineEdit / bridged HTML <input> (see name_prompt.gd's previous
## revision and web/telegram_shell.html) on every platform alike — no DOM
## focus quirks to work around, same visual language everywhere (Telegram,
## web, native), and the same component serves both first-launch name entry
## and the rename flow.
##
## Real Button nodes per key, not a custom _draw/_input hit-test grid — a
## Button already gives correct touch feedback and consumes its own tap (same
## reasoning as name_prompt.gd's existing "Continue" button and every
## Death-screen button), so there's no reason to reinvent hit-testing here.
##
## Owns its own text buffer and preview line, and the Done key, so a caller
## just calls start() and listens for `submitted` — same "spawn it and read
## one signal back" shape as every other dynamically-built modal in this game.
##
## Absolute pixel position/size against `vp`, not anchors — same convention
## documented in name_prompt.gd's header (anchors don't reliably resolve for
## a Control added to the tree at runtime in this project).

signal submitted(text: String)

const MAX_LEN := 20
const KEY_W := 46.0
const KEY_H := 46.0
const GAP := 4.0

const ROW_LETTERS_1 := ["q", "w", "e", "r", "t", "y", "u", "i", "o", "p"]
const ROW_LETTERS_2 := ["a", "s", "d", "f", "g", "h", "j", "k", "l"]
## "DEL", not the "⌫" glyph (U+232B) this used to be — Space Mono has no
## glyph for it, and unlike a native build (which can pull in an OS-level
## fallback font), a web export like Telegram's Mini App has no such
## fallback: the key rendered completely blank there. Still tappable either
## way (Button hit-testing doesn't care what the label renders as), but
## invisible reads as "not working" when you can't see where to tap it.
const ROW_LETTERS_3 := ["z", "x", "c", "v", "b", "n", "m", "DEL"]
const ROW_DIGITS := ["1", "2", "3", "4", "5", "6", "7", "8", "9", "0"]
const ROW_SPECIALS := ["_", "-", "."]

var _vp := Vector2(540.0, 1170.0)
var _text := ""
var _preview: Label
var _done_btn: Button
var _key_style: StyleBoxFlat
var _key_style_pressed: StyleBoxFlat


## `top_y` is where the keyboard's own rect begins in the CALLER's space —
## everything below is this component; everything above (title, error line,
## suggestion chips) is the caller's own to lay out, since this Control only
## covers (and only captures input across) its own rect from `top_y` down.
func start(vp: Vector2, top_y: float, initial_text := "") -> void:
	_vp = Vector2(vp.x, vp.y - top_y)
	_text = initial_text
	position = Vector2(0.0, top_y)
	size = _vp
	mouse_filter = Control.MOUSE_FILTER_STOP

	_key_style = StyleBoxFlat.new()
	_key_style.bg_color = Color(1, 1, 1, 0.08)
	_key_style.corner_radius_top_left = 8
	_key_style.corner_radius_top_right = 8
	_key_style.corner_radius_bottom_right = 8
	_key_style.corner_radius_bottom_left = 8
	_key_style_pressed = _key_style.duplicate()
	_key_style_pressed.bg_color = Color(1, 1, 1, 0.2)

	_preview = Label.new()
	_preview.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_preview.add_theme_color_override("font_color", Palette.SCORE)
	_preview.add_theme_font_size_override("font_size", 24)
	_preview.position = Vector2(0.0, PREVIEW_Y)
	_preview.size = Vector2(_vp.x, 36.0)
	add_child(_preview)
	_update_preview()

	var y := PREVIEW_Y + 56.0
	y = _add_row(ROW_LETTERS_1, y)
	y = _add_row(ROW_LETTERS_2, y)
	y = _add_row(ROW_LETTERS_3, y)
	y = _add_row(ROW_DIGITS, y)
	y = _add_row(ROW_SPECIALS, y)

	_done_btn = Button.new()
	_done_btn.text = "Done"
	_done_btn.position = Vector2(_vp.x * 0.5 - 90.0, y + 10.0)
	_done_btn.size = Vector2(180.0, 48.0)
	_done_btn.add_theme_font_size_override("font_size", 18)
	_done_btn.pressed.connect(_on_done)
	add_child(_done_btn)


## Godot's own default button theme otherwise, clashing with every other
## button in the game — the owner calls this right after start() (see
## name_prompt.gd) to give Done the same cream primary look as Play/Replay,
## borrowed from a live button elsewhere rather than redefining it here.
func style_primary(donor: Button) -> void:
	for state in ["normal", "hover", "pressed", "focus"]:
		_done_btn.add_theme_stylebox_override(state, donor.get_theme_stylebox(state))
	for state in ["font_color", "font_hover_color", "font_pressed_color"]:
		_done_btn.add_theme_color_override(state, donor.get_theme_color(state))


const PREVIEW_Y := 10.0


func _add_row(keys: Array, y: float) -> float:
	var n := keys.size()
	var row_w := float(n) * KEY_W + float(n - 1) * GAP
	var x := (_vp.x - row_w) * 0.5
	for k in keys:
		var btn := _make_key(k)
		btn.position = Vector2(x, y)
		add_child(btn)
		x += KEY_W + GAP
	return y + KEY_H + GAP


func _make_key(label: String) -> Button:
	var btn := Button.new()
	btn.text = label
	btn.size = Vector2(KEY_W, KEY_H)
	# "DEL" is 3 characters against everything else's 1 — shrink just that
	# one label so it doesn't crowd the same 46px-wide key.
	btn.add_theme_font_size_override("font_size", 13 if label == "DEL" else 18)
	btn.add_theme_color_override("font_color", Palette.SCORE)
	btn.add_theme_stylebox_override("normal", _key_style)
	btn.add_theme_stylebox_override("hover", _key_style)
	btn.add_theme_stylebox_override("pressed", _key_style_pressed)
	btn.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
	if label == "DEL":
		btn.pressed.connect(_on_backspace)
	else:
		btn.pressed.connect(_on_char.bind(label))
	return btn


func _on_char(ch: String) -> void:
	if _text.length() >= MAX_LEN:
		return
	_text += ch
	_update_preview()


func _on_backspace() -> void:
	if _text.is_empty():
		return
	_text = _text.substr(0, _text.length() - 1)
	_update_preview()


func _update_preview() -> void:
	_preview.text = _text if not _text.is_empty() else " "


func _on_done() -> void:
	var t := _text.strip_edges()
	if t.is_empty():
		return
	submitted.emit(t)
