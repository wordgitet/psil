local cl_cases = require("../cases/cl_cases")
local source_suite = require("../support/source_suite")

local cl_spec = {}

function cl_spec.run()
	source_suite.run("common_lisp_subset", cl_cases)
end

return cl_spec
--[[
SPDX-License-Identifier: MPL-2.0
]]
