# git-ai-merge.jq — merge several `git ai usage --json` documents into one.
#
# Run as:  jq -s -f git-ai-merge.jq store1.json store2.json ...
#
# WHY THIS IS NOT A DEEP MERGE
# ----------------------------
# `git ai usage --json` reports DERIVED aggregates, not raw rows. Summing every
# number produces a document that is internally inconsistent and confidently
# wrong: ratios exceed 1, percentages exceed 100, and streaks become longer than
# the window. Each field class needs its own rule, and three classes cannot be
# combined from the summands at all — they have to be recomputed from the merged
# data underneath them:
#
#   ratios      cache_hit_ratio, wow_spend.change_pct
#   streaks     longest_streak, current_streak, active_days, most_active_day
#   extrema     longest_session_secs, favorite_model
#
# The design spec's merge table describes tokens.by_model and repos as
# [key, count] pairs. They are not — in git-ai 1.7.4 both are arrays of objects
# with several numeric members each, and the spec's table omits wow_spend and
# cache_hit_ratio entirely. This file follows the observed schema.

# ── Window guard ────────────────────────────────────────────────────────────
# Totals over two different windows describe no real period, so a disagreement
# is fatal rather than something to reconcile. Checked first: every rule below
# assumes the documents cover the same span.
def guard_window:
  (map(.period_label) | unique) as $labels
  | (map(.calendar_start) | unique) as $starts
  | (map(.calendar_end) | unique) as $ends
  | if ($labels | length) > 1 then
      error("period_label disagrees across stores: \($labels | map(tostring) | join(" vs "))")
    elif ($starts | length) > 1 then
      error("period boundary calendar_start disagrees across stores: \($starts | map(tostring) | join(" vs "))")
    elif ($ends | length) > 1 then
      error("period boundary calendar_end disagrees across stores: \($ends | map(tostring) | join(" vs "))")
    else . end;

# ── Building blocks ─────────────────────────────────────────────────────────
def nsum(f): map(f // 0) | add // 0;

# [[key, n], ...] — sum per key. A key present in only one store survives;
# an intersection would silently drop a tool nobody else used.
def merge_pairs(f):
  (map(f // []) | add // [])
  | group_by(.[0])
  | map([.[0][0], (map(.[1] // 0) | add)])
  | sort_by(-.[1]);

# [{<key>: ..., <numeric members>}, ...] — group on the identity key and sum
# the named members. Non-numeric members are taken from the first entry in the
# group; anything derived is recomputed by the caller afterwards.
def merge_objects(f; key; fields):
  (map(f // []) | add // [])
  | group_by(.[key])
  | map(
      . as $group
      | reduce (fields[]) as $k ($group[0];
          .[$k] = ($group | map(.[$k] // 0) | add))
    );

# Fixed-length positional arrays (hourly=24, daily=7): add slot by slot.
# Length is taken as the longest input so a short array cannot truncate.
def merge_indexwise(f):
  (map(f // [])) as $arrays
  | ($arrays | map(length) | max // 0) as $n
  | [range($n) as $i | ($arrays | map(.[$i] // 0) | add // 0)];

# ── Calendar and the summary derived from it ────────────────────────────────
def day_number: strptime("%Y-%m-%d") | mktime | (. / 86400) | floor;

# The longest run of consecutive active days anywhere in the merged calendar.
# Cannot be taken from the inputs: two stores each holding a 2-day run that abut
# form a 3-day run that appears in neither, and max() and sum() are both wrong.
def longest_run($days):
  if ($days | length) == 0 then 0
  else
    reduce $days[1:][] as $d
      ({prev: $days[0], run: 1, best: 1};
        if $d == (.prev + 1)
        then {prev: $d, run: (.run + 1), best: ([.best, (.run + 1)] | max)}
        else {prev: $d, run: 1, best: .best}
        end)
    | .best
  end;

# The run ending on the most recent active day. Anchored to the data, not to
# the wall clock: a store reports this relative to "today", which a merged view
# spanning archived sessions has no basis to assume.
def trailing_run($days):
  if ($days | length) == 0 then 0
  else
    ($days | reverse) as $desc
    | reduce $desc[1:][] as $d
        ({prev: $desc[0], run: 1, done: false};
          if .done then .
          elif $d == (.prev - 1) then {prev: $d, run: (.run + 1), done: false}
          else (.done = true)
          end)
      | .run
  end;

# ── Merge ───────────────────────────────────────────────────────────────────
guard_window
| . as $docs
| ($docs
   | (map(.calendar // []) | add // [])
   | group_by(.date)
   | map({
       date: .[0].date,
       ai_lines: (map(.ai_lines // 0) | add),
       estimated_cost_usd: (map(.estimated_cost_usd // 0) | add)
     })
   | sort_by(.date)) as $calendar
| ($calendar | map(select(.ai_lines > 0))) as $active
| ($active | map(.date | day_number) | sort) as $active_days
| ($docs | merge_objects(.tokens.by_model; "model";
     ["sessions", "input", "output", "cache_read", "cache_creation", "estimated_cost_usd"])
   | map(
       # Recomputed, never averaged: a ratio of sums, not a sum of ratios.
       ((.cache_read // 0) + (.cache_creation // 0)) as $denom
       | .cache_hit_ratio = (if $denom > 0 then (.cache_read / $denom) else 0 end)
     )
   | sort_by(-.output)) as $by_model
| ($docs | nsum(.tokens.wow_spend.this_week_usd)) as $this_week
| ($docs | nsum(.tokens.wow_spend.last_week_usd)) as $last_week
| {
    period_label: $docs[0].period_label,
    calendar_start: $docs[0].calendar_start,
    calendar_end: $docs[0].calendar_end,

    commits: {
      total:            ($docs | nsum(.commits.total)),
      ai_lines:         ($docs | nsum(.commits.ai_lines)),
      human_lines:      ($docs | nsum(.commits.human_lines)),
      diff_added_lines: ($docs | nsum(.commits.diff_added_lines)),
      by_tool:          ($docs | merge_pairs(.commits.by_tool)),

      # A percentage, so it is re-derived rather than summed. The exact
      # denominator (per-tool checkpoint lines) is not present in this
      # document, so each store's rate is weighted by that store's session
      # count for the same tool — the closest pooling the data supports, and
      # strictly better than the flat average the spec forbids. Stores that
      # report a tool with no session count are weighted 1 rather than dropped.
      acceptance_by_tool: (
        [ $docs[]
          | . as $doc
          # Built by reduce, not from_entries: these are [key, value] PAIRS,
          # and from_entries only understands {key, value} objects.
          | (reduce ((.sessions.by_tool // [])[]) as $p ({}; .[$p[0]] = $p[1])) as $weights
          | (.commits.acceptance_by_tool // [])[]
          | { tool: .[0],
              pct: (.[1] // 0),
              w: (($weights[.[0]] // 1) | if . <= 0 then 1 else . end) }
        ]
        | group_by(.tool)
        # The inner parens are load-bearing: `[a, x | round]` parses as
        # `[(a, x) | round]`, which rounds the tool NAME and dies.
        | map([ .[0].tool,
                (((map(.pct * .w) | add) / (map(.w) | add)) | round) ])
        | sort_by(-.[1])
      )
    },

    checkpoints: {
      total:             ($docs | nsum(.checkpoints.total)),
      ai_lines_added:    ($docs | nsum(.checkpoints.ai_lines_added)),
      human_lines_added: ($docs | nsum(.checkpoints.human_lines_added)),
      files_edited:      ($docs | nsum(.checkpoints.files_edited))
    },

    sessions: {
      total:   ($docs | nsum(.sessions.total)),
      by_tool: ($docs | merge_pairs(.sessions.by_tool)),
      yield_stats: {
        shipped:   ($docs | nsum(.sessions.yield_stats.shipped)),
        abandoned: ($docs | nsum(.sessions.yield_stats.abandoned))
      }
    },

    tokens: {
      input:              ($docs | nsum(.tokens.input)),
      output:             ($docs | nsum(.tokens.output)),
      cache_read:         ($docs | nsum(.tokens.cache_read)),
      cache_creation:     ($docs | nsum(.tokens.cache_creation)),
      estimated_cost_usd: ($docs | nsum(.tokens.estimated_cost_usd)),
      by_model:           $by_model,
      wow_spend: {
        this_week_usd: $this_week,
        last_week_usd: $last_week,
        # Recomputed from the merged totals. A zero prior week has no
        # percentage change, which is what new_this_week reports instead.
        change_pct: (if $last_week > 0
                     then (($this_week - $last_week) / $last_week) * 100
                     else 0 end),
        new_this_week: (($docs | map(.tokens.wow_spend.new_this_week // false) | any)
                        and $last_week == 0)
      }
    },

    repos: ($docs | merge_objects(.repos; "repo_url";
              ["ai_lines", "commits", "sessions", "estimated_cost_usd"])
            | sort_by(-.ai_lines)),

    buckets: ($docs | merge_objects(.buckets; "label";
               ["ai_lines", "attributed_lines", "commit_count", "diff_added_lines"])
              | sort_by(.label)),

    hourly: ($docs | merge_indexwise(.hourly)),
    daily:  ($docs | merge_indexwise(.daily)),

    calendar: $calendar,

    summary: {
      active_days: ($active | length),
      # The window is shared (guarded above), so this is a property of the
      # period rather than something to accumulate.
      total_days: ($docs[0].summary.total_days // ($docs | map(.summary.total_days // 0) | max)),
      longest_streak: longest_run($active_days),
      current_streak: trailing_run($active_days),
      most_active_day: ($active | sort_by(-.ai_lines) | .[0] // null),
      # An extremum, never a sum: two 10-minute sessions are not one 20-minute
      # session.
      longest_session_secs: ($docs | map(.summary.longest_session_secs // 0) | max),
      # Re-derived from the merged totals rather than taken from whichever
      # store happened to be read first.
      favorite_model: ($by_model | .[0].model // null)
    }
  }
