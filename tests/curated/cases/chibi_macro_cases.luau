local chibi_macro_cases = {
	{
		feature_area = "macros",
		name = "sc-macro-transformer can leave introduced exit identifiers free for generated bindings",
		source = "https://github.com/ashinn/chibi-scheme/blob/master/tests/syntax-tests.scm",
		input = [[
(begin
	(define-syntax loop1
		(sc-macro-transformer
			(lambda (exp env)
				(let ((body (cdr exp)))
					`(call-with-current-continuation
						(lambda (exit)
							(let f ()
								,@(map (lambda (exp)
									(make-syntactic-closure env '(exit) exp))
									body)
								(f))))))))
	(define exit 42)
	(loop1 (exit 10)))
]],
		expected = "10",
	},
	{
		feature_area = "macros",
		name = "nested sc-macro-transformers preserve captured lexical scopes through syntactic closures",
		source = "https://github.com/ashinn/chibi-scheme/blob/master/tests/syntax-tests.scm",
		input = [[
(begin
	(define (y) 0)
	(define-syntax macro
		(sc-macro-transformer
			(lambda (exp env)
				(make-syntactic-closure env '(y) (cadr exp)))))
	(let ((y (lambda () 100)))
		(list
			(macro (y))
			(let ((x 10))
				(define-syntax macro
					(sc-macro-transformer
						(lambda (exp env)
							(make-syntactic-closure env '(x) (cadr exp)))))
				(let ((x 20))
					(define-syntax macro2
						(sc-macro-transformer
							(lambda (exp env)
								(macro (make-syntactic-closure env '(x) (cadr exp))))))
					(let ((x 30))
						(macro2 x)))))))
]],
		expected = "(0 20)",
	},
	{
		feature_area = "macros",
		name = "let-syntax bodies expand against local syntax before evaluation",
		source = "https://github.com/ashinn/chibi-scheme/blob/master/tests/r7rs-tests.scm",
		input = [[
(let-syntax
	((when (syntax-rules ()
		((when test stmt1 stmt2 ...)
			(if test
				(begin stmt1
					stmt2 ...))))))
	(let ((if #t))
		(when if (set! if 'now))
		if))
]],
		expected = "now",
	},
	{
		feature_area = "macros",
		name = "let-syntax preserves lexical capture hygiene",
		source = "https://github.com/ashinn/chibi-scheme/blob/master/tests/r7rs-tests.scm",
		input = [[
(let ((x 'outer))
	(let-syntax ((m (syntax-rules () ((m) x))))
		(let ((x 'inner))
			(m))))
]],
		expected = "outer",
	},
	{
		feature_area = "macros",
		name = "define-syntax handles underscore wildcard patterns",
		source = "https://github.com/ashinn/chibi-scheme/blob/master/tests/r7rs-tests.scm",
		input = [[
(begin
	(define-syntax underscore
		(syntax-rules ()
			((foo _) '_)))
	(underscore foo))
]],
		expected = "_",
	},
	{
		feature_area = "macros",
		name = "local define-syntax supports wildcard list patterns",
		source = "https://github.com/ashinn/chibi-scheme/blob/master/tests/r7rs-tests.scm",
		input = [[
(let ()
	(define-syntax underscore2
		(syntax-rules ()
			((underscore2 (a _) ...) 42)))
	(underscore2 (1 2)))
]],
		expected = "42",
	},
	{
		feature_area = "macros",
		name = "syntax-rules can escape literal ellipsis in generated templates",
		source = "https://github.com/ashinn/chibi-scheme/blob/master/tests/r7rs-tests.scm",
		input = [[
(begin
	(define-syntax elli-esc-1
		(syntax-rules ()
			((_)
				'(... ...))
			((_ x)
				'(... (x ...)))
			((_ x y)
				'(... (... x y)))))
	(list (elli-esc-1) (elli-esc-1 100) (elli-esc-1 100 200)))
]],
		expected = "(... (100 ...) (... 100 200))",
	},
	{
		feature_area = "macros",
		name = "syntax-rules supports custom ellipsis identifiers",
		source = "https://github.com/ashinn/chibi-scheme/blob/master/tests/r5rs-tests.scm",
		input = [[
(let-syntax
	((foo (syntax-rules ::: ()
		((foo ... args :::)
			(args ::: ...)))))
	(foo 3 - 5))
]],
		expected = "2",
	},
	{
		feature_area = "macros",
		name = "syntax-rules literal underscore beats wildcard matching when declared",
		source = "https://github.com/ashinn/chibi-scheme/blob/master/tests/r7rs-tests.scm",
		input = [[
(begin
	(define-syntax count-to-2_
		(syntax-rules (_)
			((_) 0)
			((_ _) 1)
			((_ _ _) 2)
			((x . y) 'fail)))
	(list (count-to-2_ _ _) (count-to-2_) (count-to-2_ a b) (count-to-2_ a b c d)))
]],
		expected = "(2 0 fail fail)",
	},
	{
		feature_area = "macros",
		name = "syntax-rules supports repeated arguments before a fixed tail",
		source = "https://github.com/ashinn/chibi-scheme/blob/master/tests/r5rs-tests.scm",
		input = [[
(let-syntax
	((foo (syntax-rules ()
		((foo args ... penultimate ultimate)
			(list ultimate penultimate args ...)))))
	(foo 1 2 3 4 5))
]],
		expected = "(5 4 1 2 3)",
	},
	{
		feature_area = "macros",
		name = "letrec-syntax recursive my-or preserves introduced temp hygiene",
		source = "https://github.com/ashinn/chibi-scheme/blob/master/tests/r7rs-tests.scm",
		input = [[
(letrec
	((even? (lambda (n) (if (= n 0) #t (odd? (- n 1)))))
	 (odd? (lambda (n) (if (= n 0) #f (even? (- n 1))))))
	(letrec-syntax
		((my-or (syntax-rules ()
			((my-or) #f)
			((my-or e) e)
			((my-or e1 e2 ...)
				(let ((temp e1))
					(if temp
						temp
						(my-or e2 ...)))))))
		(let ((x #f)
			(y 7)
			(temp 8)
			(let odd?)
			(if even?))
			(my-or x
				(let temp)
				(if y)
				y))))
]],
		expected = "7",
	},
}

return chibi_macro_cases
--[[
SPDX-License-Identifier: MPL-2.0
]]
