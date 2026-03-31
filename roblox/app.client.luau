--[[
SPDX-License-Identifier: MPL-2.0
]]

local gui_service = game:GetService("GuiService")
local players = game:GetService("Players")
local replicated_storage = game:GetService("ReplicatedStorage")
local starter_gui = game:GetService("StarterGui")
local user_input_service = game:GetService("UserInputService")
local run_service = game:GetService("RunService")

local local_player = players.LocalPlayer
local player_gui = local_player:WaitForChild("PlayerGui")
local psil = require(replicated_storage:WaitForChild("Psil"))

local palette = {
	bg = Color3.fromRGB(13, 17, 23),
	panel = Color3.fromRGB(22, 27, 34),
	panel_alt = Color3.fromRGB(17, 21, 27),
	surface = Color3.fromRGB(1, 4, 9),
	border = Color3.fromRGB(48, 54, 61),
	text = Color3.fromRGB(201, 209, 217),
	muted = Color3.fromRGB(139, 148, 158),
	accent = Color3.fromRGB(88, 166, 255),
	accent_dim = Color3.fromRGB(31, 111, 235),
	accent_alt = Color3.fromRGB(210, 153, 34),
	error = Color3.fromRGB(248, 81, 73),
	success = Color3.fromRGB(63, 185, 80),
	print = Color3.fromRGB(165, 214, 255),
	result = Color3.fromRGB(126, 231, 135),
	comment = Color3.fromRGB(139, 148, 158),
	string = Color3.fromRGB(165, 214, 255),
	keyword = Color3.fromRGB(255, 123, 114),
}

-- SESSION INITIALIZATION
local session = psil.new_session()
local history = {}

local function create(class_name, props)
	local instance = Instance.new(class_name)
	for key, value in pairs(props) do
		if key ~= "Parent" and key ~= "Stroke" and key ~= "Corner" then
			instance[key] = value
		end
	end

	if props.Corner then
		local corner = Instance.new("UICorner")
		corner.CornerRadius = typeof(props.Corner) == "UDim" and props.Corner or UDim.new(0, props.Corner)
		corner.Parent = instance
	end

	if props.Stroke then
		local stroke = Instance.new("UIStroke")
		stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
		stroke.Color = props.Stroke.Color or palette.border
		stroke.Thickness = props.Stroke.Thickness or 1
		stroke.Transparency = props.Stroke.Transparency or 0
		stroke.Parent = instance
	end

	if props.Parent then
		instance.Parent = props.Parent
	end
	return instance
end

local function escape_rich_text(text)
	return tostring(text):gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;")
end

local function hide_core_ui()
	pcall(function() starter_gui:SetCoreGuiEnabled(Enum.CoreGuiType.All, false) end)
	pcall(function() starter_gui:SetCore("TopbarEnabled", false) end)
	gui_service.AutoSelectGuiEnabled = false
end

hide_core_ui()
task.delay(1, hide_core_ui)

local function create_button(parent, text, accent, icon)
	local button = create("TextButton", {
		Name = text:gsub("%s+", ""),
		Parent = parent,
		AutomaticSize = Enum.AutomaticSize.X,
		BackgroundColor3 = accent,
		BorderSizePixel = 0,
		Font = Enum.Font.Code,
		Size = UDim2.fromOffset(0, 32),
		Text = text,
		TextColor3 = Color3.new(1, 1, 1),
		TextSize = 14,
		Corner = 6,
	})

	create("UIPadding", {
		Parent = button,
		PaddingLeft = UDim.new(0, 12),
		PaddingRight = UDim.new(0, 12),
	})

	button.MouseEnter:Connect(function()
		button.BackgroundTransparency = 0.2
	end)
	button.MouseLeave:Connect(function()
		button.BackgroundTransparency = 0
	end)

	return button
end

local function set_button_state(button, active)
	if active then
		button.BackgroundColor3 = palette.accent
		button.TextColor3 = palette.bg
	else
		button.BackgroundColor3 = palette.panel_alt
		button.TextColor3 = palette.muted
	end
end

local screen_gui = create("ScreenGui", {
	Name = "PsilGui",
	Parent = player_gui,
	IgnoreGuiInset = true,
	ResetOnSpawn = false,
	ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
})

local root = create("Frame", {
	Name = "Root",
	Parent = screen_gui,
	BackgroundColor3 = palette.bg,
	BorderSizePixel = 0,
	Size = UDim2.fromScale(1, 1),
})

local top_bar = create("Frame", {
	Name = "TopBar",
	Parent = root,
	BackgroundColor3 = palette.panel,
	BorderSizePixel = 0,
	Size = UDim2.new(1, 0, 0, 48),
	Stroke = { Color = palette.border },
})

local title_label = create("TextLabel", {
	Name = "Title",
	Parent = top_bar,
	BackgroundTransparency = 1,
	Font = Enum.Font.Code,
	Position = UDim2.fromOffset(16, 0),
	Size = UDim2.new(0, 100, 1, 0),
	Text = "λ PSIL",
	TextColor3 = palette.accent,
	TextSize = 20,
	TextXAlignment = Enum.TextXAlignment.Left,
})

local nav_container = create("Frame", {
	Name = "Nav",
	Parent = top_bar,
	BackgroundTransparency = 1,
	Position = UDim2.fromOffset(120, 0),
	Size = UDim2.new(1, -240, 1, 0),
})

create("UIListLayout", {
	Parent = nav_container,
	FillDirection = Enum.FillDirection.Horizontal,
	Padding = UDim.new(0, 8),
	VerticalAlignment = Enum.VerticalAlignment.Center,
})

local editor_tab_btn = create_button(nav_container, "Editor", palette.accent)
local repl_tab_btn = create_button(nav_container, "REPL", palette.panel_alt)

local actions_container = create("Frame", {
	Name = "Actions",
	Parent = top_bar,
	AnchorPoint = Vector2.new(1, 0),
	BackgroundTransparency = 1,
	Position = UDim2.new(1, -16, 0, 0),
	Size = UDim2.new(0, 300, 1, 0),
})

create("UIListLayout", {
	Parent = actions_container,
	FillDirection = Enum.FillDirection.Horizontal,
	HorizontalAlignment = Enum.HorizontalAlignment.Right,
	Padding = UDim.new(0, 8),
	VerticalAlignment = Enum.VerticalAlignment.Center,
})

local clear_btn = create_button(actions_container, "Clear", palette.panel_alt)
local reset_btn = create_button(actions_container, "Reset", palette.accent_alt)
local stop_btn = create_button(actions_container, "Stop", palette.error)
stop_btn.Visible = false

local content_area = create("Frame", {
	Name = "Content",
	Parent = root,
	BackgroundTransparency = 1,
	Position = UDim2.fromOffset(0, 48),
	Size = UDim2.new(1, 0, 1, -48),
})

local editor_view = create("Frame", {
	Name = "EditorView",
	Parent = content_area,
	BackgroundTransparency = 1,
	Size = UDim2.fromScale(1, 1),
})

local repl_view = create("Frame", {
	Name = "ReplView",
	Parent = content_area,
	BackgroundTransparency = 1,
	Size = UDim2.fromScale(1, 1),
	Visible = false,
})

-- EDITOR IMPLEMENTATION
local editor_main = create("Frame", {
	Name = "Main",
	Parent = editor_view,
	BackgroundColor3 = palette.panel,
	Position = UDim2.new(0, 16, 0, 16),
	Size = UDim2.new(1, -32, 0.7, -24),
	Corner = 8,
	Stroke = { Color = palette.border },
})

local editor_scroll = create("ScrollingFrame", {
	Name = "EditorScroll",
	Parent = editor_main,
	Active = true,
	BackgroundTransparency = 1,
	BorderSizePixel = 0,
	Size = UDim2.new(1, 0, 1, -24),
	CanvasSize = UDim2.new(0, 0, 0, 0),
	ScrollBarThickness = 4,
	ScrollBarImageColor3 = palette.border,
})

local gutter = create("Frame", {
	Name = "Gutter",
	Parent = editor_scroll,
	BackgroundColor3 = palette.panel_alt,
	BorderSizePixel = 0,
	Size = UDim2.new(0, 40, 1, 0),
})

create("Frame", {
	Name = "GutterBorder",
	Parent = gutter,
	AnchorPoint = Vector2.new(1, 0),
	BackgroundColor3 = palette.border,
	BorderSizePixel = 0,
	Position = UDim2.fromScale(1, 0),
	Size = UDim2.new(0, 1, 1, 0),
})

local line_numbers_label = create("TextLabel", {
	Name = "Lines",
	Parent = gutter,
	BackgroundTransparency = 1,
	Font = Enum.Font.Code,
	Size = UDim2.new(1, -8, 1, 0),
	Text = "1",
	TextColor3 = palette.muted,
	TextSize = 14,
	TextXAlignment = Enum.TextXAlignment.Right,
	TextYAlignment = Enum.TextYAlignment.Top,
})

create("UIPadding", {
	Parent = line_numbers_label,
	PaddingTop = UDim.new(0, 12),
})

local editor_container = create("Frame", {
	Name = "EditorContainer",
	Parent = editor_scroll,
	BackgroundTransparency = 1,
	Position = UDim2.fromOffset(40, 0),
	Size = UDim2.new(1, -40, 1, 0),
})

local editor_box = create("TextBox", {
	Name = "Editor",
	Parent = editor_container,
	BackgroundTransparency = 1,
	ClearTextOnFocus = false,
	Font = Enum.Font.Code,
	MultiLine = true,
	Position = UDim2.fromOffset(8, 12),
	Size = UDim2.new(1, -16, 1, -12),
	Text = ";; Psil Editor\n(define (fib n)\n  (if (< n 2) n\n      (+ (fib (- n 1))\n         (fib (- n 2)))))\n\n(print (fib 10))",
	TextColor3 = palette.text,
	TextSize = 14,
	TextWrapped = false,
	TextXAlignment = Enum.TextXAlignment.Left,
	TextYAlignment = Enum.TextYAlignment.Top,
})

local editor_footer = create("Frame", {
	Name = "Footer",
	Parent = editor_main,
	AnchorPoint = Vector2.new(0, 1),
	BackgroundColor3 = palette.panel_alt,
	Position = UDim2.fromScale(0, 1),
	Size = UDim2.new(1, 0, 0, 24),
})

create("Frame", {
	Name = "Border",
	Parent = editor_footer,
	BackgroundColor3 = palette.border,
	BorderSizePixel = 0,
	Size = UDim2.new(1, 0, 0, 1),
})

local cursor_info = create("TextLabel", {
	Name = "CursorInfo",
	Parent = editor_footer,
	BackgroundTransparency = 1,
	Font = Enum.Font.Code,
	Position = UDim2.new(1, -16, 0, 0),
	AnchorPoint = Vector2.new(1, 0),
	Size = UDim2.new(0, 200, 1, 0),
	Text = "Ln 1, Col 1",
	TextColor3 = palette.muted,
	TextSize = 12,
	TextXAlignment = Enum.TextXAlignment.Right,
})

local run_btn = create_button(editor_view, "Run Buffer", palette.success)
run_btn.AnchorPoint = Vector2.new(1, 1)
run_btn.Position = UDim2.new(1, -16, 0.7, -32)
run_btn.ZIndex = 10

local editor_output_panel = create("Frame", {
	Name = "Output",
	Parent = editor_view,
	BackgroundColor3 = palette.panel,
	Position = UDim2.new(0, 16, 0.7, 8),
	Size = UDim2.new(1, -32, 0.3, -24),
	Corner = 8,
	Stroke = { Color = palette.border },
})

local output_scroll = create("ScrollingFrame", {
	Name = "Scroll",
	Parent = editor_output_panel,
	Active = true,
	BackgroundTransparency = 1,
	BorderSizePixel = 0,
	Position = UDim2.fromOffset(12, 12),
	Size = UDim2.new(1, -24, 1, -24),
	ScrollBarThickness = 4,
	ScrollBarImageColor3 = palette.border,
	CanvasSize = UDim2.fromOffset(0, 0),
})

local output_list = create("Frame", {
	Name = "List",
	Parent = output_scroll,
	BackgroundTransparency = 1,
	Size = UDim2.new(1, 0, 0, 0),
})

create("UIListLayout", {
	Parent = output_list,
	Padding = UDim.new(0, 4),
})

-- REPL IMPLEMENTATION
local terminal_main = create("Frame", {
	Name = "Terminal",
	Parent = repl_view,
	BackgroundColor3 = palette.surface,
	Position = UDim2.new(0, 16, 0, 16),
	Size = UDim2.new(1, -32, 1, -32),
	Corner = 8,
	Stroke = { Color = palette.border },
})

local repl_scroll = create("ScrollingFrame", {
	Name = "Scroll",
	Parent = terminal_main,
	Active = true,
	BackgroundTransparency = 1,
	BorderSizePixel = 0,
	Position = UDim2.fromOffset(12, 12),
	Size = UDim2.new(1, -24, 1, -64),
	ScrollBarThickness = 4,
	ScrollBarImageColor3 = palette.border,
	CanvasSize = UDim2.fromOffset(0, 0),
})

local repl_list = create("Frame", {
	Name = "List",
	Parent = repl_scroll,
	BackgroundTransparency = 1,
	Size = UDim2.new(1, 0, 0, 0),
})

create("UIListLayout", {
	Parent = repl_list,
	Padding = UDim.new(0, 4),
})

local repl_input_container = create("Frame", {
	Name = "InputBar",
	Parent = terminal_main,
	AnchorPoint = Vector2.new(0, 1),
	BackgroundColor3 = palette.panel_alt,
	Position = UDim2.fromScale(0, 1),
	Size = UDim2.new(1, 0, 0, 40),
})

create("Frame", {
	Name = "Border",
	Parent = repl_input_container,
	BackgroundColor3 = palette.border,
	BorderSizePixel = 0,
	Size = UDim2.new(1, 0, 0, 1),
})

local prompt_label = create("TextLabel", {
	Name = "Prompt",
	Parent = repl_input_container,
	BackgroundTransparency = 1,
	Font = Enum.Font.Code,
	Position = UDim2.fromOffset(12, 0),
	Size = UDim2.new(0, 50, 1, 0),
	Text = "psil>",
	TextColor3 = palette.accent,
	TextSize = 16,
	TextXAlignment = Enum.TextXAlignment.Left,
})

local repl_input = create("TextBox", {
	Name = "Input",
	Parent = repl_input_container,
	BackgroundTransparency = 1,
	ClearTextOnFocus = false,
	Font = Enum.Font.Code,
	Position = UDim2.fromOffset(62, 0),
	Size = UDim2.new(1, -74, 1, 0),
	Text = "",
	PlaceholderText = "Type Lisp expression...",
	PlaceholderColor3 = palette.muted,
	TextColor3 = palette.text,
	TextSize = 16,
	TextXAlignment = Enum.TextXAlignment.Left,
})

-- LOGIC
local function sync_running_state()
	local running = session:is_running()
	local stopping = session:is_stopping()
	
	stop_btn.Visible = running
	stop_btn.Text = stopping and "Stopping..." or "Stop"
	run_btn.Text = running and "Running..." or "Run Buffer"
	run_btn.BackgroundColor3 = running and palette.panel_alt or palette.success
end

session.callbacks.on_state_change = function()
	sync_running_state()
end

local function create_entry(parent, entry)
	if entry.kind == "prompt" then
		local row = create("Frame", {
			Parent = parent,
			AutomaticSize = Enum.AutomaticSize.Y,
			BackgroundTransparency = 1,
			Size = UDim2.new(1, 0, 0, 0),
		})

		create("TextLabel", {
			Name = "Prompt",
			Parent = row,
			AutomaticSize = Enum.AutomaticSize.XY,
			BackgroundTransparency = 1,
			Font = Enum.Font.Code,
			Position = UDim2.fromOffset(0, 0),
			Size = UDim2.fromOffset(0, 0),
			Text = "psil>",
			TextColor3 = palette.accent,
			TextSize = 14,
			TextXAlignment = Enum.TextXAlignment.Left,
			TextYAlignment = Enum.TextYAlignment.Top,
		})

		create("TextLabel", {
			Name = "Input",
			Parent = row,
			AutomaticSize = Enum.AutomaticSize.Y,
			BackgroundTransparency = 1,
			Font = Enum.Font.Code,
			Position = UDim2.fromOffset(44, 0),
			Size = UDim2.new(1, -44, 0, 0),
			Text = escape_rich_text(entry.text),
			TextColor3 = palette.text,
			TextSize = 14,
			TextWrapped = true,
			TextXAlignment = Enum.TextXAlignment.Left,
			TextYAlignment = Enum.TextYAlignment.Top,
		})

		return row
	end

	local color = palette.text
	local prefix = ""

	if entry.kind == "result" then
		prefix = "=> "
		color = palette.result
	elseif entry.kind == "print" then
		color = palette.print
	elseif entry.kind == "error" then
		prefix = "!! "
		color = palette.error
	elseif entry.kind == "status" then
		prefix = "; "
		color = palette.muted
	end

	return create("TextLabel", {
		Parent = parent,
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundTransparency = 1,
		Font = Enum.Font.Code,
		RichText = true,
		Size = UDim2.new(1, 0, 0, 0),
		Text = string.format("<font color=\"#%s\">%s</font>%s",
			color:ToHex(), escape_rich_text(prefix), escape_rich_text(entry.text)),
		TextColor3 = palette.text,
		TextSize = 14,
		TextWrapped = true,
		TextXAlignment = Enum.TextXAlignment.Left,
	})
end

local function refresh_history_views()
	task.defer(function()
		output_scroll.CanvasSize = UDim2.fromOffset(0, output_list.UIListLayout.AbsoluteContentSize.Y)
		output_scroll.CanvasPosition = Vector2.new(0, output_scroll.CanvasSize.Y.Offset)

		repl_scroll.CanvasSize = UDim2.fromOffset(0, repl_list.UIListLayout.AbsoluteContentSize.Y)
		repl_scroll.CanvasPosition = Vector2.new(0, repl_scroll.CanvasSize.Y.Offset)
	end)
end

local function append_history(kind, text, target)
	local entry = {
		kind = kind,
		text = text,
		target = target or "both",
	}

	table.insert(history, entry)

	if entry.target == "editor" or entry.target == "both" then
		create_entry(output_list, entry)
	end

	if entry.target == "repl" or entry.target == "both" then
		create_entry(repl_list, entry)
	end

	refresh_history_views()
end

session.callbacks.on_output = function(entry)
	append_history(entry.kind, entry.text, entry.target or "both")
end

local function update_editor_info()
	local text = editor_box.Text
	local cursor = editor_box.CursorPosition
	
	if cursor == -1 then cursor = #text + 1 end
	
	local before = string.sub(text, 1, cursor - 1)
	local _, lines = string.gsub(before, "\n", "")
	local last_newline = string.find(string.reverse(before), "\n")
	local col = last_newline and last_newline or (#before + 1)
	
	cursor_info.Text = string.format("Ln %d, Col %d", lines + 1, col)
	
	local _, total_lines = string.gsub(text, "\n", "")
	local line_nums = {}
	for i = 1, total_lines + 1 do
		table.insert(line_nums, tostring(i))
	end
	line_numbers_label.Text = table.concat(line_nums, "\n")

	-- Sync scrolling frame canvas size
	local height = math.max(editor_scroll.AbsoluteSize.Y, editor_box.TextBounds.Y + 40)
	editor_scroll.CanvasSize = UDim2.new(0, 0, 0, height)
	gutter.Size = UDim2.new(0, 40, 0, height)
	editor_container.Size = UDim2.new(1, -40, 0, height)
end

editor_box:GetPropertyChangedSignal("Text"):Connect(update_editor_info)
editor_box:GetPropertyChangedSignal("CursorPosition"):Connect(update_editor_info)
editor_box:GetPropertyChangedSignal("TextBounds"):Connect(update_editor_info)
update_editor_info()

local function set_tab(mode)
	editor_view.Visible = mode == "editor"
	repl_view.Visible = mode == "repl"
	set_button_state(editor_tab_btn, mode == "editor")
	set_button_state(repl_tab_btn, mode == "repl")
	clear_btn.Visible = mode == "repl"
	
	if mode == "editor" then editor_box:CaptureFocus()
	else repl_input:CaptureFocus() end
end

editor_tab_btn.Activated:Connect(function() set_tab("editor") end)
repl_tab_btn.Activated:Connect(function() set_tab("repl") end)

clear_btn.Activated:Connect(function()
	for _, v in ipairs(output_list:GetChildren()) do if not v:IsA("UIListLayout") then v:Destroy() end end
	for _, v in ipairs(repl_list:GetChildren()) do if not v:IsA("UIListLayout") then v:Destroy() end end
	session:clear_history()
	append_history("status", "cleared", "repl")
end)

reset_btn.Activated:Connect(function()
	session:reset()
	append_history("status", "session reset", "repl")
end)

stop_btn.Activated:Connect(function()
	session:cancel()
end)

run_btn.Activated:Connect(function()
	if session:is_running() then return end
	local src = editor_box.Text
	if src == "" then return end
	task.spawn(function() session:eval_buffer(src) end)
end)

repl_input.FocusLost:Connect(function(enter)
	if not enter then return end
	local src = repl_input.Text
	if src == "" then return end
	append_history("prompt", src, "repl")
	repl_input.Text = ""
	task.spawn(function() session:eval_line(src) end)
	task.defer(function() repl_input:CaptureFocus() end)
end)

local function replace_selection(box, insert_text)
	local text = box.Text
	local cursor = box.CursorPosition
	local selection = box.SelectionStart

	if cursor < 0 then
		box.Text = text .. insert_text
		task.defer(function()
			box.CursorPosition = #box.Text + 1
			box.SelectionStart = #box.Text + 1
		end)
		return
	end

	local start_index = cursor
	local end_index = cursor

	if selection ~= nil and selection > 0 and selection ~= cursor then
		start_index = math.min(cursor, selection)
		end_index = math.max(cursor, selection)
	end

	local before = string.sub(text, 1, start_index - 1)
	local after = string.sub(text, end_index)

	box.Text = before .. insert_text .. after

	local new_cursor = #before + #insert_text + 1

	task.defer(function()
		box.CursorPosition = new_cursor
		box.SelectionStart = new_cursor
	end)
end

user_input_service.InputBegan:Connect(function(input, processed)
	local focused = user_input_service:GetFocusedTextBox()

	if focused == editor_box or focused == repl_input then
		if input.KeyCode == Enum.KeyCode.Tab then
			replace_selection(focused, "  ")
			return
		end

		if focused == editor_box
			and input.KeyCode == Enum.KeyCode.Return
			and (
				user_input_service:IsKeyDown(Enum.KeyCode.LeftControl)
				or user_input_service:IsKeyDown(Enum.KeyCode.RightControl)
			) then
			task.spawn(function()
				if session:is_running() then return end
				local src = editor_box.Text
				if src == "" then return end
				session:eval_buffer(src)
			end)
			return
		end
	end
end)

set_tab("editor")
append_history("status", "Psil playground ready", "repl")