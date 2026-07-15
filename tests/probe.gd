extends Node
## Headless balance probe. Attached by game.gd when `--probe` is passed:
##
##   Godot --headless --path . -- --probe=8 --speed=60
##
## It must run inside a normal project launch (not a `--script` main loop),
## because autoload singletons like `Beat` do not exist as globals when a script
## main loop compiles the tree.
##
## AutoPlay drives the run and we print the beat each seed died on. The sim is
## deterministic per seed, so this is repeatable — it is how the escalation curve
## gets tuned without playing the game forty times.

const FIRST_SEED := 1001
const SEED_STRIDE := 977
const AUTOPLAY_PERIOD := 0.4
## Game-seconds. A run that never dies is a tuning bug, but the ceiling has to
## clear a real run with headroom — at ~100bpm a ~900-beat run is ~540s.
const RUN_TIMEOUT := 2400.0

var runs := 5
var speed := 60.0
## Stop AutoPlay after this many veins. `--cap=1` reproduces the reported "you
## connect one circle and you never die": if a run survives on a single Well, the
## escalation is not actually escalating.
var cap := 0

var _game: Node
var _idx := 0
var _results: Array[int] = []
var _accum := 0.0
var _elapsed := 0.0


func _ready() -> void:
	_game = get_parent()
	Engine.time_scale = speed
	print("probe: runs=%d speed=%.0fx" % [runs, speed])
	_begin()


func _begin() -> void:
	_elapsed = 0.0
	_game.start_run(FIRST_SEED + _idx * SEED_STRIDE)


func _process(delta: float) -> void:
	if _game == null:
		return

	_elapsed += delta
	_accum += delta
	if _accum >= AUTOPLAY_PERIOD:
		_accum = 0.0
		if cap <= 0 or _game.veins.size() < cap:
			AutoPlay.step(_game)

	if _elapsed > RUN_TIMEOUT:
		push_error("run %d survived %.0fs of game time without dying" % [_idx + 1, RUN_TIMEOUT])
		_finish()
		return

	if not _game.alive:
		_record()


func _record() -> void:
	var beats: int = _game.beats
	_results.append(beats)

	var wells := 0
	var fed := 0
	var inert := 0
	for n in _game.nodes:
		if n.kind == VNode.Kind.WELL:
			wells += 1
			if n.depth >= 0:
				fed += 1
	var peak := 0.0
	var heart_degree := 0
	for v in _game.veins:
		if v.dir == Vein.Dir.INERT:
			inert += 1
		peak = maxf(peak, v.peak_stress)
		if v.a == _game.heart or v.b == _game.heart:
			heart_degree += 1

	var full_buffers := 0
	for n in _game.nodes:
		if n.kind != VNode.Kind.HEART and n.depth >= 0 and n.buffer.size() >= VNode.BUFFER_CAP:
			full_buffers += 1

	var rotted := 0
	for n in _game.nodes:
		if n.corrupted:
			rotted += 1

	print("run %d: beat %4d | budget %2d | wells %2d (%d fed) | rotted %d | poisoned %d | ruptures %d"
		% [_idx + 1, beats, _game.budget, wells, fed, rotted, _game.poisoned, _game.ruptures])

	_idx += 1
	if _idx >= runs:
		_finish()
	else:
		_begin()


func _finish() -> void:
	if not _results.is_empty():
		var total := 0
		var lo := 1 << 30
		var hi := 0
		for r in _results:
			total += r
			lo = mini(lo, r)
			hi = maxi(hi, r)
		var avg := float(total) / float(_results.size())
		# The heart accelerates through a run; ~100bpm is a fair average.
		print("\nbeats  min %d  avg %.0f  max %d   (~%.1f min at ~100bpm)"
			% [lo, avg, hi, avg / 100.0])
	get_tree().quit()
