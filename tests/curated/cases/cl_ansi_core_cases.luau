--[[
SPDX-License-Identifier: MPL-2.0
]]

local cl_ansi_core_cases = {
	{
		feature_area = "truthiness",
		name = "nil is false in if",
		source = "tests/upstream/ansi-cl/data-and-control-flow/nil.lsp",
		dialect = "cl-compat",
		input = "(if nil 'bad 'ok)",
		expected = "ok",
	},
	{
		feature_area = "truthiness",
		name = "t is true in if",
		source = "tests/upstream/ansi-cl/data-and-control-flow/t.lsp",
		dialect = "cl-compat",
		input = "(if t 'ok 'bad)",
		expected = "ok",
	},
	{
		feature_area = "control_flow",
		name = "progn returns the final form",
		source = "tests/upstream/ansi-cl/data-and-control-flow/progn.lsp",
		dialect = "cl-compat",
		input = "(progn (+ 1 2) (+ 3 4) 9)",
		expected = "9",
	},
	{
		feature_area = "control_flow",
		name = "setq updates multiple bindings and returns the last value",
		source = "tests/upstream/ansi-cl/data-and-control-flow/places.lsp",
		dialect = "cl-compat",
		input = "(let ((x 1) (y 2)) (setq x 3 y 4) (list x y))",
		expected = "(3 4)",
	},
	{
		feature_area = "definitions",
		name = "defun defines a callable function",
		source = "tests/upstream/ansi-cl/data-and-control-flow/defun.lsp",
		dialect = "cl-compat",
		input = "(progn (defun add2 (x) (+ x 2)) (add2 5))",
		expected = "7",
	},
	{
		feature_area = "definitions",
		name = "defparameter defines and initializes a variable",
		source = "tests/upstream/ansi-cl/data-and-control-flow/defparameter.lsp",
		dialect = "cl-compat",
		input = "(progn (defparameter *x* 12) *x*)",
		expected = "12",
	},
	{
		feature_area = "definitions",
		name = "defvar does not overwrite an existing value",
		source = "tests/upstream/ansi-cl/data-and-control-flow/defvar.lsp",
		dialect = "cl-compat",
		input = "(progn (defparameter *x* 12) (defvar *x* 99) *x*)",
		expected = "12",
	},
	{
		feature_area = "functions",
		name = "function quote works with funcall on named functions",
		source = "tests/upstream/ansi-cl/data-and-control-flow/function.lsp",
		dialect = "cl-compat",
		input = "(progn (defun add1 (x) (+ x 1)) (funcall #'add1 5))",
		expected = "6",
	},
	{
		feature_area = "functions",
		name = "function returns lambdas as callable values",
		source = "tests/upstream/ansi-cl/data-and-control-flow/function.lsp",
		dialect = "cl-compat",
		input = "(funcall (function (lambda (x) (+ x 3))) 4)",
		expected = "7",
	},
	{
		feature_area = "functions",
		name = "print returns the printed object in CL mode",
		source = "project regression",
		dialect = "cl-compat",
		input = "(print 55)",
		expected = "55",
	},
	{
		feature_area = "predicates",
		name = "not returns t for nil and nil for true values",
		source = "tests/upstream/ansi-cl/data-and-control-flow/not-and-null.lsp",
		dialect = "cl-compat",
		input = "(list (not nil) (not t) (not 3))",
		expected = "(t nil nil)",
	},
}

return cl_ansi_core_cases
