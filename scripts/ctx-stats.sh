#!/usr/bin/env bash
# ctx-stats.sh — aggregate Context Mode run records written at session exit.
#
# Reads the ledger `scripts/mount-projects.sh` mounts into each session
# (one JSON file per run, schema in
# docs/design/2026-07-30-context-mode-rollup-design.md) and reports what the
# feature actually withheld over time. Runs entirely on the host: no container
# is started, and the session stores are never touched.
#
# Why this exists rather than a scan of the stores: upstream prunes
# session_events after seven days (cleanupOldSessions(7), hardcoded), so the
# counters cannot be re-derived later. The records are the only durable copy.
#
# -E (errtrace): without it the ERR trap is NOT inherited by functions or
# subshells, so a failure inside a helper would exit silently with no line
# number.
set -Eeuo pipefail
trap 'echo "ctx-stats: failed at line ${LINENO}" >&2' ERR

ROOT_DIR="${ROOT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

# _humanize_bytes lives with the exit report and is reused verbatim so this
# command and the on-screen summary never render the same number differently.
# Sourcing that file is side-effect free by design (see its header).
# shellcheck source=../container/context-mode-summary.sh disable=SC1091
source "${ROOT_DIR}/container/context-mode-summary.sh"

LEDGER_DIR="${RIOTBOX_CONTEXT_LEDGER:-${XDG_DATA_HOME:-${HOME}/.local/share}/riotbox-context-mode}/runs"
AS_JSON=0
VIEW="aggregate"
# Tracks whether VIEW was set by an explicit selector (--by-project/--runs)
# rather than left at its default, so a second, different selector can be
# rejected instead of silently discarding an argument the user typed.
VIEW_CHOSEN=0

usage() {
	cat <<'EOF'
Usage: riotbox ctx-stats [options]

Aggregate Context Mode run records recorded at session exit.

Options:
  --by-project        Group totals by project set
  --runs [N|all]      Per-run table, newest first (default 20)
  --json              Emit the aggregation as JSON
  --ledger-dir DIR    Read records from DIR (default: the mounted ledger)
  -h, --help          Show this help

Ledger location: $RIOTBOX_CONTEXT_LEDGER, else
                 ${XDG_DATA_HOME:-~/.local/share}/riotbox-context-mode/runs
EOF
}

# "1 run" reads as an error report when it says "1 runs". Shared by every
# plural word this report prints (runs, records), not just the run count.
_plural() { [[ "$1" -eq 1 ]] && printf '%s' "$2" || printf '%s' "$3"; }

# Shared by all three views' empty-ledger path (aggregate, --by-project,
# --runs): each one can find zero rows for a different reason (no records at
# all, or every record present was excluded/newer/skipped from that view's
# grouping), but the message and the disclosure of why are identical, so one
# definition keeps them from drifting into three different wordings for the
# same state. Reads skipped/newer_schema/LEDGER_DIR from the caller's scope,
# matching this script's existing convention of global rather than passed
# state (see LEDGER_DIR/AS_JSON above).
_print_empty_state() {
	if [[ "${skipped}" -gt 0 || "${newer_schema}" -gt 0 ]]; then
		echo "no readable runs recorded yet"
	else
		echo "no runs recorded yet"
	fi
	if [[ "${newer_schema}" -gt 0 ]]; then
		printf '%s %s from a newer schema (upgrade riotbox)\n' \
			"${newer_schema}" "$(_plural "${newer_schema}" record records)"
	fi
	if [[ "${skipped}" -gt 0 ]]; then
		printf '%s %s skipped (unreadable)\n' "${skipped}" "$(_plural "${skipped}" file files)"
	fi
	echo "ledger: ${LEDGER_DIR}"
}

# Shared by all three views' populated path: skipped/newer-schema files are
# not specific to any one grouping, so every view that prints rows must
# disclose them the same way the aggregate view always has — a by-project or
# per-run table that stayed silent about them would silently regress the
# disclosure guarantee _print_empty_state already enforces for the zero-rows
# case.
_print_disclosures() {
	if [[ "${newer_schema}" -gt 0 ]]; then
		printf ' %s %s from a newer schema (upgrade riotbox)\n' \
			"${newer_schema}" "$(_plural "${newer_schema}" record records)"
	fi
	if [[ "${skipped}" -gt 0 ]]; then
		printf ' %s %s skipped (unreadable)\n' "${skipped}" "$(_plural "${skipped}" file files)"
	fi
}

while [[ $# -gt 0 ]]; do
	case "$1" in
	--by-project)
		# --by-project and --runs are mutually exclusive view selectors, not
		# repeatable valueless flags: silently letting the second one win
		# would discard an argument (e.g. the "5" in `--runs 5 --by-project`)
		# with no cue that it was ignored.
		if [[ "${VIEW_CHOSEN}" -eq 1 && "${VIEW}" != "by-project" ]]; then
			echo "ctx-stats: choose one of --by-project or --runs" >&2
			exit 2
		fi
		VIEW="by-project"
		VIEW_CHOSEN=1
		shift
		;;
	--runs)
		if [[ "${VIEW_CHOSEN}" -eq 1 && "${VIEW}" != "runs" ]]; then
			echo "ctx-stats: choose one of --by-project or --runs" >&2
			exit 2
		fi
		shift
		VIEW="runs"
		VIEW_CHOSEN=1
		RUNS_LIMIT=20
		# The count is optional, so only consume the next argument when it
		# looks like one — otherwise `--runs --json` would eat the flag.
		# 0 is syntactically a count but not a meaningful one: it would slice
		# to an empty array and fall into the empty-ledger message, falsely
		# claiming "no runs recorded" against a ledger that has some — reject
		# it here rather than let the view lie about why it printed nothing.
		if [[ "${1:-}" == "all" ]]; then
			RUNS_LIMIT="all"
			shift
		elif [[ "${1:-}" =~ ^[0-9]+$ ]]; then
			if [[ "$1" -eq 0 ]]; then
				echo "ctx-stats: --runs 0 is not a valid row count" >&2
				exit 2
			fi
			RUNS_LIMIT="$1"
			shift
		fi
		;;
	--json)
		AS_JSON=1
		shift
		;;
	--ledger-dir)
		if [[ -z "${2:-}" ]]; then
			echo "ctx-stats: --ledger-dir requires a directory" >&2
			exit 2
		fi
		LEDGER_DIR="$2"
		shift 2
		;;
	-h | --help)
		usage
		exit 0
		;;
	*)
		echo "ctx-stats: unknown option '$1'" >&2
		usage >&2
		exit 2
		;;
	esac
done

# Collect valid records into one stream, counting what could not be read and,
# separately, what came from a schema this reader does not recognize. Folding
# either into the other bucket corrupts a total: a skipped 5 MB record
# silently vanishes from "kept out", and calling a newer schema "unreadable"
# implies corruption when the actual fix is "upgrade riotbox".
#
# The schema check is strict equality (.schema == 1), not `has("schema")`: a
# schema-2 record with renamed fields still has a `schema` key, so
# `has("schema")` alone would let it reach the reduce below, where `// 0`
# would render its absent kept_out_bytes as a run that saved nothing while its
# actual bytes vanish from the total — confidently wrong rather than visibly
# excluded.
#
# A record is valid only when it is schema 1, ended_at is a string (first/last
# ordering below is a string comparison; a non-string would poison it silently
# rather than sort predictably), project_set is a non-empty string (--by-project
# and --runs group and print it as a bare field via `IFS=$'\t' read`, which
# collapses an empty column and shifts every field after it — the same "poison
# it silently rather than fail visibly" exposure as ended_at, just discovered
# later), AND — when baseline_unknown is false — the three delta fields are
# actually numbers. baseline_unknown:false is this schema's promise that those
# deltas were measured; null deltas paired with that promise break the
# promise, and are not a genuine zero-saving run. The `// 0` fallback in the
# aggregation below would otherwise launder such a record into one.
# baseline_unknown:true records skip that delta check because the writer
# (context_mode_ledger_append) deliberately pairs it with null deltas — a
# recorded-but-unmeasured run, not malformed input.
STREAM="$(mktemp)"
trap 'rm -f "${STREAM}"' EXIT
skipped=0
newer_schema=0
if [[ -d "${LEDGER_DIR}" ]]; then
	while IFS= read -r -d '' record_file; do
		class="$(jq -r '
			if (type == "object") and (.schema == 1) and
			   ((.ended_at | type) == "string") and
			   ((.project_set | type) == "string") and (.project_set != "") and
			   ((.baseline_unknown == true) or
			    ((.baseline_unknown == false) and
			     ((.kept_out_bytes | type) == "number") and
			     ((.re_read_bytes | type) == "number") and
			     ((.hook_log_bytes | type) == "number")))
			then "valid"
			elif (type == "object") and ((.schema | type) == "number") and (.schema > 1)
			then "newer"
			else "skip"
			end' "${record_file}" 2>/dev/null)" || class="skip"
		case "${class}" in
		valid)
			cat "${record_file}" >> "${STREAM}"
			;;
		newer)
			newer_schema=$((newer_schema + 1))
			;;
		*)
			skipped=$((skipped + 1))
			;;
		esac
	done < <(find "${LEDGER_DIR}" -maxdepth 1 -type f -name '*.json' -print0 2>/dev/null | sort -z)
fi

case "${VIEW}" in
aggregate)
	# One reduce over the stream rather than a slurp: the file count is
	# unbounded and every field needed is a running total. An empty STREAM
	# (no valid records, including "no ledger directory at all") runs the
	# reduce zero times and returns the initial state as-is — the same shape
	# a populated ledger produces, just zeroed, so `--json` never has two
	# different contracts for "no runs" and "some runs".
	AGG="$(jq -n --argjson skipped "${skipped}" --argjson newer "${newer_schema}" '
		reduce inputs as $r (
			{runs: 0, measured: 0, excluded: 0, zero_saving: 0,
			 kept: 0, reread: 0, hooklog: 0, first: null, last: null};
			.runs += 1
			| .first = (if .first == null or $r.ended_at < .first then $r.ended_at else .first end)
			| .last  = (if .last  == null or $r.ended_at > .last  then $r.ended_at else .last  end)
			| if $r.baseline_unknown == true then .excluded += 1
			  else
				.measured += 1
				| .kept    += ($r.kept_out_bytes // 0)
				| .reread  += ($r.re_read_bytes // 0)
				| .hooklog += ($r.hook_log_bytes // 0)
				| (if ($r.kept_out_bytes // 0) == 0 then .zero_saving += 1 else . end)
			  end
		) + {skipped_files: $skipped, newer_schema_files: $newer}' < "${STREAM}")"

	if [[ "${AS_JSON}" -eq 1 ]]; then
		printf '%s\n' "${AGG}"
		exit 0
	fi

	# Bash cannot index JSON, and six separate jq calls would read the
	# aggregate six times; one tab-separated line keeps it to a single pass.
	# `measured` is part of the AGG/--json contract but this text report
	# derives nothing from it directly, so it is read into `_` rather than an
	# unused named variable.
	IFS=$'\t' read -r runs _ excluded zero_saving kept reread hooklog first last <<<"$(
		jq -r '[.runs, .measured, .excluded, .zero_saving, .kept, .reread, .hooklog,
		        (.first // "-"), (.last // "-")] | @tsv' <<<"${AGG}"
	)"

	if [[ "${runs}" -eq 0 ]]; then
		# "no runs recorded yet" implies an empty ledger. That's misleading
		# when records exist but were all excluded from the count below it —
		# _print_empty_state says so instead of leaving the two lines to
		# contradict each other.
		_print_empty_state
		exit 0
	fi

	printf '── context-mode rollup ──────────────────────────────\n'
	printf ' %s %s  %s → %s\n' "${runs}" "$(_plural "${runs}" run runs)" "${first%T*}" "${last%T*}"
	printf ' kept out  %s\n' "$(_humanize_bytes "${kept}")"
	printf ' re-read   %s\n' "$(_humanize_bytes "${reread}")"
	printf ' hook log  %s (disk, not tokens)\n' "$(_humanize_bytes "${hooklog}")"
	printf ' %s %s saved nothing\n' "${zero_saving}" "$(_plural "${zero_saving}" run runs)"
	if [[ "${excluded}" -gt 0 ]]; then
		printf ' %s %s excluded (baseline unknown)\n' "${excluded}" "$(_plural "${excluded}" run runs)"
	fi
	_print_disclosures
	printf ' ledger: %s\n' "${LEDGER_DIR}"
	;;

by-project)
	# jq -s slurps the whole valid stream into memory. That is fine here
	# (unlike the aggregate's `reduce inputs`) because the working set this
	# grouping needs is bounded by the number of distinct project sets, not
	# by the ledger's total size.
	BY_PROJECT="$(jq -s '
		group_by(.project_set)
		| map({
			project_set: .[0].project_set,
			runs: length,
			measured: (map(select(.baseline_unknown != true)) | length),
			kept: (map(select(.baseline_unknown != true) | (.kept_out_bytes // 0)) | add // 0)
		  })
		| sort_by(-.kept)
	' < "${STREAM}")"

	if [[ "${AS_JSON}" -eq 1 ]]; then
		printf '%s\n' "${BY_PROJECT}"
		exit 0
	fi

	if [[ "$(jq 'length' <<<"${BY_PROJECT}")" -eq 0 ]]; then
		_print_empty_state
		exit 0
	fi

	printf '── context-mode by project ────────────────────────────\n'
	while IFS=$'\t' read -r project_set runs measured kept; do
		# A project whose every run is baseline_unknown has nothing measured
		# to sum — "0 B" there would read as "measured and saved nothing",
		# the same fabricated-figure mistake --runs avoids for a single
		# unmeasured run.
		if [[ "${measured}" -eq 0 ]]; then
			display="unmeasured"
		else
			display="$(_humanize_bytes "${kept}")"
		fi
		printf ' %-20s %s %-4s  %s\n' "${project_set}" "${runs}" \
			"$(_plural "${runs}" run runs)" "${display}"
	done < <(jq -r '.[] | [.project_set, .runs, .measured, .kept] | @tsv' <<<"${BY_PROJECT}")
	_print_disclosures
	printf ' ledger: %s\n' "${LEDGER_DIR}"
	;;

runs)
	# Same "bounded working set" reasoning as --by-project: the array this
	# sorts is capped by RUNS_LIMIT (or, for `all`, by the ledger itself,
	# which the aggregate view already treats as safe to hold as one JSON
	# document turn-around, just not to *reduce* one record at a time).
	RUNS_JSON="$(jq -s --arg limit "${RUNS_LIMIT}" '
		sort_by(.ended_at) | reverse
		| (if $limit == "all" then . else .[0:($limit | tonumber)] end)
		| map({ended_at, project_set, session_id, kept_out_bytes, baseline_unknown})
	' < "${STREAM}")"

	if [[ "${AS_JSON}" -eq 1 ]]; then
		printf '%s\n' "${RUNS_JSON}"
		exit 0
	fi

	if [[ "$(jq 'length' <<<"${RUNS_JSON}")" -eq 0 ]]; then
		_print_empty_state
		exit 0
	fi

	printf '── context-mode runs ────────────────────────────────\n'
	while IFS=$'\t' read -r ended project_set kept unknown; do
		if [[ "${unknown}" == "true" ]]; then
			display="baseline unknown"
		else
			display="$(_humanize_bytes "${kept}")"
		fi
		printf ' %s  %-20s  %s\n' "${ended}" "${project_set}" "${display}"
	done < <(jq -r '.[] | [.ended_at, .project_set, (.kept_out_bytes // 0), (.baseline_unknown | tostring)] | @tsv' <<<"${RUNS_JSON}")
	_print_disclosures
	printf ' ledger: %s\n' "${LEDGER_DIR}"
	;;
esac
