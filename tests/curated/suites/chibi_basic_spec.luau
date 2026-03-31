--[[
SPDX-License-Identifier: MPL-2.0
]]

local chibi_basic_cases = require("../cases/chibi_basic_cases")
local source_suite = require("../support/source_suite")

local chibi_basic_spec = {}

function chibi_basic_spec.run()
	source_suite.run("chibi_basic", chibi_basic_cases)
end

return chibi_basic_spec