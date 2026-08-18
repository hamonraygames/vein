extends Node
## Per-frame cost benchmark. Attached by game.gd when `--bench` is passed:
##
##   Godot --path . -- --bench [--after=20] [--every=5]
##
## Must run WINDOWED (no --headless): the whole point is measuring real draw
## calls and render primitives, which a null renderer never produces.
##
## AutoPlay builds a realistic board, then this samples Godot's own
## Performance monitors and reports how much geometry the board actually
## emits per frame — draw calls and render primitives, which is the number
## that tracks GPU cost (and phone heat) as a network grows. FPS is reported
## too but is the least trustworthy column here: the OS compositor and
## display sync distort it badly on a desktop, so read draw_calls/prims.
## `--after` is how many seconds to let the board grow before sampling.

const AUTOPLAY_PERIOD := 0.4

var after := 20.0
var every := 5.0

var _game: Node
var _accum := 0.0
var _elapsed := 0.0
var _report_t := 0.0

var _frames := 0
var _draw_calls_sum := 0.0
var _prims_sum := 0.0
var _fps_sum := 0.0


func _ready() -> void:
	_game = get_parent()
	# game.gd caps at 60 and the platform vsyncs on top of that, so both FPS
	# and TIME_PROCESS just report "we waited for the display" rather than
	# what a frame actually costs. Uncapped, FPS becomes a true measure.
	Engine.max_fps = 0
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	print("bench: warmup=%.0fs report_every=%.0fs (vsync off, fps uncapped)" % [after, every])


func _process(delta: float) -> void:
	if _game == null:
		return
	_elapsed += delta

	_accum += delta
	if _accum >= AUTOPLAY_PERIOD:
		_accum = 0.0
		AutoPlay.step(_game)

	if not _game.alive:
		_game.start_run(0)

	if _elapsed < after:
		return

	_frames += 1
	_draw_calls_sum += Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)
	_prims_sum += Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME)
	_fps_sum += Performance.get_monitor(Performance.TIME_FPS)

	_report_t += delta
	if _report_t >= every:
		_report_t = 0.0
		_report()


func _report() -> void:
	if _frames == 0:
		return
	var f := float(_frames)
	var scars: int = _game.heart.scars.size() if is_instance_valid(_game.heart) else 0
	print("nodes %2d veins %2d dots %3d scars %2d | fps %6.1f | draw_calls %6.0f | prims %7.0f"
		% [_game.nodes.size(), _game.veins.size(), _count_dots(), scars,
			_fps_sum / f, _draw_calls_sum / f, _prims_sum / f])
	_frames = 0
	_draw_calls_sum = 0.0
	_prims_sum = 0.0
	_fps_sum = 0.0


func _count_dots() -> int:
	var n := 0
	for v in _game.veins:
		n += v.dots.size()
	return n
