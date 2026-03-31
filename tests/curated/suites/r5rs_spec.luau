--[[
SPDX-License-Identifier: MPL-2.0
]]

local r5rs_cases = require("../cases/r5rs_cases")
local source_suite = require("../support/source_suite")

local r5rs_spec = {}

function r5rs_spec.run()
	source_suite.run("r5rs_subset", r5rs_cases)
end

return r5rs_spec