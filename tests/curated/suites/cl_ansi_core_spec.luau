--[[
SPDX-License-Identifier: MPL-2.0
]]

local cl_ansi_core_cases = require("../cases/cl_ansi_core_cases")
local source_suite = require("../support/source_suite")

local cl_ansi_core_spec = {}

function cl_ansi_core_spec.run()
	source_suite.run("common_lisp_ansi_core", cl_ansi_core_cases, {
		dialect = "cl-compat",
	})
end

return cl_ansi_core_spec
