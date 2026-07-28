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
## Playtest: "keyboard buttons should be bigger, similar to iPhone keyboard",
## then a follow-up pass asking for still more height and bigger labels — a
## real iOS keyboard's keys run nearly edge to edge with a taller-than-wide
## shape and only a few points of gap between them, not a small tile
## floating in a lot of empty margin. KEY_W is already close to the 10-key
## top row's own width ceiling against `_vp.x`, so it barely moves; KEY_H and
## GAP (and KEY_FONT_SIZE below) are what actually change the feel.
const KEY_W := 47.0
const KEY_H := 60.0
const GAP := 6.0
const KEY_FONT_SIZE := 22
## DEL is the one key players hunt for under pressure (typo, wrong char) —
## explicit direction to give it more width than an ordinary letter key, on
## top of the vector icon below replacing its old cramped "DEL" text.
const DEL_KEY_W := 66.0

const ROW_LETTERS_1 := ["q", "w", "e", "r", "t", "y", "u", "i", "o", "p"]
const ROW_LETTERS_2 := ["a", "s", "d", "f", "g", "h", "j", "k", "l"]
## "DEL" used to be the "⌫" glyph (U+232B) — Space Mono has no glyph for it,
## and unlike a native build (which can pull in an OS-level fallback font), a
## web export like Telegram's Mini App has no such fallback: the key
## rendered completely blank there. Swapping to the literal text "DEL"
## worked everywhere but read as cramped and less recognizable than a real
## icon — _make_key below now draws a plain left-arrow backspace icon with
## draw_line/draw_colored_polygon instead of text, so it's a proper icon that
## still can't go blank on any platform: no font glyph involved anywhere.
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
	_done_btn.position = Vector2(_vp.x * 0.5 - 100.0, y + 10.0)
	_done_btn.size = Vector2(200.0, KEY_H)
	_done_btn.add_theme_font_size_override("font_size", 22)
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


## DEL is wider than an ordinary key (see DEL_KEY_W), so a row's total width
## can no longer assume every key is the same size — summed per-key instead.
func _key_width(label: String) -> float:
	return DEL_KEY_W if label == "DEL" else KEY_W


func _add_row(keys: Array, y: float) -> float:
	var row_w := 0.0
	for k in keys:
		row_w += _key_width(k)
	row_w += float(keys.size() - 1) * GAP
	var x := (_vp.x - row_w) * 0.5
	for k in keys:
		var w := _key_width(k)
		var btn := _make_key(k, w)
		btn.position = Vector2(x, y)
		add_child(btn)
		x += w + GAP
	return y + KEY_H + GAP


func _make_key(label: String, width: float) -> Button:
	var btn := Button.new()
	btn.size = Vector2(width, KEY_H)
	btn.add_theme_color_override("font_color", Palette.SCORE)
	btn.add_theme_stylebox_override("normal", _key_style)
	btn.add_theme_stylebox_override("hover", _key_style)
	btn.add_theme_stylebox_override("pressed", _key_style_pressed)
	btn.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
	if label == "DEL":
		# No text at all — see _draw_del_icon, a plain vector arrow instead of
		# a font glyph, so it can never render blank on any platform.
		var icon := Control.new()
		icon.size = btn.size
		icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
		icon.draw.connect(_draw_del_icon.bind(icon))
		btn.add_child(icon)
		btn.pressed.connect(_on_backspace)
	else:
		btn.text = label
		btn.add_theme_font_size_override("font_size", KEY_FONT_SIZE)
		btn.pressed.connect(_on_char.bind(label))
	return btn


## A plain left-pointing arrow (shaft + arrowhead), drawn straight onto a
## Control laid over the DEL key — see ROW_LETTERS_3's comment for why this
## replaced BOTH the old Unicode glyph (invisible in Telegram's web export)
## and the "DEL" text fallback (readable everywhere, but cramped and less
## recognizable than an actual icon). A vector draw has no font dependency
## at all, so there's no platform left for it to go blank on.
const DEL_ICON_W := 24.0
const DEL_ICON_H := 16.0

func _draw_del_icon(icon: Control) -> void:
	var col := Palette.SCORE
	var c := icon.size * 0.5
	var half_w := DEL_ICON_W * 0.5
	var half_h := DEL_ICON_H * 0.5
	var tip := c + Vector2(-half_w, 0.0)
	var head_top := c + Vector2(-half_w + half_h, -half_h)
	var head_bot := c + Vector2(-half_w + half_h, half_h)
	icon.draw_line(tip, c + Vector2(half_w, 0.0), col, 3.0)
	icon.draw_colored_polygon(PackedVector2Array([tip, head_top, head_bot]), col)


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
