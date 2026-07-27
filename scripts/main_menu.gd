extends Control
## Landing screen: shown from game.gd's _ready() on every real launch once a
## name is set (see there), and reopened from the death screen's Menu button
## without forcing a replay first. Three entries — Play, Leaderboard, and the
## current name (tap to rename) — nothing else, by explicit direction: keep
## it minimal.
##
## The Heart itself sits here at its real gameplay position
## (game.heart_spawn_pos(), the same call start_run() uses), in silhouette
## only — no demand glyph (see VNode.suppress_demand), never beating (Beat
## isn't running until Play is pressed) — a resting version of the exact
## shape the run's own Heart will occupy the instant it starts, not a
## redrawn lookalike. Tapping Play fades the surrounding chrome (backdrop,
## title, buttons) away, then hands off to game.start_run() — which spawns
## the REAL Heart/Wells/veins at those same positions and starts the beat —
## and frees this decorative stand-in. The Heart itself never disappears;
## it just gains its inner shape and starts beating as everything else
## fades in around it.
##
## Styled with the SAME StyleBoxFlat/color theme overrides the Death
## screen's buttons already use (see scenes/game.tscn's
## BtnPrimaryNormal/BtnSecondaryNormal), borrowed at runtime off `game`'s
## existing button instances rather than redefining the same colors again
## here — one visual source of truth for every button in the game, not two.
##
## Absolute pixel position/size against `vp`, not anchors — same convention
## documented in name_prompt.gd's header (anchors don't reliably resolve for
## a Control added to the tree at runtime in this project).

const VNodeScene := preload("res://scripts/vnode.gd")
const FADE_TIME := 0.35

var game: Node2D
var _name_btn: Button
var _backdrop: ColorRect
var _title: Label
var _stats_label: Label
var _play_btn: Button
var _board_btn: Button
var _heart: VNode

var _fading := false
var _fade_t := 0.0


func start(g: Node2D, vp: Vector2) -> void:
	game = g
	position = Vector2.ZERO
	size = vp
	mouse_filter = Control.MOUSE_FILTER_STOP
	# Kept well under leaderboard_panel.gd's 30 / name_prompt.gd's 31: VNode's
	# own _ready() adds a further +10 (z_as_relative) on top of whatever this
	# is set to for the decorative Heart below, so this must leave enough
	# headroom that heart's effective z stays under both those modals —
	# otherwise the Heart renders on top of a rename/leaderboard screen
	# opened from this menu instead of staying behind it.
	z_index = 15

	_backdrop = ColorRect.new()
	_backdrop.position = Vector2.ZERO
	_backdrop.size = vp
	_backdrop.color = Palette.BG
	_backdrop.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(_backdrop)

	_heart = VNodeScene.new()
	_heart.kind = VNode.Kind.HEART
	_heart.fuel_ratio = 1.0
	_heart.suppress_demand = true
	_heart.position = game.heart_spawn_pos()
	add_child(_heart)

	_title = Label.new()
	_title.text = "VEIN"
	_title.add_theme_color_override("font_color", Palette.SCORE)
	_title.add_theme_font_size_override("font_size", 30)
	_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	# Just above the Heart's own top edge (it sits at 0.44*vp.y, extending
	# roughly 0.85*HEART_RADIUS above that) rather than floating in the
	# empty upper third of the screen on its own.
	_title.position = Vector2(0.0, vp.y * 0.33)
	_title.size = Vector2(vp.x, 40.0)
	add_child(_title)

	# Your best score (always known locally) and your leaderboard rank
	# (fetched read-only — see game._fetch_rank/server/leaderboard/submit.js's
	# /rank route, which never counts a menu visit as a run). Sits in the gap
	# between the Heart's own footprint and the buttons below.
	_stats_label = Label.new()
	_stats_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_stats_label.add_theme_font_size_override("font_size", 15)
	_stats_label.add_theme_color_override("font_color", Palette.SCORE)
	_stats_label.position = Vector2(0.0, vp.y * 0.535)
	_stats_label.size = Vector2(vp.x, 26.0)
	add_child(_stats_label)
	game._fetch_rank()

	# Buttons sit BELOW the Heart's real footprint (it occupies roughly
	# 0.38-0.50 of vp.y at HEART_RADIUS scale) so nothing overlaps it.
	_play_btn = _make_button("Play", true)
	_play_btn.position = Vector2(vp.x * 0.2, vp.y * 0.6)
	_play_btn.size = Vector2(vp.x * 0.6, 54.0)
	_play_btn.pressed.connect(_on_play)
	add_child(_play_btn)

	_board_btn = _make_button("Leaderboard", false)
	_board_btn.position = Vector2(vp.x * 0.2, vp.y * 0.6 + 74.0)
	_board_btn.size = Vector2(vp.x * 0.6, 46.0)
	_board_btn.pressed.connect(game._on_open_leaderboard)
	add_child(_board_btn)

	_name_btn = _make_button(_name_label(), false)
	_name_btn.position = Vector2(vp.x * 0.2, vp.y * 0.6 + 138.0)
	_name_btn.size = Vector2(vp.x * 0.6, 46.0)
	_name_btn.pressed.connect(game._on_open_rename)
	add_child(_name_btn)


## Kept live rather than set once — a rename opened from here (see
## game._on_open_rename) leaves this menu open underneath it, so the label
## needs to pick up the new name the moment the rename prompt confirms and
## frees itself, without this menu having to listen for that separately.
## Also drives the post-Play fade-out (see _on_play) since there's no Tween
## precedent elsewhere in this game — every other transient effect
## (pulse decay, fade warnings, etc.) is a plain per-frame decay in
## _process, so this follows the same idiom rather than introducing one.
func _process(delta: float) -> void:
	if not _fading:
		if _name_btn != null:
			_name_btn.text = _name_label()
		_stats_label.text = _stats_text()
		return

	_fade_t += delta
	var a := clampf(1.0 - _fade_t / FADE_TIME, 0.0, 1.0)
	_backdrop.modulate.a = a
	_title.modulate.a = a
	_stats_label.modulate.a = a
	_play_btn.modulate.a = a
	_board_btn.modulate.a = a
	_name_btn.modulate.a = a
	if _fade_t >= FADE_TIME:
		game.start_run(0)
		queue_free()  # takes _heart and every other child down with it


func _name_label() -> String:
	return "Playing as %s" % game.player_name


## Best score is always known locally; rank only once game._fetch_rank's
## request lands (or never, for a player who has yet to post a single
## score — rank_value stays 0 and this quietly says nothing about it).
func _stats_text() -> String:
	var parts: Array[String] = []
	if game.best > 0:
		parts.append("Best %s" % _commas(game.best))
	if game.rank_state == "loading":
		parts.append("finding your rank…")
	elif game.rank_state == "loaded" and game.rank_value > 0:
		parts.append("Rank #%s of %s" % [_commas(game.rank_value), _commas(game.rank_total_players)])
	return "  ·  ".join(parts)


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


func _make_button(text: String, primary: bool) -> Button:
	var btn := Button.new()
	btn.text = text
	var donor: Button = game.replay_btn if primary else game.share_btn
	btn.add_theme_font_size_override("font_size", 24 if primary else 15)
	for state in ["normal", "hover", "pressed", "focus"]:
		btn.add_theme_stylebox_override(state, donor.get_theme_stylebox(state))
	for state in ["font_color", "font_hover_color", "font_pressed_color"]:
		btn.add_theme_color_override(state, donor.get_theme_color(state))
	return btn


func _on_play() -> void:
	if _fading:
		return
	_fading = true
	# mouse_filter (not .disabled) so nothing else can re-trigger these mid-fade
	# — .disabled would swap in the engine's default disabled theme for a frame
	# before the manual alpha fade below catches up, since normal/hover/pressed
	# are the only states _make_button overrides.
	_play_btn.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_board_btn.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_name_btn.mouse_filter = Control.MOUSE_FILTER_IGNORE
