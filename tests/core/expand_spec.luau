--[[
SPDX-License-Identifier: MPL-2.0
]]

local assert_mod = require("../support/assert")
local lisp = require("../../lib/lisp")

local expand_spec = {}

function expand_spec.run()
	local shorthand = lisp.expand("(define (inc x) (+ x 1))")
	assert_mod.equal(
		lisp.to_string(shorthand),
		"(define inc (lambda (x) (+ x 1)))",
		"expand rewrites function shorthand define"
	)

	local quoted = lisp.expand("'(+ 1 2)")
	assert_mod.equal(
		lisp.to_string(quoted),
		"(quote (+ 1 2))",
		"expand preserves quoted data"
	)

	local quasiquoted = lisp.expand("`(+ 1 ,x)")
	assert_mod.equal(
		lisp.to_string(quasiquoted),
		"(quasiquote (+ 1 (unquote x)))",
		"expand preserves quasiquote syntax as data"
	)

	local nested = lisp.expand("(begin (define (inc x) (+ x 1)) (inc 4))")
	assert_mod.equal(
		lisp.to_string(nested),
		"(begin (define inc (lambda (x) (+ x 1))) (inc 4))",
		"expand recurses through begin bodies"
	)

	local when_form = lisp.expand("(when (> 3 2) (print 1) 9)")
	assert_mod.equal(
		lisp.to_string(when_form),
		"(if (> 3 2) (begin (print 1) 9))",
		"expand rewrites when into if/begin"
	)

	local unless_form = lisp.expand("(unless #f (print 1) 9)")
	assert_mod.equal(
		lisp.to_string(unless_form),
		"(if #f (quote ()) (begin (print 1) 9))",
		"expand rewrites unless into if with empty-list branch"
	)

	local progn_form = lisp.expand("(progn (define x 1) (+ x 1))")
	assert_mod.equal(
		lisp.to_string(progn_form),
		"(begin (define x 1) (+ x 1))",
		"expand rewrites progn into begin"
	)
end

return expand_spec