'use strict';
const crypto = require('crypto');

// Validates a Telegram Mini App `initData` string against the bot's own
// token — see https://core.telegram.org/bots/webapps#validating-data-received-via-the-mini-app.
// Without this, POST /score would accept a forged score from anyone who can
// see the endpoint URL; this is the only thing standing between "leaderboard"
// and "whatever number a curl request feels like submitting."
const MAX_AGE_SECONDS = 24 * 60 * 60;

function verifyInitData(initData, botToken) {
	if (!initData || !botToken) {
		return null;
	}
	const params = new URLSearchParams(initData);
	const hash = params.get('hash');
	if (!hash) {
		return null;
	}
	params.delete('hash');

	const dataCheckString = [...params.entries()]
		.sort(([a], [b]) => (a < b ? -1 : a > b ? 1 : 0))
		.map(([k, v]) => `${k}=${v}`)
		.join('\n');

	const secretKey = crypto.createHmac('sha256', 'WebAppData').update(botToken).digest();
	const computedHash = crypto.createHmac('sha256', secretKey).update(dataCheckString).digest('hex');

	// Constant-time compare — this is exactly the kind of check a timing
	// side-channel could otherwise leak one byte of at a time.
	const a = Buffer.from(computedHash, 'hex');
	const b = Buffer.from(hash, 'hex');
	if (a.length !== b.length || !crypto.timingSafeEqual(a, b)) {
		return null;
	}

	const authDate = Number(params.get('auth_date') || 0);
	if (!authDate || (Date.now() / 1000 - authDate) > MAX_AGE_SECONDS) {
		return null;
	}

	const userRaw = params.get('user');
	if (!userRaw) {
		return null;
	}
	let user;
	try {
		user = JSON.parse(userRaw);
	} catch (e) {
		return null;
	}
	if (!user || !user.id) {
		return null;
	}
	return {
		id: String(user.id),
		name: user.username || user.first_name || ('Player ' + user.id),
	};
}

module.exports = { verifyInitData };
