local chibi_macro_cases = require("../cases/chibi_macro_cases")
local source_suite = require("../support/source_suite")

local chibi_macro_spec = {}

function chibi_macro_spec.run()
	source_suite.run("chibi_macros", chibi_macro_cases)
end

return chibi_macro_spec
--[[
SPDX-License-Identifier: MPL-2.0
]]
