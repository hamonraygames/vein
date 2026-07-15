extends Node
## Visual harness. Attached by game.gd when `--shot` is passed:
##
##   Godot --path . -- --shot=/tmp/vein.png --after=25 --speed=3
##
## Must run WITH a window (no --headless) — headless has no renderer, so the
## grabbed image would be blank. AutoPlay builds a plausible network first so the
## frame shows a living circulatory diagram rather than an empty screen.

const AUTOPLAY_PERIOD := 0.5

var out_path := "shot.png"
var after := 20.0
var speed := 3.0
var run_seed := 4242

var _game: Node
var _t := 0.0
var _accum := 0.0
var _done := false


func _ready() -> void:
	_game = get_parent()
	Engine.time_scale = speed
	_game.start_run(run_seed)


func _process(delta: float) -> void:
	if _done:
		return

	_t += delta
	_accum += delta
	if _accum >= AUTOPLAY_PERIOD:
		_accum = 0.0
		AutoPlay.step(_game)

	if _t >= after:
		_done = true
		_grab()


func _grab() -> void:
	# Freeze first: a long exposure of a moving sim is unreadable, and the shot
	# should show the same thing the player's eye rests on.
	Engine.time_scale = 1.0
	await RenderingServer.frame_post_draw
	var img: Image = get_viewport().get_texture().get_image()
	var err := img.save_png(out_path)
	if err != OK:
		push_error("could not write %s (err %d)" % [out_path, err])
	else:
		print("shot: %s  beat=%d wells=%d veins=%d alive=%s"
			% [out_path, _game.beats, _game.nodes.size() - 1, _game.veins.size(), _game.alive])
	get_tree().quit()
