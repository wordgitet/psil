local errors = require("../../lib/errors")

local assert_mod = {}

function assert_mod.equal(actual, expected, label)
	if actual ~= expected then
		error(
			string.format(
				"%s\nexpected: %s\nactual: %s",
				label or "assert.equal failed",
				tostring(expected),
				tostring(actual)
			),
			0
		)
	end
end

function assert_mod.truthy(value, label)
	if not value then
		error(label or "assert.truthy failed", 0)
	end
end

function assert_mod.errors(fn, expected_fragment, label)
	local ok, err = pcall(fn)

	if ok then
		error(label or "assert.errors failed: expected an error", 0)
	end

	if expected_fragment ~= nil then
		local message = errors.message(err)

		if string.find(message, expected_fragment, 1, true) == nil then
			error(
				string.format(
					"%s\nexpected error to contain: %s\nactual: %s",
					label or "assert.errors failed",
					expected_fragment,
					message
				),
				0
			)
		end
	end
end

return assert_mod
--[[
SPDX-License-Identifier: MPL-2.0
]]
