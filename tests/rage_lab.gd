extends Node
## Visual harness for the disconnected-poison-rage relay — see game.gd's
## _tick_corruption/_start_poison_dart. Builds a small
## island of Wells wired ONLY to each other (never to the Heart, so every
## node starts orphaned — depth stays -1 the instant it exists) off in a
## corner of the board, then corrupts the hub node to kick the rage off
## immediately. No need to play a real run, build a real network, and wait
## for something to accidentally get cut loose from the Heart to see this.
##
##   Godot --path . -- --rage [--speed=X] [--every=S]
##
## Must run WITH a window (no --headless) — this is for watching the dart
## speed/reach directly, not asserting anything.
##
## The island is a hub with three direct neighbours, two of which have an
## indirect neighbour of their own, and one of THOSE runs on into a long
## tail three more hops deep — deliberately not just a star, so the flood is
## visibly attacking direct AND indirect targets at once (some die sooner,
## the ones farther down a limb a beat later) AND is exercised all the way
## out to an actual leaf several hops from the trigger, not just one hop
## out. Re-spawns a fresh island every `every` seconds so the effect can be
## watched on a loop without restarting the process — a spent island
## collapses on its own well before that (see VNode.ORPHAN_COLLAPSE_TIME),
## same as in a real run.

var _game: Node
var every := 10.0
var speed := 1.0
var _t := 0.0
var _run_seed := 5150


func _ready() -> void:
	_game = get_parent()
	Engine.time_scale = speed
	_game.start_run(_run_seed)
	_spawn_island()


func _process(delta: float) -> void:
	if _game == null or not _game.alive:
		return
	_t += delta
	if _t >= every:
		_t = 0.0
		_spawn_island()


## Positioned bottom-right, comfortably past Vein.MAX_LEN (340) from the
## Heart (which sits at heart_spawn_pos(), roughly board-centre) so nothing
## here could ever be manually joined to it even by accident — not that it
## matters, since a vein to the Heart is never added, but it keeps the demo
## honest about what "disconnected" means.
func _spawn_island() -> void:
	var hub: VNode = _game._make_node(VNode.Kind.WELL, Vector2(480.0, 850.0))
	var d1: VNode = _game._make_node(VNode.Kind.WELL, Vector2(480.0, 750.0))
	var d2: VNode = _game._make_node(VNode.Kind.WELL, Vector2(400.0, 900.0))
	var d3: VNode = _game._make_node(VNode.Kind.WELL, Vector2(500.0, 950.0))
	var i1: VNode = _game._make_node(VNode.Kind.WELL, Vector2(480.0, 650.0))
	var i2: VNode = _game._make_node(VNode.Kind.WELL, Vector2(320.0, 920.0))
	# A long tail off i1, three more hops deep — the actual "leaf shape"
	# several hops from the trigger, not just one hop out.
	var leaf_a: VNode = _game._make_node(VNode.Kind.WELL, Vector2(480.0, 550.0))
	var leaf_b: VNode = _game._make_node(VNode.Kind.WELL, Vector2(480.0, 450.0))
	var leaf_c: VNode = _game._make_node(VNode.Kind.WELL, Vector2(480.0, 350.0))

	# _add_vein spends against the run's normal vein budget — bump it rather
	# than fight it, so the island always wires up regardless of what the
	# real network has already spent.
	_game.budget = _game.veins_used() + 8
	_game._add_vein(hub, d1)
	_game._add_vein(hub, d2)
	_game._add_vein(hub, d3)
	_game._add_vein(d1, i1)
	_game._add_vein(d2, i2)
	_game._add_vein(i1, leaf_a)
	_game._add_vein(leaf_a, leaf_b)
	_game._add_vein(leaf_b, leaf_c)

	print("rage_lab: fresh island (hub + 3 direct + 5 indirect, 4 hops deep), corrupting hub")
	hub.corrupt()
