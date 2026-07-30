'use strict';
// POST /score, POST /name, POST /rank, and POST /run/start — the
// leaderboard's four endpoints, one Lambda. /score does submit-and-fetch:
// record the run, then return the same payload a plain "show me the board"
// call would (top 10, this player's rank, global totals) so the in-game
// panel never needs a second round trip after posting (see
// scripts/game.gd's _submit_score). /name claims or renames a player's
// display name up front, enforcing uniqueness — see handleName below — so
// /score itself never has to re-check it on every single run. /rank is a
// read-only "where do I stand" query for the main menu — see handleRank
// below — that never writes anything, since opening the menu is not a run.
// /run/start fires the instant a real run begins (see game.gd's start_run)
// and hands back an unguessable run_id that /score later requires — this is
// a gameplay-lifecycle ping, not a registration step: it carries no name, no
// uniqueness check, nothing /name does.
//
// Arcade-style, by explicit direction: no login, no account, no per-name
// proof of identity — a player is whatever `player_id` their client sends (a
// random ID generated once and saved locally, see game.gd's _load_save),
// under whatever `name` they've claimed. That trade was made on purpose to
// drop the Telegram-only requirement the first version had (see git
// history), and it matches VEIN's own stakes — bragging rights on a casual
// mobile game, not a competitive ranking with anything real riding on it.
// It no longer means a score can be fabricated from nothing, though: /score
// requires a run_id minted server-side by /run/start at the moment a real
// run began, ties elapsed time to the server's own clock (never anything the
// client claims), and rejects a run_id that's unknown, already used, or
// implausible for the score it's paired with — see handleScore. Anyone can
// still play a real run and pad the number at the margins; nobody can POST a
// #1 score with zero gameplay behind it anymore. The bounds below exist to
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
// How much score a run_id's elapsed real time (server clock only, never
// anything the client claims) is allowed to plausibly represent. All four
// tunable via Lambda env vars so they can be retuned from real play data
// without a code deploy — see deploy.sh's ENV_VARS for the defaults.
const MAX_SCORE_RATE = Number(process.env.MAX_SCORE_RATE) || 1000; // points/sec
const MAX_RUN_SECONDS = Number(process.env.MAX_RUN_SECONDS) || 1200; // 20 min
const MIN_RUN_SECONDS = Number(process.env.MIN_RUN_SECONDS) || 2;
const SCORE_GRACE = Number(process.env.SCORE_GRACE) || 100;
// Table hygiene only (auto-expire abandoned run_ids) — deliberately well
// past MAX_RUN_SECONDS so a slow/backgrounded client never loses a
// legitimately-still-in-progress run_id before it can submit.
const RUN_TTL_SECONDS = 60 * 60 * 6;

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
	// default to 0 and has_played to false ONLY the first time this row is
	// touched (if_not_exists), so a later real score write's own math (and
	// the leaderboard scan's sort, which assumes every row has a numeric
	// best_score) never sees an undefined field.
	await ddb.send(new UpdateCommand({
		TableName: PLAYERS_TABLE,
		Key: { player_id: playerId },
		UpdateExpression: 'SET #n = :name, '
			+ 'best_score = if_not_exists(best_score, :zero), '
			+ 'total_runs = if_not_exists(total_runs, :zero), '
			+ 'has_played = if_not_exists(has_played, :false)',
		ExpressionAttributeNames: { '#n': 'name' },
		ExpressionAttributeValues: { ':name': requested, ':zero': 0, ':false': false },
	}));

	return respond(200, { ok: true, name: requested });
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
			// DynamoDB-native TTL attribute (epoch seconds) — see deploy.sh's
			// update-time-to-live call.
			ttl: Math.floor(now / 1000) + RUN_TTL_SECONDS,
		},
	}));

	return respond(200, { run_id: runId });
}

async function handleScore(payload) {
	const playerId = String(payload.player_id || '').trim();
	if (!playerId || playerId.length > MAX_ID_LEN) {
		return respond(400, { error: 'bad player_id' });
	}
	const cleaned = cleanName(payload.name);
	const name = cleaned.length > 0 ? cleaned : 'player';

	const score = Number(payload.score);
	if (!Number.isFinite(score) || score < 0 || score > MAX_SCORE) {
		return respond(400, { error: 'bad score' });
	}

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

	// Only server-side timestamps feed this — `started_at` was set by this
	// same Lambda in handleRunStart, `Date.now()` here is this Lambda's own
	// clock right now. The client's own elapsed-time claims (there are none
	// in the payload today, and none should ever be added) never enter this
	// math. Clamped to MAX_RUN_SECONDS BEFORE use in the rate check below —
	// without that clamp, an attacker could grab a run_id and simply wait
	// real wall-clock hours before ever submitting, "banking" unbounded
	// elapsed-time budget against MAX_SCORE_RATE. The clamp is what turns a
	// per-second rate limit into an actual ceiling.
	const rawElapsedSeconds = (Date.now() - Number(run.started_at)) / 1000;
	const elapsedSeconds = Math.min(Math.max(rawElapsedSeconds, 0), MAX_RUN_SECONDS);

	if (score > 0 && elapsedSeconds < MIN_RUN_SECONDS) {
		return respond(400, { error: 'run too short' });
	}
	if (score > elapsedSeconds * MAX_SCORE_RATE + SCORE_GRACE) {
		return respond(400, { error: 'score implausible for run duration' });
	}

	// Conditional on !consumed so two concurrent /score calls for the same
	// run_id can't both pass the checks above and both write — the loser gets
	// a ConditionalCheckFailedException, turned into the same "already
	// submitted" rejection a genuine second attempt gets. Marked consumed
	// BEFORE the writes below proceed, so a crash/timeout partway through
	// handleScore after this point fails safe (run_id burned, no
	// double-count risk) rather than leaving a replay window open.
	try {
		await ddb.send(new UpdateCommand({
			TableName: RUNS_TABLE,
			Key: { run_id: runId },
			// `consumed` is a DynamoDB reserved keyword — must be aliased via
			// ExpressionAttributeNames, same as `name` (`#n`) elsewhere here.
			UpdateExpression: 'SET #c = :true',
			ConditionExpression: '#c = :false',
			ExpressionAttributeNames: { '#c': 'consumed' },
			ExpressionAttributeValues: { ':true': true, ':false': false },
		}));
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
	const isNewBest = score > priorBest;
	const newTotalRuns = priorRuns + 1;

	if (isNewBest) {
		await ddb.send(new PutCommand({
			TableName: PLAYERS_TABLE,
			Item: {
				player_id: playerId,
				name,
				best_score: score,
				best_score_at: new Date().toISOString(),
				total_runs: newTotalRuns,
				has_played: true,
			},
		}));
	} else {
		// Still record the run and keep the display name current even when
		// this run didn't beat their best — total_runs feeds totalPlays/plays,
		// and a renamed player would otherwise stay stuck under their old name.
		await ddb.send(new UpdateCommand({
			TableName: PLAYERS_TABLE,
			Key: { player_id: playerId },
			UpdateExpression: 'SET total_runs = :runs, #n = :name, has_played = :true',
			ExpressionAttributeNames: { '#n': 'name' },
			ExpressionAttributeValues: { ':runs': newTotalRuns, ':name': name, ':true': true },
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
			score: you ? you.best_score : score,
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
	if (path.endsWith('/name')) {
		return handleName(payload);
	}
	if (path.endsWith('/rank')) {
		return handleRank(payload);
	}
	return handleScore(payload);
};
