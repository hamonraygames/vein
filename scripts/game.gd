extends Node2D
## VEIN — run controller.
##
## Weekend-1 slice: Wells, the Heart, vein drawing, dots flowing, appetite
## escalation, death. No Forges yet.
##
## The whole sim is deterministic given a seed, which is what later buys the
## Daily, replays and offline balancing for free. Keep it that way: no randomness
## outside `rng`, no logic that reads wall-clock time.

# Instantiate through preloaded consts, not the `class_name` globals: global
# class resolution is unreliable when the game is driven from a `--script` main
# loop, which is exactly how tests/ runs it.
const VNodeScene := preload("res://scripts/vnode.gd")
const VeinScene := preload("res://scripts/vein.gd")
const BurstScene := preload("res://scripts/burst.gd")
const FloatTextScene := preload("res://scripts/float_text.gd")

const SAVE_PATH := "user://vein.cfg"

## Bump whenever tuning changes what a score is worth. A best set on an easier
## curve is not a target, it is a wall — the 1244 from the 0.008 appetite build
## was unreachable after the rebalance and would just read as broken.
const TUNING_VERSION := 9

# --- Tuning. Everything the balance depends on lives here. -------------------
const START_BUDGET := 4
## Was a flat 5.0 that never grew while appetite (fuel burned per beat) climbs
## toward ~2.9 by late-game — the buffer against a single missed beat shrank
## to almost nothing exactly when supply gets hardest to keep up with. Real
## playtest (not the bot): "heart dying rate is very fast." Raised so a bad
## few seconds is survivable slack, not an instant strike against
## MISSES_FATAL — see START_FUEL below, sized to match.
const FUEL_CAP := 9.0

## Fuel per item by resource. A Forge burns two RAW (2.0 of fuel) into one
## REFINED (3.0), so refining is worth 1.5x — but it costs an extra vein and
## adds latency, which is the trade. The bigger prize is that it HALVES the item
## count carrying that fuel, so a Forge in front of a bursting trunk is the tool
## for congestion, not just a multiplier.
## VOID is negative fuel: a corrupted Well doesn't stop feeding you, it feeds you
## poison, down the vein you built and came to rely on. Cutting it costs the
## throughput you were depending on — which is the point.
const FUEL_BY_RES := {
	VNode.Res.RAW: 1.0,
	VNode.Res.REFINED: 3.0,
	VNode.Res.CLOTH: 7.0,
	VNode.Res.PRISM: 15.0,
	VNode.Res.VOID: -2.5,
}

## A sloppy redraw is surgery while the body is awake. Cutting a live vein spills
## whatever was in flight and costs Heart fuel immediately. Rot is the exception:
## amputating poison is already punishment enough because it costs throughput.
const CUT_BLEED_BY_DOT := 0.35

## Tools arrive before the Heart asks for them. Seeing the piece first makes the
## demand flip feel like a test, not a hidden rule.
##
## FIRST_FORGE_TIME used to be 10.0 against a REFINED flip at t=14 — only 4s to
## notice the Forge, draw 2 veins, and let material travel + smelt, which the
## probe showed was unwinnable BY ANYONE: cap=1/2/4 all died within a beat or
## two of each other (21/26/26-27), seed-independent, because nothing can
## reach the Heart as REFINED before ~t=18-20 no matter how fast you play.
## That is a scripted death, not a skill test. Pulled both tools' lead time
## forward so a fast, correct build can actually beat its flip; the flip
## itself stays exactly as sudden.
## Was 4.0 — but that landed a Forge before the first extra Well even arrived,
## which is part of why the opening felt like a spawn flood. It now comes after
## a couple of Wells exist to feed it, still with lead time before the REFINED
## flip. During the tutorial the demand flip is held off entirely until the
## connect+chain lessons are done (see tutorial.gd), so the Forge is never a
## surprise there either.
const FIRST_FORGE_TIME := 9.0
const FORGE_GAP := 22.0
const FIRST_LOOM_TIME := 22.0
const LOOM_GAP := 36.0
## A Kiln needs a full Well->Forge->Loom chain already functioning before it's
## worth anything, so it gets the longest lead time of any tool — arriving
## comfortably after the CLOTH flip has had time to settle, not while the
## player is still mid-scramble re-plumbing for it.
const FIRST_KILN_TIME := 40.0
const KILN_GAP := 50.0

## What the Heart DEMANDS, by run-second. This is the game.
##
## The Forge was built as an optional fuel multiplier — an abstract 1.5x you
## cannot see — and playtest was blunt: "the red triangle is not understandable
## even to me." Correct, because an optional thing explains nothing. The doc
## always said it: "the Heart starts demanding refined shapes, not raw ones."
##
## Now the Heart wants ONE shape at a time and shows you which. Off-demand items
## are near-worthless (WRONG_SHAPE_FUEL), so when it flips to triangles your
## entire circle network is suddenly feeding it garbage and you must re-plumb
## every Well through a Forge, against the budget, against reach, while it
## starves. That is the strategy that was missing: the board you built is
## invalidated on a clock, and the whole run is about restructuring under fire.
##
## It also makes the Forge self-teaching — the Heart is visibly asking for a
## triangle, and only the triangle node makes triangles.
##
## This is the TEACHING schedule, walked once, in order — RAW, then REFINED,
## then CLOTH, then PRISM. What happens after the last entry is a different
## system entirely; see ROTATE_GAP_START below. Playtest: "we get to square
## and it never changes at all" — holding at the final tier forever made the
## whole second half of a long run static. A PRISM tier here, and the
## rotation phase that follows it, are both direct answers to that.
const DEMAND_TIERS := [
	{"at": 0.0, "res": VNode.Res.RAW},
	{"at": 14.0, "res": VNode.Res.REFINED},
	{"at": 37.0, "res": VNode.Res.CLOTH},
	{"at": 100.0, "res": VNode.Res.PRISM},
]

## Once every tier above has been introduced, demand stops marching forward
## and starts jumping randomly among everything unlocked so far — the Heart
## can suddenly want RAW again even after you've built all the way to PRISM,
## so nothing you built early is ever safe to walk away from for good.
## "Start simple, slowly go crazy": the gap between rotations shrinks (and
## gets less predictable, via _jitter) as intensity climbs, so the opening of
## this phase still gives time to react and the tail end genuinely doesn't.
const ROTATE_GAP_START := 26.0
## Physical floor under the tuned one below: the longest possible PRISM
## lineage — Well->Forge->Loom->Kiln->Heart, four hops all at the single
## uniform Vein.MAX_LEN now that every pair shares one reach ceiling (see
## in_reach) — takes this long for a single item to physically cross, full
## stop. By the time rotation starts, PRISM is always among the unlocked pool
## (see _tick_escalation), so this is the real worst case the floor has to
## clear, not a hypothetical one.
const WORST_CASE_PRISM_TRAVEL := (Vein.MAX_LEN * 4.0) / Vein.SPEED   # ~8.10s
## Absolute floor the rotation gap keeps creeping toward past EXERTION_SPAN
## (see pressure()) — below this a flip can't be answered at all, even in
## principle, and impossible stops being interesting. The 25% margin over
## WORST_CASE_PRISM_TRAVEL covers dot-spacing queueing and an unbalanced
## branch's assembly stall on top of pure travel.
const ROTATE_GAP_FLOOR := WORST_CASE_PRISM_TRAVEL * 1.25   # ~10.13s
## The lerp target intensity climbs toward — was a flat 8.0 from before the
## reach unification raised WORST_CASE_PRISM_TRAVEL (see MAX_LEN in vein.gd),
## which left it BELOW ROTATE_GAP_FLOOR: the hard clamp always overrode it and
## the lerp's own floor was dead code. Pinned to the real floor so the curve
## actually bottoms out where the clamp does, instead of asymptoting toward a
## number it can never reach.
const ROTATE_GAP_MIN := ROTATE_GAP_FLOOR

## Feeding the Heart something it did not ask for: WASTED, never poison.
##
## This was -0.85 and it was the bug behind "when the heart turns to square and
## I connect square, I die — what am I missing?" Nothing. Audited at a flip:
## fuel went 3.73 -> 0.00 in 0.7s, because the moment demand changed, every item
## already in flight across a healthy 6-vein network hit for -0.85. Your own
## working network instantly became a poison pump aimed at the Heart, and the
## square you connected to fix it could not possibly arrive in time.
##
## The rule that was violated: A WORKING NETWORK MUST NEVER BE WORSE THAN NO
## NETWORK. At -0.85 you were strictly better off having built nothing, which
## inverts the entire game. The demand flip is still a hard survival gate —
## off-demand fuel is ~nothing, so a stale network starves you on the clock —
## but starving is a deadline you can race, not an execution.
const WRONG_SHAPE_FUEL := 0.05

## Appetite grows LINEARLY, on the CLOCK. Both halves of that matter.
##
## Linear, because against an exponential curve doubling your supply only buys a
## fixed increment, so skill is nearly worthless: measured 1 Well -> 109 beats,
## 2 -> 211, 4 -> 254, 10 -> 266. Five times the supply bought 26% more score.
## Against a linear curve, survival time scales with supply, so ten Wells is
## worth roughly ten times one — which is where the doc's 10x expert gap lives.
##
## On the clock rather than per beat, because a starving Heart SLOWS (see
## Beat.RATE_BY_STATE). With beat-indexed escalation, dying slowed the very curve
## that was killing you — the run stabilised into an endless limp instead of
## dying. Time doesn't care that you are dying.
##
## The pairing is the design: escalation on time, score on beats. A healthy Heart
## races, so it scores faster AND survives; a dying one crawls, scores nothing,
## and the curve keeps coming.
## Bisected against the bot: 0.008 -> ~1060 beats (far too easy), 0.021 -> ~176
## and the skill gap collapses to 4x because escalation outruns budget growth
## before you can build anything. 0.016 flattens the spread to 190-216, which
## means the run is over-determined and your choices stopped mattering. 0.013
## keeps the bot near 400 beats with a healthy 228-649 spread.
## The slap in the face is START_FUEL, not APPETITE_BASE.
##
## Raising BASE to 0.9 did open hard — and collapsed the skill gap to ~1.1x
## (2 Wells died at 137, the bot managed 146). A steep floor kills everyone
## early, so extra supply buys nothing and mastery stops paying. Same failure as
## the old exponential curve, wearing a different hat.
##
## REVERSED (July 2026, real playtest, not a probe number): "the Heart now
## OPENS nearly empty, no grace period" above was the previous answer, and it
## was wrong for a first-time human even though the bot handled it fine — a
## bot doesn't need a moment to read the board, aim a thumb, and learn the one
## verb. "Connect both Wells or die in the first two beats" reads as "the game
## is just hard," not "I am bad at this and will get better," which is the
## entire hook a run-based game needs. The fix is NOT the same mistake as
## raising BASE to 0.9: that made the whole CURVE steeper (appetite forever
## after also punished), while this only widens the OPENING buffer — the
## late-game slope (APPETITE_RATE, unchanged) is what still has to produce the
## skill gap, and it does (see probe numbers below). Slow start, hard finish.
## Scaled up alongside FUEL_CAP above so the opening reserve is still the
## same fraction of a full tank, not suddenly thin against a bigger cap.
const START_FUEL := 4.5
## Real playtest (not the bot bisection this was previously tuned against):
## reaching PRISM landed right as the run was already nearly maxed out (see
## EXERTION_SPAN below — PRISM unlocks at run-second 100, EXERTION_SPAN used
## to be 110), so pentagon was a near-death-experience milestone instead of
## the easy, generous one a first-time or non-expert player needs it to be.
## Both cut roughly in half: the long-run curve a couple gets good at is
## still there, it just takes longer to arrive.
const APPETITE_BASE := 0.16
const APPETITE_RATE := 0.013    # per second

## Seconds of exertion before the heart is fully racing.
##
## Was 150, then cut to 110 because bot probes were dying at ~100-105s and the
## back half of the threat curve never got felt. That reasoning still holds,
## but real (non-bot) playtest said the result was backwards for a human:
## PRISM unlocking at t=100 against a 110 span meant pentagon arrived at ~91%
## intensity — "easily reach pentagon" was never possible, the run was
## already almost fully feral by the time it was reachable at all. Pushed
## back out so PRISM has a real, generous window to be enjoyed at moderate
## intensity before the late curve bites — see HARDCORE_RAMP_TIME below for
## the other half of this fix.
const EXERTION_SPAN := 200.0

## Missed feedings before the beat stops for good. DYING/FATAL both raised a
## notch alongside FUEL_CAP/APPETITE above — more real seconds of grace before
## the beat slows, more before it stops for good.
const MISSES_STRAINED := 1
const MISSES_DYING := 4
const MISSES_FATAL := 8

## Hard cap on live Wells. Playtest: "the circles grow and grow" — the board
## only ever accumulated. Wither alone can't hold the line, because it only
## catches Wells that are ORPHANED, and doubling the spawn rate doubled the
## inflow. Past this cap, a new Well displaces the most-neglected existing one
## (the oldest orphan) rather than piling on: the board churns instead of
## silting up, and the screen stays readable at phone size. Connected Wells are
## never displaced — you never lose something you were actually using.
## Raised alongside the spawn-cadence cut below: real playtest said circle
## supply couldn't keep pace with what the Heart wanted, especially by the
## time it's asking for refined tiers with several Wells committed to one
## lineage — more room for those lineages to coexist without evicting each
## other.
const MAX_LIVE_WELLS := 20

# Spawns and budget are on the clock for the same reason as appetite.
##
## Slowed at the open, ramping with the run. Playtest: "objects get spawned
## very quickly at the beginning; the spawning should match the game tempo and
## progression." The board used to fill with Wells inside the first ten
## seconds. It now opens sparse — a first Well only after the two starters have
## had time to be wired in — and the gap DECAYS as the run escalates, so late
## play stays busy. Slow start, quickening finish, same as appetite.
## Cadence cut further (11->8 start, 3.75->2.5 floor) on top of that shape:
## real playtest said circles simply weren't arriving fast enough against the
## Heart's pace, independent of the per-Well rate fix in VNode.WELL_PERIOD.
const FIRST_WELL_TIME := 5.0
const WELL_GAP_START := 8.0
const WELL_GAP_DECAY := 0.6      # wells arrive faster and faster as the run climbs
const WELL_GAP_MIN := 2.5

const FIRST_BUDGET_TIME := 8.0
const BUDGET_GAP_START := 12.0
## Was 3.5 — with more Wells, longer reach, and deeper lineages all landing at
## once (this pass), the player needs veins to keep pace for longer, not have
## budget growth taper off early.
const BUDGET_GAP_GROWTH := 2.5  # ...while veins arrive slower and slower

## Nothing spawns inside this radius of the Heart. Playtest: "don't spawn
## objects too close to the Heart, it makes around the Heart very messy." Tools
## used to be scored to HUG the Heart and could land ~24px off its centre,
## piling up on top of it; Wells could creep in behind the starters. A clearance
## ring keeps the area around the Heart readable. It stays well under Vein.MAX_LEN
## so a tool can still always reach the Heart from just outside the ring.
const MIN_HEART_CLEARANCE := 132.0
## Where a tool prefers to sit: out in the reachable band, not on the Heart.
## Kept modest — far enough to clear the Heart's surroundings, close enough that
## the tool->Heart vein isn't so long that delivery latency starves the run.
const TOOL_IDEAL_HEART_DIST := 195.0

## A tool<->Heart pair used to link across a longer span than every other
## pair (TOOL_HEART_REACH, a 1.45x bonus on top of Vein.MAX_LEN) — that was
## what let the whole Well->Forge->Loom->Kiln chain live scattered out in the
## field near its supply instead of collapsing onto the Heart. Removed per
## explicit direction: the small radius is gone for good, and the ONE radius
## every pair now shares (Vein.MAX_LEN itself, raised to absorb the old
## bonus — see vein.gd) does the same job for every pair, not just the
## Heart-facing one.

## Live-tool ceilings. Playtest: "after a while the screen is full of
## triangles and squares" — tools never die, so without a cap every gap tick
## added scenery forever. Enough for one canonical of each plus exotics.
const MAX_LIVE_FORGES := 3
const MAX_LIVE_LOOMS := 2
const MAX_LIVE_KILNS := 2

## Rot that is never cut does not get to sit there forever as free clutter,
## poisoning at your leisure — it collapses outright, taking the asset with it.
## This is what makes the board turn over instead of only ever accumulating.
## The fade-warning threshold lives on VNode.COLLAPSE_FADE_AT, next to the
## corrupt_age it reads.

## Corruption gets meaner as the run does — this is the second half of "the
## enemy gets worse", on top of the fixed per-Well depletion. Both the vein-borne
## spread AND a new airborne jump (corruption leaping to an unconnected Well
## with no vein at all — a roaming blight, not just a plumbing hazard) scale in
## with intensity, gated to the back half of the run so the opening stays
## learnable and the mid-late game is where it goes feral.
const SPREAD_TIME_LATE := 5.0     ## VNode.SPREAD_TIME at intensity 1.0
## Rot keeps tightening past EXERTION_SPAN (see pressure()) down to this.
const SPREAD_TIME_FLOOR := 3.0
const AIRBORNE_AT := 0.38         ## intensity floor before blight can jump gaps
const AIRBORNE_RADIUS := 190.0
const AIRBORNE_CHANCE := 0.35     ## per spread-tick, once AIRBORNE_AT is crossed
const AIRBORNE_CHANCE_MAX := 0.6  ## ...climbing toward this past EXERTION_SPAN

## How fast a tool spends its reserve per smelt, at intensity 0 — see
## VNode.depletion_rate. Playtest: a Forge could go necrotic within the
## player's first minute, right as they were still learning the recipe
## mechanic, which reads as "the game is broken" rather than "the game is
## hard" — this game's whole design language is escalation ON THE CLOCK
## (see pressure()/intensity()), and tool death shipped as the one exception,
## a flat cost from beat one. 0.12 means an early tool effectively never dies
## from ordinary use; by EXERTION_SPAN it reaches the full 1.0 that
## FORGE_YIELD/LOOM_YIELD/KILN_YIELD were actually tuned against.
const TOOL_DEPLETION_EARLY := 0.12
## Keeps climbing past pressure 1.0, same rule as SPREAD_TIME/AIRBORNE_CHANCE
## above — the enemy never stops getting worse.
const TOOL_DEPLETION_POST_EXTRA := 0.6

## Veins cannot cross — this is the spatial skill check: spaghetti is not a
## strategy. A bad draw is simply REFUSED (see _add_vein), not punished; it used
## to bleed fuel and destroy the crossed vein instead, which silently ate the
## Heart's most-needed rescue connection right where veins most converge.
## Rhythm is a pure carrot: an on-beat edit pays SYNC_FUEL and builds combo, an
## off-beat one just doesn't. There is deliberately no OFFBEAT penalty — see
## _tempo_action.
const SYNC_FUEL := 0.18
const PERFECT_WINDOW := 0.11
const GOOD_WINDOW := 0.22
const COMBO_GAIN := 0.07
const COMBO_CAP := 10

const SNAP := 48.0             # magnetic radius; imprecise thumbs feel precise
const LONG_PRESS := 0.32
const DILATION := 0.3
const DRAG_SLOP := 12.0

# --- Scene ------------------------------------------------------------------
@onready var vein_layer: Node2D = $VeinLayer
@onready var node_layer: Node2D = $NodeLayer
@onready var drag_layer: Node2D = $DragLayer
@onready var drain: ColorRect = $Fx/Drain
@onready var death_ui: Control = $Ui/Death
@onready var score_label: Label = $Ui/Death/Score
@onready var best_label: Label = $Ui/Death/Best
@onready var budget_hint: Node2D = $BudgetHint
@onready var score_hud: Node2D = $ScoreHud
@onready var tutorial: Node2D = $Tutorial
@onready var replay_btn: Button = $Ui/Death/ReplayBtn
@onready var tutorial_btn: Button = $Ui/Death/TutorialBtn

var rng := RandomNumberGenerator.new()
var seed_used := 0

## True when any dev harness (probe/shot/audiocheck) is driving the game.
## Harness runs must never persist saves: the probe was writing every bot
## death into the player's own best/lifetime via _store_save — a bot-set
## best is a wall the player never earned and can't fairly chase.
var _harness_active := false

var nodes: Array[VNode] = []
var veins: Array[Vein] = []
var heart: VNode

var budget := START_BUDGET
var fuel := START_FUEL
var misses := 0
var alive := false
## Mirrors Beat.index. Survival time in heartbeats — what the harnesses read.
## Not the score: "the heartbeat is not important, it's the blood it
## receives that's important" — see `score` below, which is what's actually
## shown to the player.
var beats := 0

## The live score, shown in the HUD and on the death screen, compared
## against `best`. Reactive to every popped delivery (see _pop_gain) — every
## pop that lands is exactly what score moved by — so it reads 0 when
## nothing was ever connected, not some unrelated survival-time number.
var score := 0
## Fractional score the combo bonus produced but hasn't rounded into a pop
## yet (a RAW delivery at combo ×1.07 is worth 1.07 score, and 0.07 can't
## pop on its own) — carried to the NEXT delivery instead of being silently
## discarded every time, so the fraction accumulates until it actually earns
## an extra point, then pops it.
var _score_carry := 0.0

## The number to beat. There is no winning in VEIN — every run ends — so the
## only thing that can pull a player back is their own last best.
var best := 0
var lifetime_beats := 0
var beat_best_this_run := false
## Persisted across runs (see _load_save/_store_save) — drives VNode.teach so
## the recipe demonstration plays on the first Forge/Loom/Kiln the player EVER
## sees, not every run once they already understand it.
var seen_forge := false
var seen_loom := false
var seen_kiln := false
## The Cut-the-Rope-style first-run tutorial (see tutorial.gd). Each lesson
## persists separately so dying mid-tutorial never re-teaches a verb already
## performed; tutorial_done is the aggregate that switches the whole system
## off forever.
var tut_connect := false
var tut_chain := false
var tut_forge := false
var tut_cut := false
var tutorial_done := false
## Ruptures this run. If this stays at zero, trunk capacity never binds and
## layout still does not matter — the probe watches it for exactly that reason.
var ruptures := 0
## Items destroyed on arrival at a node whose buffer was already full. Every one
## of these is pressure that vanished instead of backing up the network.
var dropped := 0
## VOID items that reached the Heart. If this is 0 across a run, the enemy never
## engaged and corruption is decorative.
var poisoned := 0
## Wells that ran dry and turned this run.
var corruptions := 0
## Wells withered from neglect, and rot collapsed outright. Both remove the
## node itself, so `nodes` undercounts everything that ever appeared once
## either of these fires — these are the cumulative truth the probe reads
## instead.
var withered := 0
var collapsed := 0
## Every node ever created, by kind — `nodes.size()` alone undercounts once
## withering/collapse can remove them mid-run.
var spawned_wells := 0
## Items the Heart accepted but did not want. High counts mean the player (or
## bot) failed to re-plumb after a demand flip.
var wasted := 0
## Consecutive edits made on the heartbeat. This is the mastery layer: elite
## play is not just topology, it is surgery in rhythm.
var combo := 0

## The shape the Heart wants right now. Drawn inside it — see VNode._draw_hex.
var demand: int = VNode.Res.RAW
## Every resource DEMAND_TIERS has introduced so far this run — the pool the
## post-teaching rotation phase draws from (see _tick_escalation).
var _unlocked_res: Array[int] = [VNode.Res.RAW]
var _next_rotate_time := INF

## True from the instant the Heart has EVER received a delivery — any kind,
## even a wrong-shape one, since it only exists to prove the player has
## actually engaged. Gates the DEMAND_TIERS schedule below: playtest reported
## dying of pure opening neglect (nothing ever connected) right as the demand
## flip to REFINED happened to land, which reads as "the triangle killed me"
## when neglect already had. The schedule simply doesn't run until this is
## true, so an idle board never sees a demand change to blame.
var _heart_fed_ever := false
## Seconds since the FIRST feed, not since run start — this is what
## DEMAND_TIERS is actually measured against (see _tick_escalation). Frozen at
## 0 until _heart_fed_ever flips true.
var _demand_clock := 0.0
## run_time the moment PRISM was first unlocked (see _tick_escalation). INF
## until then — read by _hardcore_ramp() below.
var _prism_unlocked_at := INF

## Seconds this run has been alive. The escalation clock — see APPETITE_RATE.
var run_time := 0.0
var _next_well_time := FIRST_WELL_TIME
var _next_forge_time := FIRST_FORGE_TIME
var _next_loom_time := FIRST_LOOM_TIME
var _next_kiln_time := FIRST_KILN_TIME
var _well_gap := WELL_GAP_START
var _next_budget_time := FIRST_BUDGET_TIME
var _budget_gap := BUDGET_GAP_START

var _appetite_clock := 0.0

var _drag_from: VNode = null
var _drag_pos := Vector2.ZERO
var _touch_start := Vector2.ZERO
var _touch_time := 0.0
var _touching := false
var _dilating := false
var _moved := false
## What the press landed on, before we know whether it turns into a drag or
## stays a stationary tap — see _on_press/_on_move/_on_release.
var _press_node: VNode = null
var _press_vein: Vein = null

var _rescue := 0.0
var _drain_amt := 0.0
var _sync_flash := 0.0
var _bad_tempo_flash := 0.0
## Time scale to restore when the panic-pinch ends. Captured on engage so the
## harnesses' scale survives.
var _pre_dilation_scale := 1.0


func _end_dilation() -> void:
	if not _dilating:
		return
	_dilating = false
	Engine.time_scale = _pre_dilation_scale


func _ready() -> void:
	_fit_desktop_window()
	drag_layer.draw.connect(_draw_drag)
	death_ui.hide()
	# Death-screen buttons. A real Button consumes its own tap before
	# _unhandled_input sees it, so each does its own thing while a tap anywhere
	# ELSE on the death screen still does the default retry. The primary
	# Replay button was previously never connected — tapping it ate the tap
	# and did nothing, which read as "the replay button is broken".
	replay_btn.pressed.connect(func() -> void: start_run(0))
	tutorial_btn.pressed.connect(_on_replay_tutorial)
	Beat.beat.connect(_on_beat)
	Beat.stopped.connect(_on_stopped)
	_load_save()
	start_run(0)
	_maybe_attach_harness()


## Desktop windows launch at project.godot's fixed window_width/height_override,
## which is only ever right for the one screen it happened to be tuned against
## — "hit play" on a bigger laptop still opened the same small fixed window.
## Maximizing hands the window manager the job of finding "as big as this
## screen allows" (it already knows about menu bars, docks, and multi-monitor
## setups, which a hand-computed size does not); stretch/aspect="keep" then
## letterboxes VEIN's phone aspect (design_size()) inside that, same as it
## already does for an arbitrarily-sized browser tab.
func _fit_desktop_window() -> void:
	if OS.has_feature("web") or OS.has_feature("mobile"):
		return
	if DisplayServer.get_name() == "headless":
		return
	DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_MAXIMIZED)


func _load_save() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(SAVE_PATH) != OK:
		return
	# Lifetime beats survive a rebalance; a best score does not.
	lifetime_beats = int(cfg.get_value("run", "lifetime", 0))
	if int(cfg.get_value("run", "tuning", 0)) == TUNING_VERSION:
		best = int(cfg.get_value("run", "best", 0))
	seen_forge = bool(cfg.get_value("run", "seen_forge", false))
	seen_loom = bool(cfg.get_value("run", "seen_loom", false))
	seen_kiln = bool(cfg.get_value("run", "seen_kiln", false))
	tut_connect = bool(cfg.get_value("run", "tut_connect", false))
	tut_chain = bool(cfg.get_value("run", "tut_chain", false))
	tut_forge = bool(cfg.get_value("run", "tut_forge", false))
	tut_cut = bool(cfg.get_value("run", "tut_cut", false))
	tutorial_done = bool(cfg.get_value("run", "tutorial_done", false))


func _store_save() -> void:
	if _harness_active:
		return
	var cfg := ConfigFile.new()
	cfg.set_value("run", "best", best)
	cfg.set_value("run", "lifetime", lifetime_beats)
	cfg.set_value("run", "tuning", TUNING_VERSION)
	cfg.set_value("run", "seen_forge", seen_forge)
	cfg.set_value("run", "seen_loom", seen_loom)
	cfg.set_value("run", "seen_kiln", seen_kiln)
	cfg.set_value("run", "tut_connect", tut_connect)
	cfg.set_value("run", "tut_chain", tut_chain)
	cfg.set_value("run", "tut_forge", tut_forge)
	cfg.set_value("run", "tut_cut", tut_cut)
	cfg.set_value("run", "tutorial_done", tutorial_done)
	cfg.save(SAVE_PATH)


## Dev harnesses, driven off the command line so they run inside a normal project
## launch — autoload singletons like Beat do not resolve as globals under a
## `--script` main loop, which is why these are attached rather than standalone.
##
##   --probe=N [--speed=X]        headless balance run
##   --shot=PATH [--after=S] [--speed=X]   render a frame (needs a window)
##
## Loaded dynamically so an exported build without tests/ still runs.
func _maybe_attach_harness() -> void:
	var probe_runs := 0
	var shot_path := ""
	var speed := 0.0
	var after := 20.0
	var cap := 0

	for a in OS.get_cmdline_user_args():
		if a.begins_with("--probe"):
			probe_runs = int(a.get_slice("=", 1)) if a.contains("=") else 5
		elif a.begins_with("--shot="):
			shot_path = a.get_slice("=", 1)
		elif a.begins_with("--cap="):
			cap = int(a.get_slice("=", 1))
		elif a.begins_with("--speed="):
			speed = float(a.get_slice("=", 1))
		elif a.begins_with("--after="):
			after = float(a.get_slice("=", 1))

	if probe_runs > 0:
		# The tutorial's grace window would silently change probe balance —
		# harness runs always measure the real game, never the lesson.
		_harness_active = true
		tutorial.enabled = false
		var p: Node = _load_harness("res://tests/probe.gd")
		if p == null:
			return
		p.runs = probe_runs
		p.speed = speed if speed > 0.0 else 60.0
		p.cap = cap
		add_child(p)
	elif "--audiocheck" in OS.get_cmdline_user_args():
		_harness_active = true
		tutorial.enabled = false
		var a: Node = _load_harness("res://tests/audiocheck.gd")
		if a != null:
			add_child(a)
	elif "--chainstress" in OS.get_cmdline_user_args():
		_harness_active = true
		tutorial.enabled = false
		var c: Node = _load_harness("res://tests/chain_stress.gd")
		if c != null:
			add_child(c)
	elif shot_path != "":
		_harness_active = true
		# `--tutorial` forces the hints on regardless of the save, so they
		# can be screenshot-verified; a plain shot shows the real game.
		if "--tutorial" in OS.get_cmdline_user_args():
			tut_connect = false
			tut_chain = false
			tut_forge = false
			tut_cut = false
			tutorial_done = false
		else:
			tutorial.enabled = false
		var s: Node = _load_harness("res://tests/shot.gd")
		if s == null:
			return
		s.out_path = shot_path
		s.after = after
		s.speed = speed if speed > 0.0 else 3.0
		s.demo_tutorial = "--tutorial" in OS.get_cmdline_user_args()
		add_child(s)


func _load_harness(path: String) -> Node:
	if not ResourceLoader.exists(path):
		push_error("harness missing: %s" % path)
		return null
	var script: Script = load(path)
	return null if script == null else script.new()


# --- Run lifecycle ----------------------------------------------------------

## Wipes the tutorial-completion flags and starts a fresh run, so the
## Cut-the-Rope lessons play again from the top — wired to the death screen's
## "Replay tutorial" button. Persisted, so the replayed tutorial also sticks
## if the player quits partway and comes back.
func _on_replay_tutorial() -> void:
	tut_connect = false
	tut_chain = false
	tut_forge = false
	tut_cut = false
	tutorial_done = false
	_store_save()
	start_run(0)


func start_run(run_seed: int) -> void:
	Audio.start()
	for n in nodes:
		n.queue_free()
	for v in veins:
		v.queue_free()
	nodes.clear()
	veins.clear()

	seed_used = run_seed if run_seed != 0 else randi()
	rng.seed = seed_used

	budget = START_BUDGET
	fuel = START_FUEL
	misses = 0
	beats = 0
	score = 0
	_score_carry = 0.0
	ruptures = 0
	dropped = 0
	withered = 0
	collapsed = 0
	spawned_wells = 0
	poisoned = 0
	corruptions = 0
	wasted = 0
	combo = 0
	demand = VNode.Res.RAW
	_unlocked_res = [VNode.Res.RAW]
	_next_rotate_time = INF
	_heart_fed_ever = false
	_demand_clock = 0.0
	_prism_unlocked_at = INF
	_no_move_time = 0.0
	rescues = 0
	_rescue = 0.0
	_drain_amt = 0.0
	_sync_flash = 0.0
	_bad_tempo_flash = 0.0
	_appetite_clock = 0.0
	run_time = 0.0
	_next_well_time = FIRST_WELL_TIME
	_next_forge_time = FIRST_FORGE_TIME
	_next_loom_time = FIRST_LOOM_TIME
	_next_kiln_time = FIRST_KILN_TIME
	_well_gap = WELL_GAP_START
	_next_budget_time = FIRST_BUDGET_TIME
	_budget_gap = BUDGET_GAP_START
	_chain_stall.clear()
	chain_rescues = 0
	_throughput_stall = 0.0
	throughput_rescues = 0

	var vp := design_size()
	heart = _make_node(VNode.Kind.HEART, Vector2(vp.x * 0.5, vp.y * 0.44))

	# Two wells to open with, placed relative to the Heart and inside its reach:
	# the first connection must be obvious, so the player learns the verb by
	# doing it rather than being told. Anchoring these to the viewport corners
	# instead would put them out of reach and open the run already lost.
	# One above, one below. New Wells only spawn within reach of an existing node,
	# so the network grows outward from these two — seeding both below the Heart
	# meant it could only ever creep downward and the top third of the screen
	# stayed empty for the whole run.
	_make_node(VNode.Kind.WELL, heart.position + Vector2(-142, -118))
	_make_node(VNode.Kind.WELL, heart.position + Vector2(146, 122))

	death_ui.hide()
	alive = true
	if tutorial != null:
		tutorial.reset()
	Beat.reset()
	_rebuild_graph()


## The playfield, in design space — NOT get_viewport_rect().
##
## One screen is the whole world (no pan, no zoom), and the stretch mode maps
## this rect onto whatever the device is. Reading the live viewport instead
## breaks the sim wherever the window is not 540x1170: headless reports a square
## 1170x1170, which pushed every Well past Vein.MAX_LEN and quietly made the
## probe unwinnable. Layout must not depend on the window, or the seed no longer
## determines the run.
func design_size() -> Vector2:
	return Vector2(
		float(ProjectSettings.get_setting("display/window/size/viewport_width", 540)),
		float(ProjectSettings.get_setting("display/window/size/viewport_height", 1170)),
	)


func _make_node(kind: int, pos: Vector2) -> VNode:
	var n: VNode = VNodeScene.new()
	n.kind = kind
	n.position = pos
	if kind == VNode.Kind.WELL:
		spawned_wells += 1
	match kind:
		VNode.Kind.FORGE:
			n.produces = VNode.Res.REFINED
		VNode.Kind.LOOM:
			n.produces = VNode.Res.CLOTH
		VNode.Kind.KILN:
			n.produces = VNode.Res.PRISM
		_:
			n.produces = VNode.Res.RAW
	node_layer.add_child(n)
	nodes.append(n)
	return n


func _on_stopped(total: int) -> void:
	alive = false
	Audio.stop_all()
	# The run can die mid panic-pinch; never leave the world dilated. Only undo
	# our own dilation — blindly writing 1.0 here would stomp the time scale the
	# dev harnesses set, which silently dropped the probe back to real time.
	_end_dilation()

	lifetime_beats += total
	# Best/the death screen both track `score` — what the Heart actually
	# received — not survival time. `total` (beats) still feeds
	# lifetime_beats, a separate lifetime stat the harnesses read.
	beat_best_this_run = score > best
	if beat_best_this_run:
		best = score
	_store_save()

	score_label.text = "Score  %s" % _commas(score)
	# The target. Without something to beat, "one more run" has no hook — and
	# VEIN has no win state to offer instead.
	if beat_best_this_run:
		best_label.text = "Your best yet."
	else:
		best_label.text = "Best  %s" % _commas(best)
	death_ui.show()


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


# --- The beat: consumption, escalation, death -------------------------------

func _on_beat(index: int) -> void:
	beats = index
	if not alive:
		return

	fuel -= appetite()
	if fuel < 0.0:
		fuel = 0.0
		misses += 1
	elif misses > 0:
		misses -= 1

	if misses >= MISSES_FATAL:
		Beat.stop()
		return
	elif misses >= MISSES_DYING:
		Beat.set_state(Beat.State.DYING)
	elif misses >= MISSES_STRAINED:
		Beat.set_state(Beat.State.STRAINED)
	else:
		Beat.set_state(Beat.State.HEALTHY)

	Beat.set_exertion(intensity())


## How far into the escalation curve this run is, UNCLAMPED — passes 1.0 at
## EXERTION_SPAN and keeps climbing forever. The clamped intensity() below
## is for everything cosmetic (audio, exertion, particle violence), which
## has a natural ceiling; the threat systems (demand rotation, corruption
## spread, airborne blight — see _tick_escalation/_tick_corruption) read
## THIS, because the run must never plateau: past EXERTION_SPAN the only
## thing still escalating used to be raw appetite, so a long run flattened
## into a grind against one number instead of a world still getting meaner.
## The loop runs forever; it just keeps getting harder until you lose.
##
## Muted while still walking the DEMAND_TIERS teaching schedule (RAW through
## PRISM has never all been unlocked yet), then eases up to full strength
## over HARDCORE_RAMP_TIME once PRISM lands. Playtest: the schedule itself
## already waits for demand to flip gently (see _demand_clock), but every
## OTHER threat — corruption spread, airborne blight, tool depletion, even
## the appetite wave below — was still climbing on the raw run clock the
## whole time, so by the time a player actually REACHED pentagon the world
## was already nearly maxed out. "Easy to reach pentagon, then it gets hard"
## needs the whole hazard mix gated on tier progress, not just the shape the
## Heart is asking for. Nothing about the tuned LATE curve changes — this
## only compresses how much of it you feel while still climbing to PRISM.
const TEACHING_PRESSURE_MULT := 0.35
## Seconds after PRISM unlocks before pressure reaches full strength.
## Was 10 — a "short breather," but paired with the old EXERTION_SPAN=110 that
## meant full hardcore intensity landed within 10s of reaching pentagon at
## all, no matter how well built the board was. Real playtest: this needs to
## be a real window to enjoy the milestone in, not a cutover with a different
## number. Raised alongside EXERTION_SPAN's own increase above so "easy to
## reach pentagon, then it gets hard" actually has a middle where it's just
## pentagon for a while.
const HARDCORE_RAMP_TIME := 60.0

func pressure() -> float:
	return run_time / EXERTION_SPAN * lerpf(TEACHING_PRESSURE_MULT, 1.0, _hardcore_ramp())


## 0 while PRISM has never been unlocked, ramping 0->1 over HARDCORE_RAMP_TIME
## once it is (see _prism_unlocked_at, set in _tick_escalation).
func _hardcore_ramp() -> float:
	if _prism_unlocked_at == INF:
		return 0.0
	return clampf((run_time - _prism_unlocked_at) / HARDCORE_RAMP_TIME, 0.0, 1.0)


## pressure() clamped to 0..1 — the cosmetic ceiling. Exertion, the mix, and
## particle violence read this; they max out and stay there.
func intensity() -> float:
	return clampf(pressure(), 0.0, 1.0)


## Fuel the Heart burns per beat, rising on the run clock.
##
## The climb used to be a flat ramp: predictable the moment you'd seen a
## minute of it. A sine wave riding on top makes the hunger itself feel
## alive rather than a metronome — amplitude starts at zero (the opening
## stays exactly as learnable as before) and grows with intensity, so late
## in a run the Heart is genuinely surging and easing, not just climbing.
## Averages out to the same long-run curve; only the moment-to-moment texture
## changes, not the tuned difficulty.
const APPETITE_WAVE_AMP := 0.09
const APPETITE_WAVE_PERIOD := 17.0
## How much slower the fuel drain's RATE climbs while still teaching (see
## TEACHING_PRESSURE_MULT above — same reasoning, applied to the single
## biggest killer in the game). APPETITE_BASE/START_FUEL are untouched: those
## already carry the tuned "first ten seconds" grace on their own.
const TEACHING_APPETITE_MULT := 0.4

func appetite() -> float:
	var rate := APPETITE_RATE * lerpf(TEACHING_APPETITE_MULT, 1.0, _hardcore_ramp())
	var base := APPETITE_BASE + rate * _appetite_clock
	var wave := sin(_appetite_clock * TAU / APPETITE_WAVE_PERIOD) * APPETITE_WAVE_AMP * intensity()
	return maxf(0.02, base + wave)


func fuel_cap() -> float:
	return FUEL_CAP


## Every spawn cadence used to be a flat interval — the exact same gap, every
## time, seed after seed — which reads as a metronome once you've played a
## few runs: "I know exactly when the next Boost lands." Wobbling each gap
## by up to `spread` (still drawn from the seeded `rng`, so a given seed is
## still fully reproducible) keeps the same average pace but breaks the
## predictability that made the board feel inert between events.
func _jitter(base: float, spread: float) -> float:
	return base * rng.randf_range(1.0 - spread, 1.0 + spread)


func _tut_holds_demand() -> bool:
	return tutorial != null and tutorial.holds_demand()


func _tut_gates_spawns() -> bool:
	return tutorial != null and tutorial.gates_spawns()


## Drives the spawn and budget clocks. Kept out of _on_beat so a slowing Heart
## cannot slow its own escalation.
func _tick_escalation(delta: float) -> void:
	run_time += delta
	_appetite_clock += delta
	# The demand SCHEDULE runs on time-since-first-feed, not run_time — see
	# _heart_fed_ever. Everything else (appetite, spawns, corruption) still
	# escalates on real run_time regardless of engagement; only the "what does
	# the Heart want" clock waits for proof the player has done something.
	if _heart_fed_ever:
		_demand_clock += delta

	# During the tutorial the demand schedule is suspended — the tutorial owns
	# `demand` and brings the triangle in on its own paced clock (see
	# tutorial.holds_demand), so a first-timer isn't hit with a flip before
	# they've learned to connect and chain.
	if not _tut_holds_demand():
		var want: int = demand
		for t in DEMAND_TIERS:
			if _demand_clock >= t.at:
				want = t.res
				if not _unlocked_res.has(t.res):
					_unlocked_res.append(t.res)
					if t.res == VNode.Res.PRISM:
						_prism_unlocked_at = run_time

		# Teaching schedule is over once every DEMAND_TIERS entry has landed —
		# from here, demand jumps randomly among everything unlocked instead of
		# sitting at PRISM forever (see ROTATE_GAP_START/MIN above).
		# _next_rotate_time starts at INF (see start_run) so the first crossing
		# just arms the timer rather than firing an immediate switch the instant
		# PRISM lands.
		if _demand_clock >= DEMAND_TIERS[-1].at and _next_rotate_time == INF:
			_next_rotate_time = _demand_clock + _jitter(ROTATE_GAP_START, 0.3)
		elif _demand_clock >= _next_rotate_time:
			var pool := _unlocked_res.duplicate()
			pool.erase(want)
			if not pool.is_empty():
				want = pool[rng.randi() % pool.size()]
			# Keeps shrinking past pressure 1.0 (see pressure()) toward a hard
			# floor, so deep-late demand flips genuinely never stop accelerating.
			var gap := lerpf(ROTATE_GAP_START, ROTATE_GAP_MIN, intensity())
			gap = maxf(ROTATE_GAP_FLOOR, gap - maxf(pressure() - 1.0, 0.0) * 2.0)
			_next_rotate_time = _demand_clock + _jitter(gap, 0.35)

		if want != demand:
			demand = want
			heart.demand = want
			# The Heart changing its mind is the loudest event in the run:
			# everything you built is now feeding it the wrong thing.
			heart.pulse = 1.0
			Audio.play("corrupt", -6.0, 1.5)
			if OS.has_feature("mobile"):
				Input.vibrate_handheld(220)

	# During the tutorial's controlled opening, spawns are suspended entirely —
	# the tutorial injects the one Well it needs and keeps the board calm until
	# chaining is taught (see tutorial.gates_spawns). Budget still grows below.
	if not _tut_gates_spawns():
		if run_time >= _next_well_time:
			_spawn_well()
			_next_well_time += _jitter(_well_gap, 0.3)
			_well_gap = maxf(WELL_GAP_MIN, _well_gap - WELL_GAP_DECAY)

		_ensure_move(delta)
		_tick_tool_chain(delta)
		_ensure_throughput(delta)

		# Tools keep arriving on their cadence but the BOARD stays capped —
		# playtest: "after a while the screen is full of triangles and squares."
		# At cap the timer still advances, so a slot freed later (a collapse)
		# refills on the next tick rather than never.
		if run_time >= _next_forge_time:
			if _count_healthy_kind(VNode.Kind.FORGE) < MAX_LIVE_FORGES:
				_spawn_node(VNode.Kind.FORGE)
			_next_forge_time += _jitter(FORGE_GAP, 0.25)

		if run_time >= _next_loom_time:
			if _count_healthy_kind(VNode.Kind.LOOM) < MAX_LIVE_LOOMS:
				_spawn_node(VNode.Kind.LOOM)
			_next_loom_time += _jitter(LOOM_GAP, 0.2)

		if run_time >= _next_kiln_time:
			if _count_healthy_kind(VNode.Kind.KILN) < MAX_LIVE_KILNS:
				_spawn_node(VNode.Kind.KILN)
			_next_kiln_time += _jitter(KILN_GAP, 0.2)

	if run_time >= _next_budget_time:
		budget += 1
		_next_budget_time += _jitter(_budget_gap, 0.15)
		_budget_gap += BUDGET_GAP_GROWTH
		budget_hint.queue_redraw()


## New Wells displace the most-neglected old one once the board is full, so the
## count stays flat and readable instead of climbing all run. Only orphans are
## ever displaced — a Well you actually wired in is safe.
func _spawn_well() -> void:
	var live: Array[VNode] = []
	for n in nodes:
		if n.kind == VNode.Kind.WELL and not n.corrupted:
			live.append(n)

	if live.size() >= MAX_LIVE_WELLS:
		var oldest: VNode = null
		for n in live:
			if n.depth >= 0:
				continue
			if oldest == null or n.orphan_age > oldest.orphan_age:
				oldest = n
		# Everything is connected and we're at cap: the player has earned a full
		# board, so skip this spawn rather than deleting something in use.
		if oldest == null:
			return
		withered += 1
		_remove_node(oldest)

	_spawn_node(VNode.Kind.WELL)


## New nodes spawn in awkward places, forcing rerouting. Bias to the lower two
## thirds so everything stays in one-thumb reach.
##
## A tool is placed by the opposite rule to a Well: it wants to sit CLOSE to the
## Heart, because its job is to stand between a cluster of Wells and the trunk
## they overload. Spawning it out at the rim like a Well would make it
## unroutable and it would never be worth the veins.
func _spawn_node(kind: int) -> void:
	var vp := design_size()
	var best := Vector2.ZERO
	var best_score := -INF

	# Grow OUTWARD from a node already on the board, at a uniformly random angle.
	#
	# Playtest: "the circles mostly spawn at the bottom." Two biases were stacked
	# and compounded: sqrt(randf()) pulled the y-roll downward, AND the score
	# rewarded distance from the Heart — which sits at 44% height, so the bottom
	# edge (573px away) beat the top (351px) every single time. Rejection
	# sampling over the whole rect also wasted most candidates, since anything
	# beyond MAX_LEN of everything is unjoinable. Seeding from an existing node
	# at a random bearing fills the board evenly and every candidate is reachable
	# by construction — reachable from the ANCHOR, at least.
	#
	# The anchor pool used to be every node on the board, connected or not.
	# That let a new Well/tool spawn off an already-orphaned node, growing an
	# island that could end up in reach of nothing the Heart's live network
	# ever touches — reported as "sometimes there's no possible move at all."
	# Anchoring to the connected component only guarantees every new node is
	# reachable from something you can actually build to right now (the Heart
	# itself always qualifies, so this pool is never empty).
	#
	# A Forge/Loom is a single point of failure for an entire demand tier —
	# unlike a Well, there is no redundant backup a moment later. Anchoring it
	# to any connected node (rather than the Heart specifically) meant its
	# reach guarantee only held at the instant it spawned: if THAT anchor
	# later withered or was cut loose, the tool's position never moved, and it
	# could end up outside MAX_LEN of everything the live network still
	# touches — a demand flip with no possible move to answer it, fair by
	# construction at spawn time but not for the rest of the run. The Heart's
	# position never changes and the Heart is never removed, so a Forge
	# anchors to it specifically, keeping it within one direct vein of the
	# Heart for the run's entire duration, not just the moment it appeared.
	#
	# A Loom is different: it doesn't just need to reach the Heart, it needs
	# to RECEIVE from a Forge (2 REFINED in, 1 CLOTH out) — bug report: "heart
	# wanted square, there was no square anywhere" plus "square wants two
	# triangles, there should be triangles somehow in reach for it". Anchoring
	# a Loom to the Heart the same way a Forge does guarantees Loom-to-Heart
	# reach but NOT Forge-to-Loom reach — the two tools would land as
	# independent siblings around the Heart with nothing ensuring they were
	# ever close enough to hand off to each other, which makes the square
	# exist but leaves it permanently unfeedable. A Loom instead anchors to
	# the MIDPOINT between the Heart and an existing Forge: both are within
	# MAX_LEN of a point roughly half as far away as either, so Forge->Loom
	# and Loom->Heart are both always directly drawable — a complete,
	# guaranteed-buildable Well->Forge->Loom->Heart chain, not just two
	# separately-reachable dead ends. A Kiln repeats exactly the same trick
	# one link further down the chain: it anchors to the midpoint between the
	# Heart and an existing Loom, so Loom->Kiln->Heart is guaranteed the same
	# way Forge->Loom->Heart is.
	# A Well's anchor must not just be CONNECTED, it must be able to USE what
	# a Well makes: a Well whose only in-reach neighbour is a Loom/Kiln (which
	# may refuse RAW) or a corrupted node "spawned reachable" but every vein
	# you could draw to it was a dead move — RAW arrived and was refused on
	# contact. Anchoring only to nodes that accept or relay RAW (the Heart,
	# healthy Wells) guarantees at least one USEFUL connection exists the
	# moment it appears, not merely a drawable one.
	#
	# The pool also includes the FRONTIER: orphan Wells that are themselves
	# within reach of the network. Playtest: "spawning seems to happen in a
	# perfect circle around the heart" — with only the connected core as
	# anchors, every new node landed on the same annulus around the same few
	# points. Growing off the frontier too lets the board wander outward in
	# organic chains instead of stacking rings.
	var connected: Array[VNode] = []
	for n in nodes:
		if n.depth < 0 or n.corrupted:
			continue
		if n.kind == VNode.Kind.HEART or n.kind == VNode.Kind.WELL \
				or (n.kind == VNode.Kind.FORGE and n.recipe.has(VNode.Res.RAW)):
			connected.append(n)
	if connected.is_empty():
		connected = [heart]
	var anchors := connected.duplicate()
	for n in nodes:
		if n.depth >= 0 or n.corrupted or n.kind != VNode.Kind.WELL:
			continue
		for m in connected:
			if in_reach(n, m):
				anchors.append(n)
				break

	var is_tool := kind == VNode.Kind.FORGE or kind == VNode.Kind.LOOM or kind == VNode.Kind.KILN

	# A tool is USELESS unless BOTH its feeder and its delivery target can reach
	# it — playtest: "the triangle spawned where no circle could reach it,
	# there must never be a scenario with no move." The feeder is what hands it
	# raw material (a Forge eats from a Well, a Loom from a Forge, a Kiln from a
	# Loom); the target is always the Heart (every chain drains to it). Placing
	# the tool near the MIDPOINT of feeder<->Heart, inside a ring tight enough
	# that any candidate stays within Vein.MAX_LEN of both, makes the whole
	# link buildable by construction. The reach is then re-checked per
	# candidate below, so an off-midpoint pick can never sneak out of range.
	var anchor_point := heart.position
	var feeder: VNode = null
	var min_dist := 40.0
	var max_dist := Vein.MAX_LEN * 0.9
	if is_tool:
		if kind == VNode.Kind.FORGE:
			feeder = _nearest_node_of_kind(VNode.Kind.WELL, heart.position)
		elif kind == VNode.Kind.LOOM:
			feeder = _nearest_node_of_kind(VNode.Kind.FORGE, heart.position)
		else:
			feeder = _nearest_node_of_kind(VNode.Kind.LOOM, heart.position)
		# A tool anchors to its FEEDER, not the feeder<->Heart midpoint: it
		# lives out in the field next to its supply and reaches the Heart
		# across the same single Vein.MAX_LEN every other pair gets now. That
		# is the whole scatter fix — the chain no longer collapses onto the
		# Heart. The feeder must itself be within reach of the Heart, or a
		# tool placed by it couldn't also reach the Heart; if it isn't, fall
		# back to hugging the Heart and let the rescue system drop supply
		# nearby.
		if feeder != null and heart.position.distance_to(feeder.position) > Vein.MAX_LEN - 24.0:
			feeder = null
		if feeder != null:
			anchor_point = feeder.position
			min_dist = 78.0
			max_dist = Vein.MAX_LEN * 0.82
		else:
			min_dist = MIN_HEART_CLEARANCE
			max_dist = Vein.MAX_LEN * 0.7

	for _i in 64:
		var p: Vector2
		if is_tool:
			var bearing := rng.randf() * TAU
			var dist := rng.randf_range(min_dist, max_dist)
			p = anchor_point + Vector2(cos(bearing), sin(bearing)) * dist
		else:
			var anchor: VNode = anchors[rng.randi() % anchors.size()]
			var bearing := rng.randf() * TAU
			var dist := rng.randf_range(90.0, Vein.MAX_LEN * 0.95)
			p = anchor.position + Vector2(cos(bearing), sin(bearing)) * dist
		if p.x < 56.0 or p.x > vp.x - 56.0 or p.y < 70.0 or p.y > vp.y - 70.0:
			continue

		var to_heart := p.distance_to(heart.position)
		# Keep the Heart's immediate surroundings clear — nothing crowds it.
		if to_heart < MIN_HEART_CLEARANCE:
			continue

		# Hard reachability gate for tools: reject any spot the Heart or the
		# feeder cannot directly reach. This is the guarantee, not a preference.
		if is_tool:
			if to_heart > Vein.MAX_LEN:
				continue
			if feeder != null and p.distance_to(feeder.position) > Vein.MAX_LEN:
				continue

		var near := INF
		for n in nodes:
			near = minf(near, p.distance_to(n.position))
		if near < 104.0:
			continue

		var s := 0.0
		if is_tool:
			# Tools stand between supply and the Heart, but out in the reachable
			# band — not piled on the Heart. Reward elbow room and sitting near
			# the ideal ring distance, so tools scatter across the mid-field.
			s = near - absf(to_heart - TOOL_IDEAL_HEART_DIST) * 0.6
		else:
			# Prefer awkward — elbow room from neighbours — WITHOUT preferring a
			# compass direction. Distance from the Heart is deliberately not a
			# term here; that was the bias.
			s = near
		if s > best_score:
			best_score = s
			best = p

	if best_score == -INF:
		# NOTHING is allowed to silently fail to spawn. For a tool the fallback
		# must STILL be reachable, so it goes at the feeder<->Heart midpoint
		# (which is within one reach of both by construction) nudged to the
		# least-crowded nearby bearing; a Well falls back to a spot off any
		# anchor.
		if is_tool:
			if feeder != null:
				# Sample the full allowed ring, not a tight 40px stub: the
				# least-crowded spot is also the one farthest from the Heart, so
				# a fallback tool spreads outward rather than piling on the Heart.
				best = _least_crowded_spot(anchor_point, max_dist)
			else:
				best = _least_crowded_spot(anchor_point, Vein.MAX_LEN * 0.6)
		else:
			var anchor: VNode = anchors[rng.randi() % anchors.size()]
			best = _least_crowded_spot(anchor.position, Vein.MAX_LEN * 0.7)
	var n := _make_node(kind, best)
	if is_tool:
		n.recipe = _roll_recipe(kind)
	if kind == VNode.Kind.FORGE and not seen_forge:
		seen_forge = true
		n.teach = true
		_store_save()
	elif kind == VNode.Kind.LOOM and not seen_loom:
		seen_loom = true
		n.teach = true
		_store_save()
	elif kind == VNode.Kind.KILN and not seen_kiln:
		seen_kiln = true
		n.teach = true
		_store_save()
	_rebuild_graph()


## What each tool kind makes never varies; what it EATS does. The plain
## recipe is two of the tier below — the classic chain. Exotic recipes are
## mixed multisets ("1 square and 1 circle", "2 x 1 y", up to three slots)
## drawn from everything the run has unlocked so far, excluding VOID and the
## tool's own product.
const CANONICAL_RECIPE := {
	VNode.Kind.FORGE: [VNode.Res.RAW, VNode.Res.RAW],
	VNode.Kind.LOOM: [VNode.Res.REFINED, VNode.Res.REFINED],
	VNode.Kind.KILN: [VNode.Res.CLOTH, VNode.Res.CLOTH],
}
## Chance a tool rolls exotic, growing with run pressure — the opening stays
## the learnable classic chain, the late game goes strange.
const EXOTIC_CHANCE_BASE := 0.25
const EXOTIC_CHANCE_MAX := 0.75


## THE NO-MOVE GUARANTEE APPLIES HERE TOO: the first tool of each kind on
## the board — and any tool spawned while no plain-recipe sibling of its
## kind is alive — is always canonical, so every demand tier is always
## answerable through the classic Well->Forge->Loom->Kiln chain no matter
## how weird the extras get.
func _roll_recipe(kind: int) -> Array[int]:
	var canonical: Array[int] = []
	canonical.assign(CANONICAL_RECIPE[kind])

	var has_canonical := false
	for n in nodes:
		if n.kind == kind and not n.corrupted and n.recipe == canonical:
			has_canonical = true
			break
	if not has_canonical:
		return canonical

	var chance := lerpf(EXOTIC_CHANCE_BASE, EXOTIC_CHANCE_MAX, intensity())
	if rng.randf() > chance:
		return canonical

	var produces: int = VNode.Res.REFINED
	match kind:
		VNode.Kind.LOOM: produces = VNode.Res.CLOTH
		VNode.Kind.KILN: produces = VNode.Res.PRISM
	var pool: Array[int] = []
	for res in _unlocked_res:
		if res != produces and res != VNode.Res.VOID:
			pool.append(res)
	if pool.is_empty():
		return canonical

	var out: Array[int] = []
	var slots := 2 + (1 if rng.randf() < 0.3 else 0)
	for _i in slots:
		out.append(pool[rng.randi() % pool.size()])
	out.sort()
	return out


func _random_node_of_kind(kind: int) -> VNode:
	var matches: Array[VNode] = []
	for n in nodes:
		if n.kind == kind:
			matches.append(n)
	return matches[rng.randi() % matches.size()] if not matches.is_empty() else null


func _count_kind(kind: int) -> int:
	var c := 0
	for n in nodes:
		if n.kind == kind:
			c += 1
	return c


## Live, non-corrupted nodes of a kind. The tool caps count this so a necrotic
## tool waiting to collapse doesn't hold its own replacement out — the board
## should always be working back toward a full spread of every shape, ready for
## whatever the Heart demands next.
func _count_healthy_kind(kind: int) -> int:
	var c := 0
	for n in nodes:
		if n.kind == kind and not n.corrupted:
			c += 1
	return c


## Guaranteed fallback placement when the normal rejection search found
## nowhere valid: whichever of a fixed ring of bearings around `center` is
## farthest from every existing node, so the node always gets SOMEWHERE on
## the board rather than silently not spawning at all. Candidates are clamped
## into the playfield margins before scoring — clamping only ever pulls a
## point INWARD toward the anchor, so it can never push one out of reach.
func _least_crowded_spot(center: Vector2, dist: float) -> Vector2:
	var vp := design_size()
	var best := center + Vector2(dist, 0.0)
	var best_near := -INF
	for i in 24:
		var a := TAU * float(i) / 24.0
		var p := center + Vector2(cos(a), sin(a)) * dist
		p.x = clampf(p.x, 56.0, vp.x - 56.0)
		p.y = clampf(p.y, 70.0, vp.y - 70.0)
		var near := INF
		for n in nodes:
			near = minf(near, p.distance_to(n.position))
		if near > best_near:
			best_near = near
			best = p
	return best


# --- The no-move guarantee ---------------------------------------------------
#
# The one unrecoverable state VEIN must never produce: the Heart is starving
# and there is nothing on the board the player could possibly do about it.
# Spawn anchoring (see _spawn_node) makes every new node reachable AND useful
# at the moment it appears, but reachability decays as the run chews the board
# up — Wells deplete, corrupt, wither; the network gets amputated — so the
# guarantee also needs a live check, not just careful placement.

## How long the board may sit with no claimable fresh supply before a rescue
## Well is forced in. Non-zero so a transient gap (the half-second between
## cutting a rotten limb and wiring its replacement) doesn't trigger it, but
## short enough that the rescue lands with several missed feedings still in
## hand (MISSES_FATAL) — the player should experience "supply is scarce",
## never "supply is impossible".
const RESCUE_DEBOUNCE := 1.5

var _no_move_time := 0.0
## Rescue Wells forced in this run — the probe reads it: a handful per run is
## the guarantee working; dozens means normal spawning itself is starving the
## board and needs retuning.
var rescues := 0


## True while at least one healthy Well with reserve left can still be wired
## into the live network — already on it, or within one vein of a connected
## node that would actually accept RAW (Heart, healthy Well, Forge; a Loom or
## a rotten node in reach is not a move, it just looks like one).
func _has_reachable_supply() -> bool:
	for n in nodes:
		if n.kind != VNode.Kind.WELL or n.corrupted or n.reserve <= 0.0:
			continue
		if n.depth >= 0:
			return true
		for m in nodes:
			if m.depth < 0 or m.corrupted or not in_reach(n, m):
				continue
			if m.kind == VNode.Kind.HEART or m.kind == VNode.Kind.WELL \
					or (m.kind == VNode.Kind.FORGE and m.recipe.has(VNode.Res.RAW)):
				return true
	return false


func _ensure_move(delta: float) -> void:
	if _has_reachable_supply():
		_no_move_time = 0.0
		return
	_no_move_time += delta
	if _no_move_time < RESCUE_DEBOUNCE:
		return
	_no_move_time = 0.0
	rescues += 1
	_spawn_rescue_well()


## Where a rescue Well must appear to be answerable: near the entry point of
## the chain the CURRENT demand needs. For RAW that's the Heart itself; for
## every refined tier the chain enters through a Forge (RAW is the only thing
## a Well makes), so it lands by the Forge best placed for the rest of the
## chain — nearest a Loom when the demand needs one, nearest the Heart
## otherwise. Every link downstream of that Forge is already guaranteed by
## tool anchoring (see _spawn_node).
func _rescue_anchor() -> Vector2:
	if demand == VNode.Res.RAW:
		return heart.position
	var goal := heart.position
	if demand == VNode.Res.CLOTH or demand == VNode.Res.PRISM:
		var loom := _nearest_node_of_kind(VNode.Kind.LOOM, heart.position)
		if loom != null:
			goal = loom.position
	# Only a RAW-eating Forge is a chain entry a fresh Well can actually
	# feed — an exotic one that wants squares is no rescue at all.
	var forge: VNode = null
	var best_d := INF
	for n in nodes:
		if n.kind != VNode.Kind.FORGE or n.corrupted or not n.recipe.has(VNode.Res.RAW):
			continue
		var d := n.position.distance_to(goal)
		if d < best_d:
			best_d = d
			forge = n
	return forge.position if forge != null else heart.position


func _nearest_node_of_kind(kind: int, to: Vector2) -> VNode:
	var best: VNode = null
	var best_d := INF
	for n in nodes:
		if n.kind != kind or n.corrupted:
			continue
		var d := n.position.distance_to(to)
		if d < best_d:
			best_d = d
			best = n
	return best


## Forces a fresh Well within one vein of _rescue_anchor(). Ignores
## MAX_LIVE_WELLS — when this fires the board has zero usable supply, and
## survival outranks board hygiene. Same elbow-room sampling as _spawn_node,
## same guaranteed _least_crowded_spot fallback, so this can never itself
## fail to place.
func _spawn_rescue_well() -> void:
	var vp := design_size()
	var center := _rescue_anchor()
	var best := Vector2.ZERO
	var best_score := -INF
	for _i in 64:
		var bearing := rng.randf() * TAU
		var dist := rng.randf_range(112.0, Vein.MAX_LEN * 0.85)
		var p := center + Vector2(cos(bearing), sin(bearing)) * dist
		if p.x < 56.0 or p.x > vp.x - 56.0 or p.y < 70.0 or p.y > vp.y - 70.0:
			continue
		if p.distance_to(heart.position) < MIN_HEART_CLEARANCE:
			continue
		var near := INF
		for n in nodes:
			near = minf(near, p.distance_to(n.position))
		if near < 104.0:
			continue
		if near > best_score:
			best_score = near
			best = p
	if best_score == -INF:
		best = _least_crowded_spot(center, Vein.MAX_LEN * 0.6)
	_make_node(VNode.Kind.WELL, best)
	_rebuild_graph()


# --- The chain-integrity guarantee -------------------------------------------
#
# _has_reachable_supply/_spawn_rescue_well above guarantee RAW is always
# reachable, but they predate tools being able to DIE (see VNode's per-smelt
# depletion). Once a Forge/Loom/Kiln can corrupt from use, two new
# unrecoverable states become possible that the RAW-only guarantee doesn't
# cover: every canonical instance of a tier's tool dies at once (the tier
# becomes unbuildable, full stop — no Well hookup fixes it), or one survives
# but the specific node that fed it just corrupted and nothing else has ever
# spawned close enough to replace it (the tool exists but is permanently
# stranded). Either one is exactly "the Heart wants X and there is nothing you
# can do about it" for that tier — this section closes both, for every tier
# the run has ever unlocked, not just the one currently demanded, since
# rotation can bring any of them back at any time.

## Debounce for the checks below. Tighter than RESCUE_DEBOUNCE: a broken tier
## link is a harder stop than "supply is scarce" (nothing you build reaches the
## Heart as the right shape until it resolves), so it gets caught sooner.
const CHAIN_STALL_DEBOUNCE := 2.0

var _chain_stall := {}   # String key -> accumulated stall seconds, per check.
## Rescue tools/feeders forced in by the checks below, this run. Like
## `rescues`, a handful is the guarantee working; a flood means a tier is
## structurally too fragile and needs retuning (MAX_LIVE_* caps, yield, gaps).
var chain_rescues := 0


## Live, non-corrupted instances of `kind` running the CANONICAL recipe (the
## plain "two of the tier below," not an exotic mix). The classic
## Well->Forge->Loom->Kiln chain must stay completable through at least one
## canonical instance of every unlocked tier — exotic siblings are flavour,
## never the only way through.
func _count_canonical_healthy(kind: int) -> int:
	if not CANONICAL_RECIPE.has(kind):
		return 0
	var canonical: Array[int] = []
	canonical.assign(CANONICAL_RECIPE[kind])
	var c := 0
	for n in nodes:
		if n.kind == kind and not n.corrupted and n.recipe == canonical:
			c += 1
	return c


## True if at least one live, non-corrupted `kind` node has a live,
## non-corrupted `feeder_kind` node within reach (a Well must also have
## reserve left). This is the "is the link actually USABLE" check, distinct
## from merely existing: a Loom can sit on the board forever while the one
## Forge that used to feed it is long gone and nothing new ever spawned close
## enough — it looks like progress but is dead weight.
func _any_kind_fed(kind: int, feeder_kind: int) -> bool:
	for n in nodes:
		if n.kind != kind or n.corrupted:
			continue
		for m in nodes:
			if m.kind != feeder_kind or m.corrupted:
				continue
			if feeder_kind == VNode.Kind.WELL and m.reserve <= 0.0:
				continue
			if in_reach(n, m):
				return true
	return false


## The best live, non-corrupted `kind` node to rescue-feed: nearest the Heart,
## since that is the one most likely already load-bearing in the player's build.
func _pick_stranded(kind: int) -> VNode:
	var best: VNode = null
	var best_d := INF
	for n in nodes:
		if n.kind != kind or n.corrupted:
			continue
		var d := n.position.distance_to(heart.position)
		if d < best_d:
			best_d = d
			best = n
	return best


## Ensures at least one CANONICAL `kind` stays alive once `unlock_res` has ever
## been demanded. Spawns through the normal _spawn_node path, which already
## rolls canonical automatically when none of that kind survive (see
## _roll_recipe) — this just ignores the live-count cap, because a fully dead
## tier is worse than one extra tool on the board.
func _ensure_canonical_alive(kind: int, unlock_res: int, delta: float) -> void:
	if not _unlocked_res.has(unlock_res):
		return
	var key := "canon_%d" % kind
	if _count_canonical_healthy(kind) > 0:
		_chain_stall[key] = 0.0
		return
	_chain_stall[key] = _chain_stall.get(key, 0.0) + delta
	if _chain_stall[key] < CHAIN_STALL_DEBOUNCE:
		return
	_chain_stall[key] = 0.0
	chain_rescues += 1
	_spawn_node(kind)


## Ensures a live `kind` has a USABLE `feeder_kind` in reach once `unlock_res`
## has ever been demanded — the tool existing is not enough if the one thing
## that fed it is gone (see _any_kind_fed).
func _ensure_chain_link(kind: int, feeder_kind: int, unlock_res: int, delta: float) -> void:
	if not _unlocked_res.has(unlock_res):
		return
	var key := "link_%d" % kind
	var live := _count_healthy_kind(kind) > 0
	if not live or _any_kind_fed(kind, feeder_kind):
		_chain_stall[key] = 0.0
		return
	_chain_stall[key] = _chain_stall.get(key, 0.0) + delta
	if _chain_stall[key] < CHAIN_STALL_DEBOUNCE:
		return
	_chain_stall[key] = 0.0
	chain_rescues += 1
	var target := _pick_stranded(kind)
	if target != null:
		_spawn_rescue_feeder(feeder_kind, target)


func _tick_tool_chain(delta: float) -> void:
	_ensure_canonical_alive(VNode.Kind.FORGE, VNode.Res.REFINED, delta)
	_ensure_canonical_alive(VNode.Kind.LOOM, VNode.Res.CLOTH, delta)
	_ensure_canonical_alive(VNode.Kind.KILN, VNode.Res.PRISM, delta)
	_ensure_chain_link(VNode.Kind.FORGE, VNode.Kind.WELL, VNode.Res.REFINED, delta)
	_ensure_chain_link(VNode.Kind.LOOM, VNode.Kind.FORGE, VNode.Res.CLOTH, delta)
	_ensure_chain_link(VNode.Kind.KILN, VNode.Kind.LOOM, VNode.Res.PRISM, delta)


## Emergency placement for a feeder a live, stranded `target` needs RIGHT NOW.
## A Well just needs to land within reach of `target`; a rescue tool (a Forge
## for a stranded Loom, a Loom for a stranded Kiln) also needs its OWN feeder
## in reach — the same dual-anchor rule _spawn_node uses, just anchored to
## `target` instead of the Heart, since here the Heart isn't the broken link.
func _spawn_rescue_feeder(feeder_kind: int, target: VNode) -> void:
	if feeder_kind == VNode.Kind.WELL:
		_spawn_rescue_well_near(target.position)
		return

	var vp := design_size()
	var sub_feeder: VNode = null
	match feeder_kind:
		VNode.Kind.FORGE:
			sub_feeder = _nearest_node_of_kind(VNode.Kind.WELL, target.position)
		VNode.Kind.LOOM:
			sub_feeder = _nearest_node_of_kind(VNode.Kind.FORGE, target.position)

	var anchor := target.position
	var min_dist := 60.0
	var max_dist := Vein.MAX_LEN * 0.85
	if sub_feeder != null and target.position.distance_to(sub_feeder.position) <= Vein.MAX_LEN * 1.9:
		anchor = (target.position + sub_feeder.position) * 0.5
		var half := target.position.distance_to(sub_feeder.position) * 0.5
		max_dist = clampf(Vein.MAX_LEN - half - 14.0, 24.0, 135.0)
		min_dist = minf(48.0, max_dist * 0.6)
	else:
		sub_feeder = null

	var best := Vector2.ZERO
	var best_score := -INF
	for _i in 64:
		var bearing := rng.randf() * TAU
		var dist := rng.randf_range(min_dist, max_dist)
		var p := anchor + Vector2(cos(bearing), sin(bearing)) * dist
		if p.x < 56.0 or p.x > vp.x - 56.0 or p.y < 70.0 or p.y > vp.y - 70.0:
			continue
		if p.distance_to(target.position) > Vein.MAX_LEN:
			continue
		if sub_feeder != null and p.distance_to(sub_feeder.position) > Vein.MAX_LEN:
			continue
		if p.distance_to(heart.position) < MIN_HEART_CLEARANCE:
			continue
		var near := INF
		for n in nodes:
			near = minf(near, p.distance_to(n.position))
		if near < 104.0:
			continue
		if near > best_score:
			best_score = near
			best = p
	if best_score == -INF:
		best = _least_crowded_spot(anchor, minf(max_dist, 60.0))

	var n := _make_node(feeder_kind, best)
	var canonical: Array[int] = []
	canonical.assign(CANONICAL_RECIPE[feeder_kind])
	n.recipe = canonical
	if feeder_kind == VNode.Kind.FORGE and not seen_forge:
		seen_forge = true
		n.teach = true
		_store_save()
	elif feeder_kind == VNode.Kind.LOOM and not seen_loom:
		seen_loom = true
		n.teach = true
		_store_save()
	_rebuild_graph()


## Well-flavoured half of _spawn_rescue_feeder: lands a fresh Well within reach
## of `near`, same elbow-room sampling and guaranteed fallback as
## _spawn_rescue_well, just anchored to a specific stranded tool instead of
## _rescue_anchor()'s single current-demand guess.
func _spawn_rescue_well_near(near: Vector2) -> void:
	var vp := design_size()
	var best := Vector2.ZERO
	var best_score := -INF
	for _i in 64:
		var bearing := rng.randf() * TAU
		var dist := rng.randf_range(70.0, Vein.MAX_LEN * 0.85)
		var p := near + Vector2(cos(bearing), sin(bearing)) * dist
		if p.x < 56.0 or p.x > vp.x - 56.0 or p.y < 70.0 or p.y > vp.y - 70.0:
			continue
		if p.distance_to(heart.position) < MIN_HEART_CLEARANCE:
			continue
		var nd := INF
		for n in nodes:
			nd = minf(nd, p.distance_to(n.position))
		if nd < 104.0:
			continue
		if nd > best_score:
			best_score = nd
			best = p
	if best_score == -INF:
		best = _least_crowded_spot(near, Vein.MAX_LEN * 0.6)
	_make_node(VNode.Kind.WELL, best)
	_rebuild_graph()


# --- The throughput guarantee -------------------------------------------------
#
# The two guarantees above answer "does a path exist" (_has_reachable_supply)
# and "is that path's tool actually fed" (_any_kind_fed) — both are pass/fail,
# neither asks how FAST. A Forge with exactly one starved-looking Well in
# reach is a technical yes on both, but if the Heart burns through a
# triangle's worth of fuel every few seconds and that Well can only make one
# circle every WELL_PERIOD, the "move" the other guarantees promised isn't
# actually one — the board just looks solvable. This section is the rate
# check: the CURRENT demand's best buildable lineage must be able to sustain
# at least the Heart's current burn rate, with margin, same debounce+rescue
# shape as the two guarantees above.

## Every hop's throughput ceiling, independent of length — see
## Vein.DOT_SPACING. A vein's cap doesn't care whether it's short or stretched
## to Vein.MAX_LEN; only the gap between items does.
const EDGE_RATE := Vein.SPEED / Vein.DOT_SPACING

## Fraction of bare-survival rate the achievable rate must clear before this
## check is satisfied. NOT "stay fully fed forever" — that's explicitly not
## the promise (see VEIN.md: "difficulty escalates until the topology problem
## becomes unsolvable... collapse is the content"). A probe run with every
## other guarantee healthy still dies right around EXERTION_SPAN on appetite
## alone; a margin tuned to full sustainability would have this guarantee
## fight that intended ending, forcing rescue Wells in every few seconds
## through the entire back half of every run. What it must never allow is a
## reachable, fed lineage reduced to a functional trickle — the SPECIFIC
## complaint this guarantee exists for ("circles are rare around it so flow
## can't keep the heart alive" even though a path exists and is fed). Wide
## (near-full sustain) while still walking the teaching schedule, so a first
## board never has to feel that trickle at all; falls to a low floor once the
## run is at full intensity, on the same _hardcore_ramp() lever
## TEACHING_PRESSURE_MULT/TEACHING_APPETITE_MULT already use — losing ground
## late is intended, going to literally nothing is not.
const THROUGHPUT_MARGIN_TEACHING := 1.0
## Was 0.3 — raised alongside this pass's broader generosity push (EXERTION_
## SPAN, HARDCORE_RAMP_TIME, FUEL_CAP). The late game staying genuinely
## losable is still the intent; 0.45 just means "losing ground" doesn't start
## from as thin a trickle as 0.3 allowed.
const THROUGHPUT_MARGIN_HARDCORE := 0.45

## Longer than RESCUE_DEBOUNCE/CHAIN_STALL_DEBOUNCE on purpose: appetite rides
## a sine wave (see APPETITE_WAVE_PERIOD, 17s) that alone walks needed_rate
## up and down, so a lean-but-working single-chain board can drift under
## margin for a few seconds every wave cycle without ever being in real
## trouble. A short debounce reacted to that wobble, not a genuine shortfall.
const THROUGHPUT_DEBOUNCE := 4.0
var _throughput_stall := 0.0
## Rescue Wells forced in by a THROUGHPUT shortfall specifically — a chain
## that exists and is fed, just too thinly to keep up. Distinct from
## `rescues` (nothing reachable at all) and `chain_rescues` (a tier's tool or
## link is dead): a flood here means the RATE side of the tuning (yields,
## EDGE_RATE, well density near a tier's entry point) needs work even though
## both existence guarantees read healthy.
var throughput_rescues := 0


## Items/sec of `demand` the Heart needs right now to hold fuel steady,
## reading combo as zero — combo only ever helps, it must never be load-
## bearing for the guarantee itself.
func _needed_rate() -> float:
	var interval := Beat.interval()
	if interval <= 0.0 or interval == INF:
		return 0.0
	var gain: float = FUEL_BY_RES.get(demand, 1.0)
	return appetite() / interval / gain


## RAW is the one tier with no tool of its own — the Heart eats it directly.
## Reachability here mirrors _has_reachable_supply's accept-list (a healthy
## Well or a RAW-eating Forge; a Loom in reach is not a move, it just looks
## like one) but walks it out through every hop instead of stopping at one —
## Vein.MAX_LEN's own doc comment is explicit that a spread-out RAW network is
## expected to chain distant Wells through nearer ones on the way to the
## Heart, so a well three relays out still counts.
func _raw_reachable_wells() -> Array[VNode]:
	var out: Array[VNode] = []
	var visited := {heart: true}
	var frontier: Array[VNode] = [heart]
	while not frontier.is_empty():
		var cur: VNode = frontier.pop_back()
		for m in nodes:
			if visited.has(m) or m.corrupted or not in_reach(cur, m):
				continue
			var relay := m.kind == VNode.Kind.WELL \
					or (m.kind == VNode.Kind.FORGE and m.recipe.has(VNode.Res.RAW))
			if not relay:
				continue
			visited[m] = true
			frontier.append(m)
			if m.kind == VNode.Kind.WELL and m.reserve > 0.0:
				out.append(m)
	return out


## Best steady-state items/sec of `demand` a BUILDABLE lineage could sustain
## right now — buildable, not built, same philosophy as
## _has_reachable_supply/_any_kind_fed above: this is "could the player make
## this work", not "have they already".
func _achievable_rate() -> float:
	if demand == VNode.Res.RAW:
		return _raw_reachable_wells().size() * (1.0 / VNode.WELL_PERIOD)
	var kind := VNode.Kind.FORGE
	match demand:
		VNode.Res.CLOTH: kind = VNode.Kind.LOOM
		VNode.Res.PRISM: kind = VNode.Kind.KILN
	var best := 0.0
	for n in nodes:
		if n.kind != kind or n.corrupted or not in_reach(n, heart):
			continue
		best = maxf(best, _node_rate(n, {}))
	return best


## Recursive bottleneck: a tool's output rate is capped by the slowest of its
## own recipe needs, where each need's rate is everything live and in reach
## that makes it, summed, divided by how many of it the recipe actually wants
## (a canonical [RAW, RAW] wants 2 total, from any mix of Wells — not two
## separately-tracked slots). `seen` guards the cycle an exotic recipe can
## create once every tier is unlocked (a Loom that wants PRISM, fed by a Kiln
## that wants CLOTH, fed by that same Loom) — without it this recurses
## forever the moment such a pair rolls.
func _node_rate(n: VNode, seen: Dictionary) -> float:
	if n == null or n.corrupted or seen.has(n):
		return 0.0
	seen = seen.duplicate()
	seen[n] = true
	if n.kind == VNode.Kind.WELL:
		return 1.0 / VNode.WELL_PERIOD if n.reserve > 0.0 else 0.0
	if n.recipe.is_empty():
		return 0.0
	var needed := {}
	for r in n.recipe:
		needed[r] = needed.get(r, 0) + 1
	var worst := INF
	for res_kind in needed:
		var incoming := 0.0
		for m in nodes:
			if m == n or m.corrupted or m.produces != res_kind or not in_reach(n, m):
				continue
			incoming += minf(_node_rate(m, seen), EDGE_RATE)
		worst = minf(worst, incoming / float(needed[res_kind]))
	return minf(worst, EDGE_RATE)


func _ensure_throughput(delta: float) -> void:
	var needed := _needed_rate()
	if needed <= 0.0:
		_throughput_stall = 0.0
		return
	var margin := lerpf(THROUGHPUT_MARGIN_TEACHING, THROUGHPUT_MARGIN_HARDCORE, _hardcore_ramp())
	var have := _achievable_rate()
	if have >= needed * margin:
		_throughput_stall = 0.0
		return
	_throughput_stall += delta
	if _throughput_stall < THROUGHPUT_DEBOUNCE:
		return
	_throughput_stall = 0.0
	throughput_rescues += 1
	_spawn_rescue_well()


# --- Graph: everything flows downhill toward demand -------------------------

func _rebuild_graph() -> void:
	for n in nodes:
		n.depth = -1
		n.feed_depth = -1
	if heart == null:
		return
	heart.depth = 0
	var q: Array[VNode] = [heart]
	while not q.is_empty():
		var cur: VNode = q.pop_front()
		for v in veins:
			var o := v.other(cur)
			if o != null and o.depth < 0:
				o.depth = cur.depth + 1
				q.append(o)

	# Secondary orientation for everything the Heart can't reach: a
	# multi-source BFS out from the Wells (and corrupted Wells, which push
	# VOID) still stranded at depth < 0. This is what makes a circle->triangle
	# with no onward path actually FLOW and pool at the triangle, instead of
	# sitting inert. A node's feed_depth is its hop-distance from the nearest
	# such Well; veins between two disconnected nodes orient low->high, i.e.
	# away from the Well toward the dead-end (see Vein.update_dir).
	var fq: Array[VNode] = []
	for n in nodes:
		if n.depth < 0 and (n.kind == VNode.Kind.WELL or n.corrupted):
			n.feed_depth = 0
			fq.append(n)
	while not fq.is_empty():
		var cur: VNode = fq.pop_front()
		for v in veins:
			var o := v.other(cur)
			if o != null and o.depth < 0 and o.feed_depth < 0:
				o.feed_depth = cur.feed_depth + 1
				fq.append(o)

	for v in veins:
		v.update_dir()
	budget_hint.queue_redraw()


func veins_used() -> int:
	return veins.size()


func can_afford() -> bool:
	return veins_used() < budget


func _find_vein(a: VNode, b: VNode) -> Vein:
	for v in veins:
		if (v.a == a and v.b == b) or (v.a == b and v.b == a):
			return v
	return null


## Can these two ever be joined directly? Reach is the constraint the whole
## puzzle rests on — see Vein.MAX_LEN. One radius for every pair, no
## exceptions — a tool<->Heart pair used to reach farther (the since-removed
## TOOL_HEART_REACH); that bonus is now just baked into Vein.MAX_LEN itself,
## so every pair gets it.
func in_reach(a: VNode, b: VNode) -> bool:
	return a.position.distance_to(b.position) <= Vein.MAX_LEN


func _add_vein(a: VNode, b: VNode) -> void:
	if a == b or _find_vein(a, b) != null or not in_reach(a, b):
		return

	# Crossing BLOCKS the connection — it does not destroy the crossed vein.
	#
	# Playtest: "when the heart changes to square and I connect square to it, I
	# die." Root cause: the Heart is where the most veins converge, so the
	# rescue connection you most need to complete is also the one geometrically
	# likeliest to cross something. The old behaviour silently failed to create
	# the new vein AND bled fuel AND ruptured a different, unrelated vein — from
	# the player's side the drag visually snapped, nothing looked wrong, and the
	# game had actually destroyed a load-bearing connection and cost fuel while
	# never delivering the CLOTH that would have saved them. Spaghetti-avoidance
	# is still a real constraint (the drag preview still warns in red and the
	# connection is refused), it just no longer punishes you for a geometry
	# mistake with more than "try a different angle."
	if _crossing_vein(a, b) != null:
		return

	if not can_afford():
		return

	var synced := _tempo_action()
	var v: Vein = VeinScene.new()
	# Alternate the bend so parallel veins fan out instead of overlapping.
	v.setup(a, b, 1.0 if veins.size() % 2 == 0 else -1.0)
	v.tempo_grade = combo if synced else -1
	v.ruptured.connect(_on_ruptured)
	vein_layer.add_child(v)
	veins.append(v)
	# Flash the line inventory on every spend so a first-timer sees the budget
	# tick down — the just-spent slot is the highest lit one.
	budget_hint.flash(veins.size() - 1)
	_rebuild_graph()


func _tempo_action() -> bool:
	var q := _tempo_quality()
	if q <= GOOD_WINDOW:
		combo = mini(combo + (2 if q <= PERFECT_WINDOW else 1), COMBO_CAP)
		_sync_flash = 1.0
		var gain := SYNC_FUEL * (1.0 + float(combo) * 0.08)
		fuel = clampf(fuel + gain, 0.0, fuel_cap())
		Audio.sync_hit(combo, q <= PERFECT_WINDOW)
		if OS.has_feature("mobile"):
			Input.vibrate_handheld(30 + combo * 6)
		return true

	# Off-beat costs you the COMBO and nothing else — no fuel, no hurt sound.
	#
	# It used to bleed OFFBEAT_BLEED fuel and play the "corrupt" (hurt) cue on
	# every edit. Two problems, both reported: it taxed the rescue connection at
	# the exact moment you could least afford it (see WRONG_SHAPE_FUEL for the
	# audit), and it fired the hurt sound when you were merely wiring two
	# ISOLATED nodes together to prepare a Forge — nowhere near the Heart, and
	# hurting nothing. The hurt cue now belongs exclusively to the Heart taking
	# damage (see _deliver). Rhythm is a carrot: play on the beat and you get
	# fuel and a rising combo; miss and you simply don't. Building is never
	# punished, so a vein is always safe to draw.
	combo = 0
	_bad_tempo_flash = 1.0
	return false


func _tempo_quality() -> float:
	return minf(Beat.phase, 1.0 - Beat.phase)


## Shared teardown for a node leaving the board outside of the normal
## rupture/cut paths — withered Wells, collapsed rot. Always drops any vein
## still attached (a withered/collapsed node is by definition orphaned or
## about to be cut).
func _remove_node(n: VNode) -> void:
	for v in veins.duplicate():
		if v.a == n or v.b == n:
			_remove_vein(v)
	nodes.erase(n)
	n.queue_free()
	if heart == n:
		heart = null
	_rebuild_graph()


## A trunk carried more than it could bear. The dots in flight scatter and die,
## the vein is destroyed, and the budget point comes back — so a rupture is a
## loss of throughput and position, never of resources you can't rebuild.
func _on_ruptured(v: Vein) -> void:
	ruptures += 1
	var pts: Array[Vector2] = []
	var kinds: Array[int] = []
	for d in v.dots:
		pts.append(v.sample(d.t))
		kinds.append(d.kind)

	if not pts.is_empty():
		var burst: Node2D = BurstScene.new()
		vein_layer.add_child(burst)
		burst.spawn(pts, kinds, rng.randi(), Color(0, 0, 0, 0), intensity())

	Audio.play("rupture", -3.0, randf_range(0.9, 1.1))
	if OS.has_feature("mobile"):
		Input.vibrate_handheld(180)

	_remove_vein(v)


func _remove_vein(v: Vein, surgical := false) -> void:
	var synced := true
	if surgical:
		synced = _tempo_action()
	if surgical and not (v.a.corrupted or v.b.corrupted) and not v.dots.is_empty():
		# Only spilling something the Heart actually WANTS costs you. Cutting a
		# vein full of wrong-shape cargo is free, because that cargo was already
		# worth nothing — charging for it taxed exactly the re-plumbing a demand
		# flip forces you into, on top of the flip itself.
		var precious := 0
		for d in v.dots:
			if d.kind == demand:
				precious += 1
		var bleed := float(precious) * CUT_BLEED_BY_DOT
		if synced:
			bleed *= 0.25
		fuel = maxf(0.0, fuel - bleed)
		var pts: Array[Vector2] = []
		var kinds: Array[int] = []
		for d in v.dots:
			pts.append(v.sample(d.t))
			kinds.append(d.kind)
		var burst: Node2D = BurstScene.new()
		vein_layer.add_child(burst)
		burst.spawn(pts, kinds, rng.randi(), Color(0, 0, 0, 0), intensity())
		Audio.play("rupture", -8.0, 0.75)
	veins.erase(v)
	# Flash the line inventory on a refund too — a cut hands a slot back, and
	# seeing it light up teaches that veins are finite and reclaimable.
	budget_hint.flash(veins.size())
	# die() lets the vein shrink-and-fade in place (see vein.gd) instead of
	# blinking out — the removal itself needs to be visible even when there
	# was nothing precious in flight to burst, which is the common case for a
	# vein you'd actually choose to cut.
	v.die()
	_rebuild_graph()


func _crossing_vein(a: VNode, b: VNode) -> Vein:
	for v in veins:
		if v.a == a or v.a == b or v.b == a or v.b == b:
			continue
		if _segments_cross(a.position, b.position, v.a.position, v.b.position):
			return v
	return null


func _segments_cross(a0: Vector2, a1: Vector2, b0: Vector2, b1: Vector2) -> bool:
	var r := a1 - a0
	var s := b1 - b0
	var den := r.cross(s)
	if absf(den) < 0.001:
		return false
	var t := (b0 - a0).cross(s) / den
	var u := (b0 - a0).cross(r) / den
	return t > 0.04 and t < 0.96 and u > 0.04 and u < 0.96


# --- Sim --------------------------------------------------------------------

func _process(delta: float) -> void:
	# A frame hitch must not teleport the sim — see Beat.MAX_DELTA.
	delta = minf(delta, Beat.MAX_DELTA)
	_rescue = maxf(0.0, _rescue - delta * 2.2)
	_sync_flash = maxf(0.0, _sync_flash - delta * 3.8)
	_bad_tempo_flash = maxf(0.0, _bad_tempo_flash - delta * 4.4)

	var target_drain := 0.0
	if not alive:
		target_drain = 1.0
	elif Beat.state == Beat.State.DYING:
		target_drain = 0.55
	elif Beat.state == Beat.State.STRAINED:
		target_drain = 0.2
	_drain_amt = Vein._smooth(_drain_amt, target_drain, 1.6, delta)
	drain.material.set_shader_parameter("drain", _drain_amt)
	drain.material.set_shader_parameter("warm", _rescue)

	if _touching and not _moved and not _dilating:
		_touch_time += delta
		if _touch_time >= LONG_PRESS and _drag_from == null:
			_dilating = true
			_pre_dilation_scale = Engine.time_scale
			Engine.time_scale = _pre_dilation_scale * DILATION

	if not alive:
		return

	_tick_escalation(delta)
	_tick_corruption(delta)
	_tick_lifecycle(delta)
	heart.fuel_ratio = fuel / fuel_cap()
	# Same escalation shape as corruption spread/airborne blight/demand
	# rotation: near-zero at the open, ramping to full bite by EXERTION_SPAN,
	# and still climbing past it (see pressure()) — a tool's per-smelt reserve
	# cost is not exempt from "the enemy never stops getting worse."
	var tool_depletion := lerpf(TOOL_DEPLETION_EARLY, 1.0, intensity()) \
		+ maxf(pressure() - 1.0, 0.0) * TOOL_DEPLETION_POST_EXTRA
	for n in nodes:
		if n.kind == VNode.Kind.FORGE or n.kind == VNode.Kind.LOOM or n.kind == VNode.Kind.KILN:
			n.depletion_rate = tool_depletion
	_push_from_nodes()
	for v in veins:
		for item in v.advance(delta):
			_deliver(item.kind, v, v.sink(), item.pot)

	# Driven every frame, not per-beat: a dying run's beats slow way down, and
	# the mix must keep evolving smoothly through that instead of freezing
	# between rare beats. This is the whole fix for "the sound doesn't
	# progress" — it is now a continuous function of the run, not a state
	# machine that jumps between fixed stages.
	Audio.set_intensity(intensity())
	Audio.set_tension(float(combo) / float(COMBO_CAP))
	Audio.set_corruption(_corruption_ratio())

	budget_hint.queue_redraw()
	drag_layer.queue_redraw()
	queue_redraw()


## Fraction of live Wells currently corrupted. Drives the corruption drone —
## the mix should sicken continuously as rot spreads, not just spike once per
## infection event.
func _corruption_ratio() -> float:
	var wells := 0
	var rotted := 0
	for n in nodes:
		if n.kind == VNode.Kind.WELL:
			wells += 1
			if n.corrupted:
				rotted += 1
	return 0.0 if wells == 0 else float(rotted) / float(wells)


func _draw() -> void:
	if heart == null or not alive:
		return

	var centre := heart.position
	var exert := intensity()
	var phase := Beat.phase
	var beat_r := 48.0 + phase * (44.0 + exert * 54.0)

	# The heartbeat pulse — a ring that blooms outward on every beat. This is
	# the whole on-Heart overlay now: the rhythm-target arc, the combo teeth,
	# and the off-beat flash that used to ring the Heart were removed as
	# unreadable clutter (playtest: "a half curve and dashes around the heart
	# I don't understand"). The rhythm bonus still pays out under the hood, it
	# just no longer draws a gauge nobody was reading.
	var ring := Palette.HEART
	ring.a = (1.0 - phase) * (0.22 + exert * 0.22)
	draw_arc(centre, beat_r, 0.0, TAU, 72, ring, 1.5 + exert * 2.0, true)


## Rot spreads down live veins. Leaving a necrotic Well wired in doesn't just
## poison the Heart — it takes the neighbours with it, so the punishment for
## ignoring one dead lifeline is losing that whole limb of your network.
func _tick_corruption(delta: float) -> void:
	# Rot gets meaner as the run does: the vein-borne spread tightens toward
	# SPREAD_TIME_LATE, and past AIRBORNE_AT it can also leap to an unconnected
	# Well with no vein at all — a second, distinct threat (a roaming blight,
	# not a plumbing hazard) that only matters once the run is far enough along
	# that the opening stays learnable.
	var exert := intensity()
	# Past pressure 1.0 the rot keeps tightening toward a hard floor and the
	# blight jumps more often — the enemy never stops getting worse, same
	# rule as the demand rotation (see pressure()).
	var spread_time := lerpf(VNode.SPREAD_TIME, SPREAD_TIME_LATE, exert)
	spread_time = maxf(SPREAD_TIME_FLOOR, spread_time - maxf(pressure() - 1.0, 0.0) * 0.8)
	var airborne := exert >= AIRBORNE_AT
	var airborne_chance := minf(
		AIRBORNE_CHANCE_MAX, AIRBORNE_CHANCE + maxf(pressure() - 1.0, 0.0) * 0.1)

	var newly: Array[VNode] = []
	for n in nodes:
		if not n.corrupted:
			continue
		n.spread_accum += delta
		if n.spread_accum < spread_time:
			continue
		n.spread_accum = 0.0

		for v in veins:
			var o := v.other(n)
			if o != null and not o.corrupted and o.kind == VNode.Kind.WELL and o not in newly:
				newly.append(o)

		if airborne and rng.randf() < airborne_chance:
			var jumped := _nearest_orphan_well(n.position, AIRBORNE_RADIUS)
			if jumped != null and jumped not in newly:
				newly.append(jumped)

	for n in newly:
		n.corrupt()
		corruptions += 1
		Audio.play("corrupt", -4.0, 0.62)
		if OS.has_feature("mobile"):
			Input.vibrate_handheld(140)


func _nearest_orphan_well(from: Vector2, within: float) -> VNode:
	var best: VNode = null
	var best_d := within
	for n in nodes:
		if n.kind != VNode.Kind.WELL or n.corrupted:
			continue
		var d := from.distance_to(n.position)
		if d < best_d:
			best_d = d
			best = n
	return best


## Wells nobody ever wired in wither away; rot nobody ever cut collapses
## outright. Both remove the node itself (see _remove_node), which is what
## keeps the board turning over instead of only ever accumulating — every
## object that appears either gets used, gets cut, or eventually leaves.
func _tick_lifecycle(_delta: float) -> void:
	for n in nodes.duplicate():
		if not is_instance_valid(n) or n not in nodes:
			continue
		if n.wither_ratio() >= 1.0:
			withered += 1
			_remove_node(n)
		elif n.collapse_ratio() >= 1.0:
			collapsed += 1
			var burst: Node2D = BurstScene.new()
			vein_layer.add_child(burst)
			var pts: Array[Vector2] = [n.position]
			var kinds: Array[int] = [VNode.Res.VOID]
			burst.spawn(pts, kinds, rng.randi(), Color(0, 0, 0, 0), intensity())
			Audio.play("corrupt", -6.0, 0.4)
			_remove_node(n)


## Every node with something buffered tries to hand it downhill.
func _push_from_nodes() -> void:
	for n in nodes:
		if n.kind == VNode.Kind.HEART or n.buffer.is_empty():
			continue
		var outs: Array[Vein] = []
		for v in veins:
			if v.source() == n:
				outs.append(v)
		if outs.is_empty():
			continue

		# Sample the backlog BEFORE pushing: the push below removes an item, so
		# checking afterwards always reads one short of full and never trips.
		var was_full := n.buffer.size() >= VNode.BUFFER_CAP

		# Round-robin so a node with two downhill veins splits between them, but
		# fall through to the others rather than stalling on a full one.
		var placed := false
		var start := n.next_out(outs.size())
		var pot: float = n.poison_pot if n.corrupted else 1.0
		var item: int = n.buffer[0]
		for i in outs.size():
			var v: Vein = outs[(start + i) % outs.size()]
			var sink := v.sink()
			# A sink that would just refuse this item on arrival is treated as
			# blocked, same as one with no physical room left — sending it
			# anyway only burns THIS node's reserve to watch it get discarded
			# as `dropped` at the far end. Holding it here instead lets the
			# backlog build and correctly back-pressure all the way up to
			# whatever is producing it (see VNode.can_accept).
			if sink != null and not sink.can_accept(item):
				v.note_blocked()
				continue
			if v.inject(item, pot):
				n.buffer.remove_at(0)
				n.pulse = 1.0
				placed = true
				break

		# Strain is "this node cannot clear its backlog through these veins", not
		# "nothing moved this frame". A node pushes at most one item per frame but
		# can receive several from its children in the same frame, so it sits
		# permanently full — dropping the excess — while still placing one item
		# every frame. Keying off `placed` alone therefore reported healthy veins
		# right up until the run starved.
		# Only a genuinely full backlog counts as strain. A failed push on its own
		# does not: items must sit DOT_SPACING apart, so every vein refuses on
		# most frames simply waiting for the gap to open, and treating that as
		# blockage ruptured healthy direct links carrying a quarter of capacity.
		if was_full:
			for v in outs:
				v.note_blocked()


func _deliver(kind: int, v: Vein, to: VNode, pot := 1.0) -> void:
	if to == null:
		return
	if to.kind == VNode.Kind.HEART:
		# The very first delivery of the run, of any kind — this is what starts
		# the demand SCHEDULE's own clock (see _demand_clock / _tick_escalation).
		_heart_fed_ever = true
		# Near-miss engineering: a save when the heart is nearly gone must feel
		# enormous.
		if misses >= MISSES_DYING:
			_rescue = 1.0
			if OS.has_feature("mobile"):
				Input.vibrate_handheld(120)
		var gain := float(FUEL_BY_RES.get(kind, 1.0))
		# A spent tool's poison bites harder than a spent circle's (pot > 1).
		if kind == VNode.Res.VOID:
			gain *= pot
		var off_demand := kind != demand and kind != VNode.Res.VOID
		if off_demand:
			# Wrong shape is wasted, not damaging — so no hurt cue and no fuel
			# penalty. It gets a flat, dull "wrong note" via swallow() instead:
			# you hear that it landed and gave you nothing. It still gets a
			# visible (not numeric, not score-costing) alarm below — see
			# _pop_gain — so a stale network reads as something to go fix, not
			# free clutter to ignore.
			gain = WRONG_SHAPE_FUEL
			wasted += 1
			combo = 0
			_bad_tempo_flash = 1.0
		elif kind == demand and kind != VNode.Res.VOID:
			gain *= (1.0 + minf(float(combo), float(COMBO_CAP)) * COMBO_GAIN)
		fuel = clampf(fuel + gain, 0.0, fuel_cap())
		to.pulse = 1.0
		Audio.swallow(kind, fuel / fuel_cap(), kind == demand)
		if kind == VNode.Res.VOID:
			poisoned += 1
			if OS.has_feature("mobile"):
				Input.vibrate_handheld(90)
		var entry := _vein_entry_point(v, to)
		var out_dir := entry - to.position
		out_dir = out_dir.normalized() if out_dir.length() > 0.001 else Vector2.UP
		_pop_gain(kind, gain, entry, out_dir, off_demand)
	elif not to.take(kind):
		dropped += 1


## Where a delivered item visibly crossed into `to` — the point on its rim
## facing back along the vein it just travelled, not the node's centre.
## Every vein converges on the same centre point, so a pop anchored there
## couldn't be read back to the delivery that caused it; anchoring it to the
## vein's own approach direction ties the number to the actual blood that
## just arrived.
func _vein_entry_point(v: Vein, to: VNode) -> Vector2:
	var near := v.sample(0.9)
	var approach := to.position - near
	if approach.length() < 0.001:
		return to.position
	return to.position - approach.normalized() * to.radius()


## The Notcoin/Hamster-Kombat confirmation: a number pops out of the Heart
## and fades, right where the value actually landed, instead of only ever
## showing up as a fuel line that rose too gradually to read as "that
## delivery was worth more than the last one." The score moves by exactly
## what pops — a "+3" here is a +3 there — because the score IS the blood
## the Heart has received, not survival time (see `beats`).
##
## Wrong-shape drops (off_demand) are worth ~0 fuel by design (see
## WRONG_SHAPE_FUEL) — a numeric "+0" would read as a bug, and charging the
## score for them would resurrect the exact failure the WRONG_SHAPE_FUEL
## rewrite fixed (a working network becoming worse than no network). They
## still get a mark instead of total silence: proof that the delivery landed
## and did nothing, so a stale network reads as something to go re-plumb, not
## free clutter to leave connected forever. First pass at this made the mark
## small, dim, and text-only (13px, no burst) — verified the code path fires
## correctly every time, but playtest still reported "I don't see anything":
## right next to the Heart's own busy ring of overlays, a tiny dim glyph
## alone just doesn't win the eye. Sized and colored to match the numeric
## pops now, plus the same little burst every other board event gets, so it
## competes on equal visual footing instead of trying to be quiet about a
## real (if fuel-free) event.
func _pop_gain(kind: int, gain: float, at: Vector2, out_dir: Vector2, off_demand := false) -> void:
	# Jitter across the direction of drift, not against it — a sideways nudge
	# reads as "the same arrival, imprecisely placed"; a nudge along `out_dir`
	# would just look like a longer or shorter drift.
	var jitter := out_dir.rotated(PI * 0.5) * rng.randf_range(-6.0, 6.0)
	if off_demand:
		var warn := Palette.VEIN_STRAINED.lerp(Palette.WARM, 0.4)
		var ring: Array[Vector2] = []
		var kinds: Array[int] = []
		for i in 8:
			var a := TAU * float(i) / 8.0
			ring.append(at + Vector2(cos(a), sin(a)) * 5.0)
			kinds.append(0)
		var burst: Node2D = BurstScene.new()
		vein_layer.add_child(burst)
		burst.spawn(ring, kinds, rng.randi(), warn)

		var mark: Node2D = FloatTextScene.new()
		vein_layer.add_child(mark)
		mark.spawn("!", at + jitter, warn, 20, out_dir)
		return
	if absf(gain) < 0.5:
		return
	# Carried through _score_carry (see its own comment) rather than rounded
	# per-delivery, so the combo bonus's fractional score is never silently
	# discarded on every delivery.
	_score_carry += gain
	var rounded := int(_score_carry)
	_score_carry -= float(rounded)
	if rounded == 0:
		return
	score = maxi(0, score + rounded)
	var col: Color
	var text: String
	if kind == VNode.Res.VOID:
		col = Palette.VOID
		text = "%d" % rounded
	else:
		col = Palette.HEART
		text = "+%d" % rounded
	var pop: Node2D = FloatTextScene.new()
	vein_layer.add_child(pop)
	pop.spawn(text, at + jitter, col, 16, out_dir)


# --- Input: one thumb, one verb ---------------------------------------------

func _node_at(p: Vector2) -> VNode:
	var best: VNode = null
	var best_d := SNAP
	for n in nodes:
		var d := p.distance_to(n.position)
		if d <= maxf(best_d, n.radius()):
			best_d = d
			best = n
	return best


func _vein_at(p: Vector2) -> Vein:
	var best: Vein = null
	var best_d := Vein.HIT_RADIUS
	for v in veins:
		var d := v.distance_to_point(p)
		if d < best_d:
			best_d = d
			best = v
	return best


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventScreenTouch:
		if event.pressed:
			_on_press(event.position)
		else:
			_on_release(event.position)
	elif event is InputEventScreenDrag:
		_on_move(event.position)


func _on_press(p: Vector2) -> void:
	if not alive:
		start_run(0)
		return
	_touching = true
	_touch_time = 0.0
	_moved = false
	_touch_start = p
	_drag_pos = p
	# Don't commit to "start a new vein from this node" yet. Near the Heart,
	# every vein converges inside its own 48px SNAP radius — that radius
	# exists to make DRAGGING forgiving, but it used to also swallow a
	# stationary tap aimed at cutting one of those veins (18px HIT_RADIUS,
	# much tighter) before the vein hit-test ever got a look, so the tap
	# silently no-opped via _add_vein(heart, heart). Recording both
	# candidates and deciding at release/move time (see below) fixes that
	# without changing how an actual drag behaves.
	_press_node = _node_at(p)
	_press_vein = _vein_at(p)
	_drag_from = null


func _on_move(p: Vector2) -> void:
	_drag_pos = p
	if not _moved and p.distance_to(_touch_start) > DRAG_SLOP:
		_moved = true
		# The gesture just became a real drag: commit to "new connection from
		# the pressed node" even if a vein also happened to be under the
		# initial touch point — near the Heart that's the common case, not
		# an edge case, since veins fan out from point-blank range.
		_drag_from = _press_node


func _on_release(p: Vector2) -> void:
	_touching = false
	if _dilating:
		_end_dilation()
		_drag_from = null
		return

	if _drag_from != null:
		var to := _node_at(p)
		if to != null and to != _drag_from:
			_add_vein(_drag_from, to)
		_drag_from = null
		return

	if not _moved:
		# A stationary tap: prefer cutting whatever vein was precisely under
		# the thumb over starting a connection from a node that merely
		# caught it in its wider magnetic radius.
		if _press_vein != null:
			_remove_vein(_press_vein, true)


## The provisional vein under the thumb, plus a highlight on whatever it would
## snap to. This is the only affordance the game ever shows.
func _draw_drag() -> void:
	if _drag_from == null or not alive:
		return

	# How far this node can reach. Only shown while dragging — the constraint
	# appears exactly when it is the question being asked, and never otherwise.
	# One ring for every node kind now — no separate outer ring, since there
	# is no longer a second, longer reach for a tool/Heart pair to show.
	var reach := Palette.HEART
	reach.a = 0.10
	drag_layer.draw_arc(_drag_from.position, Vein.MAX_LEN, 0.0, TAU, 64, reach, 1.5, true)

	var to := _node_at(_drag_pos)
	var end := _drag_pos if to == null else to.position
	var stretched := _drag_from.position.distance_to(end) > Vein.MAX_LEN
	var crossing := to != null and to != _drag_from and _crossing_vein(_drag_from, to) != null

	var col := Palette.VEIN_STRAINED if stretched or crossing else Palette.VEIN_LIVE
	col.a = 0.75
	drag_layer.draw_line(_drag_from.position, end, col, 3.0, true)

	if to == null:
		return
	var ok := to != _drag_from and can_afford() and _find_vein(_drag_from, to) == null \
		and in_reach(_drag_from, to) and not crossing
	var ring := Palette.WARM if ok else Palette.VEIN_STRAINED
	ring.a = 0.85
	drag_layer.draw_arc(to.position, to.radius() + 8.0, 0.0, TAU, 28, ring, 2.0, true)
