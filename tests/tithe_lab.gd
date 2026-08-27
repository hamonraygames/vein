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
##   run 0 (control): the score node appears and is never wired to anything.
##   run 1 (tithe):   the instant the score node exists, draw the one line
##                    from it to the Heart and leave it there.
##
## The line is drawn through _on_press/_on_move/_on_release, i.e. the real
## gesture, not _add_vein directly — the whole point of the change is that
## the rescue is an ordinary drag, so the harness has to prove an ordinary
## drag does it.
##
## Score is seeded to a flat 500 in both runs (score is not a sim input — the
## sim stays deterministic; it only gates/feeds the tithe). Asserts:
##   - the score node appeared in both runs,
##   - the drag actually produced a vein, and it cost a budget slot,
##   - the linked run outlived the control run,
##   - every point that left the score is accounted for: 500 - final == given,
##   - the link actually spent (given > 0) and dots actually landed.

const SEED := 4242
const START_SCORE := 500

var speed := 20.0

var _game: Node
var _phase := 0          # 0 = control, 1 = tithe
var _linked := false
var _node_seen := [false, false]
var _died_at := [0, 0]
var _given := [0, 0]
var _score_end := [0, 0]
var _linked_ok := false
var _slot_charged := false

## `--shots=DIR` grabs the board a moment after the line is drawn, so the
## thing this change is actually about — a vein running from the score down
## to the Heart with points falling along it — can be looked at rather than
## inferred from counters. Needs a window.
var _shot_dir := ""
var _shot_t := -1.0
var _shot_done := false


func _ready() -> void:
	_game = get_parent()
	Engine.time_scale = speed
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--shots="):
			_shot_dir = a.get_slice("=", 1)
	print("tithelab: seed=%d speed=%.0fx" % [SEED, speed])
	_begin()


func _begin() -> void:
	_linked = false
	_game.start_run(SEED)
	_game.score = START_SCORE


func _process(delta: float) -> void:
	if _game == null:
		return
	if _shot_t >= 0.0 and not _shot_done:
		_shot_t += delta
		if _shot_t >= 0.5:
			_shot_done = true
			_snap()

	if _game.alive:
		if _game.score_node != null:
			_node_seen[_phase] = true
			if _phase == 1 and not _linked:
				_linked = true
				_draw_the_line()
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


## The player's own gesture, start to finish: press the score circle, drag to
## the Heart, let go. Nothing here reaches past the input layer.
func _draw_the_line() -> void:
	var from: Vector2 = _game.score_node.position
	var to: Vector2 = _game.heart.position
	var used_before: int = _game.veins_used()
	_game._on_press(from)
	_game._on_move(from.lerp(to, 0.5))
	_game._on_move(to)
	_game._on_release(to)
	_linked_ok = _game._score_vein() != null
	_slot_charged = _game.veins_used() == used_before + 1
	if _shot_dir != "":
		_shot_t = 0.0


func _finish() -> void:
	var ok := true
	if not _node_seen[0] or not _node_seen[1]:
		push_error("score node never appeared (control %s, tithe %s)"
			% [_node_seen[0], _node_seen[1]])
		ok = false
	if not _linked_ok:
		push_error("dragging from the score to the Heart drew no vein")
		ok = false
	if not _slot_charged:
		push_error("the score link cost no budget slot")
		ok = false
	if _given[0] != 0:
		push_error("control run spent %d without ever being wired in" % _given[0])
		ok = false
	if _given[1] <= 0:
		push_error("tithe run drew the link but spent nothing")
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


func _snap() -> void:
	await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	img.save_png("%s/tithe-link.png" % _shot_dir)
