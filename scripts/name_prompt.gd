extends Control
## "What should we call you?" (first launch) / rename prompt — shown from
## game.gd's _ready() before the very first run ever starts, and reopened
## from the main menu's "Name" entry to change it later (see
## game._on_open_rename). Both paths share this one screen: empty
## `initial_text` for a first-time claim, the current player_name for a
## rename — the only visible difference is the title and whether a Cancel
## corner button exists (nothing to cancel back to on the very first launch).
##
## Text entry is the custom onscreen_keyboard.gd component on every platform
## alike — no native LineEdit, no bridged HTML <input> (see git history for
## the old per-platform approach this replaced). Submitting goes through
## game._claim_name, which enforces server-side name uniqueness (see
## server/leaderboard/submit.js's /name route) — this screen just watches
## game.name_state (same live-read-every-frame pattern leaderboard_panel.gd
## uses for game.lb_state) and reacts: "checking" shows a status line,
## "taken" shows the error plus tappable suggested variations instead of
## making the player guess blind, "ok" confirms and closes.
##
## Every rect below is explicit position/size math against `vp`, NOT anchor
## fractions — verified empirically that a Control's anchors do not reliably
## resolve when it's added to the tree at runtime, so this uses the same
## absolute-pixel-against-design-size approach every other dynamically-built
## element in this game already does (score_hud.gd, leaderboard_panel.gd,
## ranks_strip.gd).

signal confirmed(name_text: String)

const OnscreenKeyboardScene := preload("res://scripts/onscreen_keyboard.gd")
const KEYBOARD_TOP_Y := 230.0
const TITLE_Y := 60.0
const STATUS_Y := 110.0
const SUGGESTIONS_Y := 150.0

var game: Node2D
var _vp := Vector2(540.0, 1170.0)
var _status_label: Label
var _suggestion_btns: Array[Button] = []
var _watching := false
var _editable := false
var _last_text := ""


func start(g: Node2D, vp: Vector2, initial_text := "") -> void:
	game = g
	_vp = vp
	_editable = not initial_text.is_empty()
	position = Vector2.ZERO
	size = vp
	mouse_filter = Control.MOUSE_FILTER_STOP
	z_index = 31

	var backdrop := ColorRect.new()
	backdrop.position = Vector2.ZERO
	backdrop.size = vp
	backdrop.color = Color(Palette.BG, 0.94)
	backdrop.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(backdrop)

	var title := Label.new()
	title.text = "Change your name" if _editable else "What should we call you?"
	title.add_theme_color_override("font_color", Palette.SCORE)
	title.add_theme_font_size_override("font_size", 20)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.position = Vector2(0.0, TITLE_Y)
	title.size = Vector2(vp.x, 30.0)
	add_child(title)

	if _editable:
		var cancel := Button.new()
		cancel.text = "Cancel"
		cancel.flat = true
		cancel.add_theme_color_override("font_color", Palette.SCORE)
		cancel.add_theme_font_size_override("font_size", 15)
		cancel.position = Vector2(20.0, 20.0)
		cancel.size = Vector2(90.0, 34.0)
		cancel.pressed.connect(func() -> void: queue_free())
		add_child(cancel)

	_status_label = Label.new()
	_status_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_status_label.add_theme_font_size_override("font_size", 15)
	_status_label.position = Vector2(0.0, STATUS_Y)
	_status_label.size = Vector2(vp.x, 26.0)
	add_child(_status_label)

	var keyboard: Control = OnscreenKeyboardScene.new()
	add_child(keyboard)
	keyboard.submitted.connect(_submit)
	keyboard.start(vp, KEYBOARD_TOP_Y, initial_text)
	keyboard.style_primary(game.replay_btn)


func _process(_delta: float) -> void:
	if not _watching:
		return
	match game.name_state:
		"checking":
			pass
		"ok":
			_watching = false
			confirmed.emit(_last_text)
			queue_free()
		"taken":
			_watching = false
			_set_status("\"%s\" is taken." % _last_text, Palette.VOID)
			_show_suggestions(game.name_suggestions)
		"error":
			_watching = false
			_set_status("Couldn't reach the server. Try again.", Palette.VOID)


func _submit(text: String) -> void:
	_last_text = text
	_clear_suggestions()
	_watching = true
	_set_status("Checking…", Palette.SCORE)
	game._claim_name(text)


func _set_status(text: String, col: Color) -> void:
	_status_label.text = text
	var c := col
	c.a = 0.8
	_status_label.add_theme_color_override("font_color", c)


func _clear_suggestions() -> void:
	for b in _suggestion_btns:
		b.queue_free()
	_suggestion_btns.clear()


func _show_suggestions(suggestions: Array) -> void:
	_clear_suggestions()
	if suggestions.is_empty():
		return
	const BTN_H := 34.0
	const GAP := 8.0
	var widths: Array[float] = []
	var total_w := 0.0
	for s in suggestions:
		var w: float = 70.0 + float(str(s).length()) * 8.0
		widths.append(w)
		total_w += w
	total_w += GAP * float(suggestions.size() - 1)
	var x := (_vp.x - total_w) * 0.5
	for i in suggestions.size():
		var s := str(suggestions[i])
		var btn := Button.new()
		btn.text = s
		btn.add_theme_font_size_override("font_size", 15)
		for state in ["normal", "hover", "pressed", "focus"]:
			btn.add_theme_stylebox_override(state, game.share_btn.get_theme_stylebox(state))
		for state in ["font_color", "font_hover_color", "font_pressed_color"]:
			btn.add_theme_color_override(state, game.share_btn.get_theme_color(state))
		btn.position = Vector2(x, SUGGESTIONS_Y)
		btn.size = Vector2(widths[i], BTN_H)
		btn.pressed.connect(_submit.bind(s))
		add_child(btn)
		_suggestion_btns.append(btn)
		x += widths[i] + GAP
