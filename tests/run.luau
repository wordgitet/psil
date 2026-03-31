local suite_registry = {
	{
		id = "core",
		kind = "core",
		load = function()
			return require("./core/core_spec")
		end,
	},
	{
		id = "expand",
		kind = "core",
		load = function()
			return require("./core/expand_spec")
		end,
	},
	{
		id = "norvig",
		kind = "curated",
		load = function()
			return require("./curated/suites/norvig_spec")
		end,
	},
	{
		id = "chibi_basic",
		kind = "curated",
		load = function()
			return require("./curated/suites/chibi_basic_spec")
		end,
	},
	{
		id = "chibi_macro",
		kind = "curated",
		load = function()
			return require("./curated/suites/chibi_macro_spec")
		end,
	},
	{
		id = "cl_subset",
		kind = "curated",
		load = function()
			return require("./curated/suites/cl_spec")
		end,
	},
	{
		id = "r5rs_subset",
		kind = "curated",
		load = function()
			return require("./curated/suites/r5rs_spec")
		end,
	},
	{
		id = "r7rs_subset",
		kind = "curated",
		load = function()
			return require("./curated/suites/r7rs_spec")
		end,
	},
	{
		id = "sicp_subset",
		kind = "curated",
		load = function()
			return require("./curated/suites/sicp_spec")
		end,
	},
	{
		id = "roblox_session",
		kind = "core",
		load = function()
			return require("./core/roblox_session_spec")
		end,
	},
	{
		id = "future",
		kind = "curated",
		load = function()
			return require("./curated/suites/future_spec")
		end,
	},
	{
		id = "repl",
		kind = "core",
		load = function()
			return require("./core/repl_spec")
		end,
	},
}

local passed = 0

for _, entry in ipairs(suite_registry) do
	local suite = entry.load()
	suite.run()
	passed = passed + 1
end

print(string.format("ok - %d test suites passed", passed))
--[[
SPDX-License-Identifier: MPL-2.0
]]
