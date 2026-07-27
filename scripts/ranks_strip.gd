extends Node2D
## The death screen's "nearby ranks" strip: two ranks above the player, the
## player's own row, two below — drawn once the run's score has been
## auto-submitted (see game.gd's _submit_score/_on_stopped). Same custom-
## drawn table language as leaderboard_panel.gd's full top-10 view (which
## the death screen's "Leaderboard" button still opens), just five fixed
## rows instead of ten, and always visible on death rather than behind a
## tap — same "always-on HUD element" pattern as score_hud.gd/budget_hint.gd,
## just gated to the death screen instead of live play.

@onready var game: Node2D = get_parent()
var _font: Font

const TOP := 650.0
const ROW_H := 28.0


func _ready() -> void:
	z_index = 6


func _process(_delta: float) -> void:
	queue_redraw()


func _draw() -> void:
	if game == null or game.alive:
		return
	if game.lb_state != "loaded" or game.lb_nearby.is_empty():
		return
	if _font == null:
		_font = Palette.MONO_FONT

	var vp: Vector2 = game.design_size()
	var col_rank := vp.x * 0.5 - 150.0
	var col_name := vp.x * 0.5 - 110.0
	var col_score_r := vp.x * 0.5 + 150.0
	# Small rank-change chevron in the gap between score and plays.
	var col_chevron := vp.x * 0.5 + 172.0
	# Small dim mini-column past the score, inside the backdrop's own right
	# edge (vp.x - 24) with margin to spare — matches leaderboard_panel.gd's
	# "N plays" subtext, just compressed to fit this strip's single line.
	var col_plays_r := vp.x * 0.5 + 220.0

	# The death screen's shatter debris (see shatter.gd) keeps drifting
	# through this whole region for a while after death — a first attempt at
	# this backdrop used 0.72 alpha and was nearly invisible: Palette.BG IS
	# the canvas colour, so blending toward it only mildly dims whatever's
	# already behind it instead of properly covering it. leaderboard_panel.gd
	# already proved 0.94 reliably blocks the same debris, so this matches
	# that value instead of re-guessing.
	# Fully opaque, not the 0.94 this used to share with leaderboard_panel.gd's
	# full-screen version — playtest: "i can't see it well." That panel sits
	# over nothing but its own dedicated backdrop; this one has to win
	# against the death screen's own shatter debris still drifting behind it,
	# which a hair of bleed-through was reading as visual noise.
	var panel_h := float(game.lb_nearby.size()) * ROW_H + 14.0
	var backdrop := Palette.BG
	backdrop.a = 1.0
	draw_rect(Rect2(Vector2(24.0, TOP - ROW_H * 0.5), Vector2(vp.x - 48.0, panel_h)), backdrop)

	var y := TOP
	for row in game.lb_nearby:
		var mine: bool = int(row.get("rank", 0)) == int(game.lb_you.get("rank", 0))
		var col := Palette.SCORE
		col.a = 0.95 if mine else 0.72
		_left("#%d" % int(row.get("rank", 0)), Vector2(col_rank, y), 16, col)
		_left(_ellipsize(str(row.get("name", "?")), 14), Vector2(col_name, y), 16, col)
		_right(_commas(int(row.get("score", 0))), Vector2(col_score_r, y), 16, col)
		_draw_chevron(Vector2(col_chevron, y - 3.0), int(row.get("rankChange", 0)))

		var dim := Palette.SCORE
		dim.a = 0.55 if mine else 0.4
		_right("%d×" % int(row.get("plays", 0)), Vector2(col_plays_r, y), 12, dim)

		y += ROW_H


## Small filled triangle, green tip-up/red tip-down — see
## leaderboard_panel.gd's own copy of this for the full rationale (silent at
## 0, which covers both "unchanged" and "no prior run yet").
const CHEVRON_W := 7.0
const CHEVRON_H := 6.0

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


func _ellipsize(s: String, max_len: int) -> String:
	if s.length() <= max_len:
		return s
	return s.substr(0, max_len - 1) + "…"


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
	draw_string(_font, at, text, HORIZONTAL_ALIGNMENT_LEFT, -1, size, col)


func _right(text: String, at: Vector2, size: int, col: Color) -> void:
	var w := _font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, size).x
	draw_string(_font, at - Vector2(w, 0.0), text, HORIZONTAL_ALIGNMENT_LEFT, -1, size, col)
