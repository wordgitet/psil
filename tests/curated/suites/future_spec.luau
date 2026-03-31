local errors = require("../../../lib/errors")
local runner = require("../../../host/runner")
local lisp = require("../../../lib/lisp")
local future_cases = require("../cases/future_cases")

local future_spec = {}

function future_spec.run()
	local xfailed = 0
	local area_counts = {}

	for _, case in ipairs(future_cases) do
		local ok, result = pcall(lisp.eval, case.input, runner.new_env())
		local label = string.format(
			"%s/%s: %s [%s]",
			case.suite,
			case.feature_area or "misc",
			case.name,
			case.source
		)

		if ok then
			local actual = lisp.to_string(result)

			if case.expected ~= nil and actual ~= case.expected then
				local area = case.feature_area or "misc"
				area_counts[area] = (area_counts[area] or 0) + 1
				xfailed = xfailed + 1
				goto continue
			end

			error(
				string.format(
					"%s\nexpected feature to remain unsupported for now\nactual: %s",
					label,
					actual
				),
				0
			)
		end

		local message = errors.message(result)

		if case.expect_error_contains ~= nil then
			if string.find(message, case.expect_error_contains, 1, true) == nil then
				error(
					string.format(
						"%s\nexpected unsupported error to contain: %s\nactual: %s",
						label,
						case.expect_error_contains,
						message
					),
					0
				)
			end
		end

		local area = case.feature_area or "misc"
		area_counts[area] = (area_counts[area] or 0) + 1
		xfailed = xfailed + 1
		::continue::
	end

	print(string.format("ok - %d expected-fail compatibility cases tracked", xfailed))

	for area, count in pairs(area_counts) do
		print(string.format("ok - %d expected-fail cases in %s", count, area))
	end
end

return future_spec
--[[
SPDX-License-Identifier: MPL-2.0
]]
