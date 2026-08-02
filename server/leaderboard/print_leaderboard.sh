#!/usr/bin/env bash
# Prints the ENTIRE leaderboard (not just the top 10 /score and /rank return
# to the game) plus aggregate health/engagement stats, straight from
# DynamoDB. Admin/debug tool only — reads the live tables directly, so it
# needs the same AWS credentials deploy.sh does, not an HTTP call through the
# public API.
# Plain aws-cli + jq, matching this project's existing no-build-tooling
# approach (see deploy.sh, submit.js's top-of-file comment).
set -euo pipefail

cd "$(dirname "$0")"

REGION="eu-north-1"
PLAYERS_TABLE="vein-leaderboard-players"
META_TABLE="vein-leaderboard-meta"
RUNS_TABLE="vein-leaderboard-runs"

# Scans a table to exhaustion (a single Scan call can return a partial page)
# and prints one DynamoDB item's JSON per line, unwrapped from the
# {"S": "x"} / {"N": "1"} / {"BOOL": true} attribute-value wrapper down to
# plain JSON — every table this script reads only ever uses those three
# types (see submit.js), so this doesn't need to handle the rest of
# DynamoDB's type zoo.
scan_all() {
	local table="$1"
	local start_key=""
	while true; do
		local args=(dynamodb scan --region "$REGION" --table-name "$table" --output json)
		if [[ -n "$start_key" ]]; then
			args+=(--exclusive-start-key "$start_key")
		fi
		local page
		page="$(aws "${args[@]}")"
		jq -c '.Items[] | map_values(
			if has("S") then .S
			elif has("N") then (.N | tonumber)
			elif has("BOOL") then .BOOL
			else .
			end
		)' <<<"$page"
		start_key="$(jq -c '.LastEvaluatedKey // empty' <<<"$page")"
		[[ -z "$start_key" ]] || [[ "$start_key" == "null" ]] && break
	done
}

echo "==> Fetching players from $PLAYERS_TABLE (region $REGION)..." >&2
players_json="$(scan_all "$PLAYERS_TABLE" | jq -s '.')"

echo "==> Fetching totals from $META_TABLE..." >&2
meta_json="$(aws dynamodb get-item --region "$REGION" --table-name "$META_TABLE" \
	--key '{"id": {"S": "totals"}}' --output json \
	| jq -c '.Item // {} | map_values(if has("N") then (.N|tonumber) else .S end)')"

# runs_table has a 6h TTL (see submit.js's RUN_TTL_SECONDS / README's "Scale
# note" sibling) — this is a live, ~6h-rolling window of in-flight/recent
# runs, not the full history of every run ever played. Useful as a "right
# now" activity pulse, not a lifetime counter.
echo "==> Fetching recent runs from $RUNS_TABLE..." >&2
runs_json="$(scan_all "$RUNS_TABLE" | jq -s '.')"

now_epoch="$(date +%s)"

# --- Full leaderboard, ranked by best_score desc, ties broken by name -------
#
# Includes every player row, not just ones with a score: a claimed-but-never-
# played name (has_played == false) still shows up, unranked, at the bottom
# — the point of this script is a complete admin picture of the table, not
# just what the in-game panel would show.

echo
echo "==================== VEIN LEADERBOARD ===================="
printf "%-5s %-22s %10s %7s  %-24s  %s\n" "RANK" "NAME" "SCORE" "PLAYS" "LAST BEST" "LAST PLAYED"
echo "--------------------------------------------------------------------------------------"

sorted_json="$(jq -c '[.[] | select(.has_played != false)]
	| sort_by(-(.best_score // 0), .name // "")' <<<"$players_json")"

# last_played_at moves on EVERY /score submission, best or not (see
# submit.js's handleScore) — best_score_at only ever moves on an actual new
# best, so a player who's played 50 times without beating their first run
# would otherwise look stale since day one. Rows written before
# last_played_at existed fall back to "-", same as best_score_at already did.
jq -r 'to_entries[] | "\(.key+1)\t\(.value.name // "?")\t\(.value.best_score // 0)\t\(.value.total_runs // 0)\t\(.value.best_score_at // "-")\t\(.value.last_played_at // "-")"' \
	<<<"$sorted_json" \
	| while IFS=$'\t' read -r rank name score plays at played; do
		printf "%-5s %-22s %10s %7s  %-24s  %s\n" "$rank" "$name" "$score" "$plays" "$at" "$played"
	done

unranked_json="$(jq -c '[.[] | select(.has_played == false)] | sort_by(.name // "")' <<<"$players_json")"
unranked_count="$(jq 'length' <<<"$unranked_json")"

if [[ "$unranked_count" -gt 0 ]]; then
	echo "--------------------------------------------------------------------------------------"
	echo "(claimed a name, never finished a run — unranked)"
	jq -r '.[] | .name // "?"' <<<"$unranked_json" \
		| while IFS= read -r name; do
			printf "%-5s %-22s %10s %7s  %-24s  %s\n" "-" "$name" "-" "0" "(no runs yet)" "-"
		done
fi

# --- Stats -------------------------------------------------------------------

stats="$(jq -c --argjson meta "$meta_json" --argjson now "$now_epoch" '
	{
		ranked: [.[] | select(.has_played != false)],
		unclaimed_names: ([.[] | select(.has_played == false)] | length),
	}
	| .ranked as $r
	| ($r | map(.best_score // 0)) as $scores
	| ($scores | sort) as $sorted_scores
	| ($sorted_scores | length) as $n
	| (if $n == 0 then 0 else $sorted_scores[(($n - 1) * 0.25 | floor)] end) as $p25
	| (if $n == 0 then 0 else $sorted_scores[(($n - 1) * 0.75 | floor)] end) as $p75
	| (if $n == 0 then 0 else $sorted_scores[(($n - 1) * 0.90 | floor)] end) as $p90
	| ($r | map(select((.total_runs // 0) > 1)) | length) as $returning
	| ($r | map(select((.total_runs // 0) == 1)) | length) as $one_and_done
	| ($r | map(
		(.best_score_at // "") as $t
		# best_score_at is `new Date().toISOString()` (submit.js), which always
		# includes a millisecond fraction (".000Z") that fromdateiso8601
		# cannot parse directly, so strip it before parsing.
		| ($t | sub("\\.[0-9]+Z$"; "Z") | try fromdateiso8601 catch null)
	) | map(select(. != null))) as $timestamps
	| ($timestamps | map(select(($now - .) <= 86400)) | length) as $active_24h
	| ($timestamps | map(select(($now - .) <= 604800)) | length) as $active_7d
	| {
		ranked_players: ($r | length),
		unclaimed_names: .unclaimed_names,
		total_players_meta: ($meta.total_players // 0),
		total_plays_meta: ($meta.total_plays // 0),
		sum_runs: ($r | map(.total_runs // 0) | add // 0),
		top_score: ($scores | max // 0),
		min_score: ($scores | min // 0),
		avg_score: (if $n > 0 then ($scores | add) / $n else 0 end),
		median_score: (
			if $n == 0 then 0
			elif ($n % 2) == 1 then $sorted_scores[($n - 1) / 2]
			else ($sorted_scores[$n/2 - 1] + $sorted_scores[$n/2]) / 2
			end
		),
		p25_score: $p25,
		p75_score: $p75,
		p90_score: $p90,
		returning_players: $returning,
		one_and_done_players: $one_and_done,
		active_players_24h: $active_24h,
		active_players_7d: $active_7d,
	}
	| . + {
		avg_plays_per_player: (if .ranked_players > 0 then (.sum_runs / .ranked_players) else 0 end),
		pct_returning: (if .ranked_players > 0 then ($returning / .ranked_players * 100) else 0 end),
	}
' <<<"$players_json")"

runs_stats="$(jq -c '
	{
		runs_total: length,
		runs_consumed: (map(select(.consumed == true)) | length),
		completed: [.[] | select(.consumed == true)],
	}
	| .completed as $c
	| {
		runs_total: .runs_total,
		runs_consumed: .runs_consumed,
		runs_in_progress_or_abandoned: (.runs_total - .runs_consumed),
		avg_validated_score: (if ($c | length) > 0 then ($c | map(.validated_score // 0) | add) / ($c | length) else 0 end),
		avg_deliveries_per_run: (if ($c | length) > 0 then ($c | map((.total_raw_count // 0) + (.total_refined_count // 0)) | add) / ($c | length) else 0 end),
	}
	| . + {
		completion_rate_pct: (if .runs_total > 0 then (.runs_consumed / .runs_total * 100) else 0 end),
	}
' <<<"$runs_json")"

echo
echo "==================== STATS ===================="
jq -r '
	"Ranked players (has played):  \(.ranked_players)",
	"Names claimed, never played:  \(.unclaimed_names)",
	"Total players (meta counter): \(.total_players_meta)",
	"Total runs submitted (meta):  \(.total_plays_meta)",
	"Sum of per-player total_runs: \(.sum_runs)",
	"Avg runs per ranked player:   \(.avg_plays_per_player | . * 100 | round / 100)",
	"",
	"Top score:                    \(.top_score)",
	"Lowest (ranked) score:        \(.min_score)",
	"Average best_score:           \(.avg_score | . * 100 | round / 100)",
	"Median best_score:            \(.median_score)",
	"25th / 75th / 90th pctile:    \(.p25_score) / \(.p75_score) / \(.p90_score)"
' <<<"$stats"

echo
echo "---- Engagement (is vein sticky?) ----"
jq -r '
	"Returning players (>1 run):   \(.returning_players) (\(.pct_returning | . * 10 | round / 10)% of ranked)",
	"One-and-done players:         \(.one_and_done_players)",
	"Best-score set in last 24h:   \(.active_players_24h)",
	"Best-score set in last 7d:    \(.active_players_7d)"
' <<<"$stats"

echo
echo "---- Live run funnel, last ~6h (is vein being played right now?) ----"
jq -r '
	"Runs started (in TTL window): \(.runs_total)",
	"Runs completed (/score sent): \(.runs_consumed)",
	"In progress / abandoned:      \(.runs_in_progress_or_abandoned)",
	"Completion rate:              \(.completion_rate_pct | . * 10 | round / 10)%",
	"Avg validated_score/run:      \(.avg_validated_score | . * 100 | round / 100)",
	"Avg deliveries/run:           \(.avg_deliveries_per_run | . * 100 | round / 100)"
' <<<"$runs_stats"
echo "================================================="
