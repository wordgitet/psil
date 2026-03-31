local host_io = {}

-- Host-side I/O adapter used by the shared builtin layer.
-- This wraps stdout, argv, environment variables, clocks, and a small set of
-- file operations behind the interface the core runtime expects.

function host_io.new(options)
	local opts = options or {}
	local env = opts.env or {}

	if next(env) == nil and os ~= nil and type(os.getenv) == "function" then
		local names = {
			"PATH",
			"HOME",
			"USER",
			"SHELL",
			"TERM",
		}

		for _, name in ipairs(names) do
			local value = os.getenv(name)

			if value ~= nil then
				env[name] = value
			end
		end
	end

	return {
		write = opts.write or function(_, text)
			print(text)
		end,
		argv = opts.argv or {},
		env = env,
	}
end

return host_io
--[[
SPDX-License-Identifier: MPL-2.0
]]
