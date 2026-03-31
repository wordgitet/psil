--[[
SPDX-License-Identifier: MPL-2.0
]]

local norvig_cases = {
	{
		feature_area = "special_forms",
		name = "if chooses the alternate branch",
		source = "https://norvig.com/lispy.html",
		input = "(if (> 10 20) (+ 1 1) (+ 3 3))",
		expected = "6",
	},
	{
		feature_area = "binding_and_eval",
		name = "begin with define computes circle area shape",
		source = "https://norvig.com/lispy.html",
		input = "(begin (define r 10) (* 3.141592653589793 (* r r)))",
		expected = "314.15926535898",
	},
	{
		feature_area = "quotation",
		name = "quoted form is returned literally",
		source = "https://norvig.com/lispy.html",
		input = "(quote (+ 1 2))",
		expected = "(+ 1 2)",
	},
	{
		feature_area = "procedures",
		name = "lambda applies with lexical scope",
		source = "https://norvig.com/lispy.html",
		input = "((lambda (r) (* r r)) 12)",
		expected = "144",
	},
	{
		feature_area = "procedures",
		name = "lambda can receive another procedure",
		source = "https://norvig.com/lispy.html",
		input = "((lambda (f) (f 9)) (lambda (x) (+ x 1)))",
		expected = "10",
	},
	{
		feature_area = "procedures",
		name = "closure captures surrounding binding",
		source = "https://norvig.com/lispy.html",
		input = "(begin (define make-adder (lambda (n) (lambda (x) (+ x n)))) ((make-adder 5) 7))",
		expected = "12",
	},
}

return norvig_cases