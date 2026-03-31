local r7rs_cases = require("../cases/r7rs_cases")
local source_suite = require("../support/source_suite")

local r7rs_spec = {}

function r7rs_spec.run()
	source_suite.run("r7rs_subset", r7rs_cases)
end

return r7rs_spec
--[[
SPDX-License-Identifier: MPL-2.0
]]
