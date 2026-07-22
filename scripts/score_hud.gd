extends Node2D
## The live score: the blood the Heart has actually received, not survival
## time — "it's the blood it receives that's important, the score should be
## zero when you connect nothing." Reactive to every popped delivery (see
## game.gd's _pop_gain), so it reads exactly what those pops add up to.
##
## The doc's diegetic pillar bans HUD numbers, and this is a deliberate exception
## — without a visible score there is nothing to beat. It stays dim and swells
## on the beat so it reads as part of the organism, not a readout.
##
## It used to sit directly under the Heart with the personal-best ghost beneath
## it, but the Heart is where every vein, tool, and the beat ring already
## converge — playtest: "the area around the heart becomes very messy very
## soon." The score now lives at the TOP of the screen, clear of that traffic,
## and the best is gone from live play entirely (it only appears on the death
## screen now) — mid-run, the only number that matters is the one you're
## building.

var _font: Font
var _swell := 0.0

@onready var game: Node2D = get_parent()


func _ready() -> void:
	z_index = 6
	_font = ThemeDB.fallback_font
	Beat.beat.connect(func(_i: int) -> void: _swell = 1.0)


func _process(delta: float) -> void:
	_swell = maxf(0.0, _swell - delta * 4.0)
	queue_redraw()


func _draw() -> void:
	if game == null or not game.alive:
		return

	# Top-centre, clear of the Heart's traffic. Best is intentionally absent
	# here — it lives only on the death screen now.
	var vp: Vector2 = game.design_size()
	var origin := Vector2(vp.x * 0.5, 70.0)

	var col := Palette.HEART
	col.a = 0.30 + _swell * 0.34
	_centred(str(game.score), origin, 26, col)


func _centred(text: String, at: Vector2, size: int, col: Color) -> void:
	var w := _font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, size).x
	draw_string(_font, at - Vector2(w * 0.5, 0.0), text,
		HORIZONTAL_ALIGNMENT_LEFT, -1, size, col)
