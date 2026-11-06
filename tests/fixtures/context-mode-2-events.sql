-- The events and sources tables of a context-mode 2.1.4 store, copied verbatim
-- from the sqlite_master of a context.db the real hook wrote (not transcribed
-- from the TypeScript source), plus the user_version that store carried.
-- container/context-mode-stats.mjs reads only events, and sqlite_sequence,
-- which AUTOINCREMENT creates on its own. sources is here because it is where
-- 2.x records a replaced Read, Grep or WebFetch output — no events row at all —
-- and the suites pin that the reader does not count it.
--
-- The suites build their stores from this file because the test image has no
-- Node 24 and no context-mode package to run the hook with. The image build is
-- what keeps it honest: its Context Mode layer feeds the real hook a canned
-- PostToolUse and runs the stats reader on the store that produces, so an
-- upstream change to these columns fails the build, not just this fixture.
--
-- To regenerate after a version bump, run the real hook once under
-- docker.io/library/node:<CONTEXT_MODE_NODE> with the package mounted at /p and
-- HOME=/tmp/h (see "Producing a real context.db" in docs/dev/context-mode.md),
-- then print the statements:
--   node -e 'const {DatabaseSync}=require("node:sqlite");
--     const d=new DatabaseSync(process.argv[1],{readOnly:true});
--     for (const t of ["events", "sources"])
--       for (const r of d.prepare("SELECT sql FROM sqlite_master WHERE tbl_name = ?").all(t))
--         console.log(r.sql + ";");
--     console.log("PRAGMA user_version = " + d.prepare("PRAGMA user_version").get().user_version + ";")' \
--     /tmp/h/.context-mode/projects/*/context.db
CREATE TABLE events (
  seq            INTEGER PRIMARY KEY AUTOINCREMENT,
  session_id     TEXT NOT NULL,
  worktree       TEXT NOT NULL,
  agent          TEXT NOT NULL,
  kind           TEXT NOT NULL CHECK (kind IN ('prompt','edit','cmd','toolerr','index','cost','decision')),
  tool           TEXT,
  key            TEXT,
  path           TEXT,
  ok             INTEGER,
  exit_code      INTEGER,
  bytes          INTEGER,
  body           TEXT,
  turn           INTEGER NOT NULL,
  sandbox_bytes  INTEGER NOT NULL DEFAULT 0,
  returned_bytes INTEGER NOT NULL DEFAULT 0,
  created_at     INTEGER NOT NULL,
  accessed_at    INTEGER NOT NULL
);
CREATE INDEX idx_events_session_kind_seq ON events(session_id, kind, seq);
CREATE INDEX idx_events_session_kind_key_seq ON events(session_id, kind, key, seq);
CREATE UNIQUE INDEX idx_events_cost_session_turn ON events(session_id, turn) WHERE kind = 'cost';
CREATE TABLE sources (
  id          INTEGER PRIMARY KEY AUTOINCREMENT,
  session_id  TEXT NOT NULL,
  worktree    TEXT NOT NULL,
  agent       TEXT NOT NULL,
  kind        TEXT NOT NULL CHECK (kind IN ('path','content','url')),
  label       TEXT NOT NULL,
  bytes_total INTEGER NOT NULL,
  chunk_count INTEGER NOT NULL,
  created_ts  INTEGER NOT NULL,
  created_at  TEXT NOT NULL,
  accessed_ts INTEGER NOT NULL
);
CREATE INDEX idx_sources_accessed ON sources(accessed_ts);
PRAGMA user_version = 6;
