// context-mode-stats.mjs — read this run's byte counters out of the
// context-mode 2.x stores, for container/context-mode-summary.sh.
//
//   node context-mode-stats.mjs <data-root> <agent> [<watermark-json> | --seq-only]
//
// <data-root> is ~/.context-mode. Every <data-root>/projects/<key>/context.db
// is read; a session's stores all belong to its project set, because the
// directory is a per-project-set mount. <agent> is upstream's agent id
// (claude-code, opencode, pi): only rows that agent wrote are counted.
// <watermark-json> maps a store's <key> to the AUTOINCREMENT counter it had
// when the run started; rows above it are this run's. Absent, or a key missing
// from it, means 0: everything in that store is this run's.
//
// --seq-only prints {"seq": {...}} alone: the start read needs only the
// watermark, and it sits in front of the agent, so it skips the counter query.
//
// Prints one line of JSON and exits 0:
//   {"seq": {<key>: <counter>, ...},   the watermark to pass at exit
//    "kept_out": n, "re_read": n, "calls": n,   rows above the watermark
//    "total_kept_out": n,               kept_out over every row in the stores
//    "rewound": bool}                   a store's counter is below its
//                                       watermark: it was recreated and has
//                                       not grown past the old counter yet. A
//                                       recreated store that already has is
//                                       not detected, and its rows above the
//                                       watermark are counted as the run's
// Exits 1, printing nothing on stdout, when there is no store or when the
// watermark is not a map of non-negative integers. Exits 2 when a store cannot
// be read (locked past the busy timeout, corrupt, not a 2.x store), with one
// stderr line "<path>: <reason>" for the caller to report. One unreadable
// store fails the whole read: skipping it would under-count without a word.
//
// What counts, and why, is in the header of container/context-mode-summary.sh.
import { DatabaseSync } from "node:sqlite";
import { existsSync, readdirSync } from "node:fs";
import { join } from "node:path";

// Per store. The shell caller bounds the whole read with `timeout`; this keeps
// one locked store from spending all of that budget.
const BUSY_TIMEOUT_MS = 1000;

// One pass over the rows that are tool calls (cost and prompt rows are not).
//   kept_out  bytes a call produced and the model did not receive, clamped
//             per row, over work calls only: not the diagnostic tools, not
//             ctx_index (its bytes can be content the model wrote into the
//             call), and not the two retrieval tools
//   re_read   bytes ctx_search and ctx_resume brought back from the store
//   calls     every journalled tool call, as proof that the hooks fired
// 2.x journals only shell commands, edits, tool errors and ctx_* calls. A
// clean Read, Grep or WebFetch gets no row even when its output is replaced,
// so those savings are not here: kept_out is a lower bound.
const COUNTERS = `
SELECT
  COALESCE(SUM(CASE WHEN tool NOT IN ('ctx_stats', 'ctx_doctor', 'ctx_upgrade', 'ctx_purge',
                                      'ctx_index', 'ctx_search', 'ctx_resume')
                    THEN MAX(sandbox_bytes - returned_bytes, 0) END), 0) AS kept_out,
  COALESCE(SUM(CASE WHEN tool IN ('ctx_search', 'ctx_resume')
                    THEN returned_bytes END), 0) AS re_read,
  COUNT(*) AS calls
FROM events
WHERE seq > ? AND agent = ? AND tool IS NOT NULL AND kind <> 'cost'`;

// The AUTOINCREMENT counter, not MAX(seq): ctx_purge deletes rows but leaves
// the counter, so MAX(seq) can fall below a watermark the counter never will.
const SEQUENCE = "SELECT seq FROM sqlite_sequence WHERE name = 'events'";

function fail(message, code = 1) {
  process.stderr.write(`${code === 2 ? "" : "context-mode-stats: "}${message}\n`);
  process.exit(code);
}

const [root, agent, third] = process.argv.slice(2);
if (!root || !agent) fail("usage: context-mode-stats.mjs <data-root> <agent> [<watermark-json> | --seq-only]");
const seqOnly = third === "--seq-only";
const watermarkArg = seqOnly || third === undefined ? "{}" : third;

let watermark;
try {
  watermark = JSON.parse(watermarkArg);
} catch {
  fail("the watermark is not JSON");
}
if (watermark === null || typeof watermark !== "object" || Array.isArray(watermark)) fail("the watermark is not an object");
for (const [key, value] of Object.entries(watermark)) {
  if (!Number.isSafeInteger(value) || value < 0) fail(`the watermark for ${key} is not a non-negative integer`);
}

let entries;
try {
  entries = readdirSync(join(root, "projects"), { withFileTypes: true });
} catch {
  fail("no projects directory");
}
const stores = entries
  .filter((e) => e.isDirectory())
  .map((e) => ({ key: e.name, path: join(root, "projects", e.name, "context.db") }))
  .filter((s) => existsSync(s.path));
if (stores.length === 0) fail("no store");

const out = seqOnly ? { seq: {} } : { seq: {}, kept_out: 0, re_read: 0, calls: 0, total_kept_out: 0, rewound: false };
for (const { key, path } of stores) {
  let db;
  try {
    db = new DatabaseSync(path, { readOnly: true, timeout: BUSY_TIMEOUT_MS });
    // One read transaction, so the counter and the sums see one snapshot.
    db.exec("BEGIN");
    const seq = db.prepare(SEQUENCE).get()?.seq ?? 0;
    out.seq[key] = seq;
    if (seqOnly) {
      db.exec("COMMIT");
      continue;
    }
    const mark = watermark[key] ?? 0;
    const counters = db.prepare(COUNTERS);
    const run = counters.get(mark, agent);
    const all = counters.get(0, agent);
    db.exec("COMMIT");
    if (seq < mark) out.rewound = true;
    out.kept_out += run.kept_out;
    out.re_read += run.re_read;
    out.calls += run.calls;
    out.total_kept_out += all.kept_out;
  } catch (err) {
    fail(`${path}: ${err.message}`, 2);
  } finally {
    db?.close();
  }
}
process.stdout.write(JSON.stringify(out) + "\n");
