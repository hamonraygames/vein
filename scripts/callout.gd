extends Node
## Fun, loud, deliberately NOT diegetic milestone reactions — a big on-screen
## text pop plus an optional voice line (see audio.gd's play_voice) for a
## combo streak, a score milestone, a narrow escape, or a new personal best.
## Autoload so any part of game.gd can fire one without threading a
## reference through.
##
## Every category is a POOL, not a single fixed line, and picking WHICH
## category-crossing moments actually fire is itself randomised (see
## FIRE_CHANCE) — a callout that showed the identical line on every single
## threshold, every single run, would read as a slot machine ticking over,
## not a reaction. The point is that it sometimes surprises you.

const CalloutBannerScene := preload("res://scripts/callout_banner.gd")

## `voice` keys are Audio.VOICE keys (scripts/audio.gd) — most of them have
## no real recording yet and just play text-only until someone records one
## (see audio.gd's VOICE comment and assets/CREDITS.md's Voice section).
const POOLS := {
	"combo": {
		"text": ["NICE", "FLOWING", "ON FIRE", "UNSTOPPABLE", "GODLIKE"],
		"voice": ["power_up", "level_up", "godlike"],
		"color": "score",
	},
	"milestone": {
		"text": ["KEEP GOING", "DON'T STOP", "GIVE ME MORE", "FEED IT", "I WANT MORE", "MORE."],
		"voice": ["give_me_more", "dont_stop", "juicy", "delicious"],
		"color": "score",
	},
	"rescue": {
		"text": ["THAT WAS CLOSE", "SAVED", "PHEW", "CHEATED DEATH", "AGAIN?!"],
		"voice": ["phew", "close_one"],
		"color": "warm",
	},
	"best": {
		"text": ["NEW BEST", "RECORD BROKEN", "PERSONAL BEST", "UNFORGETTABLE"],
		"voice": ["new_highscore", "congratulations", "unforgettable"],
		"color": "warm",
	},
}

## A callout firing right on top of the last one reads as noisy rather than
## as a reaction to something that just happened — these are meant to feel
## rare and earned, not constant.
const MIN_GAP := 3.0
## Not every crossed threshold fires (see the file comment) — combo/milestone
## pass through this roll; rescue/best are rare enough on their own that
## gating them further would just make them feel like they should have
## fired and silently didn't (see fire()'s `force` argument).
const FIRE_CHANCE := 0.55

var _rng := RandomNumberGenerator.new()
var _last_at := -INF
var _last_text := {}


func _ready() -> void:
	_rng.randomize()


## `layer` is where the banner gets added (a Node2D already in the tree —
## game.gd's vein_layer for every call site so far) and `at` is where it's
## centered, in that layer's local space. `force` skips the FIRE_CHANCE roll.
func fire(category: String, layer: Node2D, at: Vector2, force := false) -> void:
	if not POOLS.has(category) or layer == null:
		return
	var now := Time.get_ticks_msec() * 0.001
	if now - _last_at < MIN_GAP:
		return
	if not force and _rng.randf() > FIRE_CHANCE:
		return
	_last_at = now

	var pool: Dictionary = POOLS[category]
	var text: String = _pick(category, pool["text"])
	var col: Color = Palette.WARM if pool.get("color", "") == "warm" else Palette.SCORE

	var banner: Node2D = CalloutBannerScene.new()
	layer.add_child(banner)
	banner.spawn(text, at, col)

	var voices: Array = pool.get("voice", [])
	if not voices.is_empty():
		Audio.play_voice(voices[_rng.randi() % voices.size()])


## Rerolls once on an immediate repeat rather than tracking full history —
## each pool is small enough that one reroll all but rules out showing the
## same line twice back to back.
func _pick(category: String, options: Array) -> String:
	if options.size() <= 1:
		return options[0]
	var choice: String = options[_rng.randi() % options.size()]
	if choice == _last_text.get(category, ""):
		choice = options[_rng.randi() % options.size()]
	_last_text[category] = choice
	return choice
