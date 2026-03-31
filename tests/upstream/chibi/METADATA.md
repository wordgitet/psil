# Chibi Snapshot

These files are vendored from the Chibi Scheme upstream test suite.

- Upstream repository: `https://github.com/ashinn/chibi-scheme`
- Snapshot commit: `a227a8334a8eb32f50a7dd4008ce8245cbb4f384`
- Vendored on: `2026-03-30`

Included here:

- `r5rs-tests.scm`
- `r7rs-tests.scm`
- `syntax-tests.scm`
- `unicode-tests.scm`
- `lib-tests.scm`
- `division-tests.scm`
- `basic/`
- `COPYING`

License:

- See [COPYING](/home/mario/proj/lisp-luau/tests/upstream/chibi/COPYING)

Notes:

- Psil's raw-suite runner is in [tools/chibi_full_suite.luau](/home/mario/proj/lisp-luau/tools/chibi_full_suite.luau).
- The fast default official report uses the vendored `r5rs`, `division`, `syntax`, and `unicode` files.
- `r7rs-tests.scm` is vendored too, but it is still a long-running compatibility report and is best run explicitly.
