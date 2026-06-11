---
description: Migrate the next pending feature from myHammerSpoon into hammerdeck (one item per run; loop-friendly)
---

Migrate exactly ONE item from the queue in `docs/MIGRATION.md`.

1. Read `docs/MIGRATION.md` first -- it is the shared state and the protocol.
   Obey the "Loop policies" section literally (commit policy, daily-driver
   gate, verification suite). Pick the first `pending` item whose
   prerequisites ("after #N") are met. If none is `pending`, summarize the
   final state and STOP -- do not reschedule the loop.
2. Execute the "Migration protocol" section of that doc for the chosen item:
   read the donor source in `~/workspaces/git/myHammerSpoon` in full, extend
   the seam (Native.swift + adapter.lua + fake_adapter.lua) only as needed,
   port the feature onto the manifest/ctx contract, add test coverage, verify
   everything green (`luac -p`, `lua test/run.lua`, `swift build`, smoke boot,
   `HAMMERDECK_DUMP_CATALOG=1`).
3. Update `docs/MIGRATION.md` (row status/date/notes, "Needs human
   verification" additions) and `docs/HANDOVER.md` M5. Commit per policy.
4. End your turn with a 2-4 sentence report: what landed, what's verified,
   what needs the human, what's next in the queue.

Hard rules: one item per run. Never edit myHammerSpoon except the retirement
comments allowed by the daily-driver gate. Never touch `Sources/CLua/`. If the
item turns out bigger than one iteration, land a coherent verified sub-step,
keep the row `pending` with a progress note, and end the turn.
