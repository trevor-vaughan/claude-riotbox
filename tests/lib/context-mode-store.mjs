// Test fixture driver for context-mode 2.x stores, called through
// tests/lib/context-mode-store-helpers.sh; see that file for why the suites
// build stores this way rather than through the real hook.
//
//   rows  <db> <json-array>  create <db> from the fixture schema when absent
//                            (WAL, as upstream opens it), then insert one
//                            events row per element
//   source <db> <json-array> as rows, into sources: what a replaced Read,
//                            Grep or WebFetch output leaves behind (2.x writes
//                            no events row for one)
//   purge <db>               DELETE FROM events, as ctx_purge does: the
//                            AUTOINCREMENT counter in sqlite_sequence survives
//   lock  <db> <ms>          hold an exclusive lock for <ms>, printing
//                            "locked" once readers are shut out
import { DatabaseSync } from "node:sqlite";
import { existsSync, mkdirSync, readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const SCHEMA = join(dirname(fileURLToPath(import.meta.url)), "..", "fixtures", "context-mode-2-events.sql");
const [op, db, arg] = process.argv.slice(2);

function open() {
  const fresh = !existsSync(db);
  mkdirSync(dirname(db), { recursive: true });
  const d = new DatabaseSync(db);
  d.exec("PRAGMA journal_mode = WAL");
  if (fresh) d.exec(readFileSync(SCHEMA, "utf8"));
  return d;
}

if (op === "rows") {
  const d = open();
  const insert = d.prepare(
    "INSERT INTO events (session_id, worktree, agent, kind, tool, turn, sandbox_bytes, returned_bytes, created_at, accessed_at) " +
      "VALUES (?, '/workspace', ?, ?, ?, 1, ?, ?, ?, ?)",
  );
  const now = Date.now();
  for (const r of JSON.parse(arg)) {
    insert.run(r.session_id, r.agent, r.kind ?? "cmd", r.tool ?? null, r.sandbox_bytes ?? 0, r.returned_bytes ?? 0, now, now);
  }
  d.close();
} else if (op === "source") {
  const d = open();
  const insert = d.prepare(
    "INSERT INTO sources (session_id, worktree, agent, kind, label, bytes_total, chunk_count, created_ts, created_at, accessed_ts) " +
      "VALUES (?, '/workspace', ?, ?, ?, ?, ?, ?, ?, ?)",
  );
  const now = Date.now();
  for (const r of JSON.parse(arg)) {
    insert.run(r.session_id, r.agent, r.kind ?? "content", r.label, r.bytes_total, r.chunk_count ?? 1, now, new Date(now).toISOString(), now);
  }
  d.close();
} else if (op === "purge") {
  const d = new DatabaseSync(db);
  d.exec("DELETE FROM events");
  d.close();
} else if (op === "lock") {
  const d = new DatabaseSync(db);
  d.exec("PRAGMA locking_mode = EXCLUSIVE; BEGIN EXCLUSIVE; UPDATE events SET turn = turn;");
  process.stdout.write("locked\n");
  setTimeout(() => {
    d.exec("COMMIT");
    d.close();
  }, Number(arg));
} else {
  process.stderr.write("usage: context-mode-store.mjs rows|source|purge|lock <db> [arg]\n");
  process.exit(2);
}
