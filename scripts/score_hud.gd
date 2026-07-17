extends Node2D
## The live score: the blood the Heart has actually received, not survival
## time — "it's the blood it receives that's important, the score should be
## zero when you connect nothing." Reactive to every popped delivery (see
## game.gd's _pop_gain), so it reads exactly what those pops add up to.
##
## The doc's diegetic pillar bans HUD numbers, and this is a deliberate exception
## — without a visible score there is nothing to beat, and beating your own last
## run is the only pull VEIN has (there is no win state). It earns its place by
## behaving like part of the organism rather than a readout: dim, centred under
## the Heart, and it swells on the beat. The personal best sits beneath it as a
## ghost until you pass it, then disappears — the target stops mattering once
## it's gone.

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
	if game == null or game.heart == null or not game.alive:
		return

	var origin: Vector2 = game.heart.position + Vector2(0.0, 74.0)

	var col := Palette.HEART
	col.a = 0.30 + _swell * 0.34
	_centred(str(game.score), origin, 26, col)

	# The number to beat, shown only while it is still ahead of you.
	if game.best > 0 and game.score < game.best:
		var ghost := Palette.HEART
		ghost.a = 0.16
		_centred(str(game.best), origin + Vector2(0.0, 22.0), 14, ghost)


func _centred(text: String, at: Vector2, size: int, col: Color) -> void:
	var w := _font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, size).x
	draw_string(_font, at - Vector2(w * 0.5, 0.0), text,
		HORIZONTAL_ALIGNMENT_LEFT, -1, size, col)
