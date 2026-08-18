extends Node2D
## The in-game leaderboard: a read-only view over game.gd's lb_* state (see
## there — _submit_score fires the moment the Heart stops, automatically,
## not from here), opened by the death screen's "Leaderboard" button, the
## main menu's "Leaderboard" entry, and self-freeing on tap. Same "caller
## spawns it and forgets it" pattern as ShatterScene/BurstScene/FloatText.
##
## Reads game's live state every frame rather than a frozen snapshot (same
## pattern as ranks_strip.gd/score_hud.gd) so a submission still in flight
## when this panel opens still updates it once it lands, instead of leaving
## a stale "Submitting..." on screen.
##
## Shows the top 10 always; when you (game.lb_you) fall outside it, an
## ellipsis and the nearby block (2 above, you, 2 below — game.lb_nearby,
## already shaped this way server-side) follow, so "where do I actually
## stand" never requires a separate screen.
##
## Custom-drawn like every other dynamic-content readout in this game
## rather than built from Control/Label nodes — there is no fixed number of
## rows to hand-place in the scene, and this keeps the same vector-drawn
## language as everything else.

var game: Node2D
var _vp := Vector2(540.0, 1170.0)
var _font: Font


func start(g: Node2D, vp: Vector2) -> void:
	game = g
	_vp = vp
	z_index = 30


func _process(_delta: float) -> void:
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
	if game == null:
		return

	var backdrop := Palette.BG
	backdrop.a = 0.94
	draw_rect(Rect2(Vector2.ZERO, _vp), backdrop)

	var title_col := Palette.SCORE
	title_col.a = 0.85
	_centred("LEADERBOARD", Vector2(_vp.x * 0.5, 96.0), 26, title_col)

	match game.lb_state:
		"loading", "idle":
			var col := Palette.SCORE
			col.a = 0.5
			_centred("Submitting...", _vp * 0.5, 18, col)
		"error":
			var col := Palette.VOID
			_centred("Couldn't reach the leaderboard.", _vp * 0.5, 16, col)
		"loaded":
			_draw_rows()

	var hint := Palette.SCORE
	hint.a = 0.35
	_centred("tap to continue", Vector2(_vp.x * 0.5, _vp.y - 60.0), 14, hint)


const ROW_H := 54.0
const ROW_TOP := 160.0
const COL_RANK := 46.0
const COL_NAME := 84.0
const COL_SCORE_R := 478.0
## Small rank-change chevron past the score — shrunk COL_SCORE_R above to
## leave it room without crowding the backdrop's own right edge.
const COL_CHEVRON := 496.0


func _draw_rows() -> void:
	var top: Array = game.lb_top
	var you: Dictionary = game.lb_you
	var rank: int = you.get("rank", 0)

	var y := ROW_TOP
	for i in top.size():
		y = _draw_row(top[i], i + 1, y, i + 1 == rank)

	# The nearby block (2 above, you, 2 below — see submit.js's `nearby`) only
	# needs to show up when you fell outside the top 10 — inside it, the
	# highlighted row above already says the same thing. Outside it, this is
	# what turns "top 10" into "top 10 ... your actual neighborhood".
	if rank > top.size():
		y += 10.0
		var dots := Palette.SCORE
		dots.a = 0.3
		_centred("···", Vector2(_vp.x * 0.5, y), 20, dots)
		y += 30.0
		for row in game.lb_nearby:
			y = _draw_row(row, int(row.get("rank", 0)), y, int(row.get("rank", 0)) == rank)

	var foot := Palette.SCORE
	foot.a = 0.38
	_centred("%s players  ·  %s runs" % [_commas(game.lb_total_players), _commas(game.lb_total_plays)],
		Vector2(_vp.x * 0.5, y + 20.0), 13, foot)


## Draws one rank/name/score row plus its dim plays/last-played subline, and
## returns the y for the next row — shared by both the top-10 loop and the
## outside-top-10 nearby block above, so "you" reads identically wherever it
## actually lands.
func _draw_row(row: Dictionary, rank: int, y: float, mine: bool) -> float:
	if mine:
		var hi := Palette.HEART
		hi.a = 0.12
		draw_rect(Rect2(Vector2(30.0, y - ROW_H * 0.5 + 4.0), Vector2(_vp.x - 60.0, ROW_H - 8.0)), hi)

	var col := Palette.SCORE
	col.a = 0.95 if mine else 0.7
	if rank == 1:
		# The crown IS rank 1's number — no "1" printed alongside it, same
		# as nobody labels an actual crown "#1".
		_draw_crown(Vector2(COL_RANK + 8.0, y - 6.0), 11.0)
	else:
		_left("%d" % rank, Vector2(COL_RANK, y), 17, col)
	_left(_ellipsize(str(row.get("name", "?")), 16), Vector2(COL_NAME, y), 17, col)
	_right(_commas(int(row.get("score", 0))), Vector2(COL_SCORE_R, y), 17, col)
	_draw_chevron(Vector2(COL_CHEVRON, y), int(row.get("rankChange", 0)))

	var dim := Palette.SCORE
	dim.a = 0.32
	var plays := int(row.get("plays", 0))
	var plays_text := "%d play%s" % [plays, "" if plays == 1 else "s"]
	var at_text := _relative_time(str(row.get("at", "")))
	_left(plays_text + ("  ·  " + at_text if not at_text.is_empty() else ""),
		Vector2(COL_NAME, y + 20.0), 12, dim)

	return y + ROW_H


## A small filled triangle, green tip-up when this row's player climbed
## since their own last run, red tip-down when they fell — see
## submit.js's rankChangeFor. Silent (draws nothing) at 0, which covers
## both "unchanged" and "no prior run to compare against" alike, so a
## first-time row never shows a fabricated arrow.
const CHEVRON_W := 9.0
const CHEVRON_H := 8.0

func _draw_chevron(at: Vector2, change: int) -> void:
	if change == 0:
		return
	var up := change > 0
	var col := Palette.RANK_UP if up else Palette.RANK_DOWN
	col.a = 0.9
	var half_h := CHEVRON_H * 0.5
	var tri: PackedVector2Array
	if up:
		tri = PackedVector2Array([
			at + Vector2(0.0, -half_h), at + Vector2(-CHEVRON_W * 0.5, half_h), at + Vector2(CHEVRON_W * 0.5, half_h),
		])
	else:
		tri = PackedVector2Array([
			at + Vector2(0.0, half_h), at + Vector2(-CHEVRON_W * 0.5, -half_h), at + Vector2(CHEVRON_W * 0.5, -half_h),
		])
	draw_colored_polygon(tri, col)


## Rank 1's number, replaced outright — same straight-edged, hand-placed-
## vertex language as every shape this game draws, and the same silhouette
## vnode.gd's Heart wears (tilted, over its left lobe) when YOU are the
## one holding this spot; this copy stays upright, since there's no lobe
## here to lean over. A single "W" on top (two valleys reaching the bottom
## line, centre point tallest, left/right points a little lower), each
## outer point dropping straight down to that bottom line.
const CROWN_POINTS: Array[Vector2] = [
	Vector2(-1.0, 0.62), Vector2(-1.0, -0.42), Vector2(-0.5, 0.02), Vector2(0.0, -0.85),
	Vector2(0.5, 0.02), Vector2(1.0, -0.42), Vector2(1.0, 0.62),
]

func _draw_crown(at: Vector2, s: float) -> void:
	var pts := PackedVector2Array()
	for p in CROWN_POINTS:
		pts.append(p * s + at)
	draw_colored_polygon(pts, Palette.GOLD)
	var outline := pts.duplicate()
	outline.append(pts[0])
	draw_polyline(outline, Palette.GOLD.darkened(0.25), 1.5, true)


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


func _left(text: String, at: Vector2, size: int, col: Color) -> void:
	if _font == null:
		_font = Palette.MONO_FONT
	draw_string(_font, at, text, HORIZONTAL_ALIGNMENT_LEFT, -1, size, col)


func _right(text: String, at: Vector2, size: int, col: Color) -> void:
	if _font == null:
		_font = Palette.MONO_FONT
	var w := _font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, size).x
	draw_string(_font, at - Vector2(w, 0.0), text, HORIZONTAL_ALIGNMENT_LEFT, -1, size, col)


func _centred(text: String, at: Vector2, size: int, col: Color) -> void:
	if _font == null:
		_font = Palette.MONO_FONT
	var w := _font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, size).x
	draw_string(_font, at - Vector2(w * 0.5, 0.0), text, HORIZONTAL_ALIGNMENT_LEFT, -1, size, col)
