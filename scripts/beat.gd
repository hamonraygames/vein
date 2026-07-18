extends Node
## The metronome the entire game synchronises to.
##
## One timer. Every node pulse, every dot emission, every haptic tick and (later)
## every audio note subscribes to `beat`. This is what makes the game feel like a
## single organism instead of a pile of independent timers.

signal beat(index: int)
signal state_changed(new_state: int)
signal stopped(total_beats: int)

enum State { HEALTHY, STRAINED, DYING, STOPPED }

## Ceiling on a single frame's delta, shared by every system that advances the
## sim (Beat, game.gd, vnode.gd). A frame hitch must never teleport the world.
##
## Found via the probe: the first frame of a launch (asset load, shader compile)
## takes ~150ms of real time, and at the probe's Engine.time_scale=60 that ONE
## frame's delta became NINE game-seconds. Run 1 of every batch silently jumped
## to run_time 9.0 before AutoPlay could act — spawning wells, a Forge and a
## Boost instantly — while Beat only ever emits ONE beat per frame no matter how
## much time accumulated, so the Heart starved and "died at beat 7". That was a
## harness artifact reported as a balance number for who knows how long, and it
## also explains why identical seeds gave different results.
##
## Must stay below the shortest beat interval (60/BPM_MAXED = 0.45s) or beats
## get dropped on a slow frame. Clamping caps the probe's effective speedup at
## MAX_DELTA * real_fps, which is a fair trade for numbers that are true.
const MAX_DELTA := 0.25

## Base rate at the start of a run. The heart races as the run escalates — see
## `set_exertion` — which is both thematic (tachycardia under strain) and what
## makes late beats accumulate faster.
const BPM_CALM := 66.0
const BPM_MAXED := 132.0

## How much a heart in trouble drags its own rate down. Missed feedings slow the
## beat; this is the player's first warning and they feel it before they see it.
const RATE_BY_STATE := {
	State.HEALTHY: 1.0,
	State.STRAINED: 0.86,
	State.DYING: 0.58,
	State.STOPPED: 0.0,
}

var index := 0
var state: int = State.HEALTHY
var running := false

## 0..1 progress through the current beat. Nodes use this to ease their pulse.
var phase := 0.0
## 0..1, raised by the game as appetite escalates.
var exertion := 0.0

var _accum := 0.0
var _haptics := false


func _ready() -> void:
	_haptics = OS.has_feature("mobile")
	set_process(true)


func reset() -> void:
	index = 0
	phase = 0.0
	exertion = 0.0
	_accum = 0.0
	state = State.HEALTHY
	running = true


func stop() -> void:
	if not running:
		return
	running = false
	set_state(State.STOPPED)
	if _haptics:
		Input.vibrate_handheld(900)
	stopped.emit(index)


func set_state(s: int) -> void:
	if s == state:
		return
	state = s
	state_changed.emit(s)


func set_exertion(v: float) -> void:
	exertion = clampf(v, 0.0, 1.0)


func interval() -> float:
	var bpm := lerpf(BPM_CALM, BPM_MAXED, exertion) * float(RATE_BY_STATE[state])
	if bpm <= 0.0:
		return INF
	return 60.0 / bpm


func _process(delta: float) -> void:
	if not running:
		return
	delta = minf(delta, MAX_DELTA)
	var iv := interval()
	if iv == INF:
		return
	_accum += delta
	phase = clampf(_accum / iv, 0.0, 1.0)
	if _accum >= iv:
		_accum -= iv
		index += 1
		_thump()
		beat.emit(index)


## Haptic texture per state. A calm animal in your hand; then arrhythmia you feel
## before any visual reads it.
func _thump() -> void:
	if not _haptics:
		return
	match state:
		State.HEALTHY:
			Input.vibrate_handheld(24)
		State.STRAINED:
			# A doubled beat — the flutter of something working too hard.
			Input.vibrate_handheld(18)
			await get_tree().create_timer(0.09).timeout
			Input.vibrate_handheld(30)
		State.DYING:
			Input.vibrate_handheld(70)
