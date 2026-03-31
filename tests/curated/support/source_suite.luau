--[[
SPDX-License-Identifier: MPL-2.0
]]

local assert_mod = require("../../support/assert")
local runner = require("../../../host/runner")
local lisp = require("../../../lib/lisp")

local source_suite = {}

function source_suite.run(suite_name, cases)
	local area_counts = {}

	for _, case in ipairs(cases) do
		local actual = lisp.to_string(lisp.eval(case.input, runner.new_env()))
		local label = string.format(
			"%s/%s: %s [%s]",
			suite_name,
			case.feature_area or "misc",
			case.name,
			case.source
		)
		assert_mod.equal(actual, case.expected, label)

		local area = case.feature_area or "misc"
		area_counts[area] = (area_counts[area] or 0) + 1
	end

	for area, count in pairs(area_counts) do
		print(
			string.format(
				"ok - %d %s cases in %s",
				count,
				suite_name,
				area
			)
		)
	end
end

return source_suite