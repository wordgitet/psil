SPDX-License-Identifier: MPL-2.0
This file is part of Psil.


Psil
====

Psil is a Scheme-first Lisp implementation for Luau and Roblox.

It has a shared interpreter/runtime core, a host runner, a Roblox app, and a
vendored Scheme compatibility suite. The short version is:

- the core language is Scheme-first
- Luau is the source of truth
- Roblox is a real target, not an afterthought
- Common Lisp compatibility, if added later, should be explicit and opt-in

If you are here for the one-line pitch:

Psil is a Lisp that wants to survive both a test suite and Roblox Studio.


Project layout
==============

lib/
  Shared interpreter, runtime values, parser, reader, printer, macros, and
  builtins.

host/
  Host-side runner and REPL glue.

roblox/
  Roblox app entrypoint and session/UI code.

assets/
  Branding and artwork assets such as the logo and game thumbnail.

generated/roblox/
  Built Roblox package used by Rojo sync.

tests/
  Test tree, split into handwritten core specs, curated compatibility suites,
  and vendored upstream Scheme tests.


Important workflow rule
=======================

Rojo does not sync lib/ directly.

Shared runtime code in lib/ must be rebuilt into generated/roblox before Studio
will see it.

If you change lib/*.luau, run:

  lune run build_roblox

Then resync from Rojo in Studio.

If Studio still shows an old bug after that, the first suspect is stale synced
code, not ancient curses or cosmic judgment.


Quick start
===========

Host path:

  lua host/main.lua examples/hello.lisp

Project tests:

  lua tests/run.lua

Vendored official Scheme slice:

  lua tools/chibi_full_suite.lua

Heavy raw R7RS compatibility run:

  lua tools/chibi_full_suite.lua tests/upstream/chibi/r7rs-tests.scm

Roblox package rebuild:

  lune run build_roblox

Roblox static lint:

  selene . --pattern 'roblox/**/*.luau'


Testing structure
=================

tests/core/
  Handwritten Psil behavior and regression specs.

tests/curated/
  Psil-owned adaptations of external suites.

tests/upstream/chibi/
  Vendored raw upstream Chibi Scheme tests.

Main test commands are:

  lua tests/run.lua
  lua tools/chibi_full_suite.lua


Language direction
==================

Psil is currently Scheme-first.

That means:

- default semantics should stay Scheme-shaped
- test and runtime decisions should favor Scheme correctness first
- Common Lisp compatibility should be a separate layer or mode if it is added

The repo uses a host Lua bootstrap for some tooling, but the language target is
Luau. If something works in Lua but not Luau, it is wrong for Psil.


Roblox notes
============

The Roblox tree is defined in default.project.json.

Important mappings:

- ReplicatedStorage.Psil -> generated/roblox/ReplicatedStorage/Psil
- StarterPlayer.StarterPlayerScripts.PsilApp -> roblox/app.client.luau

Editor and REPL output are intentionally separate in the Roblox UI.
If a change causes output to leak between panes again, treat that as a bug.


License
=======

Source code in this repository is licensed under the Mozilla Public License,
Version 2.0 (MPL-2.0). See:

  COPYING

Branding and artwork assets are licensed under CC0-1.0. This includes the
logo and thumbnail assets under assets/. See:

  COPYING-CC0-1.0


Status
======

Psil is no longer just a toy evaluator.

It has real parsing, macro expansion, continuations, dynamic-wind behavior,
Unicode-aware strings, exact integer support where the suite needed it, a
Roblox app, and a serious Scheme test story.

It is still an interpreter, which means it is easier to reason about than it is
to benchmark brag about. That is a polite way of saying the VM arc can wait its
turn.
