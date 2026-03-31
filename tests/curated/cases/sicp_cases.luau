--[[
SPDX-License-Identifier: MPL-2.0
]]

local sicp_cases = {
	{
		feature_area = "environment_model",
		name = "let creates a local environment for body evaluation",
		source = "https://sicp.sourceacademy.org/chapters/4.1.1.html",
		input = "(let ((x 3) (y 4)) (+ x y))",
		expected = "7",
	},
	{
		feature_area = "environment_model",
		name = "closures retain bindings from their defining environment",
		source = "https://sicp.sourceacademy.org/chapters/3.2.html",
		input = "(begin (define make-adder (lambda (n) (lambda (x) (+ x n)))) (define add7 (make-adder 7)) (add7 5))",
		expected = "12",
	},
	{
		feature_area = "evaluation_rules",
		name = "begin evaluates forms left to right and returns the last value",
		source = "https://sicp.sourceacademy.org/chapters/4.1.1.html",
		input = "(begin (define x 1) (set! x (+ x 4)) (set! x (+ x 5)) x)",
		expected = "10",
	},
	{
		feature_area = "procedures",
		name = "compound procedures can call passed-in procedures",
		source = "https://sicp.sourceacademy.org/chapters/1.3.1.html",
		input = "((lambda (f x) (f (f x))) (lambda (n) (+ n 1)) 5)",
		expected = "7",
	},
	{
		feature_area = "data_as_programs",
		name = "quoted lists can be navigated with car and cdr",
		source = "https://sicp.sourceacademy.org/chapters/2.3.1.html",
		input = "(list (car '(1 2 3)) (cdr '(1 2 3)))",
		expected = "(1 (2 3))",
	},
	{
		feature_area = "control_flow",
		name = "cond can model simple case analysis",
		source = "https://sicp.sourceacademy.org/chapters/1.1.6.html",
		input = "(begin (define abs (lambda (x) (cond ((> x 0) x) ((= x 0) 0) (else (- x))))) (list (abs 5) (abs 0) (abs -8)))",
		expected = "(5 0 8)",
	},
}

return sicp_cases