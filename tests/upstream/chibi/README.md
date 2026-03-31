# Vendored Official Suite

This directory contains a repo-owned snapshot of the Chibi Scheme test corpus that Psil uses for official compatibility reporting.

Fast paths:

```bash
lua tests/run.lua
lua tools/chibi_full_suite.lua
```

The first command is Psil's curated green suite.  
The second command is the vendored official compatibility report and currently runs:

- `r5rs-tests.scm`
- `division-tests.scm`
- `syntax-tests.scm`
- `unicode-tests.scm`

Long raw runs:

```bash
lua tools/chibi_full_suite.lua tests/upstream/chibi/r7rs-tests.scm
lua tools/chibi_full_suite.lua --all
```

Notes:

- The curated test tree is split into `tests/core`, `tests/curated`, `tests/support`, and `tests/upstream`.
- The fast vendored official report is fully green right now.
- `r7rs-tests.scm` and `lib-tests.scm` are still useful explicit compatibility probes, but they are not part of the default fast path.
- You can override the vendored root with `CHIBI_SUITE_ROOT=/path/to/tests`.
