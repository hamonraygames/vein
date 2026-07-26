extends Control
## One-time "what should we call you" prompt, shown from game.gd's _ready()
## before the very first run of the game ever starts — the name is saved
## locally (game.gd's player_name) and every death from then on submits to
## the leaderboard under it automatically (see _submit_score), no further
## prompting.
##
## Built from real Control nodes, unlike leaderboard_panel.gd's custom
## _draw() — a LineEdit is the one piece of UI in this game that actually
## needs real text editing (cursor, selection, IME, and on Web the browser's
## own on-screen keyboard), none of which is worth reimplementing by hand.
##
## Every rect below is explicit position/size math against `vp`, NOT anchor
## fractions — verified empirically that a Control's anchors do not reliably
## resolve when it's added to the tree at runtime (its rect measured (0, 0)
## even parented under a proven correctly-sized, .tscn-declared Control), so
## this uses the same absolute-pixel-against-design-size approach every
## other dynamically-built element in this game already does (score_hud.gd,
## leaderboard_panel.gd, ranks_strip.gd).

signal confirmed(name_text: String)

const MAX_LEN := 20

var _edit: LineEdit


func start(vp: Vector2) -> void:
	position = Vector2.ZERO
	size = vp
	# A full-rect STOP-filter Control already consumes all input by itself —
	# no custom _input() swallowing needed the way the leaderboard panel's
	# plain Node2D required.
	mouse_filter = Control.MOUSE_FILTER_STOP
	z_index = 31

	var backdrop := ColorRect.new()
	backdrop.position = Vector2.ZERO
	backdrop.size = vp
	backdrop.color = Color(Palette.BG, 0.94)
	backdrop.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(backdrop)

	var label := Label.new()
	label.text = "What should we call you?"
	label.add_theme_color_override("font_color", Palette.SCORE)
	label.add_theme_font_size_override("font_size", 20)
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.position = Vector2(0.0, vp.y * 0.4)
	label.size = Vector2(vp.x, vp.y * 0.04)
	add_child(label)

	_edit = LineEdit.new()
	_edit.placeholder_text = "Name"
	_edit.max_length = MAX_LEN
	_edit.alignment = HORIZONTAL_ALIGNMENT_CENTER
	_edit.position = Vector2(vp.x * 0.2, vp.y * 0.46)
	_edit.size = Vector2(vp.x * 0.6, vp.y * 0.045)
	_edit.text_submitted.connect(func(_t: String) -> void: _confirm())
	add_child(_edit)

	var btn := Button.new()
	btn.text = "Continue"
	btn.position = Vector2(vp.x * 0.2, vp.y * 0.55)
	btn.size = Vector2(vp.x * 0.6, vp.y * 0.04)
	btn.pressed.connect(_confirm)
	add_child(btn)

	# Deliberately NOT auto-focusing the LineEdit here. Mobile browsers
	# (including Telegram's in-app WebView) only pop the on-screen keyboard
	# when a text field is focused synchronously INSIDE a real touch/click
	# handler — a grab_focus() called from setup code, with no tap behind
	# it, silently fails to raise the keyboard even though the field visibly
	# shows a focus outline. The player's own tap on the field focuses it
	# through Control's normal click-to-focus behaviour, which IS a real
	# gesture and does trigger the keyboard correctly.


func _confirm() -> void:
	var t := _edit.text.strip_edges()
	if t.is_empty():
		return
	confirmed.emit(t)
	queue_free()
