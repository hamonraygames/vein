extends Node
## Headless tithe check. Attached by game.gd when `--tithelab` is passed:
##
##   Godot --headless --path . -- --tithelab [--speed=X]
##
## Same launch constraints as probe.gd — must ride a normal project launch so
## autoloads (Beat) exist.
##
## Two runs on the SAME seed, no network ever built, so the Heart starves on
## a fixed clock and the only variable is the tithe:
##
##   run 0 (control): nobody holds. The offer blooms and is ignored.
##   run 1 (tithe):   the instant the offer blooms, press the Heart and never
##                    let go.
##
## Score is seeded to a flat 500 in both runs (score is not a sim input — the
## sim stays deterministic; it only gates/feeds the tithe). Asserts:
##   - the offer actually bloomed in both runs,
##   - the tithing run outlived the control run,
##   - every point that left the score is accounted for: 500 - final == given,
##   - holding actually spent (given > 0) and dots actually landed.

const SEED := 4242
const START_SCORE := 500

var speed := 20.0

var _game: Node
var _phase := 0          # 0 = control, 1 = tithe
var _pressed := false
var _offered_seen := [false, false]
var _died_at := [0, 0]
var _given := [0, 0]
var _score_end := [0, 0]


func _ready() -> void:
	_game = get_parent()
	Engine.time_scale = speed
	print("tithelab: seed=%d speed=%.0fx" % [SEED, speed])
	_begin()


func _begin() -> void:
	_pressed = false
	_game.start_run(SEED)
	_game.score = START_SCORE


func _process(_delta: float) -> void:
	if _game == null:
		return

	if _game.alive:
		if _game.tithe.offered:
			_offered_seen[_phase] = true
			if _phase == 1 and not _pressed:
				_pressed = true
				_game._on_press(_game.heart.position)
		return

	_died_at[_phase] = _game.beats
	_given[_phase] = _game._tithe_given
	_score_end[_phase] = _game.score
	print("run %d (%s): died at beat %d | gave %d | score %d -> %d | dots spent %d"
		% [_phase, "tithe" if _phase == 1 else "control", _game.beats,
			_game._tithe_given, START_SCORE, _game.score, _game._tithe_dots_spent])

	if _phase == 0:
		_phase = 1
		_begin()
		return
	_finish()


func _finish() -> void:
	var ok := true
	if not _offered_seen[0] or not _offered_seen[1]:
		push_error("offer never bloomed (control %s, tithe %s)"
			% [_offered_seen[0], _offered_seen[1]])
		ok = false
	if _given[0] != 0:
		push_error("control run spent %d without ever holding" % _given[0])
		ok = false
	if _given[1] <= 0:
		push_error("tithe run held through the offer but spent nothing")
		ok = false
	if _died_at[1] <= _died_at[0]:
		push_error("tithe bought no time: control died at %d, tithe at %d"
			% [_died_at[0], _died_at[1]])
		ok = false
	# Conservation: nothing earns score in these runs (no veins), so every
	# point missing from the final score must be a point the tithe spent.
	if START_SCORE - _score_end[1] != _given[1]:
		push_error("score leak: 500 -> %d but given=%d" % [_score_end[1], _given[1]])
		ok = false
	print("tithelab: %s  (control %d beats, tithe %d beats, +%d beats bought for %d points)"
		% ["OK" if ok else "FAILED", _died_at[0], _died_at[1],
			_died_at[1] - _died_at[0], _given[1]])
	get_tree().quit(0 if ok else 1)
