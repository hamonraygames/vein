extends Node
## Deliberately engineers the worst case the chain-integrity guarantee (see
## game.gd's "The chain-integrity guarantee" section) exists to prevent: every
## canonical Forge/Loom/Kiln dying at once, deep into a run where CLOTH/PRISM
## have long been unlocked. The floor-bot probe never survives long enough to
## reach those tiers, so this is the only harness that actually exercises them.
##
##   Godot --headless --path . -- --chainstress
##
## Three scenarios, each a fresh run:
##   WIPEOUT   — corrupt every live Forge/Loom/Kiln simultaneously. Assert all
##               three recover a canonical, USABLE instance within a bounded time.
##   STRANDED  — corrupt only the Forge feeding a live Loom (Loom itself
##               survives). Assert the Loom becomes fed again — this is the
##               "tool exists but nothing can ever reach it again" case that a
##               plain existence-count check would miss.
##   RAW_ALSO  — corrupt every Well too, alongside WIPEOUT, to confirm the
##               original RAW-tier guarantee and this one don't fight each other.
##
## A run that never recovers within the timeout is exactly the unrecoverable
## "no move" state VEIN must never produce — this harness's whole job is to
## fail loudly if that regresses.

const TIMEOUT := 30.0

var _game: Node
var _scenario := 0
var _t := 0.0
var _phase := 0   # 0 = setup done, waiting to corrupt; 1 = corrupted, waiting to recover
var _pass := true
var _fails: Array[String] = []

const SCENARIOS := ["WIPEOUT", "STRANDED", "RAW_ALSO"]


func _ready() -> void:
	Engine.time_scale = 40.0
	_game = get_parent()
	print("chain_stress: %d scenarios" % SCENARIOS.size())
	_begin(0)


func _begin(i: int) -> void:
	_scenario = i
	_t = 0.0
	_phase = 0
	_game.start_run(9001 + i)


func _process(delta: float) -> void:
	if _game == null or not _game.alive:
		return
	_t += delta

	if _phase == 0:
		# Force the run into "deep, everything unlocked" state instantly rather
		# than waiting real run-time out — what's under test is the guarantee,
		# not the escalation clock.
		if not _game._unlocked_res.has(VNode.Res.REFINED):
			_game._unlocked_res.append(VNode.Res.REFINED)
		if not _game._unlocked_res.has(VNode.Res.CLOTH):
			_game._unlocked_res.append(VNode.Res.CLOTH)
		if not _game._unlocked_res.has(VNode.Res.PRISM):
			_game._unlocked_res.append(VNode.Res.PRISM)

		while _game._count_kind(VNode.Kind.FORGE) == 0:
			_game._spawn_node(VNode.Kind.FORGE)
		while _game._count_kind(VNode.Kind.LOOM) == 0:
			_game._spawn_node(VNode.Kind.LOOM)
		if SCENARIOS[_scenario] != "STRANDED":
			while _game._count_kind(VNode.Kind.KILN) == 0:
				_game._spawn_node(VNode.Kind.KILN)

		match SCENARIOS[_scenario]:
			"WIPEOUT", "RAW_ALSO":
				for n in _game.nodes.duplicate():
					if n.kind in [VNode.Kind.FORGE, VNode.Kind.LOOM, VNode.Kind.KILN]:
						n.corrupt()
				if SCENARIOS[_scenario] == "RAW_ALSO":
					for n in _game.nodes.duplicate():
						if n.kind == VNode.Kind.WELL:
							n.corrupt()
			"STRANDED":
				# Only the Forge dies; the Loom it fed stays alive but now has
				# no reachable feeder at all — the case a plain "count > 0"
				# check would wrongly call healthy.
				for n in _game.nodes.duplicate():
					if n.kind == VNode.Kind.FORGE:
						n.corrupt()

		_phase = 1
		_t = 0.0
		return

	# _phase == 1: waiting for the guarantee to recover.
	var recovered := false
	match SCENARIOS[_scenario]:
		"WIPEOUT", "RAW_ALSO":
			recovered = _game._count_canonical_healthy(VNode.Kind.FORGE) > 0 \
				and _game._count_canonical_healthy(VNode.Kind.LOOM) > 0 \
				and _game._count_canonical_healthy(VNode.Kind.KILN) > 0 \
				and _game._any_kind_fed(VNode.Kind.FORGE, VNode.Kind.WELL) \
				and _game._any_kind_fed(VNode.Kind.LOOM, VNode.Kind.FORGE) \
				and _game._any_kind_fed(VNode.Kind.KILN, VNode.Kind.LOOM)
		"STRANDED":
			recovered = _game._any_kind_fed(VNode.Kind.LOOM, VNode.Kind.FORGE)

	if recovered:
		print("  %-9s recovered in %.1fs (chain_rescues=%d, rescues=%d)"
			% [SCENARIOS[_scenario], _t, _game.chain_rescues, _game.rescues])
		_next()
		return

	if _t > TIMEOUT:
		_pass = false
		_fails.append("%s: NOT recovered after %.0fs — canonical(F/L/K)=%d/%d/%d fed(F/L/K)=%s/%s/%s"
			% [SCENARIOS[_scenario], TIMEOUT,
				_game._count_canonical_healthy(VNode.Kind.FORGE),
				_game._count_canonical_healthy(VNode.Kind.LOOM),
				_game._count_canonical_healthy(VNode.Kind.KILN),
				_game._any_kind_fed(VNode.Kind.FORGE, VNode.Kind.WELL),
				_game._any_kind_fed(VNode.Kind.LOOM, VNode.Kind.FORGE),
				_game._any_kind_fed(VNode.Kind.KILN, VNode.Kind.LOOM)])
		print("  %-9s FAILED to recover within %.0fs" % [SCENARIOS[_scenario], TIMEOUT])
		_next()


func _next() -> void:
	if _scenario + 1 >= SCENARIOS.size():
		print("\nchain_stress: %s" % ("ALL PASS" if _pass else "FAILURES:"))
		for f in _fails:
			print("  - " + f)
		get_tree().quit(0 if _pass else 1)
		return
	_begin(_scenario + 1)
