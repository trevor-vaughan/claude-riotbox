# Decision records

Why RiotBox is built the way it is. Each record captures what we believed **at
the time it was written**, the evidence behind it, and what we decided.

**These are frozen.** A record is not updated when the code moves on; it is
superseded by a later record, or by the current-state documentation it points to.
If a record and the code disagree, the code is right and the record is history —
which is exactly what makes it worth keeping. Several of these say plainly where
they turned out to be wrong.

| Decision | Date | Outcome |
|---|---|---|
| [Should RiotBox run on OpenShell?](openshell-port.md) | 2026-05-07 | **No** — stay on direct podman; the gap is structural |
| [Should RiotBox adopt Context Mode?](context-mode-adoption.md) | 2026-07-28 | **Yes, opt-in** — one gate still open |
| [Recording Context Mode savings across sessions](context-mode-ledger.md) | 2026-07-30 | **Ship a per-run JSON ledger** plus `riotbox ctx-stats` |
| [Wiring Context Mode for opencode](context-mode-opencode.md) | 2026-07-31 | **Wire it via registry verbs** — no agent names in shared code |
| [Should a pre-session checkpoint be a commit and a tag, or a ref?](checkpoint-snapshots-refs-not-tags.md) | 2026-08-04 | **A ref** — no automatic tags, on-demand `riotbox-snapshot/*` |
| [Should the agent run in a git worktree instead of the user's checkout?](should-the-agent-run-in-a-worktree.md) | 2026-08-04 | **No** — it hides uncommitted work and shares the ref store anyway |

For how the Context Mode integration actually behaves today, read
[../context-mode.md](../context-mode.md) instead of any of the three records
above.

## Open questions

- **The Elastic-2.0 licence gate has never been recorded as a decision.** Context
  Mode was adopted assuming ELv2 is acceptable as the image's one non-OSI
  component. See [context-mode-adoption.md § Decision](context-mode-adoption.md#decision);
  whoever settles it should replace that note with a pointer to the record.
- **Context Mode has never been measured against a real RiotBox session.** It stays
  opt-in until it is.

## Writing a new one

Match the shape of the existing records:

- **Title is the question you were answering,** not the name of the thing.
- **Lead with the decision and the date,** then the evidence.
- **Say what you did not verify.** Every record here distinguishes what was run
  from what was read from source; that distinction is most of their value.
- **Never edit a record to make it right.** Add a correction section, or write a
  new record that supersedes it.
