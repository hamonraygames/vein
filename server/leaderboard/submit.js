'use strict';
// POST /score, POST /name, POST /rank, POST /run/start, and POST
// /run/deliver — the leaderboard's five endpoints, one Lambda. /score does
// submit-and-fetch: record the run, then return the same payload a plain
// "show me the board" call would (top 10, this player's rank, global
// totals) so the in-game panel never needs a second round trip after
// posting (see scripts/game.gd's _submit_score). /name claims or renames a
// player's display name up front, enforcing uniqueness — see handleName
// below — so /score itself never has to re-check it on every single run.
// /rank is a read-only "where do I stand" query for the main menu — see
// handleRank below — that never writes anything, since opening the menu is
// not a run. /run/start fires the instant a real run begins (see game.gd's
// start_run) and hands back an unguessable run_id — a gameplay-lifecycle
// ping, not a registration step: it carries no name, no uniqueness check,
// nothing /name does. /run/deliver is the run's actual proof of play: the
// client reports each scoring delivery (kind/combo/pot) as it happens,
// batched every few seconds, and this Lambda recomputes each one's gain
// itself instead of trusting a number — see handleRunDeliver.
//
// Arcade-style, by explicit direction: no login, no account, no per-name
// proof of identity — a player is whatever `player_id` their client sends (a
// random ID generated once and saved locally, see game.gd's _load_save),
// under whatever `name` they've claimed. That trade was made on purpose to
// drop the Telegram-only requirement the first version had (see git
// history), and it matches VEIN's own stakes — bragging rights on a casual
// mobile game, not a competitive ranking with anything real riding on it.
// It no longer means a score can be fabricated from nothing, though.
// Round 1 (run_id + elapsed-time bound) closed the zero-effort case — an
// instant fake #1 from a single crafted POST — but red-teaming it live
// proved a real number is still just a *plausible* one, not an *earned*
// one: `/run/start` then `sleep 2` then `score: 2000` sailed straight
// through. Round 2 closes that: /score no longer trusts `payload.score` at
// all. The authoritative score is `validated_score` on the run row,
// accumulated exclusively through /run/deliver batches (plus any final
// unflushed tail attached to /score itself) — each delivery's gain is
// recomputed server-side from `kind`/`combo`/`pot` via the same formula
// game.gd uses (see FUEL_BY_RES/COMBO_GAIN/COMBO_CAP below), and both the
// gain-sum and the raw/refined event *counts* are rate-limited against real
// server-clocked elapsed time. This is still not unforgeable — a
// sufficiently motivated attacker who reads the open client could script a
// properly-paced, properly-shaped bot — but it closes casual/opportunistic
// abuse the same way round 1 did, one level down. The bounds below exist to
// keep the data sane on top of that, not to catch every possible abuse.
//
// Uses the AWS SDK v3 client modules built into the nodejs20.x Lambda
// runtime — no npm install, no bundling step, matching this repo's existing
// no-build-tooling deploys (see deploy.sh: plain aws-cli, nothing else).

const crypto = require('crypto');
const { DynamoDBClient } = require('@aws-sdk/client-dynamodb');
const {
	DynamoDBDocumentClient, GetCommand, PutCommand, UpdateCommand, ScanCommand,
} = require('@aws-sdk/lib-dynamodb');

const ddb = DynamoDBDocumentClient.from(new DynamoDBClient({}));
const PLAYERS_TABLE = process.env.PLAYERS_TABLE;
const META_TABLE = process.env.META_TABLE;
const RUNS_TABLE = process.env.RUNS_TABLE;
const TOP_N = 10;
const MAX_SCORE = 10000000;
const MAX_NAME_LEN = 20;
const MAX_ID_LEN = 64;

const RUN_ID_LEN = 32; // crypto.randomBytes(16).toString('hex')

// A short, human-typeable secret a player can carry to a new device to
// reclaim their existing player_id/name/best_score — see handleRecover. Not
// a password (nothing here has one), just proof-of-continuity: whoever
// types it gets treated as the player who first claimed it. Lowercase
// letters + digits only, matching what the in-game onscreen keyboard can
// type (see cleanName's comment) — no `_-.` here, since a code meant to be
// read/typed off a screen shouldn't lean on characters that are easy to
// mistype or ambiguous read aloud. 8 chars from a 36-symbol alphabet is
// ~2.8e12 combinations, comfortably unguessable for what this actually
// protects (bragging-rights leaderboard identity, not anything with real
// stakes riding on it — same posture as the rest of this file's auth, see
// README.md's "Arcade-style, on purpose").
const RECOVERY_CODE_ALPHABET = 'abcdefghijklmnopqrstuvwxyz0123456789';
const RECOVERY_CODE_LEN = 8;

function generateRecoveryCode() {
	const bytes = crypto.randomBytes(RECOVERY_CODE_LEN);
	let out = '';
	for (let i = 0; i < RECOVERY_CODE_LEN; i++) {
		out += RECOVERY_CODE_ALPHABET[bytes[i] % RECOVERY_CODE_ALPHABET.length];
	}
	return out;
}
// How much score a run_id's elapsed real time (server clock only, never
// anything the client claims) is allowed to plausibly represent. Now a
// backstop on the derived validated_score (see handleScore) rather than the
// primary gate — round 2 (/run/deliver) is the primary gate. All tunable
// via Lambda env vars so they can be retuned from real play data without a
// code deploy — see deploy.sh's ENV_VARS for the defaults.
const MAX_SCORE_RATE = Number(process.env.MAX_SCORE_RATE) || 1000; // points/sec
const MAX_RUN_SECONDS = Number(process.env.MAX_RUN_SECONDS) || 1200; // 20 min
const MIN_RUN_SECONDS = Number(process.env.MIN_RUN_SECONDS) || 2;
const SCORE_GRACE = Number(process.env.SCORE_GRACE) || 100;
// Table hygiene only (auto-expire abandoned run_ids) — deliberately well
// past MAX_RUN_SECONDS so a slow/backgrounded client never loses a
// legitimately-still-in-progress run_id before it can submit.
const RUN_TTL_SECONDS = 60 * 60 * 6;

// --- Delivery-event validation (round 2) ------------------------------------
//
// Mirrors scripts/vnode.gd's `enum Res` and game.gd's FUEL_BY_RES/
// COMBO_GAIN/COMBO_CAP exactly — keep both sides in sync on any tuning
// change, same risk class as any client/server contract (e.g. the name
// charset cleanName() mirrors from onscreen_keyboard.gd).
const RES = { RAW: 0, REFINED: 1, CLOTH: 2, PRISM: 3, VOID: 4, HEXAGON: 5 };
const FUEL_BY_RES = { 0: 1.0, 1: 3.0, 2: 7.0, 3: 15.0, 4: -2.5, 5: 31.0 };
// The tithe — a SPEND event, not a delivery: the client reporting that the
// player gave `cost` score back to keep the Heart alive (see game.gd's
// TITHE_EVENT_KIND/_tithe_emit; mirrors that constant). Subtracted from
// validated_score so the leaderboard matches the death screen. This is
// bookkeeping, not proof of play — a client that hides its spends is just a
// client granting itself fuel, which was never server-visible anyway; the
// deliveries that fuel buys are still rate-checked like everyone else's.
// The clamp is a sanity bound, not a security boundary: a spend can only
// ever LOWER the submitting player's own score. Sized against the client's
// proportional cost (per-dot is at least TITHE_SCORE_FRACTION — 5% — of the
// CURRENT score, see game.gd's _tithe_emit), so it must sit above 5% of any
// plausible run's score or clamped spends would leave validated_score HIGHER
// than the death screen's number.
const TITHE_KIND = 6;
const MAX_TITHE_COST = Number(process.env.MAX_TITHE_COST) || 5000;
const COMBO_GAIN = 0.07;
const COMBO_CAP = 10;
// Generous ceiling above vnode.gd's POISON_POT_BY_KIND (tops out at 2.5) —
// not a meaningful exploit vector since VOID gain is negative, so clamping
// wide rather than hardcoding exact per-kind values is fine here.
const MAX_POT = 3.0;
// Event-count rate caps, split in two because a flat cap can't tell "many
// cheap Wells" from "many expensive Crucibles" apart. RAW is generous
// (covers a full late-game Well swarm: up to 20 Wells x ~2.8/sec each).
// Everything from a tool (REFINED/CLOTH/PRISM/HEXAGON/VOID) is far more
// constrained even at game.gd's intensity-scaled board caps, so its rate is
// much lower — this is what actually catches "claim a huge pile of
// high-value deliveries" that a single flat cap would let through.
const RAW_DELIVERY_RATE = Number(process.env.RAW_DELIVERY_RATE) || 60;
const REFINED_DELIVERY_RATE = Number(process.env.REFINED_DELIVERY_RATE) || 15;
// A flat count grace large enough to absorb one node's worth of buffered
// items releasing in a burst (vnode.gd's buffer_cap() tops out at 6, for a
// Crucible or a Well), not an arbitrary round number — sized against
// REFINED_DELIVERY_RATE (the tighter of the two tiers), where a bigger
// grace would swallow a meaningful fraction of even a several-second
// window (see the regression test for exactly this: a 10-count grace let a
// crafted 40-Hexagon batch slip through a 2-second window undetected).
const DELIVERY_COUNT_GRACE = Number(process.env.DELIVERY_COUNT_GRACE) || 6;
// Per-batch clamp ceiling — distinct from MAX_RUN_SECONDS (the cumulative
// one). Without this, one giant batch sent after a long wait since the
// previous batch would reopen the same "bank unbounded elapsed time"
// problem MAX_RUN_SECONDS exists to close, just one level down.
const MAX_BATCH_WINDOW_SECONDS = Number(process.env.MAX_BATCH_WINDOW_SECONDS) || 60;
// Payload/compute-cost bound on a single /run/deliver (or /score's final
// tail) call — no legitimate flush at DELIVER_FLUSH_INTERVAL cadence (see
// game.gd) ever needs anywhere near this many events in one request.
const MAX_DELIVERIES_PER_BATCH = 500;

const CORS_HEADERS = {
	'Access-Control-Allow-Origin': '*',
	'Access-Control-Allow-Headers': 'content-type',
	'Access-Control-Allow-Methods': 'POST,OPTIONS',
};

function respond(statusCode, body) {
	return {
		statusCode,
		headers: { ...CORS_HEADERS, 'Content-Type': 'application/json' },
		body: JSON.stringify(body),
	};
}

// Matches exactly what the in-game custom keyboard can type (see
// scripts/onscreen_keyboard.gd) — lowercase letters, digits, and a small
// special set (`_ - .`) — so a name can never enter the table looking
// different from what a player actually typed. Applied on both endpoints:
// /name is where a name is really "set", but /score's own `name` field is
// re-cleaned too in case a client ever posts a stale/hand-crafted value.
function cleanName(raw) {
	return String(raw || '').toLowerCase().replace(/[^a-z0-9_.-]/g, '').slice(0, MAX_NAME_LEN);
}

// A row's rank movement since ITS OWN last run — `last_rank` is set right
// after every /score submission (see handleScore), so this applies
// uniformly to every row a client shows (top 10, the nearby block, or
// `you`), not just whoever happens to be asking. 0 means "no prior run to
// compare against," never a fabricated 0 for a real change — the client's
// chevron (see scripts/leaderboard_panel.gd/ranks_strip.gd) only draws when
// this is nonzero.
function rankChangeFor(p, currentRank) {
	const prior = Number(p.last_rank) || 0;
	return prior > 0 ? prior - currentRank : 0;
}

async function handleName(payload) {
	const playerId = String(payload.player_id || '').trim();
	if (!playerId || playerId.length > MAX_ID_LEN) {
		return respond(400, { error: 'bad player_id' });
	}
	const requested = cleanName(payload.name);
	if (requested.length === 0) {
		// Nothing left after stripping characters the keyboard can't even
		// type — reject rather than let every empty/junk submission collide
		// on some shared fallback name.
		return respond(400, { error: 'bad_name' });
	}

	// Same "simplest correct thing at this scale" scan the score path already
	// uses for ranking (see the Scale note in README.md) — reused here to
	// check uniqueness AND to generate suggestions from the same read.
	const all = await ddb.send(new ScanCommand({ TableName: PLAYERS_TABLE }));
	const items = all.Items || [];
	const takenBy = items.find(
		(p) => p.player_id !== playerId && String(p.name || '').toLowerCase() === requested,
	);

	if (takenBy) {
		const existingNames = new Set(items.map((p) => String(p.name || '').toLowerCase()));
		const suggestions = [];
		for (let n = 2; n <= 99 && suggestions.length < 3; n++) {
			const suffix = String(n);
			const candidate = `${requested.slice(0, MAX_NAME_LEN - suffix.length)}${suffix}`;
			if (!existingNames.has(candidate)) {
				suggestions.push(candidate);
				existingNames.add(candidate); // never suggest the same candidate twice
			}
		}
		return respond(409, { error: 'name_taken', suggestions });
	}

	// UpdateItem creates the row if it doesn't exist yet — lets a brand-new
	// player claim a name before ever finishing a run. best_score/total_runs
	// default to 0, has_played to false, and recovery_code to a freshly
	// generated one, ONLY the first time this row is touched (if_not_exists)
	// — a rename must never reissue the code (it's the one thing tying a
	// player's identity together across devices, see handleRecover) or every
	// device they'd already written the old code down on would silently stop
	// working. ReturnValues gets back whichever code actually ended up
	// stored (the fresh one on a first claim, the existing one on a rename)
	// so it can be handed back in the response either way.
	const updated = await ddb.send(new UpdateCommand({
		TableName: PLAYERS_TABLE,
		Key: { player_id: playerId },
		UpdateExpression: 'SET #n = :name, '
			+ 'best_score = if_not_exists(best_score, :zero), '
			+ 'total_runs = if_not_exists(total_runs, :zero), '
			+ 'has_played = if_not_exists(has_played, :false), '
			+ 'recovery_code = if_not_exists(recovery_code, :code)',
		ExpressionAttributeNames: { '#n': 'name' },
		ExpressionAttributeValues: {
			':name': requested, ':zero': 0, ':false': false, ':code': generateRecoveryCode(),
		},
		ReturnValues: 'ALL_NEW',
	}));

	return respond(200, {
		ok: true, name: requested, recovery_code: updated.Attributes.recovery_code,
	});
}

// POST /recover — trade a recovery code (see generateRecoveryCode's comment)
// for the player_id/name it belongs to, so a player can pick their existing
// identity back up on a new device instead of starting over as a fresh
// random name. Read-only: never bumps total_runs/totalPlayers the way
// /score does, matching /rank's posture (a device switch is not a run).
async function handleRecover(payload) {
	const code = String(payload.recovery_code || '').trim().toLowerCase();
	if (code.length === 0 || code.length > RECOVERY_CODE_LEN) {
		return respond(400, { error: 'bad_code' });
	}

	// Same "simplest correct thing at this scale" scan the name/score paths
	// already use (see the Scale note in README.md) — recovery is a rare,
	// one-off action per player, not a hot path, so this doesn't need its
	// own GSI any more than those do.
	const all = await ddb.send(new ScanCommand({ TableName: PLAYERS_TABLE }));
	const match = (all.Items || []).find((p) => String(p.recovery_code || '') === code);
	if (!match) {
		return respond(404, { error: 'code_not_found' });
	}

	return respond(200, {
		ok: true, player_id: match.player_id, name: match.name || '', best_score: match.best_score || 0,
	});
}

// POST /run/start — called by game.gd's start_run() the instant a run
// begins (fire-and-forget, see _start_run_ping in game.gd). Issues an
// unguessable run_id tied to server wall-clock time, so handleScore below
// can compute elapsed time from something the client never controlled.
// Deliberately does NOT validate `name` or touch PLAYERS_TABLE at all — this
// must stay completely outside the registration/name-claim flow.
async function handleRunStart(payload) {
	const playerId = String(payload.player_id || '').trim();
	if (!playerId || playerId.length > MAX_ID_LEN) {
		return respond(400, { error: 'bad player_id' });
	}

	const runId = crypto.randomBytes(16).toString('hex');
	const now = Date.now();
	await ddb.send(new PutCommand({
		TableName: RUNS_TABLE,
		Item: {
			run_id: runId,
			player_id: playerId,
			started_at: now,
			consumed: false,
			// Accumulated exclusively by handleRunDeliver (and /score's own final
			// tail) — see there. This, not payload.score, is what handleScore
			// actually ranks a run by.
			validated_score: 0,
			total_raw_count: 0,
			total_refined_count: 0,
			last_batch_at: now,
			// DynamoDB-native TTL attribute (epoch seconds) — see deploy.sh's
			// update-time-to-live call.
			ttl: Math.floor(now / 1000) + RUN_TTL_SECONDS,
		},
	}));

	return respond(200, { run_id: runId });
}

// Recomputes each delivery's gain itself from kind/combo/pot rather than
// trusting a number — the same formula game.gd's _deliver uses. Clamps
// combo/pot to their legal ranges rather than rejecting out-of-range values,
// matching the client's own clamping behavior (no reason for the server to
// be stricter than the game itself is about a harmless-either-way input).
// Returns null if the batch itself is malformed (wrong shape, too long, a
// kind outside 0-5) — those DO reject, since there's no legal reading of them.
function _validateDeliveries(deliveries) {
	if (!Array.isArray(deliveries) || deliveries.length > MAX_DELIVERIES_PER_BATCH) {
		return null;
	}
	let gain = 0;
	let rawCount = 0;
	let refinedCount = 0;
	for (const d of deliveries) {
		const kind = Number(d && d.kind);
		if (kind === TITHE_KIND) {
			// A spend: negative gain, and deliberately outside the raw/refined
			// rate counters — it is not a delivery and must not eat into the
			// plausibility budget of the real ones riding in the same batch.
			gain -= Math.min(Math.max(Number(d.cost) || 0, 0), MAX_TITHE_COST);
			continue;
		}
		if (!Number.isInteger(kind) || !(kind in FUEL_BY_RES)) {
			return null;
		}
		const combo = Math.min(Math.max(Number(d.combo) || 0, 0), COMBO_CAP);
		const pot = Math.min(Math.max(Number(d.pot) || 1, 0), MAX_POT);
		let eventGain = FUEL_BY_RES[kind];
		if (kind === RES.VOID) {
			eventGain *= pot;
		} else {
			eventGain *= (1 + combo * COMBO_GAIN);
		}
		gain += eventGain;
		if (kind === RES.RAW) {
			rawCount += 1;
		} else {
			refinedCount += 1;
		}
	}
	return { gain, rawCount, refinedCount };
}

// POST /run/deliver — the run's actual proof of play. Called periodically by
// game.gd's _flush_deliveries() (every DELIVER_FLUSH_INTERVAL of real time)
// with the deliveries that happened since the last flush; game.gd folds any
// final unflushed tail directly into /score instead of a last round trip
// here. Every check rejects with 400 and writes nothing.
async function handleRunDeliver(payload) {
	const playerId = String(payload.player_id || '').trim();
	if (!playerId || playerId.length > MAX_ID_LEN) {
		return respond(400, { error: 'bad player_id' });
	}
	const runId = String(payload.run_id || '').trim();
	if (runId.length !== RUN_ID_LEN) {
		return respond(400, { error: 'bad run_id' });
	}

	const validated = _validateDeliveries(payload.deliveries);
	if (validated === null) {
		return respond(400, { error: 'bad deliveries' });
	}

	const runRow = await ddb.send(new GetCommand({ TableName: RUNS_TABLE, Key: { run_id: runId } }));
	const run = runRow.Item;
	if (!run) {
		return respond(400, { error: 'unknown run_id' });
	}
	if (run.player_id !== playerId) {
		return respond(400, { error: 'run_id player mismatch' });
	}
	if (run.consumed) {
		return respond(400, { error: 'run already submitted' });
	}

	const now = Date.now();
	// Two independent windows, both server-clocked only: how much this ONE
	// batch could plausibly hold (capped at MAX_BATCH_WINDOW_SECONDS so a
	// batch sent after a long gap can't bank an unbounded allowance — the
	// same lesson MAX_RUN_SECONDS already taught round 1, one level down),
	// and how much the RUN AS A WHOLE could plausibly hold so far (catches
	// many small batches each sneaking in under DELIVERY_COUNT_GRACE).
	const sinceLastBatch = Math.min(
		Math.max((now - Number(run.last_batch_at || run.started_at)) / 1000, 0),
		MAX_BATCH_WINDOW_SECONDS,
	);
	const sinceStart = Math.min(
		Math.max((now - Number(run.started_at)) / 1000, 0),
		MAX_RUN_SECONDS,
	);

	const newRawTotal = Number(run.total_raw_count || 0) + validated.rawCount;
	const newRefinedTotal = Number(run.total_refined_count || 0) + validated.refinedCount;
	if (validated.rawCount > sinceLastBatch * RAW_DELIVERY_RATE + DELIVERY_COUNT_GRACE
			|| validated.refinedCount > sinceLastBatch * REFINED_DELIVERY_RATE + DELIVERY_COUNT_GRACE
			|| newRawTotal > sinceStart * RAW_DELIVERY_RATE + DELIVERY_COUNT_GRACE
			|| newRefinedTotal > sinceStart * REFINED_DELIVERY_RATE + DELIVERY_COUNT_GRACE) {
		return respond(400, { error: 'deliveries implausible for elapsed time' });
	}

	await ddb.send(new UpdateCommand({
		TableName: RUNS_TABLE,
		Key: { run_id: runId },
		UpdateExpression: 'ADD validated_score :gain, total_raw_count :rawCount, '
			+ 'total_refined_count :refinedCount SET last_batch_at = :now',
		ExpressionAttributeValues: {
			':gain': validated.gain,
			':rawCount': validated.rawCount,
			':refinedCount': validated.refinedCount,
			':now': now,
		},
	}));

	return respond(200, { ok: true });
}

async function handleScore(payload) {
	const playerId = String(payload.player_id || '').trim();
	if (!playerId || playerId.length > MAX_ID_LEN) {
		return respond(400, { error: 'bad player_id' });
	}
	const cleaned = cleanName(payload.name);
	const name = cleaned.length > 0 ? cleaned : 'player';

	// A run_id proves a real run actually started, server-side, before this
	// score existed — the fix for someone POSTing straight to /score with a
	// fabricated number and no gameplay behind it at all (see the top-of-file
	// comment). Every check below rejects with 400 and writes nothing.
	const runId = String(payload.run_id || '').trim();
	if (runId.length !== RUN_ID_LEN) {
		return respond(400, { error: 'bad run_id' });
	}
	const runRow = await ddb.send(new GetCommand({
		TableName: RUNS_TABLE,
		Key: { run_id: runId },
	}));
	const run = runRow.Item;
	if (!run) {
		return respond(400, { error: 'unknown run_id' });
	}
	if (run.player_id !== playerId) {
		return respond(400, { error: 'run_id player mismatch' });
	}
	if (run.consumed) {
		return respond(400, { error: 'run already submitted' });
	}

	// Round 2: payload.score is advisory only now, never trusted — the
	// authoritative score is run.validated_score, built exclusively from
	// rate-limited, formula-recomputed /run/deliver batches (see there and
	// the top-of-file comment). Any deliveries still sitting in the client's
	// buffer at death ride along here (see game.gd's _submit_score) instead
	// of one more round trip, validated and rate-checked exactly the same
	// way handleRunDeliver does.
	let tailGain = 0;
	let tailRawCount = 0;
	let tailRefinedCount = 0;
	if (payload.deliveries !== undefined) {
		const validated = _validateDeliveries(payload.deliveries);
		if (validated === null) {
			return respond(400, { error: 'bad deliveries' });
		}
		tailGain = validated.gain;
		tailRawCount = validated.rawCount;
		tailRefinedCount = validated.refinedCount;
	}

	// Only server-side timestamps feed this — `started_at`/`last_batch_at`
	// were set by this same Lambda, `Date.now()` here is this Lambda's own
	// clock right now. The client's own elapsed-time claims never enter this
	// math. Both windows clamped BEFORE use, same reasoning as
	// handleRunDeliver: MAX_BATCH_WINDOW_SECONDS stops one giant tail after a
	// long gap since the last flush from banking unbounded allowance, and
	// MAX_RUN_SECONDS stops the same trick against the run's total elapsed
	// time.
	const now = Date.now();
	const sinceLastBatch = Math.min(
		Math.max((now - Number(run.last_batch_at || run.started_at)) / 1000, 0),
		MAX_BATCH_WINDOW_SECONDS,
	);
	const elapsedSeconds = Math.min(Math.max((now - Number(run.started_at)) / 1000, 0), MAX_RUN_SECONDS);

	const newRawTotal = Number(run.total_raw_count || 0) + tailRawCount;
	const newRefinedTotal = Number(run.total_refined_count || 0) + tailRefinedCount;
	if (tailRawCount > sinceLastBatch * RAW_DELIVERY_RATE + DELIVERY_COUNT_GRACE
			|| tailRefinedCount > sinceLastBatch * REFINED_DELIVERY_RATE + DELIVERY_COUNT_GRACE
			|| newRawTotal > elapsedSeconds * RAW_DELIVERY_RATE + DELIVERY_COUNT_GRACE
			|| newRefinedTotal > elapsedSeconds * REFINED_DELIVERY_RATE + DELIVERY_COUNT_GRACE) {
		return respond(400, { error: 'deliveries implausible for elapsed time' });
	}

	// Backstop on the score this run is ABOUT to have, on top of the
	// delivery-level checks above — cheap defense in depth, catches any bug
	// in the per-event math rather than gating on it exclusively.
	const wouldBeScore = Number(run.validated_score || 0) + tailGain;
	if (wouldBeScore > 0 && elapsedSeconds < MIN_RUN_SECONDS) {
		return respond(400, { error: 'run too short' });
	}
	if (wouldBeScore > elapsedSeconds * MAX_SCORE_RATE + SCORE_GRACE) {
		return respond(400, { error: 'score implausible for run duration' });
	}

	// Conditional on !consumed so two concurrent /score calls for the same
	// run_id can't both pass the checks above and both write — the loser gets
	// a ConditionalCheckFailedException, turned into the same "already
	// submitted" rejection a genuine second attempt gets. Marked consumed in
	// the SAME atomic write that folds in the final tail (if any), so a
	// crash/timeout partway through handleScore after this point fails safe
	// (run_id burned, no double-count risk) rather than leaving a replay
	// window open. ALL_NEW hands back the authoritative validated_score
	// after the tail is applied, in one round trip.
	let finalScore;
	try {
		const updated = await ddb.send(new UpdateCommand({
			TableName: RUNS_TABLE,
			Key: { run_id: runId },
			// `consumed` is a DynamoDB reserved keyword — must be aliased via
			// ExpressionAttributeNames, same as `name` (`#n`) elsewhere here.
			UpdateExpression: 'ADD validated_score :gain, total_raw_count :rawCount, '
				+ 'total_refined_count :refinedCount SET #c = :true, last_batch_at = :now',
			ConditionExpression: '#c = :false',
			ExpressionAttributeNames: { '#c': 'consumed' },
			ExpressionAttributeValues: {
				':gain': tailGain,
				':rawCount': tailRawCount,
				':refinedCount': tailRefinedCount,
				':true': true,
				':false': false,
				':now': now,
			},
			ReturnValues: 'ALL_NEW',
		}));
		// Rounded here, not in validated_score itself — the underlying
		// accumulation across multiple /run/deliver batches stays a precise
		// float (avoids compounding rounding error batch to batch), only the
		// player-facing value that becomes best_score is an integer, matching
		// what the client has always shown (game.gd's _commas takes an int;
		// a stray float leaking into the leaderboard panel would look broken).
		finalScore = Math.max(0, Math.round(Number(updated.Attributes.validated_score) || 0));
	} catch (e) {
		if (e.name === 'ConditionalCheckFailedException') {
			return respond(400, { error: 'run already submitted' });
		}
		throw e;
	}

	const existing = await ddb.send(new GetCommand({
		TableName: PLAYERS_TABLE,
		Key: { player_id: playerId },
	}));
	const hasRow = !!existing.Item;
	// `has_played` distinguishes a row created purely by a /name claim (not a
	// real player yet, for totalPlayers-counting purposes) from one that's
	// actually finished a run. Missing/undefined on any row that predates
	// this field (i.e. every row that existed before today) reads as
	// "already played", so this stays correct against the live table.
	const isNewPlayerForTotals = !hasRow || existing.Item.has_played === false;
	const priorBest = hasRow ? (Number(existing.Item.best_score) || 0) : -1;
	const priorRuns = hasRow ? (Number(existing.Item.total_runs) || 0) : 0;
	// Captured before any write below — this player's rank as of their LAST
	// run, so it can be compared against the rank they hold after THIS one
	// (see the rankChange/last_rank block once the fresh scan below knows
	// where everyone actually stands). 0 means "no prior run to compare to."
	const priorRank = hasRow ? (Number(existing.Item.last_rank) || 0) : 0;
	const isNewBest = finalScore > priorBest;
	const newTotalRuns = priorRuns + 1;
	// Every /score submission, new best or not — unlike best_score_at (only
	// ever moves on an actual new best), this is a plain "when did they last
	// finish a run" readout for print_leaderboard.sh's admin view, so a
	// player who's played 50 times without beating their first run still
	// shows up as recently active instead of looking stale since day one.
	const nowIso = new Date().toISOString();

	if (isNewBest) {
		// UpdateCommand, not a full-item PutCommand — a Put here used to
		// silently wipe every field not listed (recovery_code included, once
		// that shipped) on the exact players most likely to hit this branch:
		// anyone actively improving their score. UpdateItem creates the row
		// just as well when it doesn't exist yet (a brand-new player's first
		// run is always a "new best" against priorBest's -1 default), so
		// this loses nothing for that case either.
		await ddb.send(new UpdateCommand({
			TableName: PLAYERS_TABLE,
			Key: { player_id: playerId },
			UpdateExpression: 'SET best_score = :score, best_score_at = :at, '
				+ 'total_runs = :runs, #n = :name, has_played = :true, last_played_at = :at',
			ExpressionAttributeNames: { '#n': 'name' },
			ExpressionAttributeValues: {
				':score': finalScore, ':at': nowIso, ':runs': newTotalRuns, ':name': name, ':true': true,
			},
		}));
	} else {
		// Still record the run and keep the display name current even when
		// this run didn't beat their best — total_runs feeds totalPlays/plays,
		// and a renamed player would otherwise stay stuck under their old name.
		await ddb.send(new UpdateCommand({
			TableName: PLAYERS_TABLE,
			Key: { player_id: playerId },
			UpdateExpression: 'SET total_runs = :runs, #n = :name, has_played = :true, last_played_at = :at',
			ExpressionAttributeNames: { '#n': 'name' },
			ExpressionAttributeValues: {
				':runs': newTotalRuns, ':name': name, ':true': true, ':at': nowIso,
			},
		}));
	}

	await ddb.send(new UpdateCommand({
		TableName: META_TABLE,
		Key: { id: 'totals' },
		UpdateExpression: 'ADD total_plays :one' + (isNewPlayerForTotals ? ', total_players :one' : ''),
		ExpressionAttributeValues: { ':one': 1 },
	}));

	// A full scan sorted in memory, not a query against a sorted index — the
	// simplest correct thing, and VEIN.md's own scope (a single-screen,
	// run-based mobile game) doesn't call for a leaderboard built to survive
	// tens of thousands of rows. Revisit with a GSI on a bucketed score only
	// once the player count actually makes a scan slow, not before.
	const all = await ddb.send(new ScanCommand({ TableName: PLAYERS_TABLE }));
	const sorted = all.Items.slice().sort((a, b) => b.best_score - a.best_score);
	const top = sorted.slice(0, TOP_N).map((p, i) => ({
		name: p.name,
		score: p.best_score,
		at: p.best_score_at,
		plays: p.total_runs || 0,
		rankChange: rankChangeFor(p, i + 1),
	}));
	const rank = sorted.findIndex((p) => p.player_id === playerId) + 1;
	const you = sorted.find((p) => p.player_id === playerId);

	// Two ranks above, this player, two below — the death screen's compact
	// strip AND the full leaderboard panel's "outside the top 10" view (see
	// leaderboard_panel.gd/ranks_strip.gd). `rank` is 1-indexed and `sorted`
	// is 0-indexed, so the player sits at rank-1; clamping the start at 0 is
	// what shortens the window near #1 instead of wrapping or erroring.
	const nearbyStart = Math.max(0, rank - 3);
	const nearby = sorted.slice(nearbyStart, rank + 2).map((p, i) => ({
		rank: nearbyStart + i + 1,
		name: p.name,
		score: p.best_score,
		at: p.best_score_at,
		plays: p.total_runs || 0,
		rankChange: rankChangeFor(p, nearbyStart + i + 1),
	}));

	// Record this player's rank right after this submission so their NEXT
	// run can compare against it (see priorRank/rankChangeFor above) — one
	// extra small write, but only for the row that actually needs it; every
	// other row's rankChange above is a pure read of what THEIR own last
	// submission already recorded here.
	await ddb.send(new UpdateCommand({
		TableName: PLAYERS_TABLE,
		Key: { player_id: playerId },
		UpdateExpression: 'SET last_rank = :rank',
		ExpressionAttributeValues: { ':rank': rank },
	}));

	const meta = await ddb.send(new GetCommand({ TableName: META_TABLE, Key: { id: 'totals' } }));

	return respond(200, {
		top,
		nearby,
		you: {
			rank,
			score: you ? you.best_score : finalScore,
			isBest: isNewBest,
			plays: you ? (you.total_runs || 0) : newTotalRuns,
			rankChange: priorRank > 0 ? priorRank - rank : 0,
		},
		totalPlayers: (meta.Item && meta.Item.total_players) || 0,
		totalPlays: (meta.Item && meta.Item.total_plays) || 0,
	});
}

// Read-only "where do I stand" query for the main menu (see
// scripts/main_menu.gd) — shown alongside the locally-saved best score,
// which is why this never writes anything: a menu visit is not a run, and
// must not bump total_runs/totalPlayers the way an actual /score submission
// does. Same scan-and-sort the other two routes already do.
//
// Also doubles as the read-only "just show me the board" query: the full
// panel (scripts/leaderboard_panel.gd) reads game.lb_state, which starts
// "idle" and only ever gets set by _submit_score — so opening the leaderboard
// from the main menu, before this session has ever finished a run, had
// nothing to show and sat on "Submitting..." forever even though nothing was
// ever submitting. top/nearby/you/totalPlays below are the SAME shape
// handleScore already returns (see game._on_lb_request_completed, which
// treats /score's and /rank's responses identically), just computed from a
// plain read instead of a write.
async function handleRank(payload) {
	const playerId = String(payload.player_id || '').trim();
	if (!playerId || playerId.length > MAX_ID_LEN) {
		return respond(400, { error: 'bad player_id' });
	}

	const all = await ddb.send(new ScanCommand({ TableName: PLAYERS_TABLE }));
	const sorted = (all.Items || []).slice().sort((a, b) => b.best_score - a.best_score);
	const rank = sorted.findIndex((p) => p.player_id === playerId) + 1;
	const you = rank > 0 ? sorted[rank - 1] : null;

	const top = sorted.slice(0, TOP_N).map((p, i) => ({
		name: p.name,
		score: p.best_score,
		at: p.best_score_at,
		plays: p.total_runs || 0,
		rankChange: rankChangeFor(p, i + 1),
	}));

	// Same window as handleScore's own nearby block, only needed once you fall
	// outside the top 10 — see the comment there.
	let nearby = [];
	if (rank > top.length) {
		const nearbyStart = Math.max(0, rank - 3);
		nearby = sorted.slice(nearbyStart, rank + 2).map((p, i) => ({
			rank: nearbyStart + i + 1,
			name: p.name,
			score: p.best_score,
			at: p.best_score_at,
			plays: p.total_runs || 0,
			rankChange: rankChangeFor(p, nearbyStart + i + 1),
		}));
	}

	const meta = await ddb.send(new GetCommand({ TableName: META_TABLE, Key: { id: 'totals' } }));

	return respond(200, {
		rank,
		score: you ? you.best_score : 0,
		plays: you ? (you.total_runs || 0) : 0,
		rankChange: you ? rankChangeFor(you, rank) : 0,
		totalPlayers: sorted.length,
		top,
		nearby,
		you: {
			rank,
			score: you ? you.best_score : 0,
			isBest: false,
			plays: you ? (you.total_runs || 0) : 0,
			rankChange: you ? rankChangeFor(you, rank) : 0,
		},
		totalPlays: (meta.Item && meta.Item.total_plays) || 0,
	});
}

exports.handler = async (event) => {
	const method = event.requestContext && event.requestContext.http
		&& event.requestContext.http.method;
	if (method === 'OPTIONS') {
		return respond(204, {});
	}

	let payload;
	try {
		payload = JSON.parse(event.body || '{}');
	} catch (e) {
		return respond(400, { error: 'bad json' });
	}

	const path = event.rawPath
		|| (event.requestContext && event.requestContext.http && event.requestContext.http.path)
		|| '';
	if (path.endsWith('/run/start')) {
		return handleRunStart(payload);
	}
	if (path.endsWith('/run/deliver')) {
		return handleRunDeliver(payload);
	}
	if (path.endsWith('/name')) {
		return handleName(payload);
	}
	if (path.endsWith('/rank')) {
		return handleRank(payload);
	}
	if (path.endsWith('/recover')) {
		return handleRecover(payload);
	}
	return handleScore(payload);
};
