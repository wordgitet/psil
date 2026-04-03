--[[
SPDX-License-Identifier: MPL-2.0
]]

local reader = require("./reader")
local value = require("./value")

local dialect_hint = {}

local CL_MARKERS = {
	block = true,
	defparameter = true,
	defun = true,
	defvar = true,
	flet = true,
	labels = true,
	macrolet = true,
	["return-from"] = true,
	setq = true,
}

local SCHEME_MARKERS = {
	["call/cc"] = true,
	define = true,
	["define-record-type"] = true,
	["define-syntax"] = true,
	["define-values"] = true,
	["let-syntax"] = true,
	["letrec-syntax"] = true,
	["set!"] = true,
}

local function dialect_label(name)
	if name == "cl-compat" then
		return "Common Lisp"
	end

	return "Scheme"
end

local function tail_name(symbol_name)
	return string.match(symbol_name, "([^:]+)$") or symbol_name
end

local function marker_for_active_dialect(active_dialect)
	if active_dialect == "cl-compat" then
		return SCHEME_MARKERS, "scheme"
	end

	return CL_MARKERS, "cl-compat"
end

local function detect_from_forms(forms, active_dialect)
	local markers, detected_dialect = marker_for_active_dialect(active_dialect)

	for _, form in ipairs(forms) do
		if value.is_list(form) and #form.items > 0 and value.is_symbol(form.items[1]) then
			local head_name = string.lower(tail_name(form.items[1].name))

			if markers[head_name] then
				return {
					active_dialect = active_dialect,
					detected_dialect = detected_dialect,
					head = head_name,
				}
			end
		end
	end

	return nil
end

local function detect_from_source(source, active_dialect)
	local markers, detected_dialect = marker_for_active_dialect(active_dialect)

	for head_name in pairs(markers) do
		local pattern = string.format("^%%s*%%(%s*%s%%f[^%%a%%-_/!?+*<>=]", head_name)

		if string.match(source, pattern) ~= nil then
			return {
				active_dialect = active_dialect,
				detected_dialect = detected_dialect,
				head = head_name,
			}
		end
	end

	return nil
end

function dialect_hint.detect(source, active_dialect)
	if type(source) ~= "string" or source == "" then
		return nil
	end

	if active_dialect ~= "scheme" and active_dialect ~= "cl-compat" then
		return nil
	end

	local ok, forms = pcall(reader.read_all, source, {
		dialect = active_dialect,
	})

	if ok then
		return detect_from_forms(forms, active_dialect)
	end

	return detect_from_source(source, active_dialect)
end

function dialect_hint.build_error(source, active_dialect, frontend)
	local detected = dialect_hint.detect(source, active_dialect)

	if detected == nil then
		return nil
	end

	local advice

	if frontend == "host" then
		if detected.detected_dialect == "cl-compat" then
			advice = "restart with --cl"
		else
			advice = "restart without --cl"
		end
	else
		if detected.detected_dialect == "cl-compat" then
			advice = "switch to CL mode"
		else
			advice = "switch to Scheme mode"
		end
	end

	return {
		kind = "dialect",
		message = string.format(
			"this looks like %s code, but the current session is in %s mode; hint: %s",
			dialect_label(detected.detected_dialect),
			dialect_label(detected.active_dialect),
			advice
		),
		detail = detected.head,
	}
end

return dialect_hint
