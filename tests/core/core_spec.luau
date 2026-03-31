--[[
SPDX-License-Identifier: MPL-2.0
]]

local assert_mod = require("../support/assert")
local host_io = require("../../host/io")
local runner = require("../../host/runner")
local lisp = require("../../lib/lisp")

local core_spec = {}

function core_spec.run()
	local parse_result = lisp.parse("(+ 1 (list 2 3))")
	assert_mod.equal(
		lisp.to_string(parse_result),
		"(+ 1 (list 2 3))",
		"parse nested form"
	)
	assert_mod.equal(
		lisp.to_string(lisp.parse("'(a . b)")),
		"(quote (a . b))",
		"parse dotted list syntax"
	)
	assert_mod.equal(
		lisp.to_string(lisp.parse("1+2i")),
		"1+2i",
		"parse rectangular complex literal"
	)
	assert_mod.equal(
		lisp.to_string(lisp.parse("\"λ\"")),
		"\"λ\"",
		"parse unicode string literal"
	)
	assert_mod.equal(
		lisp.to_string(lisp.parse("#true")),
		"#t",
		"parse long true boolean literal"
	)
	assert_mod.equal(
		lisp.to_string(lisp.parse("#u8(1 2)")),
		"#u8(1 2)",
		"parse bytevector literal"
	)
	assert_mod.equal(
		lisp.to_string(lisp.parse("+i")),
		"+i",
		"parse unit imaginary literal"
	)

	assert_mod.equal(
		lisp.to_string(lisp.eval("'(1 2 3)", runner.new_env())),
		"(1 2 3)",
		"quote list"
	)
	assert_mod.equal(
		lisp.to_string(
			lisp.eval("(begin (define x 10) (+ x 5))", runner.new_env())
		),
		"15",
		"define and lookup"
	)
	assert_mod.equal(
		lisp.to_string(lisp.eval("(if #t 1 2)", runner.new_env())),
		"1",
		"if true branch"
	)
	assert_mod.equal(
		lisp.to_string(lisp.eval("(if #f 1 2)", runner.new_env())),
		"2",
		"if false branch"
	)
	assert_mod.equal(
		lisp.to_string(
			lisp.eval(
				"(begin (define make_adder (lambda (n) (lambda (x) (+ x n)))) ((make_adder 7) 4))",
				runner.new_env()
			)
		),
		"11",
		"closure captures parent scope"
	)
	assert_mod.equal(
		lisp.to_string(
			lisp.eval(
				"(let ((x 2) (y 3)) (begin (define z 4) (+ x y z)))",
				runner.new_env()
			)
		),
		"9",
		"let binds values in a child scope"
	)
	assert_mod.equal(
		lisp.to_string(lisp.eval("(car (list 9 8 7))", runner.new_env())),
		"9",
		"car builtin"
	)
	assert_mod.equal(
		lisp.to_string(lisp.eval("(cdr (list 9 8 7))", runner.new_env())),
		"(8 7)",
		"cdr builtin"
	)
	assert_mod.equal(
		lisp.to_string(lisp.eval("(cdr '(1 . 2))", runner.new_env())),
		"2",
		"cdr returns the dotted tail for an improper list"
	)
	assert_mod.equal(
		lisp.to_string(lisp.eval('(read (open-input-string "(1 . (2 3))"))', runner.new_env())),
		"(1 2 3)",
		"read normalizes dotted list tails that end in proper lists"
	)
	assert_mod.equal(
		lisp.to_string(lisp.eval('(read (open-input-string "#(a b)"))', runner.new_env())),
		"#(a b)",
		"read parses vector literals from ports"
	)
	assert_mod.equal(
		lisp.to_string(lisp.eval('(read (open-input-string "#; abc def"))', runner.new_env())),
		"def",
		"read skips datum comments"
	)
	assert_mod.equal(
		lisp.to_string(lisp.eval('(read (open-input-string "|H\\\\x65;llo|"))', runner.new_env())),
		"Hello",
		"read parses escaped bar symbols"
	)
	assert_mod.equal(
		lisp.to_string(
			lisp.eval(
				'(let ((out (open-output-string)) (x (list 1))) (set-cdr! x x) (write x out) (get-output-string out))',
				runner.new_env()
			)
		),
		'"#0=(1 . #0#)"',
		"write emits shared labels for cyclic lists"
	)
	assert_mod.equal(
		lisp.to_string(
			lisp.eval(
				'(let ((out (open-output-string)) (x (list 1 2 3))) (write-shared (list x x) out) (get-output-string out))',
				runner.new_env()
			)
		),
		'"(#0=(1 2 3) #0#)"',
		"write-shared labels repeated structure"
	)
	assert_mod.equal(
		lisp.to_string(lisp.eval("(null? '())", runner.new_env())),
		"#t",
		"null predicate"
	)
	assert_mod.equal(
		lisp.to_string(lisp.eval("(list? '(a . b))", runner.new_env())),
		"#f",
		"list predicate rejects improper lists"
	)
	assert_mod.equal(
		lisp.to_string(
			lisp.eval(
				"(let ((x (list 10 100 1000))) (set-cdr! (cddr x) x) (map * x '(1 2 3 4 5 6)))",
				runner.new_env()
			)
		),
		"(10 200 3000 40 500 6000)",
		"map walks cyclic lists until a finite input ends"
	)
	assert_mod.equal(
		lisp.to_string(
			lisp.eval(
				"(let ((x (list 10 100 1000)) (count 0)) (set-cdr! (cddr x) x) (for-each (lambda (lhs rhs) (set! count (+ count (* lhs rhs)))) '(1 2 3 4 5 6) x) count)",
				runner.new_env()
			)
		),
		"9750",
		"for-each walks cyclic lists until a finite input ends"
	)
	assert_mod.equal(
		lisp.to_string(lisp.eval("(and)", runner.new_env())),
		"#t",
		"and with no arguments is true"
	)
	assert_mod.equal(
		lisp.to_string(
			lisp.eval("(begin (define x 1) (and x (+ x 4)))", runner.new_env())
		),
		"5",
		"and returns the last truthy value"
	)
	assert_mod.equal(
		lisp.to_string(
			lisp.eval("(begin (define x 1) (or #f #f (+ x 4)))", runner.new_env())
		),
		"5",
		"or returns the first truthy value"
	)
	assert_mod.equal(
		lisp.to_string(
			lisp.eval("(begin (define x 1) (when #t (set! x 7)) x)", runner.new_env())
		),
		"7",
		"when runs its body when the condition is true"
	)
	assert_mod.equal(
		lisp.to_string(
			lisp.eval(
				"(begin (define x 1) (unless #t (set! x 7)) x)",
				runner.new_env()
			)
		),
		"1",
		"unless skips its body when the condition is true"
	)
	assert_mod.equal(
		lisp.to_string(lisp.eval("(progn 1 2 3)", runner.new_env())),
		"3",
		"progn aliases begin"
	)
	assert_mod.equal(
		lisp.to_string(lisp.eval("(not #f)", runner.new_env())),
		"#t",
		"not uses Psil truthiness"
	)
	assert_mod.equal(
		lisp.to_string(lisp.eval("(symbol? 'alpha)", runner.new_env())),
		"#t",
		"symbol predicate"
	)
	assert_mod.equal(
		lisp.to_string(lisp.eval("(number? 42)", runner.new_env())),
		"#t",
		"number predicate"
	)
	assert_mod.equal(
		lisp.to_string(lisp.eval("(complex? 1+2i)", runner.new_env())),
		"#t",
		"complex predicate"
	)
	assert_mod.equal(
		lisp.to_string(lisp.eval("(real? -2.5+0i)", runner.new_env())),
		"#t",
		"exact zero imaginary part still counts as real"
	)
	assert_mod.equal(
		lisp.to_string(lisp.eval("(real? -2.5+0.0i)", runner.new_env())),
		"#f",
		"inexact zero imaginary part stays complex"
	)
	assert_mod.equal(
		lisp.to_string(lisp.eval('(string? "psil")', runner.new_env())),
		"#t",
		"string predicate"
	)
	assert_mod.equal(
		lisp.to_string(
			lisp.eval(
				'(let ((str (string #\\a #\\b #\\c))) (string-set! str 1 #\\-) str)',
				runner.new_env()
			)
		),
		"\"a-c\"",
		"string-set! mutates the underlying string value"
	)
	assert_mod.equal(
		lisp.to_string(lisp.eval('(string-upcase "γλώσσα")', runner.new_env())),
		"\"ΓΛΏΣΣΑ\"",
		"string-upcase handles Greek letters"
	)
	assert_mod.equal(
		lisp.to_string(lisp.eval('(string-foldcase "ΜΈΛΟΣ")', runner.new_env())),
		"\"μέλοσ\"",
		"string-foldcase uses Unicode-aware case folding"
	)
	assert_mod.equal(
		lisp.to_string(lisp.eval("(digit-value #\\x0E50)", runner.new_env())),
		"0",
		"digit-value handles non-ASCII decimal digits"
	)
	assert_mod.equal(
		lisp.to_string(lisp.eval("(boolean? #t)", runner.new_env())),
		"#t",
		"boolean predicate"
	)
	assert_mod.equal(
		lisp.to_string(lisp.eval("(list? '(1 2))", runner.new_env())),
		"#t",
		"list predicate"
	)
	assert_mod.equal(
		lisp.to_string(
			lisp.eval("(procedure? (lambda (x) x))", runner.new_env())
		),
		"#t",
		"procedure predicate"
	)
	assert_mod.equal(
		lisp.to_string(lisp.eval("(atom? '())", runner.new_env())),
		"#t",
		"atom treats the empty list as atomic"
	)
	assert_mod.equal(
		lisp.to_string(lisp.eval("(eq? 'alpha 'alpha)", runner.new_env())),
		"#t",
		"eq compares symbols by name"
	)
	assert_mod.equal(
		lisp.to_string(
			lisp.eval("(equal? '(1 (2 3)) '(1 (2 3)))", runner.new_env())
		),
		"#t",
		"equal compares nested lists structurally"
	)
	assert_mod.equal(
		lisp.to_string(lisp.eval("(length '(9 8 7))", runner.new_env())),
		"3",
		"length builtin"
	)
	assert_mod.equal(
		lisp.to_string(lisp.eval("(reverse '(9 8 7))", runner.new_env())),
		"(7 8 9)",
		"reverse builtin"
	)
	assert_mod.equal(
		lisp.to_string(lisp.eval("(nth 1 '(9 8 7))", runner.new_env())),
		"8",
		"nth builtin is zero-based"
	)
	assert_mod.equal(
		lisp.to_string(lisp.eval("(log 100 10)", runner.new_env())),
		"2.0",
		"log supports a base argument"
	)
	assert_mod.equal(
		lisp.to_string(
			lisp.eval("(call-with-values (lambda () (ceiling/ 13 4)) list)", runner.new_env())
		),
		"(4 -3)",
		"ceiling/ returns quotient and remainder"
	)
	assert_mod.equal(
		lisp.to_string(lisp.eval("(euclidean-remainder -13 4)", runner.new_env())),
		"3",
		"euclidean-remainder stays non-negative"
	)
	assert_mod.equal(
		lisp.to_string(lisp.eval("(balanced-quotient 13 2)", runner.new_env())),
		"7",
		"balanced-quotient rounds half-border cases to a negative remainder"
	)
	assert_mod.equal(
		lisp.to_string(lisp.eval("(round 13/2)", runner.new_env())),
		"6",
		"round uses IEEE-style ties-to-even semantics"
	)
	assert_mod.equal(
		lisp.to_string(lisp.eval("(floor 4.3)", runner.new_env())),
		"4.0",
		"floor rounds inexact inputs downward"
	)
	assert_mod.equal(
		lisp.to_string(lisp.eval("(sqrt -1)", runner.new_env())),
		"0.0+1.0i",
		"sqrt of a negative real produces a complex value"
	)
	assert_mod.equal(
		lisp.to_string(
			lisp.eval(
				"(let-values (((root rem) (exact-integer-sqrt (expt 2 121)))) (list root rem))",
				runner.new_env()
			)
		),
		"(1630477228166597776 1772969445592542976)",
		"exact-integer-sqrt handles huge exact integers"
	)
	assert_mod.equal(
		lisp.to_string(lisp.eval("(imag-part 1+2i)", runner.new_env())),
		"2",
		"imag-part extracts the imaginary component"
	)
	assert_mod.equal(
		lisp.to_string(
			lisp.eval("(begin (define x 3) `(1 2 ,x 4))", runner.new_env())
		),
		"(1 2 3 4)",
		"quasiquote evaluates unquote within lists"
	)
	assert_mod.equal(
		lisp.to_string(
			lisp.eval("(begin (define tail '(3 4)) `(1 2 ,@tail 5))", runner.new_env())
		),
		"(1 2 3 4 5)",
		"quasiquote supports unquote-splicing"
	)
	assert_mod.equal(
		lisp.to_string(
			lisp.eval("(begin (define x 7) ``(outer ,x ,,x))", runner.new_env())
		),
		"(quasiquote (outer (unquote x) (unquote 7)))",
		"nested quasiquote tracks unquote depth"
	)
	assert_mod.equal(
		lisp.to_string(
			lisp.eval(
				"(guard (exn ((assq 'a exn) => cdr) (else 'miss)) (raise (list (cons 'a 42))))",
				runner.new_env()
			)
		),
		"42",
		"guard catches raised conditions and supports => clauses"
	)
	assert_mod.equal(
		lisp.to_string(
			lisp.eval(
				"(with-exception-handler (lambda (x) 42) (lambda () (+ (raise-continuable 'boom) 23)))",
				runner.new_env()
			)
		),
		"65",
		"with-exception-handler resumes continuable exceptions"
	)
	assert_mod.equal(
		lisp.to_string(
			lisp.eval(
				"(error-object-message (guard (exn (else exn)) (error \"BOOM!\" 1 2 3)))",
				runner.new_env()
			)
		),
		"\"BOOM!\"",
		"error produces inspectable error objects"
	)
	assert_mod.equal(
		lisp.to_string(
			lisp.eval(
				"(let ((out (open-output-string))) (list (with-exception-handler (lambda (x) (display \"reraised\" out) 'bad) (lambda () (guard (condition ((positive? condition) 'positive)) (raise 1)))) (get-output-string out)))",
				runner.new_env()
			)
		),
		"(positive \"\")",
		"guard handles matching conditions before outer exception handlers"
	)
	assert_mod.equal(
		lisp.to_string(
			lisp.eval(
				"(file-error? (guard (exn (else exn)) (open-input-file \"missing\")))",
				runner.new_env()
			)
		),
		"#t",
		"file errors are classified for guard handlers"
	)
	assert_mod.equal(
		lisp.to_string(
			lisp.eval(
				"(eval '(+ 7 3) (environment '(scheme base)))",
				runner.new_env()
			)
		),
		"10",
		"eval runs forms inside explicit environments"
	)
	assert_mod.equal(
		lisp.to_string(
			lisp.eval(
				"(let ((p (open-input-bytevector #u8(1 2 3)))) (list (read-u8 p) (read-u8 p) (read-bytevector 4 p)))",
				runner.new_env()
			)
		),
		"(1 2 #u8(3))",
		"binary input ports consume bytes in order"
	)
	assert_mod.equal(
		lisp.to_string(
			lisp.eval(
				"(char-ci=? #\\a #\\A #\\a)",
				runner.new_env()
			)
		),
		"#t",
		"char-ci=? compares case-insensitively"
	)
	assert_mod.equal(
		lisp.to_string(
			lisp.eval(
				"(string->utf8 \"λ\")",
				runner.new_env()
			)
		),
		"#u8(206 187)",
		"string->utf8 encodes UTF-8 bytevectors"
	)

	local captured = {}
	local env = runner.new_env(host_io.new({
		write = function(_, text)
			table.insert(captured, text)
		end,
	}))
	local printed = lisp.eval('(begin (print "hello" 42) #t)', env)
	assert_mod.equal(
		lisp.to_string(printed),
		"#t",
		"print returns the last form result through begin"
	)
	assert_mod.equal(captured[1], '"hello" 42', "print writes through adapter")

	assert_mod.errors(function()
		lisp.parse("(+ 1 2")
	end, "unexpected end of input", "parse error surfaces clearly")
	assert_mod.errors(function()
		lisp.eval("(missing 1)", runner.new_env())
	end, "undefined symbol", "undefined symbol errors")
	assert_mod.errors(function()
		lisp.eval("(nth 4 '(1 2 3))", runner.new_env())
	end, "out of range", "nth errors on out-of-range indexes")
	assert_mod.errors(function()
		lisp.eval("(length 99)", runner.new_env())
	end, "length expected a list", "length errors on non-lists")
	assert_mod.errors(function()
		lisp.eval("(reverse 99)", runner.new_env())
	end, "reverse expected a list", "reverse errors on non-lists")
	assert_mod.errors(function()
		lisp.eval("(unquote x)", runner.new_env())
	end, "unquote may only appear inside quasiquote", "unquote errors outside quasiquote")
	assert_mod.errors(function()
		lisp.eval("(begin (define x 1) `,@x)", runner.new_env())
	end, "unquote-splicing must appear inside a list", "top-level unquote-splicing errors")
	assert_mod.errors(function()
		lisp.eval("(begin (define x 1) `(1 ,@x))", runner.new_env())
	end, "unquote-splicing expected a list", "splicing rejects non-list values")
	assert_mod.errors(function()
		lisp.eval(
			"(begin (define (forever) (forever)) (forever))",
			runner.new_env(),
			lisp.new_execution({
				step_budget = 64,
			})
		)
	end, "evaluation budget exceeded", "execution budget interrupts runaway recursion")
	assert_mod.errors(function()
		lisp.eval("(remainder +inf.0 2)", runner.new_env())
	end, "finite operands", "remainder rejects non-finite operands")
end

return core_spec