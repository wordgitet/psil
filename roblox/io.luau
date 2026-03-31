--[[
SPDX-License-Identifier: MPL-2.0
]]

local roblox_io = {}

function roblox_io.new(callbacks)
	local handlers = callbacks or {}

	return {
		write = handlers.write or function(_, text)
			print(text)
		end,
	}
end

return roblox_io