local cl_cases = {
	{
		feature_area = "control_flow",
		name = "progn returns the value of its final form",
		source = "https://www.lispworks.com/documentation/HyperSpec/Body/s_progn.htm",
		input = "(progn (+ 1 2) (+ 3 4) 9)",
		expected = "9",
	},
	{
		feature_area = "control_flow",
		name = "when runs all body forms when the condition is true",
		source = "https://www.lispworks.com/documentation/HyperSpec/Body/m_when_.htm",
		input = "(begin (define x 1) (when #t (set! x (+ x 2)) (set! x (+ x 3))) x)",
		expected = "6",
	},
	{
		feature_area = "control_flow",
		name = "unless skips its body when the condition is true",
		source = "https://www.lispworks.com/documentation/HyperSpec/Body/m_when_.htm",
		input = "(begin (define x 4) (unless #t (set! x 9)) x)",
		expected = "4",
	},
	{
		feature_area = "control_flow",
		name = "and stops on the first false value",
		source = "https://www.lispworks.com/documentation/HyperSpec/Body/m_and.htm",
		input = "(and #t 1 #f 9)",
		expected = "#f",
	},
	{
		feature_area = "control_flow",
		name = "or returns the first truthy value",
		source = "https://www.lispworks.com/documentation/HyperSpec/Body/m_or.htm",
		input = "(or #f 'ok 9)",
		expected = "ok",
	},
	{
		feature_area = "predicates",
		name = "not only inverts false",
		source = "https://www.lispworks.com/documentation/HyperSpec/Body/f_not.htm",
		input = "(list (not #f) (not '()) (not 3))",
		expected = "(#t #f #f)",
	},
	{
		feature_area = "predicates",
		name = "atom treats non-lists as atomic data",
		source = "https://www.lispworks.com/documentation/HyperSpec/Body/f_atom.htm",
		input = "(list (atom? 'x) (atom? '(1 2)) (atom? '()))",
		expected = "(#t #f #t)",
	},
	{
		feature_area = "equality",
		name = "eq compares symbols by identity-like name match",
		source = "https://www.lispworks.com/documentation/HyperSpec/Body/f_eq.htm",
		input = "(list (eq? 'psil 'psil) (eq? '(1 2) '(1 2)))",
		expected = "(#t #f)",
	},
	{
		feature_area = "sequence_ops",
		name = "nth uses zero-based indexing in Psil",
		source = "https://www.lispworks.com/documentation/HyperSpec/Body/f_nth.htm",
		input = "(nth 2 '(10 20 30 40))",
		expected = "30",
	},
	{
		feature_area = "sequence_ops",
		name = "reverse returns a fresh reversed list",
		source = "https://www.lispworks.com/documentation/HyperSpec/Body/f_revers.htm",
		input = "(reverse '(a b c d))",
		expected = "(d c b a)",
	},
}

return cl_cases
--[[
SPDX-License-Identifier: MPL-2.0
]]
