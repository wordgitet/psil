local norvig_cases = require("../cases/norvig_cases")
local source_suite = require("../support/source_suite")

local norvig_spec = {}

function norvig_spec.run()
	source_suite.run("norvig_lispy", norvig_cases)
end

return norvig_spec
--[[
SPDX-License-Identifier: MPL-2.0
]]
