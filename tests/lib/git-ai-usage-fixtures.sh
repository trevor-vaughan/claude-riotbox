#!/usr/bin/env bash
# git-ai-usage-fixtures.sh — write two `git ai usage --json` fixtures into $1.
#
# Shapes match a real `git ai usage --json` (captured from git-ai 1.7.4), not
# the abbreviated table in the design spec: tokens.by_model and repos are arrays
# of OBJECTS rather than [key, count] pairs, and tokens.wow_spend and
# cache_hit_ratio are derived fields the spec's table never mentions.
#
# Deliberately asymmetric, because a merge that sums where it should recompute
# gives the right answer whenever both inputs are identical:
#   - different magnitudes throughout (B is roughly 3x A)
#   - tools/models/repos/buckets that overlap PARTIALLY, so both the
#     "sum the shared key" and "keep the unshared key" paths are exercised
#   - calendars that abut: A covers 09-01..09-02, B covers 09-02..09-03, so the
#     overlap day must be summed and the merged run is a 3-day streak that
#     neither input contains
set -euo pipefail

out="${1:?usage: git-ai-usage-fixtures.sh <output-dir>}"
mkdir -p "${out}"

# hourly is 24 slots and daily is 7; both merge index-wise, so the fixtures
# populate one slot each and leave the rest zero.
hourly_a="$(jq -nc '[range(24)] | map(0) | .[3] = 3')"
hourly_b="$(jq -nc '[range(24)] | map(0) | .[3] = 4')"
daily_a="$(jq -nc '[range(7)] | map(0) | .[0] = 1')"
daily_b="$(jq -nc '[range(7)] | map(0) | .[0] = 3')"

jq -n --argjson hourly "${hourly_a}" --argjson daily "${daily_a}" '{
  period_label: "last 7 days",
  calendar_start: "2026-09-01",
  calendar_end: "2026-09-07",
  commits: {
    total: 2, ai_lines: 100, human_lines: 10, diff_added_lines: 110,
    by_tool: [["claude", 100]],
    acceptance_by_tool: [["claude", 80]]
  },
  checkpoints: { total: 5, ai_lines_added: 120, human_lines_added: 5, files_edited: 3 },
  sessions: {
    total: 3,
    by_tool: [["claude", 3]],
    yield_stats: { shipped: 1, abandoned: 2 }
  },
  tokens: {
    input: 50, output: 100, cache_read: 150, cache_creation: 50,
    estimated_cost_usd: 1.5,
    by_model: [
      { model: "m-shared", sessions: 2, input: 50, output: 100,
        cache_read: 150, cache_creation: 50, estimated_cost_usd: 1.5,
        cache_hit_ratio: 0.75 }
    ],
    wow_spend: { this_week_usd: 11, last_week_usd: 10, change_pct: 10, new_this_week: false }
  },
  repos: [
    { repo_url: "r-shared", ai_lines: 100, commits: 2, sessions: 3, estimated_cost_usd: 1.5 }
  ],
  buckets: [
    { label: "week-1", ai_lines: 100, attributed_lines: 90, commit_count: 2, diff_added_lines: 110 }
  ],
  hourly: $hourly,
  daily: $daily,
  calendar: [
    { date: "2026-09-01", ai_lines: 50,  estimated_cost_usd: 0.5 },
    { date: "2026-09-02", ai_lines: 100, estimated_cost_usd: 1.0 }
  ],
  summary: {
    active_days: 2, total_days: 7, longest_streak: 2, current_streak: 1,
    most_active_day: { date: "2026-09-02", ai_lines: 100, estimated_cost_usd: 1.0 },
    longest_session_secs: 600,
    favorite_model: "m-shared"
  }
}' >"${out}/a.json"

jq -n --argjson hourly "${hourly_b}" --argjson daily "${daily_b}" '{
  period_label: "last 7 days",
  calendar_start: "2026-09-01",
  calendar_end: "2026-09-07",
  commits: {
    total: 4, ai_lines: 300, human_lines: 20, diff_added_lines: 320,
    by_tool: [["claude", 200], ["codex", 100]],
    acceptance_by_tool: [["claude", 60], ["codex", 90]]
  },
  checkpoints: { total: 10, ai_lines_added: 380, human_lines_added: 15, files_edited: 7 },
  sessions: {
    total: 6,
    by_tool: [["claude", 4], ["codex", 2]],
    yield_stats: { shipped: 3, abandoned: 3 }
  },
  tokens: {
    input: 200, output: 500, cache_read: 300, cache_creation: 0,
    estimated_cost_usd: 3.0,
    by_model: [
      { model: "m-shared", sessions: 3, input: 150, output: 400,
        cache_read: 300, cache_creation: 0, estimated_cost_usd: 2.5,
        cache_hit_ratio: 1.0 },
      { model: "m-b", sessions: 1, input: 50, output: 100,
        cache_read: 20, cache_creation: 5, estimated_cost_usd: 0.5,
        cache_hit_ratio: 0.8 }
    ],
    wow_spend: { this_week_usd: 22, last_week_usd: 12, change_pct: 83, new_this_week: false }
  },
  repos: [
    { repo_url: "r-shared", ai_lines: 200, commits: 3, sessions: 4, estimated_cost_usd: 2.0 },
    { repo_url: "r-b",      ai_lines: 100, commits: 1, sessions: 2, estimated_cost_usd: 1.0 }
  ],
  buckets: [
    { label: "week-1", ai_lines: 200, attributed_lines: 180, commit_count: 3, diff_added_lines: 210 },
    { label: "week-2", ai_lines: 100, attributed_lines: 90,  commit_count: 1, diff_added_lines: 110 }
  ],
  hourly: $hourly,
  daily: $daily,
  calendar: [
    { date: "2026-09-02", ai_lines: 150, estimated_cost_usd: 1.5 },
    { date: "2026-09-03", ai_lines: 60,  estimated_cost_usd: 0.6 }
  ],
  summary: {
    active_days: 2, total_days: 7, longest_streak: 2, current_streak: 1,
    most_active_day: { date: "2026-09-02", ai_lines: 150, estimated_cost_usd: 1.5 },
    longest_session_secs: 900,
    favorite_model: "m-shared"
  }
}' >"${out}/b.json"
