extends Node2D
## The in-game leaderboard: submits this run's score to server/leaderboard
## (an AWS Lambda, see there) and renders the top 10 + your rank + totals
## as a modal over the death screen — spawned once from game.gd's
## _on_share_score and self-freeing on tap, same "caller spawns it and
## forgets it" pattern as ShatterScene/BurstScene/FloatText.
##
## Custom-drawn like every other dynamic-content readout in this game
## (score_hud.gd, budget_hint.gd) rather than built from Control/Label nodes —
## there is no fixed number of rows to hand-place in the scene, and this
## keeps the same vector-drawn language as everything else.

enum State { LOADING, LOADED, ERROR }

var _state := State.LOADING
var _error_msg := ""
var _top: Array = []
var _you := {"rank": 0, "score": 0, "isBest": false}
var _total_players := 0
var _total_plays := 0
var _vp := Vector2(540.0, 1170.0)
var _http: HTTPRequest


func start(url: String, init_data: String, score: int, beats: int, vp: Vector2) -> void:
	_vp = vp
	z_index = 30
	if url.is_empty():
		_state = State.ERROR
		_error_msg = "Leaderboard isn't live yet."
		queue_redraw()
		return

	_http = HTTPRequest.new()
	add_child(_http)
	_http.request_completed.connect(_on_request_completed)
	var body := JSON.stringify({"initData": init_data, "score": score, "beats": beats})
	var err := _http.request(url, ["Content-Type: application/json"], HTTPClient.METHOD_POST, body)
	if err != OK:
		_state = State.ERROR
		_error_msg = "Couldn't reach the leaderboard."
	queue_redraw()


func _on_request_completed(result: int, response_code: int, _headers: PackedStringArray,
		body: PackedByteArray) -> void:
	if result != HTTPRequest.RESULT_SUCCESS or response_code != 200:
		_state = State.ERROR
		_error_msg = "Couldn't reach the leaderboard."
		queue_redraw()
		return
	var parsed: Variant = JSON.parse_string(body.get_string_from_utf8())
	if typeof(parsed) != TYPE_DICTIONARY:
		_state = State.ERROR
		_error_msg = "Couldn't reach the leaderboard."
		queue_redraw()
		return
	_top = parsed.get("top", [])
	_you = parsed.get("you", _you)
	_total_players = int(parsed.get("totalPlayers", 0))
	_total_plays = int(parsed.get("totalPlays", 0))
	_state = State.LOADED
	queue_redraw()


## Any press anywhere while this panel exists is this panel's — it is a
## modal, and blocking the input phase here (before Controls/game.gd's own
## _unhandled_input ever see it) is what stops a dismiss-tap from also
## landing on a death-screen Button underneath, or worse, from falling
## through to game.gd's own tap-anywhere-to-replay handling (see _on_press).
func _input(event: InputEvent) -> void:
	var pressed := false
	if event is InputEventScreenTouch:
		pressed = event.pressed
	elif event is InputEventMouseButton:
		pressed = event.pressed and event.button_index == MOUSE_BUTTON_LEFT
	else:
		return
	get_viewport().set_input_as_handled()
	if pressed:
		queue_free()


func _draw() -> void:
	var backdrop := Palette.BG
	backdrop.a = 0.94
	draw_rect(Rect2(Vector2.ZERO, _vp), backdrop)

	var title_col := Palette.SCORE
	title_col.a = 0.85
	_centred("LEADERBOARD", Vector2(_vp.x * 0.5, 96.0), 26, title_col)

	match _state:
		State.LOADING:
			var col := Palette.SCORE
			col.a = 0.5
			_centred("Submitting...", _vp * 0.5, 18, col)
		State.ERROR:
			var col := Palette.VOID
			_centred(_error_msg, _vp * 0.5, 16, col)
		State.LOADED:
			_draw_rows()

	var hint := Palette.SCORE
	hint.a = 0.35
	_centred("tap to continue", Vector2(_vp.x * 0.5, _vp.y - 60.0), 14, hint)


const ROW_H := 54.0
const ROW_TOP := 160.0
const COL_RANK := 46.0
const COL_NAME := 84.0
const COL_SCORE_R := 494.0


func _draw_rows() -> void:
	var y := ROW_TOP
	for i in _top.size():
		var row: Dictionary = _top[i]
		var rank := i + 1
		var mine: bool = rank == _you.get("rank", 0)
		if mine:
			var hi := Palette.HEART
			hi.a = 0.12
			draw_rect(Rect2(Vector2(30.0, y - ROW_H * 0.5 + 4.0), Vector2(_vp.x - 60.0, ROW_H - 8.0)), hi)

		var col := Palette.SCORE
		col.a = 0.95 if mine else 0.7
		_left("%d" % rank, Vector2(COL_RANK, y), 17, col)
		_left(_ellipsize(str(row.get("name", "?")), 16), Vector2(COL_NAME, y), 17, col)
		_right(_commas(int(row.get("score", 0))), Vector2(COL_SCORE_R, y), 17, col)

		var dim := Palette.SCORE
		dim.a = 0.32
		_left(_relative_time(str(row.get("at", ""))), Vector2(COL_NAME, y + 20.0), 12, dim)

		y += ROW_H

	# "You" only needs its own line when it fell outside the top 10 — inside
	# it, the highlighted row above already says the same thing.
	var rank: int = _you.get("rank", 0)
	y += 14.0
	if rank > _top.size():
		var col := Palette.HEART
		col.a = 0.85
		_centred("You  ·  #%d  ·  %s" % [rank, _commas(int(_you.get("score", 0)))], Vector2(_vp.x * 0.5, y), 16, col)
		y += 34.0

	var foot := Palette.SCORE
	foot.a = 0.38
	_centred("%s players  ·  %s runs" % [_commas(_total_players), _commas(_total_plays)],
		Vector2(_vp.x * 0.5, y + 20.0), 13, foot)


func _ellipsize(s: String, max_len: int) -> String:
	if s.length() <= max_len:
		return s
	return s.substr(0, max_len - 1) + "…"


## Coarse, no-timezone-math relative label from the server's ISO timestamp —
## this is flavour text ("2h ago"), not a clock, so second-level precision
## and DST correctness are not worth the complexity here.
func _relative_time(iso: String) -> String:
	if iso.is_empty():
		return ""
	var dt := Time.get_datetime_dict_from_datetime_string(iso, false)
	if dt.is_empty():
		return ""
	var then := Time.get_unix_time_from_datetime_dict(dt)
	var now := Time.get_unix_time_from_system()
	var delta := maxi(0, int(now - then))
	if delta < 3600:
		return "%dm ago" % maxi(1, delta / 60)
	if delta < 86400:
		return "%dh ago" % (delta / 3600)
	if delta < 86400 * 30:
		return "%dd ago" % (delta / 86400)
	return "%s" % dt.get("year", "")


func _commas(n: int) -> String:
	var s := str(n)
	var out := ""
	var c := 0
	for i in range(s.length() - 1, -1, -1):
		out = s[i] + out
		c += 1
		if c % 3 == 0 and i > 0:
			out = "," + out
	return out


var _font: Font


func _left(text: String, at: Vector2, size: int, col: Color) -> void:
	if _font == null:
		_font = ThemeDB.fallback_font
	draw_string(_font, at, text, HORIZONTAL_ALIGNMENT_LEFT, -1, size, col)


func _right(text: String, at: Vector2, size: int, col: Color) -> void:
	if _font == null:
		_font = ThemeDB.fallback_font
	var w := _font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, size).x
	draw_string(_font, at - Vector2(w, 0.0), text, HORIZONTAL_ALIGNMENT_LEFT, -1, size, col)


func _centred(text: String, at: Vector2, size: int, col: Color) -> void:
	if _font == null:
		_font = ThemeDB.fallback_font
	var w := _font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, size).x
	draw_string(_font, at - Vector2(w * 0.5, 0.0), text, HORIZONTAL_ALIGNMENT_LEFT, -1, size, col)
