extends Node
## All sound. Autoload, subscribed to Beat like everything else.
##
## Simplified back down after playtest: "let's have a soundtrack but lower the
## volume, it should loop... I don't like the sound change, you're not doing it
## right, use a simple audio, nothing fancy." The previous version tried to
## continuously CROSSFADE three unrelated CC0 tracks against each other by
## volume — different songs, different keys, different tempos, no shared stems.
## That was never going to sound like one coherent thing evolving; it was always
## going to sound like two random songs half-playing over each other. Blending
## independent full mixes is the wrong technique for these assets regardless of
## how the curve is tuned, so the fix is architectural, not a tuning pass.
##
## Now there are exactly two moving parts, both literally what was asked for:
## 1. ONE background track. Loops, quiet, constant — it does not change with
##    the run. It is scenery, not a narrator.
## 2. The HEARTBEAT is the dynamic one. Its tempo already comes from Beat's own
##    BPM curve (BPM_CALM -> BPM_MAXED as exertion rises) — that IS "tempo
##    raises with intensity". On top of that its pitch/weight shift by state,
##    so a dying heart sounds unmistakably wrong before the run ends: this is
##    the "make you nervous, remind you you're dying soon" channel, and it
##    needs no crossfading trickery to work — it is one sound getting faster
##    and heavier, which is the simplest possible way to carry dread.
## Everything else (feed notes, rupture, corrupt, sync hits) is a plain
## one-shot layered on top — "the heart beats, the feeding the heart."
##
## Everything here is real recorded CC0 material (see assets/CREDITS.md).
## Nothing is synthesised — filtered-noise "audio" has been rejected on this
## project before and it is not worth re-litigating.

## An AMBIENT DRONE, not a song. Playtest: "don't like the song itself, there's
## a drum sound I don't like." Every track shipped so far was a composed piece
## with its own percussion and structure, which fights the heartbeat for the
## same job — VEIN already has a rhythm section (the Heart), so the background
## must not have one. A drone has no beat to compete with and nothing to get
## sick of on loop.
const TRACK := "res://assets/audio/ambient_dark.ogg"
## Barely-there. Twice now this has been "still too loud"; scenery should sit
## under the heartbeat, not beside it.
const TRACK_DB := -34.0

const SFX := {
	"beat_slow": "res://assets/audio/heartbeat_slow.wav",
	"beat_fast": "res://assets/audio/heartbeat_fast.wav",
	# Bells, played near their natural pitch. The old feed notes were metal
	# dings pitched DOWN to 0.44-0.68, which is exactly what turns a ring into
	# a dull muffled thump — the "drum sound" in the report was almost
	# certainly this, firing on every delivery. A bell at ~1.0 reads as a
	# chime, which is what feeding should sound like.
	"raw": "res://assets/audio/feed_soft.wav",
	"refined": "res://assets/audio/feed_rich.wav",
	"rupture": "res://assets/audio/rupture.ogg",
	"corrupt": "res://assets/audio/corrupt.ogg",
}

## One-shots are pooled: a busy network fires several notes per beat and
## allocating a player per note would stutter on a mid-range phone.
const VOICES := 12

var intensity := 0.0

var _track: AudioStreamPlayer
var _voices: Array[AudioStreamPlayer] = []
var _next_voice := 0
var _streams := {}
var _ready_ok := false


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS

	for key in SFX:
		var s: AudioStream = load(SFX[key])
		if s == null:
			push_warning("audio: missing %s" % SFX[key])
			continue
		_streams[key] = s

	var st: AudioStream = load(TRACK)
	if st != null:
		_set_loop(st)
		_track = AudioStreamPlayer.new()
		_track.stream = st
		_track.volume_db = TRACK_DB
		_track.bus = "Master"
		add_child(_track)
	else:
		push_warning("audio: missing %s" % TRACK)

	for i in VOICES:
		var v := AudioStreamPlayer.new()
		v.bus = "Master"
		add_child(v)
		_voices.append(v)

	_ready_ok = not _streams.is_empty()
	Beat.beat.connect(_on_beat)


## Godot does not loop mp3/ogg by default, and a track that stops 90 seconds in
## reads as "the audio broke", not as design.
func _set_loop(st: AudioStream) -> void:
	if st is AudioStreamMP3:
		st.loop = true
	elif st is AudioStreamOggVorbis:
		st.loop = true


func start() -> void:
	intensity = 0.0
	if _track != null and not _track.playing:
		_track.play()


func stop_all() -> void:
	if _track != null:
		_track.stop()


## 0..1 from the game's escalation clock. Only used to nudge the heartbeat and
## the note budget — the track itself does not react to this, on purpose.
func set_intensity(v: float) -> void:
	intensity = clampf(v, 0.0, 1.0)


## Kept as a no-op entry point rather than deleted outright: game.gd still
## calls this every frame from live corruption state, and re-wiring every call
## site for a field the mix no longer uses would be churn for its own sake.
func set_corruption(_v: float) -> void:
	pass


## Same as set_corruption — kept so game.gd's per-frame calls don't need
## touching, but tension no longer drives anything in a "simple audio, nothing
## fancy" mix.
func set_tension(_v: float) -> void:
	pass


## The heart is the anchor of the mix and the one thing that must always tell
## you something is wrong without a single visual. Tempo comes from Beat's own
## curve (RATE_BY_STATE + the BPM ramp) — this only supplies the TIMBRE on top:
## a healthy heart tightens as intensity climbs, a dying one drops almost an
## octave and gets heavier. That drop is the whole "nervous, dying soon" cue.
const BEAT_BY_STATE := {
	Beat.State.HEALTHY: {"key": "beat_slow", "db": -1.5, "pitch": 1.0},
	Beat.State.STRAINED: {"key": "beat_fast", "db": -0.5, "pitch": 1.1},
	Beat.State.DYING: {"key": "beat_slow", "db": 0.0, "pitch": 0.66},
	Beat.State.STOPPED: {"key": "beat_slow", "db": 0.0, "pitch": 0.5},
}


func _on_beat(_i: int) -> void:
	var cfg: Dictionary = BEAT_BY_STATE.get(Beat.state, BEAT_BY_STATE[Beat.State.HEALTHY])
	var pitch: float = cfg.pitch
	if Beat.state == Beat.State.HEALTHY:
		pitch = lerpf(1.0, 1.16, intensity)
	play(cfg.key, cfg.db, pitch)
	# Each beat is a fresh, small budget of note voices — a calm heart sounds
	# sparse, a racing one sounds busier, but the range is deliberately small.
	_notes_this_beat = 0
	_notes_budget = 1 + int(round(intensity * 2.0))


## Per-key cooldown. Playtest: "the hit sound won't stop, there's a bug when
## I'm losing." There wasn't a stuck player — "corrupt" is shared by poison
## arrivals, off-beat misses, wrong-shape deliveries, demand flips, and rot
## spreading, and none of those were rate-limited (unlike the notes below,
## which already had a per-beat budget). A death spiral fires several of these
## within the same second and they machine-gunned the same one-shot rapidly
## enough to sound like one continuous stuck noise. A key can now only
## retrigger every MIN_RETRIGGER seconds.
const MIN_RETRIGGER := 0.09
var _last_played := {}


func play(key: String, db: float = -8.0, pitch: float = 1.0) -> void:
	if not _streams.has(key):
		return
	var now := Time.get_ticks_msec() * 0.001
	var last: float = _last_played.get(key, -INF)
	if now - last < MIN_RETRIGGER:
		return
	_last_played[key] = now

	var v := _voices[_next_voice]
	_next_voice = (_next_voice + 1) % _voices.size()
	v.stream = _streams[key]
	v.volume_db = db
	v.pitch_scale = pitch
	v.play()


## The Heart swallowing something — "the feeding the heart" sound.
##
## Playtest, earlier: every arrival used to fire a bright metal ding at full
## volume and machine-gun the mix. Pitched down into a soft thud, quiet, and
## rate-limited per beat so a fat network sounds busy rather than like a stuck
## buzzer. Poison (VOID) is the exception — rare, and meant to alarm you, so it
## keeps its own voice outside the note budget.
var _notes_budget := 1
var _notes_this_beat := 0


## `wanted` false means the Heart took a shape it did not ask for. That is a
## failure, but it is NOT damage — playtest was explicit that the hurt cue must
## mean "the Heart is being hurt" and nothing else. A wrong shape gets a flat,
## dull, detuned note instead: you hear it land and give you nothing.
func swallow(res_kind: int, fullness: float, wanted: bool = true) -> void:
	if res_kind == VNode.Res.VOID:
		play("hurt", -5.0, 1.0)
		return

	if _notes_this_beat >= _notes_budget:
		return
	_notes_this_beat += 1

	if not wanted:
		play("raw", -28.0, 0.62)
		return

	# Near natural pitch — bells, not thuds. Fuller shapes ring lower and
	# richer; a fuller Heart rings slightly brighter. The range is deliberately
	# narrow (0.9-1.25) because dragging a bell far off its recorded pitch is
	# what made these sound like drums in the first place.
	if res_kind == VNode.Res.CLOTH:
		play("refined", -20.0, lerpf(0.90, 1.02, fullness))
	elif res_kind == VNode.Res.REFINED:
		play("refined", -22.0, lerpf(1.02, 1.14, fullness))
	else:
		play("raw", -25.0, lerpf(1.10, 1.25, fullness))


## An on-beat edit. Climbs the scale as the combo builds, so a hot streak is an
## audible run of rising bells rather than a repeated blip.
func sync_hit(combo: int, perfect: bool) -> void:
	var pitch := 1.0 + float(combo) * 0.055
	var db := -20.0 + minf(float(combo), 8.0) * 0.8
	play("refined" if perfect else "raw", db, pitch)
