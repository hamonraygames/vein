'use strict';
// POST /score — the leaderboard's only endpoint. One call does submit-and-
// fetch: verify the player, record their run, then return the same payload
// a plain "show me the board" call would (top 10, this player's rank, global
// totals) so the in-game panel never needs a second round trip after
// posting (see scripts/game.gd's _on_share_score).
//
// Uses the AWS SDK v3 client modules built into the nodejs20.x Lambda
// runtime (v2's monolithic `aws-sdk` stopped being bundled after the
// nodejs16.x runtimes) — no npm install, no bundling step, matching this
// repo's existing no-build-tooling deploys (see deploy_web.sh: plain
// aws-cli, nothing else).

const { DynamoDBClient } = require('@aws-sdk/client-dynamodb');
const {
	DynamoDBDocumentClient, GetCommand, PutCommand, UpdateCommand, ScanCommand,
} = require('@aws-sdk/lib-dynamodb');
const { verifyInitData } = require('./lib/verify_telegram');

const ddb = DynamoDBDocumentClient.from(new DynamoDBClient({}));
const PLAYERS_TABLE = process.env.PLAYERS_TABLE;
const META_TABLE = process.env.META_TABLE;
const BOT_TOKEN = process.env.BOT_TOKEN;
const TOP_N = 10;

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

	const user = verifyInitData(payload.initData, BOT_TOKEN);
	if (!user) {
		return respond(401, { error: 'invalid telegram session' });
	}

	const score = Number(payload.score);
	if (!Number.isFinite(score) || score < 0) {
		return respond(400, { error: 'bad score' });
	}

	const existing = await ddb.send(new GetCommand({
		TableName: PLAYERS_TABLE,
		Key: { player_id: user.id },
	}));
	const isNewPlayer = !existing.Item;
	const isNewBest = isNewPlayer || score > existing.Item.best_score;

	if (isNewBest) {
		await ddb.send(new PutCommand({
			TableName: PLAYERS_TABLE,
			Item: {
				player_id: user.id,
				name: user.name,
				best_score: score,
				best_score_at: new Date().toISOString(),
				total_runs: (existing.Item ? existing.Item.total_runs : 0) + 1,
			},
		}));
	} else {
		// Still record the run and keep the display name current even when
		// this run didn't beat their best — total_runs feeds totalPlays,
		// and a stale Telegram display name would otherwise never refresh.
		await ddb.send(new UpdateCommand({
			TableName: PLAYERS_TABLE,
			Key: { player_id: user.id },
			UpdateExpression: 'SET total_runs = total_runs + :one, #n = :name',
			ExpressionAttributeNames: { '#n': 'name' },
			ExpressionAttributeValues: { ':one': 1, ':name': user.name },
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
	const rank = sorted.findIndex((p) => p.player_id === user.id) + 1;
	const you = sorted.find((p) => p.player_id === user.id);

	const meta = await ddb.send(new GetCommand({ TableName: META_TABLE, Key: { id: 'totals' } }));

	return respond(200, {
		top,
		you: { rank, score: you ? you.best_score : score, isBest: isNewBest },
		totalPlayers: (meta.Item && meta.Item.total_players) || 0,
		totalPlays: (meta.Item && meta.Item.total_plays) || 0,
	});
};
