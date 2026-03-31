local chibi_basic_cases = {
	{
		feature_area = "recursion",
		name = "factorial helper recursion computes fact 3",
		source = "https://github.com/ashinn/chibi-scheme/blob/master/tests/basic/test00-fact-3.scm",
		input = [[
(begin
	(define (fact-helper x res)
		(if (= x 0)
			res
			(fact-helper (- x 1) (* res x))))
	(define (fact x)
		(fact-helper x 1))
	(fact 3))
]],
		expected = "6",
	},
	{
		feature_area = "procedures",
		name = "apply spreads a final list of arguments over a procedure call",
		source = "https://github.com/ashinn/chibi-scheme/blob/master/tests/basic/test01-apply.scm",
		input = "(begin (define foo (lambda (a b c d e f g h) (+ (+ (* a b) (* c d)) (+ (* e f) (* g h))))) (apply foo (list 1 2 3 4 5 6 7 8)))",
		expected = "100",
	},
	{
		feature_area = "procedures",
		name = "apply accepts fixed arguments before the final list",
		source = "https://github.com/ashinn/chibi-scheme/blob/master/tests/basic/test01-apply.scm",
		input = "(begin (define foo (lambda (a b c d e f g h) (+ (+ (* a b) (* c d)) (+ (* e f) (* g h))))) (apply foo 1 2 3 4 (list 5 6 7 8)))",
		expected = "100",
	},
	{
		feature_area = "closures",
		name = "independent counters keep separate closed-over state",
		source = "https://github.com/ashinn/chibi-scheme/blob/master/tests/basic/test02-closure.scm",
		input = [[
(begin
	(define (make-counter n)
		(lambda ()
			(set! n (+ n 1))
			n))
	(define f (make-counter 0))
	(define g (make-counter 100))
	(list (f) (f) (g) (g) (f) (g)))
]],
		expected = "(1 2 101 102 3 103)",
	},
	{
		feature_area = "closures",
		name = "nested closure captures outer lambda parameters",
		source = "https://github.com/ashinn/chibi-scheme/blob/master/tests/basic/test03-nested-closure.scm",
		input = "((lambda (a b) ((lambda (c d e) (+ e (* c 1000) (* a 100) (* b 10) d)) (- a 2) (+ b 2) 10000)) 3 5)",
		expected = "11357",
	},
	{
		feature_area = "binding_forms",
		name = "nested let reproduces the same arithmetic shape as nested closures",
		source = "https://github.com/ashinn/chibi-scheme/blob/master/tests/basic/test04-nested-let.scm",
		input = "(let ((a 3) (b 5)) (let ((c (- a 2)) (d (+ b 2)) (e 10000)) (+ e (* c 1000) (* a 100) (* b 10) d)))",
		expected = "11357",
	},
	{
		feature_area = "binding_forms",
		name = "internal define inside let body can use prior bindings",
		source = "https://github.com/ashinn/chibi-scheme/blob/master/tests/basic/test05-internal-define.scm",
		input = "(let ((a 1000)) (define b (+ a 3)) (list a b))",
		expected = "(1000 1003)",
	},
	{
		feature_area = "binding_forms",
		name = "letrec can bind a local helper before body evaluation",
		source = "https://github.com/ashinn/chibi-scheme/blob/master/tests/basic/test06-letrec.scm",
		input = "(letrec ((add (lambda (a b) (+ a b)))) (add 3 4))",
		expected = "7",
	},
	{
		feature_area = "binding_forms",
		name = "letrec supports mutually recursive local procedures",
		source = "https://github.com/ashinn/chibi-scheme/blob/master/tests/basic/test06-letrec.scm",
		input = "(letrec ((even? (lambda (n) (if (= n 0) #t (odd? (- n 1))))) (odd? (lambda (n) (if (= n 0) #f (even? (- n 1)))))) (list (even? 10) (even? 11) (odd? 10)))",
		expected = "(#t #f #f)",
	},
	{
		feature_area = "mutation",
		name = "set updates a local binding before final arithmetic use",
		source = "https://github.com/ashinn/chibi-scheme/blob/master/tests/basic/test07-mutation.scm",
		input = "(let ((a 3) (b 5)) (let ((c (- a 2)) (d (+ b 2)) (e #f)) (set! e 10000) (+ e (* c 1000) (* a 100) (* b 10) d)))",
		expected = "11357",
	},
	{
		feature_area = "continuations",
		name = "call-with-current-continuation returns the body result when continuation is unused",
		source = "https://github.com/ashinn/chibi-scheme/blob/master/tests/basic/test08-callcc.scm",
		input = "(call-with-current-continuation (lambda (k) 1))",
		expected = "1",
	},
	{
		feature_area = "continuations",
		name = "call-with-current-continuation can escape early through the passed continuation",
		source = "https://github.com/ashinn/chibi-scheme/blob/master/tests/r5rs-tests.scm",
		input = "(call-with-current-continuation (lambda (k) (+ 2 5 (k 3))))",
		expected = "3",
	},
	{
		feature_area = "special_forms",
		name = "or returns a local binding without evaluating farther",
		source = "https://github.com/ashinn/chibi-scheme/blob/master/tests/basic/test09-hygiene.scm",
		input = "(let ((tmp 4)) (or #f tmp))",
		expected = "4",
	},
	{
		feature_area = "macros",
		name = "define-syntax can register and use a simple syntax-rules macro",
		source = "https://github.com/ashinn/chibi-scheme/blob/master/tests/basic/test09-hygiene.scm",
		input = "(begin (define-syntax myor (syntax-rules () ((myor x y) (if x x y)))) (myor #f 1))",
		expected = "1",
	},
}

return chibi_basic_cases
--[[
SPDX-License-Identifier: MPL-2.0
]]
