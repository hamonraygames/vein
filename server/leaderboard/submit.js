'use strict';
// POST /score — the leaderboard's only endpoint. One call does submit-and-
// fetch: record the run, then return the same payload a plain "show me the
// board" call would (top 10, this player's rank, global totals) so the
// in-game panel never needs a second round trip after posting (see
// scripts/game.gd's _on_share_score).
//
// Arcade-style, by explicit direction: no login, no per-submission proof of
// identity — a player is whatever `player_id` their client sends (a random
// ID generated once and saved locally, see game.gd's _load_save), under
// whatever `name` they typed. Anyone who finds this URL could POST an
// arbitrary score under an arbitrary name; that trade was made on purpose
// to drop the Telegram-only requirement the first version had (see git
// history), and it matches VEIN's own stakes — bragging rights on a casual
// mobile game, not a competitive ranking with anything real riding on it.
// The bounds below exist to keep the data sane, not to stop a determined
// cheater.
//
// Uses the AWS SDK v3 client modules built into the nodejs20.x Lambda
// runtime — no npm install, no bundling step, matching this repo's existing
// no-build-tooling deploys (see deploy_web.sh: plain aws-cli, nothing else).

const { DynamoDBClient } = require('@aws-sdk/client-dynamodb');
const {
	DynamoDBDocumentClient, GetCommand, PutCommand, UpdateCommand, ScanCommand,
} = require('@aws-sdk/lib-dynamodb');

const ddb = DynamoDBDocumentClient.from(new DynamoDBClient({}));
const PLAYERS_TABLE = process.env.PLAYERS_TABLE;
const META_TABLE = process.env.META_TABLE;
const TOP_N = 10;
const MAX_SCORE = 10000000;
const MAX_NAME_LEN = 20;
const MAX_ID_LEN = 64;

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

// Strips control characters and collapses whitespace so a stray tab/newline
// in a typed name can't break the panel's single-line layout; length is
// capped, not truncated silently past a grapheme boundary, to keep this
// simple — a name that's all junk after cleanup falls back to "Player".
function cleanName(raw) {
	const s = String(raw || '').replace(/[\x00-\x1f\x7f]+/g, ' ').trim().slice(0, MAX_NAME_LEN);
	return s.length > 0 ? s : 'Player';
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

	const playerId = String(payload.player_id || '').trim();
	if (!playerId || playerId.length > MAX_ID_LEN) {
		return respond(400, { error: 'bad player_id' });
	}
	const name = cleanName(payload.name);

	const score = Number(payload.score);
	if (!Number.isFinite(score) || score < 0 || score > MAX_SCORE) {
		return respond(400, { error: 'bad score' });
	}

	const existing = await ddb.send(new GetCommand({
		TableName: PLAYERS_TABLE,
		Key: { player_id: playerId },
	}));
	const isNewPlayer = !existing.Item;
	const isNewBest = isNewPlayer || score > existing.Item.best_score;

	if (isNewBest) {
		await ddb.send(new PutCommand({
			TableName: PLAYERS_TABLE,
			Item: {
				player_id: playerId,
				name,
				best_score: score,
				best_score_at: new Date().toISOString(),
				total_runs: (existing.Item ? existing.Item.total_runs : 0) + 1,
			},
		}));
	} else {
		// Still record the run and keep the display name current even when
		// this run didn't beat their best — total_runs feeds totalPlays, and
		// a renamed player would otherwise stay stuck under their old name.
		await ddb.send(new UpdateCommand({
			TableName: PLAYERS_TABLE,
			Key: { player_id: playerId },
			UpdateExpression: 'SET total_runs = total_runs + :one, #n = :name',
			ExpressionAttributeNames: { '#n': 'name' },
			ExpressionAttributeValues: { ':one': 1, ':name': name },
		}));
	}

	await ddb.send(new UpdateCommand({
		TableName: META_TABLE,
		Key: { id: 'totals' },
		UpdateExpression: 'ADD total_plays :one' + (isNewPlayer ? ', total_players :one' : ''),
		ExpressionAttributeValues: { ':one': 1 },
	}));

	// A full scan sorted in memory, not a query against a sorted index — the
	// simplest correct thing, and VEIN.md's own scope (a single-screen,
	// run-based mobile game) doesn't call for a leaderboard built to survive
	// tens of thousands of rows. Revisit with a GSI on a bucketed score only
	// once the player count actually makes a scan slow, not before.
	const all = await ddb.send(new ScanCommand({ TableName: PLAYERS_TABLE }));
	const sorted = all.Items.slice().sort((a, b) => b.best_score - a.best_score);
	const top = sorted.slice(0, TOP_N).map((p) => ({
		name: p.name,
		score: p.best_score,
		at: p.best_score_at,
	}));
	const rank = sorted.findIndex((p) => p.player_id === playerId) + 1;
	const you = sorted.find((p) => p.player_id === playerId);

	// Two ranks above, this player, two below — the death screen's compact
	// strip (see leaderboard_panel.gd's caller in game.gd). `rank` is
	// 1-indexed and `sorted` is 0-indexed, so the player sits at rank-1;
	// clamping the start at 0 is what shortens the window near #1 instead
	// of wrapping or erroring.
	const nearbyStart = Math.max(0, rank - 3);
	const nearby = sorted.slice(nearbyStart, rank + 2).map((p, i) => ({
		rank: nearbyStart + i + 1,
		name: p.name,
		score: p.best_score,
	}));

	const meta = await ddb.send(new GetCommand({ TableName: META_TABLE, Key: { id: 'totals' } }));

	return respond(200, {
		top,
		nearby,
		you: { rank, score: you ? you.best_score : score, isBest: isNewBest },
		totalPlayers: (meta.Item && meta.Item.total_players) || 0,
		totalPlays: (meta.Item && meta.Item.total_plays) || 0,
	});
};
