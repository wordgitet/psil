--[[
SPDX-License-Identifier: MPL-2.0
]]

local sicp_cases = require("../cases/sicp_cases")
local source_suite = require("../support/source_suite")

local sicp_spec = {}

function sicp_spec.run()
	source_suite.run("sicp_subset", sicp_cases)
end

return sicp_spec