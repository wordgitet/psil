<!--
SPDX-License-Identifier: MPL-2.0
-->

# Psil Agent Workflow

This repository is a Scheme-first Lisp implementation targeting Luau and Roblox.
Use this file as the project-specific workflow guide before making changes.

## Core Direction

- Treat **Luau as the source of truth**.
- The host `lua` path is a bootstrap/test harness, not the language model to copy from.
- Avoid Lua-only APIs and syntax if Luau/Roblox does not support them.
- Default language direction is **Scheme**.
- Common Lisp work, if added later, should be an explicit compatibility layer or mode, not a silent change to the default dialect.

## Important Mental Model

- `lib/*.luau` is the shared interpreter/runtime core.
- Roblox does **not** sync `lib/` directly through Rojo.
- `generated/roblox/ReplicatedStorage/Psil` is the built Roblox package.
- `roblox/app.client.luau` syncs directly as the Studio app entrypoint.

From `default.project.json`:

- `ReplicatedStorage.Psil` -> `generated/roblox/ReplicatedStorage/Psil`
- `StarterPlayer.StarterPlayerScripts.PsilApp` -> `roblox/app.client.luau`

That means changes to `lib/*.luau` require a rebuild before Studio sees them.

## Required Workflow After Code Changes

### If you change interpreter/runtime code

Examples:

- `lib/*.luau`
- `host/*.luau`
- `tools/*.luau`

Run:

```bash
lua tests/run.lua
lua tools/chibi_full_suite.lua
lune run build_roblox
```

If the change is likely to affect broader Scheme compatibility, also run:

```bash
lua tools/chibi_full_suite.lua tests/upstream/chibi/r7rs-tests.scm
```

### If you change Roblox UI/session code

Examples:

- `roblox/*.luau`

Run:

```bash
selene . --pattern 'roblox/**/*.luau'
lua tests/run.lua
lune run build_roblox
```

Then resync from Rojo in Studio and smoke-test the actual UI flow manually.

## Rojo / Studio Notes

- `rojo serve` alone is not enough when shared runtime code changes.
- After editing `lib/*.luau`, run:

```bash
lune run build_roblox
```

- Then resync in Studio through the Rojo plugin.
- If Studio still shows an old bug after a fix, suspect stale synced code first.

## Test Layout

The test tree is intentionally split into stable categories:

- `tests/core/`
  - handwritten Psil behavior/regression specs
- `tests/curated/`
  - Psil-owned adaptations of external suites
  - `cases/` = data
  - `suites/` = runners
  - `support/` = shared curated helpers
- `tests/support/`
  - generic assertions/helpers
- `tests/upstream/chibi/`
  - vendored raw upstream Chibi Scheme files

Main entrypoints:

```bash
lua tests/run.lua
lua tools/chibi_full_suite.lua
```

## Current Testing Expectations

- `lua tests/run.lua` should stay green.
- `lua tools/chibi_full_suite.lua` should stay green.
- `lua tools/chibi_full_suite.lua tests/upstream/chibi/r7rs-tests.scm` is the heavy compatibility check and should be used when touching broader Scheme semantics.

Do not quietly break the long raw `r7rs` path just because the fast suite still passes.

## Comment Style

- Keep comments sparse and useful.
- Prefer file-header comments and short comments above tricky sections.
- Comment invariants, representation choices, control-flow traps, and standard-compliance tradeoffs.
- Do not add narration for obvious code.

## SPDX Headers

- Repository-owned files should carry an SPDX license header.
- Use the multi-line form appropriate for the file type, not a single-line SPDX comment.
- For Luau/Lua files, prefer a top-of-file block like:

```lua
--[[
SPDX-License-Identifier: MPL-2.0
]]
```

- Apply the same idea to other file types using their native multi-line comment style where possible.
- Do not add or rewrite SPDX headers in vendored upstream files unless explicitly asked.
- When creating new repository-owned files, include the SPDX header from the start.

## Roblox UI / Session Expectations

- Editor output and REPL output are intentionally separate.
- Session entries may carry explicit routing targets such as `editor`, `repl`, or `both`.
- Do not reintroduce UI-side timing guesses for output routing if the session layer already knows the correct target.

## Numeric / Printing Caution

- Be careful with Lua-vs-Luau numeric helpers.
- `math.floor` is safe in Roblox Luau.
- `math.tointeger` is **not** available in Roblox Luau and should not be used in shared code.
- When changing numeric printing or parsing, rerun the long `r7rs` suite because numeric syntax regressions can hide behind otherwise green tests.

## When In Doubt

- Keep the core Scheme-first.
- Prefer correctness and shared semantics over clever host-only shortcuts.
- Verify both the fast suite and the Roblox build path when touching shared code.

## Commit Message Style

Use Linux-kernel-style commit messages for normal commits, adapted to this
repository.

### Normal commits

Format:

```text
subsystem: imperative summary

Explain what changed and why.

Add more detail in wrapped paragraphs when needed.

Areas:
  subsystem: short note for another touched area
  subsystem: short note for another touched area

Test: lua tests/run.lua
Test: lua tools/chibi_full_suite.lua
Signed-off-by: wordgitet <wordatet@linuxmail.org>
```

Rules:

- Use a subsystem-prefixed subject.
- Use imperative mood.
- Do not end the subject with a period.
- Keep the subject short.
- Leave one blank line after the subject.
- Wrap body text to about 72 columns.
- The body should explain both what changed and why.
- If the commit touches multiple meaningful areas, end the body with an
  `Areas:` section.
- Keep `Signed-off-by:` as the last trailer.
- Optional trailers such as `Test:` or `Upstream:` should appear above the
  sign-off when useful.

Recommended subsystem names in this repo:

- `eval`
- `parser`
- `reader`
- `printer`
- `builtins`
- `syntax`
- `value`
- `bigint`
- `host`
- `roblox`
- `tests`
- `tools`
- `build`
- `docs`

Prefer the subsystem that best matches the primary change, even if the patch
touches multiple files.

Good examples:

- `eval: preserve dynamic-wind order on continuation reentry`
- `tests: reorganize curated suite layout`
- `roblox: keep editor errors out of repl history`
- `docs: add repo workflow guide for agents`

Project-specific preferences:

- Mention Roblox rebuilds in the body when shared runtime code changed.
- Mention the long raw `r7rs` run in `Test:` trailers when numeric, reader,
  printer, or broader Scheme semantics changed.
- Do not treat `generated/roblox` as the primary subsystem; describe the source
  area that caused the generated output to change.

### Merge commits

Use the Linux-style merge summary format for merge commits.

Format:

```text
Merge branch 'topic-name'

Merge topic-name updates:

 - summary bullet
 - summary bullet
 - summary bullet

* branch 'topic-name':
  subsystem: first commit subject
  subsystem: second commit subject
  subsystem: third commit subject
```

Rules:

- Do not add `Signed-off-by:` to merge commits unless explicitly required.
- Summarize the merged branch in short bullets.
- List the merged commit subjects at the end.
- Keep the tone close to Linux kernel examples.

If the commit is not a merge commit, use the normal format above.
