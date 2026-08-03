extends Node
## Fun, loud, deliberately NOT diegetic milestone reactions — a big on-screen
## text pop plus an optional voice line (see audio.gd's play_voice) for a
## combo streak, a score milestone, a narrow escape, or a new personal best.
## Autoload so any part of game.gd can fire one without threading a
## reference through.
##
## Every category is a POOL of PAIRED {text, voice} entries — text and voice
## are picked TOGETHER as one unit, never independently. An earlier version
## kept two separate arrays and rolled each on its own, which could show
## "NICE" while playing a "level up!" clip — text and voice from two
## unrelated categories of feeling. `voice` is "" for an entry with no real
## recording yet (see audio.gd's VOICE comment); Callout never substitutes a
## mismatched clip just to have SOME sound play.
##
## Picking WHETHER a category-crossing moment fires at all is also
## randomised (see FIRE_CHANCE) — a callout on every single threshold, every
## single run, reads as a slot machine ticking over, not a reaction.

const CalloutBannerScene := preload("res://scripts/callout_banner.gd")

const POOLS := {
	"combo": {
		"entries": [
			{"text": "POWER UP", "voice": "power_up"},
			{"text": "ON FIRE", "voice": ""},
			{"text": "UNSTOPPABLE", "voice": ""},
		],
		"color": "score",
	},
	"milestone": {
		"entries": [
			{"text": "LEVEL UP", "voice": "level_up"},
			{"text": "KEEP GOING", "voice": ""},
			{"text": "FEED IT", "voice": ""},
		],
		"color": "score",
	},
	"rescue": {
		"entries": [
			{"text": "THAT WAS CLOSE", "voice": ""},
			{"text": "SAVED", "voice": ""},
			{"text": "PHEW", "voice": ""},
		],
		"color": "warm",
	},
	"best": {
		"entries": [
			{"text": "NEW HIGH SCORE", "voice": "new_highscore"},
		],
		"color": "warm",
	},
}

## A callout firing right on top of the last one reads as noisy rather than
## as a reaction to something that just happened. Widened from the original
## 3.0/0.55 after playtest feedback that it fired far too often — these are
## meant to feel rare and earned, not a running commentary.
const MIN_GAP := 7.0
## Not every crossed threshold fires (see the file comment) — combo/milestone
## pass through this roll; rescue/best are rare enough on their own that
## gating them further would just make them feel like they should have
## fired and silently didn't (see fire()'s `force` argument).
const FIRE_CHANCE := 0.3

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
	var entry: Dictionary = _pick(category, pool["entries"])
	var col: Color = Palette.WARM if pool.get("color", "") == "warm" else Palette.SCORE

	var banner: Node2D = CalloutBannerScene.new()
	layer.add_child(banner)
	banner.spawn(entry["text"], at, col)

	var voice: String = entry.get("voice", "")
	if not voice.is_empty():
		Audio.play_voice(voice)


## Rerolls once on an immediate repeat rather than tracking full history —
## each pool is small enough that one reroll all but rules out showing the
## same entry twice back to back.
func _pick(category: String, options: Array) -> Dictionary:
	if options.size() <= 1:
		return options[0]
	var choice: Dictionary = options[_rng.randi() % options.size()]
	if choice["text"] == _last_text.get(category, ""):
		choice = options[_rng.randi() % options.size()]
	_last_text[category] = choice["text"]
	return choice
