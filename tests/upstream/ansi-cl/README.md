<!--
SPDX-License-Identifier: MPL-2.0
-->

# ANSI Common Lisp Upstream Suite

This directory contains a vendored snapshot of the upstream ANSI Common Lisp
test suite used as the compatibility target for Psil's `cl-compat` mode.

Psil uses this tree in two ways:

- raw upstream input for `lua tools/ansi_cl_suite.lua`
- explicit CLOS/object-system input for `lua tools/ansi_cl_clos_suite.lua`
- source material for smaller curated CL ANSI core cases under
  `tests/curated/`

The raw runner is intentionally non-gating while the CL mode is being built
out. Scheme remains the default Psil dialect.

There is no separate ANSI-owned CLOS suite in this repository. The closest
standard/de facto source is the object-system portion of the upstream ANSI
suite, primarily `objects/` plus related `types-and-classes/` files.
