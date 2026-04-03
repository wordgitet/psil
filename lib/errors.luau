--[[
SPDX-License-Identifier: MPL-2.0
]]

local value = require("./value")

local errors = {}

function errors.raise(kind, message, detail)
	error({
		kind = kind,
		message = message,
		detail = detail,
	}, 0)
end

function errors.message(err)
	if value.is_exception(err) then
		return err.message
	end

	if type(err) == "table" and type(err.message) == "string" then
		return err.message
	end

	return tostring(err)
end

function errors.format(err)
	if value.is_exception(err) then
		return string.format("error: %s", err.message)
	end

	if type(err) == "table" and type(err.message) == "string" then
		if err.detail ~= nil then
			return string.format("%s: %s (%s)", err.kind or "error", err.message, tostring(err.detail))
		end

		return string.format("%s: %s", err.kind or "error", err.message)
	end

	return tostring(err)
end

function errors.exception(message, irritants, flags)
	return value.exception(message, irritants, flags)
end

function errors.is_flow_control(err)
	return type(err) == "table"
		and (
			err.kind == "continuation_escape"
			or err.kind == "continuation_transfer"
			or err.kind == "block_return"
			or err.kind == "go_signal"
			or err.kind == "interrupt"
			or err.kind == "guard_raise"
		)
end

function errors.to_condition(err)
	if value.is_exception(err) then
		return err
	end

	if type(err) == "table" and err.kind == "scheme_raise" then
		return err.object
	end

	if type(err) == "table" and type(err.kind) == "string" and type(err.message) == "string" then
		local irritants = {}

		if err.detail ~= nil then
			irritants[1] = err.detail
		end

		return value.exception(err.message, irritants, {
			file_error = err.kind == "file",
			read_error = err.kind == "parse",
		})
	end

	return err
end

return errors
