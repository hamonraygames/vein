extends Control
## One-time "what should we call you" prompt, shown from game.gd's _ready()
## before the very first run of the game ever starts — the name is saved
## locally (game.gd's player_name) and every death from then on submits to
## the leaderboard under it automatically (see _submit_score), no further
## prompting.
##
## On web (the only platform real players ever see this on), the actual
## text field is a REAL native HTML <input> bridged in from
## web/telegram_shell.html (see there), not Godot's own LineEdit — a canvas
## has no DOM element for a mobile browser to focus, so Godot's web LineEdit
## can never reliably raise the on-screen keyboard on a phone (a known,
## unfixed upstream Godot limitation, not something fixable from GDScript
## alone). Native/editor builds still use a plain LineEdit — no mobile
## keyboard to worry about there.
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
# Shared with web/telegram_shell.html's veinShowNameInput call below — the
# JS side positions the real <input> using these same fractions of the
# canvas's own on-screen rect, so the two stay visually aligned.
const EDIT_X := 0.2
const EDIT_Y := 0.46
const EDIT_W := 0.6
const EDIT_H := 0.045

var _edit: LineEdit
var _web := false
var _js_submit_callback: JavaScriptObject


func start(vp: Vector2) -> void:
	position = Vector2.ZERO
	size = vp
	# A full-rect STOP-filter Control already consumes all input by itself —
	# no custom _input() swallowing needed the way the leaderboard panel's
	# plain Node2D required.
	mouse_filter = Control.MOUSE_FILTER_STOP
	z_index = 31
	_web = OS.has_feature("web")

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

	if _web:
		# Real DOM element, real native focus, real OS keyboard — see the
		# class doc above. Enter/"Go" on that keyboard also submits directly
		# (worth having beyond just the Continue button below: an open
		# mobile keyboard can be tall enough to cover it entirely on a short
		# screen) via this JS -> GDScript callback.
		_js_submit_callback = JavaScriptBridge.create_callback(_on_js_submit)
		JavaScriptBridge.get_interface("window").veinOnNameSubmit = _js_submit_callback
		JavaScriptBridge.eval("window.veinShowNameInput(%f, %f, %f, %f, %s)"
			% [EDIT_X, EDIT_Y, EDIT_W, EDIT_H, JSON.stringify("Name")])
	else:
		_edit = LineEdit.new()
		_edit.placeholder_text = "Name"
		_edit.max_length = MAX_LEN
		_edit.alignment = HORIZONTAL_ALIGNMENT_CENTER
		_edit.position = Vector2(vp.x * EDIT_X, vp.y * EDIT_Y)
		_edit.size = Vector2(vp.x * EDIT_W, vp.y * EDIT_H)
		_edit.text_submitted.connect(func(_t: String) -> void: _confirm())
		add_child(_edit)

	var btn := Button.new()
	btn.text = "Continue"
	btn.position = Vector2(vp.x * 0.2, vp.y * 0.55)
	btn.size = Vector2(vp.x * 0.6, vp.y * 0.04)
	btn.pressed.connect(_confirm)
	add_child(btn)


func _on_js_submit(args: Array) -> void:
	_finish(str(args[0]) if args.size() > 0 else "")


func _confirm() -> void:
	if _web:
		_finish(str(JavaScriptBridge.eval("window.veinGetNameInputValue()")))
	else:
		_finish(_edit.text)


func _finish(raw: String) -> void:
	var t := raw.strip_edges()
	if t.is_empty():
		return
	if _web:
		JavaScriptBridge.eval("window.veinHideNameInput()")
	confirmed.emit(t)
	queue_free()
