extends Control
## "Restore account" — reopened from the main menu's own link, lets a player
## on a fresh install trade a recovery code (shown once after their first
## name claim, see game.gd's recovery_code / server/leaderboard/README.md's
## `/recover` section) for the player_id/name/best_score it belongs to,
## instead of staying stuck with whatever random name this device auto-
## claimed on first launch (see game._start_random_name_claim).
##
## Same onscreen-keyboard-plus-live-state-poll shape as name_prompt.gd — see
## its own header comment for why (no native LineEdit, absolute pixel
## position/size against `vp` rather than anchors). Submitting goes through
## game._recover_account, which only ever READS (see its own comment); this
## screen is the one that actually applies the result via game.
## _on_account_recovered, once the player has seen it land and can back out
## with Cancel if it's wrong before committing.

signal confirmed

const OnscreenKeyboardScene := preload("res://scripts/onscreen_keyboard.gd")
const KEYBOARD_TOP_Y := 230.0
const TITLE_Y := 60.0
const STATUS_Y := 110.0

var game: Node2D
var _vp := Vector2(540.0, 1170.0)
var _status_label: Label
var _watching := false
var _last_code := ""


func start(g: Node2D, vp: Vector2) -> void:
	game = g
	_vp = vp
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
	title.text = "Restore your account"
	title.add_theme_color_override("font_color", Palette.SCORE)
	title.add_theme_font_size_override("font_size", 20)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.position = Vector2(0.0, TITLE_Y)
	title.size = Vector2(vp.x, 30.0)
	add_child(title)

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
	_set_status("Enter the code shown on your other device.", Palette.SCORE)
	add_child(_status_label)

	var keyboard: Control = OnscreenKeyboardScene.new()
	add_child(keyboard)
	keyboard.submitted.connect(_submit)
	keyboard.start(vp, KEYBOARD_TOP_Y, "")
	keyboard.style_primary(game.replay_btn)


func _process(_delta: float) -> void:
	if not _watching:
		return
	match game.recover_state:
		"checking":
			pass
		"ok":
			_watching = false
			confirmed.emit()
			queue_free()
		"not_found":
			_watching = false
			_set_status("\"%s\" isn't a code we know. Check it and try again." % _last_code, Palette.VOID)
		"error":
			_watching = false
			_set_status("Couldn't reach the server. Try again.", Palette.VOID)


func _submit(text: String) -> void:
	# Same "ignore taps while a request is already in flight" guard
	# name_prompt.gd's _submit uses — see its own comment.
	if _watching:
		return
	_last_code = text
	_watching = true
	_set_status("Checking…", Palette.SCORE)
	game._recover_account(text)


func _set_status(text: String, col: Color) -> void:
	_status_label.text = text
	var c := col
	c.a = 0.8
	_status_label.add_theme_color_override("font_color", c)
