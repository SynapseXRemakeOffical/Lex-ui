--[[
	Project Lexia — UI Library  (Luau / Roblox executor)
	================================================================
	A modern, themeable script-hub UI library in the Obsidian / LinoriaLib
	model. Built from the "Project Lexia" design handoff (cyan + lavender,
	"Elaina" aesthetic).

	Architecture:
		Library  ->  Window  ->  Tab  ->  Groupbox / Tabbox  ->  Elements
		(Toggle, Button, Slider, Dropdown, Input, Label, Divider, KeyPicker,
		 ColorPicker) + Notifications + runtime ThemeManager hooks.

	Flags:
		Library.Toggles[idx]  — every toggle, addressable by key.
		Library.Options[idx]  — every other element (slider/dropdown/input/…).
		Both expose .Value / :SetValue(v) / :OnChanged(fn) so SaveManager can
		serialize the whole UI to JSON.

	Usage:
		local Library = loadstring(game:HttpGet(".../Library.luau"))()
		local Window  = Library:CreateWindow({ Title = "Project Lexia" })
		local Tab     = Window:AddTab("Main")
		local Box     = Tab:AddLeftGroupbox("Macro")
		Box:AddToggle("MyToggle", { Text = "Egg Macro", Default = true })

	This is an original implementation; it mirrors the Obsidian API shape so
	scripts written for that style port over, but shares no source.
]]

--// Services //--
local TweenService     = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")
local RunService       = game:GetService("RunService")
local Players          = game:GetService("Players")
local CoreGui          = game:GetService("CoreGui")

local LocalPlayer = Players.LocalPlayer

--// Library root //--
local Library = {
	Version = "1.0.0",

	-- flag registries (Linoria/Obsidian style)
	Toggles = {},
	Options = {},

	-- live state
	Windows = {},
	Connections = {},
	OpenedFrames = {},      -- dropdowns / popovers currently open
	Notifications = {},
	Registry = {},          -- color-theme registry
	DensityRegistry = {},   -- density-bound instances
	RadiusRegistry = {},    -- corner-radius-bound instances
	ThemeUpdaters = {},     -- custom callbacks fired on theme change

	-- behaviour
	ToggleKeybind = Enum.KeyCode.RightControl,
	Toggled = true,
	ReducedMotion = false,
	MinimizeKeyPicker = nil,

	-- typography
	Font = Enum.Font.GothamMedium,
	MonoFont = Enum.Font.Code,
}

----------------------------------------------------------------------
-- DESIGN TOKENS  (mapped from the wireframe :root variables)
----------------------------------------------------------------------
Library.Scheme = {
	Accent     = Color3.fromRGB(25, 215, 245),  -- #19D7F5 cyan
	Accent2    = Color3.fromRGB(185, 166, 255), -- #B9A6FF lavender

	Backdrop   = Color3.fromRGB(7, 14, 28),     -- #070E1C bg0
	Background  = Color3.fromRGB(12, 24, 48),    -- #0C1830 bg1
	Surface    = Color3.fromRGB(18, 34, 68),    -- #122244 bg2
	SurfaceHover = Color3.fromRGB(24, 48, 92),  -- #18305C bg3

	Outline    = Color3.fromRGB(86, 105, 138),  -- #56698A line (ink-faint)

	Text       = Color3.fromRGB(214, 226, 240), -- #D6E2F0 ink
	TextDim    = Color3.fromRGB(146, 166, 194), -- #92A6C2 ink-dim
	TextFaint  = Color3.fromRGB(86, 105, 138),  -- #56698A ink-faint
}

-- semantic (non-brand) colours
Library.Health = {
	Color3.fromRGB(255, 77, 77),   -- red
	Color3.fromRGB(255, 210, 77),  -- yellow
	Color3.fromRGB(77, 255, 136),  -- green
}

-- accent-derived transparencies (from accent-soft 16% / accent-line 55%)
local ACCENT_SOFT_T = 0.84
local ACCENT_LINE_T = 0.45
local GLOW_T        = 0.55

-- density presets {rowHeight, padding, gap}
Library.DensityPresets = {
	Compact  = { Row = 26, Pad = 11, Gap = 9  },
	Balanced = { Row = 30, Pad = 16, Gap = 14 },
	Spacious = { Row = 38, Pad = 22, Gap = 20 },
}
Library.Density = "Balanced"

-- radius presets {corner, smallCorner}
Library.RadiusPresets = {
	Sharp = { R = 3,  RS = 2 },
	Soft  = { R = 9,  RS = 6 },
}
Library.Radius = "Soft"

----------------------------------------------------------------------
-- LOW-LEVEL HELPERS
----------------------------------------------------------------------
local function New(class, props, children)
	local inst = Instance.new(class)
	local parent
	for k, v in next, props or {} do
		if k == "Parent" then parent = v else inst[k] = v end
	end
	for _, c in next, children or {} do c.Parent = inst end
	if parent then inst.Parent = parent end
	return inst
end

function Library:GetDensity()
	return self.DensityPresets[self.Density] or self.DensityPresets.Balanced
end

function Library:GetRadius()
	return self.RadiusPresets[self.Radius] or self.RadiusPresets.Soft
end

-- TweenService wrapper honouring reduced-motion
function Library:Tween(inst, duration, props, style, dir)
	if self.ReducedMotion then
		for k, v in next, props do inst[k] = v end
		return nil
	end
	local info = TweenInfo.new(duration, style or Enum.EasingStyle.Quad, dir or Enum.EasingDirection.Out)
	local t = TweenService:Create(inst, info, props)
	t:Play()
	return t
end

-- safe connection tracker
function Library:Connect(signal, fn)
	local c = signal:Connect(fn)
	table.insert(self.Connections, c)
	return c
end

----------------------------------------------------------------------
-- THEME REGISTRY
----------------------------------------------------------------------
-- register `instance` so that its `properties` (prop -> schemeKey) follow
-- the live Scheme. Transparencies set on the instance are preserved.
function Library:AddToRegistry(instance, properties)
	local data = { Instance = instance, Properties = properties }
	table.insert(self.Registry, data)
	-- apply immediately
	for prop, key in next, properties do
		local v = self.Scheme[key]
		if v ~= nil then instance[prop] = v end
	end
	return data
end

function Library:OnThemeChanged(fn)
	table.insert(self.ThemeUpdaters, fn)
	fn(self.Scheme)
	return fn
end

function Library:UpdateColors()
	for _, data in next, self.Registry do
		if data.Instance and data.Instance.Parent then
			for prop, key in next, data.Properties do
				local v = self.Scheme[key]
				if v ~= nil then
					pcall(function() self:Tween(data.Instance, 0.18, { [prop] = v }) end)
				end
			end
		end
	end
	for _, fn in next, self.ThemeUpdaters do
		pcall(fn, self.Scheme)
	end
end

-- density registry: kind = "Row" | "Pad" | "Gap"
function Library:BindDensity(instance, prop, kind, axis)
	table.insert(self.DensityRegistry, { Instance = instance, Prop = prop, Kind = kind, Axis = axis })
end

function Library:SetDensity(name)
	if not self.DensityPresets[name] then return end
	self.Density = name
	local d = self:GetDensity()
	for _, e in next, self.DensityRegistry do
		if e.Instance and e.Instance.Parent then
			local val = d[e.Kind]
			pcall(function()
				if e.Prop == "Size" then
					local s = e.Instance.Size
					e.Instance.Size = UDim2.new(s.X.Scale, s.X.Offset, s.Y.Scale, val)
				else
					e.Instance[e.Prop] = UDim.new(0, val)
				end
			end)
		end
	end
end

function Library:BindRadius(uicorner, small)
	table.insert(self.RadiusRegistry, { Instance = uicorner, Small = small })
	local r = self:GetRadius()
	uicorner.CornerRadius = UDim.new(0, small and r.RS or r.R)
end

function Library:SetRadius(name)
	if not self.RadiusPresets[name] then return end
	self.Radius = name
	local r = self:GetRadius()
	for _, e in next, self.RadiusRegistry do
		if e.Instance and e.Instance.Parent then
			e.Instance.CornerRadius = UDim.new(0, e.Small and r.RS or r.R)
		end
	end
end

----------------------------------------------------------------------
-- COMMON BUILDERS
----------------------------------------------------------------------
function Library:MakeCorner(parent, small)
	local c = New("UICorner", { Parent = parent })
	self:BindRadius(c, small)
	return c
end

-- 1px stroke at the line colour (or accent when `accent`)
function Library:MakeStroke(parent, accent, transparency)
	local stroke = New("UIStroke", {
		Parent = parent,
		Thickness = 1,
		ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
		Transparency = transparency or 0,
	})
	self:AddToRegistry(stroke, { Color = accent and "Accent" or "Outline" })
	if accent then stroke.Transparency = transparency or ACCENT_LINE_T end
	return stroke
end

-- a soft accent glow behind an element
function Library:MakeGlow(parent, accentKey)
	local glow = New("UIStroke", {
		Parent = parent,
		Thickness = 3,
		Transparency = GLOW_T,
		ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
	})
	self:AddToRegistry(glow, { Color = accentKey or "Accent" })
	return glow
end

function Library:MakeLabel(props)
	local lbl = New("TextLabel", {
		BackgroundTransparency = 1,
		Font = props.Mono and self.MonoFont or self.Font,
		Text = props.Text or "",
		TextSize = props.TextSize or 14,
		TextColor3 = self.Scheme[props.Color or "Text"],
		TextXAlignment = props.XAlign or Enum.TextXAlignment.Left,
		TextYAlignment = props.YAlign or Enum.TextYAlignment.Center,
		TextTransparency = props.TextTransparency or 0,
		RichText = props.RichText or false,
		Size = props.Size or UDim2.fromScale(1, 1),
		Position = props.Position,
		AutomaticSize = props.AutomaticSize,
		Parent = props.Parent,
	})
	self:AddToRegistry(lbl, { TextColor3 = props.Color or "Text" })
	return lbl
end

-- accent-soft fill (used for active rows / pills)
function Library:MakeFill(parent, accentKey)
	local f = New("Frame", {
		Parent = parent,
		BackgroundColor3 = self.Scheme[accentKey or "Accent"],
		BackgroundTransparency = ACCENT_SOFT_T,
		Size = UDim2.fromScale(1, 1),
		ZIndex = (parent.ZIndex or 1),
	})
	self:AddToRegistry(f, { BackgroundColor3 = accentKey or "Accent" })
	self:MakeCorner(f, true)
	return f
end

----------------------------------------------------------------------
-- GUI ROOT
----------------------------------------------------------------------
local function getParentGui()
	local ok, hui = pcall(function() return gethui() end)
	if ok and hui then return hui end
	local ok2, cg = pcall(function() return CoreGui end)
	if ok2 and cg then return cg end
	return LocalPlayer:WaitForChild("PlayerGui")
end

function Library:CreateScreenGui()
	if self.ScreenGui then return self.ScreenGui end
	local gui = New("ScreenGui", {
		Name = "LexiaLib_" .. tostring(math.random(1e5, 1e6)),
		ResetOnSpawn = false,
		ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
		IgnoreGuiInset = true,
		DisplayOrder = 9999,
	})
	-- try to protect from detection
	pcall(function()
		if syn and syn.protect_gui then syn.protect_gui(gui) end
	end)
	gui.Parent = getParentGui()
	self.ScreenGui = gui

	-- full-screen click catcher: closes popups when clicking outside them
	self.PopupCatcher = New("TextButton", {
		Name = "Catcher", Text = "", AutoButtonColor = false, Visible = false,
		BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), ZIndex = 4999,
		Parent = gui,
	})
	self.PopupCatcher.MouseButton1Click:Connect(function()
		self:CloseOpenedFrames()
	end)

	-- top-level popup holder (dropdown menus, colour popovers draw here)
	self.PopupHolder = New("Frame", {
		Name = "Popups",
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 1),
		ZIndex = 5000,
		Parent = gui,
	})
	return gui
end

function Library:ShowCatcher()
	if self.PopupCatcher then self.PopupCatcher.Visible = true end
end

function Library:RefreshCatcher()
	if not self.PopupCatcher then return end
	local any = false
	for _ in next, self.OpenedFrames do any = true break end
	self.PopupCatcher.Visible = any
end

-- close any open popup (dropdown menu / colour popover)
function Library:CloseOpenedFrames(except)
	for frame, closeFn in next, self.OpenedFrames do
		if frame ~= except then
			closeFn()
			self.OpenedFrames[frame] = nil
		end
	end
	if self.PopupCatcher then
		local any = false
		for _ in next, self.OpenedFrames do any = true break end
		self.PopupCatcher.Visible = any
	end
end

----------------------------------------------------------------------
-- NOTIFICATIONS  (toast)
----------------------------------------------------------------------
function Library:_ensureNotifyHolder()
	if self.NotifyHolder then return self.NotifyHolder end
	self:CreateScreenGui()
	local holder = New("Frame", {
		Name = "Notifications",
		AnchorPoint = Vector2.new(1, 1),
		Position = UDim2.new(1, -18, 1, -18),
		Size = UDim2.new(0, 300, 1, -36),
		BackgroundTransparency = 1,
		ZIndex = 6000,
		Parent = self.ScreenGui,
	}, {
		New("UIListLayout", {
			FillDirection = Enum.FillDirection.Vertical,
			HorizontalAlignment = Enum.HorizontalAlignment.Right,
			VerticalAlignment = Enum.VerticalAlignment.Bottom,
			Padding = UDim.new(0, 10),
			SortOrder = Enum.SortOrder.LayoutOrder,
		}),
	})
	self.NotifyHolder = holder
	return holder
end

-- Library:Notify("text", 5)  OR  Library:Notify({Title=, Description=, Time=, Accent=})
function Library:Notify(a, b)
	local info
	if typeof(a) == "table" then info = a else info = { Description = a, Time = b } end
	local title    = info.Title or "Project Lexia"
	local desc     = info.Description or info.Text or ""
	local duration = info.Time or 5
	local accentKey = info.Accent == "Accent2" and "Accent2" or "Accent"

	local holder = self:_ensureNotifyHolder()

	local toast = New("Frame", {
		Name = "Toast",
		BackgroundColor3 = self.Scheme.Surface,
		Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		ClipsDescendants = true,
		ZIndex = 6001,
		Parent = holder,
	})
	self:AddToRegistry(toast, { BackgroundColor3 = "Surface" })
	self:MakeCorner(toast, true)
	self:MakeStroke(toast)

	-- left accent bar
	local bar = New("Frame", {
		Name = "Bar",
		BackgroundColor3 = self.Scheme[accentKey],
		Size = UDim2.new(0, 3, 1, 0),
		ZIndex = 6003,
		Parent = toast,
	})
	self:AddToRegistry(bar, { BackgroundColor3 = accentKey })

	local content = New("Frame", {
		BackgroundTransparency = 1,
		Position = UDim2.new(0, 12, 0, 0),
		Size = UDim2.new(1, -24, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		ZIndex = 6003,
		Parent = toast,
	}, {
		New("UIListLayout", { Padding = UDim.new(0, 4), SortOrder = Enum.SortOrder.LayoutOrder }),
		New("UIPadding", {
			PaddingTop = UDim.new(0, 10), PaddingBottom = UDim.new(0, 12),
		}),
	})

	self:MakeLabel({
		Parent = content, Text = title, TextSize = 14, Color = "Text",
		Size = UDim2.new(1, 0, 0, 16), AutomaticSize = Enum.AutomaticSize.None,
	}).ZIndex = 6003
	if desc ~= "" then
		local d = self:MakeLabel({
			Parent = content, Text = desc, TextSize = 12, Color = "TextDim",
			Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y,
		})
		d.TextWrapped = true
		d.ZIndex = 6003
	end

	-- progress bar
	local progBg = New("Frame", {
		BackgroundColor3 = self.Scheme[accentKey],
		BackgroundTransparency = 0.65,
		Position = UDim2.new(0, 0, 1, -3),
		Size = UDim2.new(1, 0, 0, 3),
		ZIndex = 6003,
		Parent = toast,
	})
	self:AddToRegistry(progBg, { BackgroundColor3 = accentKey })
	local prog = New("Frame", {
		BackgroundColor3 = self.Scheme[accentKey],
		Size = UDim2.fromScale(1, 1),
		ZIndex = 6004,
		Parent = progBg,
	})
	self:AddToRegistry(prog, { BackgroundColor3 = accentKey })

	-- entrance: slide in from the right
	toast.Position = UDim2.fromOffset(40, 0)
	toast.BackgroundTransparency = 1
	self:Tween(toast, 0.22, { Position = UDim2.fromOffset(0, 0), BackgroundTransparency = 0 })

	-- countdown
	self:Tween(prog, duration, { Size = UDim2.fromScale(0, 1) }, Enum.EasingStyle.Linear)

	task.delay(duration, function()
		if toast and toast.Parent then
			local t = self:Tween(toast, 0.2, { Position = UDim2.fromOffset(40, 0), BackgroundTransparency = 1 })
			if t then t.Completed:Wait() end
			toast:Destroy()
		end
	end)

	return toast
end

----------------------------------------------------------------------
-- WATERMARK
----------------------------------------------------------------------
function Library:SetWatermarkVisibility(state)
	if not self.Watermark then return end
	self.Watermark.Visible = state
end

function Library:SetWatermark(text)
	self:CreateScreenGui()
	if not self.Watermark then
		local wm = New("Frame", {
			Name = "Watermark",
			BackgroundColor3 = self.Scheme.Background,
			Position = UDim2.new(0, 18, 0, 18),
			Size = UDim2.new(0, 0, 0, 26),
			AutomaticSize = Enum.AutomaticSize.X,
			ZIndex = 5500,
			Parent = self.ScreenGui,
		}, {
			New("UIPadding", {
				PaddingLeft = UDim.new(0, 12), PaddingRight = UDim.new(0, 12),
			}),
		})
		self:AddToRegistry(wm, { BackgroundColor3 = "Background" })
		self:MakeCorner(wm, true)
		self:MakeStroke(wm, true)
		local lbl = self:MakeLabel({
			Parent = wm, Text = text, Mono = true, TextSize = 13, Color = "Text",
			Size = UDim2.new(0, 0, 1, 0), AutomaticSize = Enum.AutomaticSize.X,
		})
		lbl.ZIndex = 5501
		self.Watermark = wm
		self.WatermarkLabel = lbl
	else
		self.WatermarkLabel.Text = text
	end
	self.Watermark.Visible = true
	return self.Watermark
end

----------------------------------------------------------------------
-- DRAGGING
----------------------------------------------------------------------
function Library:MakeDraggable(handle, target)
	local dragging, dragInput, dragStart, startPos
	self:Connect(handle.InputBegan, function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1
			or input.UserInputType == Enum.UserInputType.Touch then
			dragging = true
			dragStart = input.Position
			startPos = target.Position
			input.Changed:Connect(function()
				if input.UserInputState == Enum.UserInputState.End then dragging = false end
			end)
		end
	end)
	self:Connect(handle.InputChanged, function(input)
		if input.UserInputType == Enum.UserInputType.MouseMovement
			or input.UserInputType == Enum.UserInputType.Touch then
			dragInput = input
		end
	end)
	self:Connect(UserInputService.InputChanged, function(input)
		if input == dragInput and dragging then
			local delta = input.Position - dragStart
			target.Position = UDim2.new(
				startPos.X.Scale, startPos.X.Offset + delta.X,
				startPos.Y.Scale, startPos.Y.Offset + delta.Y
			)
		end
	end)
end

----------------------------------------------------------------------
-- ELEMENTS  (shared row factory used by Groupbox & Tabbox)
----------------------------------------------------------------------
local AddonMethods = {}  -- forward declaration (KeyPicker / ColorPicker attach here)
local Elements = {}
Elements.__index = Elements

-- create the standard label+control row container
function Elements:_row(height)
	local d = Library:GetDensity()
	local row = New("Frame", {
		Name = "Row",
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 0, height or d.Row),
		Parent = self.Container,
	})
	if not height then Library:BindDensity(row, "Size", "Row") end
	return row
end

-- ===== Toggle =====================================================
function Elements:AddToggle(idx, info)
	info = info or {}
	local toggle = {
		Value = info.Default or false,
		Type = "Toggle",
		Callbacks = {},
		Addons = {},
		Risky = info.Risky,
	}

	local row = self:_row()
	local holder = New("Frame", {
		Name = "Toggle",
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 1),
		Parent = row,
	}, {
		New("UIListLayout", {
			FillDirection = Enum.FillDirection.Horizontal,
			VerticalAlignment = Enum.VerticalAlignment.Center,
			Padding = UDim.new(0, 8),
			SortOrder = Enum.SortOrder.LayoutOrder,
		}),
	})

	-- the switch track
	local track = New("Frame", {
		Name = "Track",
		BackgroundColor3 = Library.Scheme.Surface,
		Size = UDim2.fromOffset(40, 20),
		LayoutOrder = 0,
		Parent = holder,
	})
	Library:AddToRegistry(track, { BackgroundColor3 = "Surface" })
	New("UICorner", { CornerRadius = UDim.new(1, 0), Parent = track })
	local trackStroke = Library:MakeStroke(track)
	local trackGlow = Library:MakeGlow(track)
	trackGlow.Enabled = false

	local knob = New("Frame", {
		Name = "Knob",
		BackgroundColor3 = Library.Scheme.TextFaint,
		Position = UDim2.new(0, 3, 0.5, 0),
		AnchorPoint = Vector2.new(0, 0.5),
		Size = UDim2.fromOffset(14, 14),
		Parent = track,
	})
	Library:AddToRegistry(knob, { BackgroundColor3 = "TextFaint" })
	New("UICorner", { CornerRadius = UDim.new(1, 0), Parent = knob })

	local label = Library:MakeLabel({
		Parent = holder, Text = info.Text or "Toggle", TextSize = 14,
		Color = "Text", Size = UDim2.new(0, 0, 1, 0),
		AutomaticSize = Enum.AutomaticSize.X,
	})
	label.LayoutOrder = 1

	-- click target spanning the whole row
	local button = New("TextButton", {
		Name = "Hit", Text = "", BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 1), ZIndex = 3, Parent = row,
	})

	function toggle:Display()
		local on = self.Value
		Library:Tween(knob, 0.2, {
			Position = on and UDim2.new(1, -3, 0.5, 0) or UDim2.new(0, 3, 0.5, 0),
			AnchorPoint = on and Vector2.new(1, 0.5) or Vector2.new(0, 0.5),
			BackgroundColor3 = on and Library.Scheme.Accent or Library.Scheme.TextFaint,
		})
		Library:Tween(track, 0.2, {
			BackgroundColor3 = on and Library.Scheme.Accent or Library.Scheme.Surface,
			BackgroundTransparency = on and ACCENT_SOFT_T or 0,
		})
		Library:Tween(trackStroke, 0.2, {
			Color = on and Library.Scheme.Accent or Library.Scheme.Outline,
			Transparency = on and ACCENT_LINE_T or 0,
		})
		trackGlow.Enabled = on
	end

	function toggle:SetValue(v)
		self.Value = (not not v)
		self:Display()
		for _, cb in next, self.Callbacks do task.spawn(cb, self.Value) end
		if info.Callback then task.spawn(info.Callback, self.Value) end
	end

	function toggle:OnChanged(fn)
		table.insert(self.Callbacks, fn)
		return self
	end

	Library:Connect(button.MouseButton1Click, function()
		toggle:SetValue(not toggle.Value)
	end)
	-- registry color for knob/track fix-ups handled in Display
	knob.BackgroundColor3 = Library.Scheme.TextFaint

	toggle.Holder = holder
	toggle.Row = row
	toggle:Display()
	setmetatable(toggle, { __index = AddonMethods })

	if idx and type(idx) == "string" then
		Library.Toggles[idx] = toggle
	end
	if info.Callback and toggle.Value then task.spawn(info.Callback, toggle.Value) end

	return toggle
end

-- ===== Button =====================================================
function Elements:AddButton(info)
	-- accept (text, func) or table
	if type(info) == "string" then info = { Text = info } end
	info = info or {}

	local d = Library:GetDensity()
	local row = self:_row(d.Row + 4)

	local btn = New("TextButton", {
		Name = "Button", Text = "", AutoButtonColor = false,
		BackgroundColor3 = Library.Scheme.Surface,
		Size = UDim2.fromScale(1, 1),
		Parent = row,
	})
	Library:AddToRegistry(btn, { BackgroundColor3 = "Surface" })
	Library:MakeCorner(btn, true)
	local stroke = Library:MakeStroke(btn)
	local glow = Library:MakeGlow(btn); glow.Enabled = false

	local lbl = Library:MakeLabel({
		Parent = btn, Text = info.Text or "Button", TextSize = 14,
		Color = "Text", XAlign = Enum.TextXAlignment.Center,
	})

	local object = { Type = "Button" }
	local disabled = info.Disabled or false

	local function refresh()
		btn.AutoButtonColor = false
		lbl.TextTransparency = disabled and 0.6 or 0
		btn.BackgroundTransparency = disabled and 0.4 or 0
	end
	refresh()

	Library:Connect(btn.MouseEnter, function()
		if disabled then return end
		Library:Tween(btn, 0.12, { BackgroundColor3 = Library.Scheme.SurfaceHover })
		Library:Tween(stroke, 0.12, { Transparency = 0, Color = Library.Scheme.Accent })
	end)
	Library:Connect(btn.MouseLeave, function()
		if disabled then return end
		Library:Tween(btn, 0.12, { BackgroundColor3 = Library.Scheme.Surface })
		Library:Tween(stroke, 0.12, { Color = Library.Scheme.Outline })
	end)
	Library:Connect(btn.MouseButton1Click, function()
		if disabled then return end
		-- active flash
		Library:Tween(btn, 0.08, { BackgroundColor3 = Library.Scheme.Accent, BackgroundTransparency = ACCENT_SOFT_T })
		task.delay(0.1, function()
			Library:Tween(btn, 0.15, { BackgroundColor3 = Library.Scheme.Surface, BackgroundTransparency = 0 })
		end)
		local fn = info.Func or info.Callback
		if fn then task.spawn(fn) end
	end)

	function object:SetText(t) lbl.Text = t end
	function object:SetDisabled(state) disabled = state; refresh() end
	function object:AddButton(sub)
		-- side-by-side second button
		if type(sub) == "string" then sub = { Text = sub } end
		row.Size = row.Size
		local right = New("TextButton", {
			Name = "Button2", Text = "", AutoButtonColor = false,
			BackgroundColor3 = Library.Scheme.Surface,
			Size = UDim2.new(0.5, -3, 1, 0), Position = UDim2.new(0.5, 3, 0, 0),
			Parent = row,
		})
		btn.Size = UDim2.new(0.5, -3, 1, 0)
		Library:AddToRegistry(right, { BackgroundColor3 = "Surface" })
		Library:MakeCorner(right, true)
		Library:MakeStroke(right)
		Library:MakeLabel({ Parent = right, Text = sub.Text or "Button", TextSize = 14, XAlign = Enum.TextXAlignment.Center })
		Library:Connect(right.MouseButton1Click, function()
			local fn = sub.Func or sub.Callback
			if fn then task.spawn(fn) end
		end)
		return object
	end

	return object
end

-- ===== Label / Divider ===========================================
function Elements:AddLabel(text, wrap)
	if type(text) == "table" then text = text.Text end
	local row = self:_row()
	local lbl = Library:MakeLabel({
		Parent = row, Text = text or "", TextSize = 14, Color = "TextDim",
		Size = UDim2.fromScale(1, 1),
	})
	lbl.TextWrapped = wrap or false
	if wrap then
		row.Size = UDim2.new(1, 0, 0, 0)
		row.AutomaticSize = Enum.AutomaticSize.Y
		lbl.AutomaticSize = Enum.AutomaticSize.Y
		lbl.Size = UDim2.new(1, 0, 0, 0)
	end
	local object = { Type = "Label", Row = row, Label = lbl, Addons = {} }
	function object:SetText(t) lbl.Text = t end
	return setmetatable(object, { __index = AddonMethods })
end

function Elements:AddDivider()
	local row = New("Frame", {
		Name = "Divider", BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 0, 10), Parent = self.Container,
	})
	local line = New("Frame", {
		BackgroundColor3 = Library.Scheme.Outline,
		BackgroundTransparency = 0.4,
		Position = UDim2.new(0, 0, 0.5, 0),
		Size = UDim2.new(1, 0, 0, 1),
		Parent = row,
	})
	Library:AddToRegistry(line, { BackgroundColor3 = "Outline" })
	return { Type = "Divider", Row = row }
end

-- ===== Input ======================================================
function Elements:AddInput(idx, info)
	info = info or {}
	local option = { Value = info.Default or "", Type = "Input", Callbacks = {} }

	if info.Text then
		Library:MakeLabel({
			Parent = self:_row(20), Text = info.Text, TextSize = 13, Color = "TextDim",
		})
	end

	local row = self:_row(Library:GetDensity().Row + 4)
	local box = New("Frame", {
		BackgroundColor3 = Library.Scheme.Surface,
		Size = UDim2.fromScale(1, 1), Parent = row,
	})
	Library:AddToRegistry(box, { BackgroundColor3 = "Surface" })
	Library:MakeCorner(box, true)
	local stroke = Library:MakeStroke(box)
	local glow = Library:MakeGlow(box); glow.Enabled = false

	local input = New("TextBox", {
		Name = "Box",
		BackgroundTransparency = 1,
		Position = UDim2.new(0, 11, 0, 0),
		Size = UDim2.new(1, -22, 1, 0),
		Font = Library.Font, TextSize = 14,
		Text = option.Value,
		PlaceholderText = info.Placeholder or "…",
		PlaceholderColor3 = Library.Scheme.TextFaint,
		TextColor3 = Library.Scheme.Text,
		TextXAlignment = Enum.TextXAlignment.Left,
		ClearTextOnFocus = false,
		Parent = box,
	})
	Library:AddToRegistry(input, { TextColor3 = "Text", PlaceholderColor3 = "TextFaint" })

	Library:Connect(input.Focused, function()
		Library:Tween(stroke, 0.12, { Color = Library.Scheme.Accent, Transparency = 0 })
		glow.Enabled = true
	end)
	Library:Connect(input.FocusLost, function()
		Library:Tween(stroke, 0.12, { Color = Library.Scheme.Outline })
		glow.Enabled = false
		option:SetValue(input.Text)
	end)

	function option:SetValue(v)
		self.Value = tostring(v)
		input.Text = self.Value
		for _, cb in next, self.Callbacks do task.spawn(cb, self.Value) end
		if info.Callback then task.spawn(info.Callback, self.Value) end
	end
	function option:OnChanged(fn) table.insert(self.Callbacks, fn); return self end

	if idx and type(idx) == "string" then Library.Options[idx] = option end
	return option
end

-- ===== Slider =====================================================
function Elements:AddSlider(idx, info)
	info = info or {}
	local min, max = info.Min or 0, info.Max or 100
	local rounding = info.Rounding or 0
	local suffix = info.Suffix or ""
	local option = {
		Value = math.clamp(info.Default or min, min, max),
		Min = min, Max = max, Type = "Slider", Callbacks = {},
	}

	-- header: label + value
	local head = self:_row(20)
	Library:MakeLabel({ Parent = head, Text = info.Text or "Slider", TextSize = 14, Color = "Text" })
	local valLabel = Library:MakeLabel({
		Parent = head, Mono = true, TextSize = 12, Color = "Accent",
		XAlign = Enum.TextXAlignment.Right, Text = "",
	})

	local row = self:_row(18)
	local track = New("Frame", {
		BackgroundColor3 = Library.Scheme.Surface,
		Position = UDim2.new(0, 0, 0.5, 0), AnchorPoint = Vector2.new(0, 0.5),
		Size = UDim2.new(1, 0, 0, 7), Parent = row,
	})
	Library:AddToRegistry(track, { BackgroundColor3 = "Surface" })
	New("UICorner", { CornerRadius = UDim.new(1, 0), Parent = track })
	Library:MakeStroke(track)

	local fill = New("Frame", {
		BackgroundColor3 = Library.Scheme.Accent,
		Size = UDim2.fromScale(0, 1), Parent = track,
	})
	Library:AddToRegistry(fill, { BackgroundColor3 = "Accent" })
	New("UICorner", { CornerRadius = UDim.new(1, 0), Parent = fill })

	local knob = New("Frame", {
		BackgroundColor3 = Library.Scheme.Accent,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.new(0, 0, 0.5, 0),
		Size = UDim2.fromOffset(15, 15), ZIndex = 3, Parent = track,
	})
	Library:AddToRegistry(knob, { BackgroundColor3 = "Accent" })
	New("UICorner", { CornerRadius = UDim.new(1, 0), Parent = knob })
	Library:MakeGlow(knob)

	local function format(v)
		if rounding > 0 then
			return string.format("%." .. rounding .. "f", v)
		end
		return tostring(math.floor(v + 0.5))
	end

	function option:Display()
		local alpha = (self.Value - min) / (max - min)
		alpha = math.clamp(alpha, 0, 1)
		fill.Size = UDim2.fromScale(alpha, 1)
		knob.Position = UDim2.new(alpha, 0, 0.5, 0)
		valLabel.Text = format(self.Value) .. suffix
	end

	function option:SetValue(v)
		v = math.clamp(tonumber(v) or min, min, max)
		if rounding > 0 then
			local m = 10 ^ rounding
			v = math.floor(v * m + 0.5) / m
		else
			v = math.floor(v + 0.5)
		end
		self.Value = v
		self:Display()
		for _, cb in next, self.Callbacks do task.spawn(cb, v) end
		if info.Callback then task.spawn(info.Callback, v) end
	end
	function option:OnChanged(fn) table.insert(self.Callbacks, fn); return self end

	local dragging = false
	local function update(inputX)
		local rel = (inputX - track.AbsolutePosition.X) / track.AbsoluteSize.X
		option:SetValue(min + math.clamp(rel, 0, 1) * (max - min))
	end
	local hit = New("TextButton", {
		Text = "", BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1),
		Position = UDim2.fromScale(0, -1), ZIndex = 5, Parent = track,
	})
	hit.Size = UDim2.new(1, 0, 3, 0); hit.Position = UDim2.new(0, 0, -1, 0)
	Library:Connect(hit.InputBegan, function(i)
		if i.UserInputType == Enum.UserInputType.MouseButton1 or i.UserInputType == Enum.UserInputType.Touch then
			dragging = true; update(i.Position.X)
		end
	end)
	Library:Connect(hit.InputEnded, function(i)
		if i.UserInputType == Enum.UserInputType.MouseButton1 or i.UserInputType == Enum.UserInputType.Touch then
			dragging = false
		end
	end)
	Library:Connect(UserInputService.InputChanged, function(i)
		if dragging and (i.UserInputType == Enum.UserInputType.MouseMovement or i.UserInputType == Enum.UserInputType.Touch) then
			update(i.Position.X)
		end
	end)

	option:Display()
	if idx and type(idx) == "string" then Library.Options[idx] = option end
	if info.Callback then task.spawn(info.Callback, option.Value) end
	return option
end

-- ===== Dropdown (single + multi) =================================
function Elements:AddDropdown(idx, info)
	info = info or {}
	local multi = info.Multi or false
	local values = info.Values or {}
	local option = {
		Value = multi and {} or (info.Default or (info.AllowNull and nil) or values[1]),
		Values = values, Multi = multi, Type = "Dropdown", Callbacks = {},
	}
	if multi and type(info.Default) == "table" then
		for _, v in next, info.Default do option.Value[v] = true end
	end

	if info.Text then
		Library:MakeLabel({
			Parent = self:_row(20), Text = info.Text, TextSize = 13, Color = "TextDim",
		})
	end

	local row = self:_row(Library:GetDensity().Row + 4)
	local head = New("TextButton", {
		Name = "Dropdown", Text = "", AutoButtonColor = false,
		BackgroundColor3 = Library.Scheme.Surface,
		Size = UDim2.fromScale(1, 1), Parent = row,
		ClipsDescendants = true,
	})
	Library:AddToRegistry(head, { BackgroundColor3 = "Surface" })
	Library:MakeCorner(head, true)
	local stroke = Library:MakeStroke(head)
	New("UIPadding", { PaddingLeft = UDim.new(0, 11), PaddingRight = UDim.new(0, 30), Parent = head })

	local display = Library:MakeLabel({
		Parent = head, Text = "", TextSize = 14, Color = "Text",
		Size = UDim2.fromScale(1, 1),
	})
	display.TextTruncate = Enum.TextTruncate.AtEnd

	local arrow = Library:MakeLabel({
		Parent = head, Text = "▾", TextSize = 14, Color = "Accent",
		XAlign = Enum.TextXAlignment.Center,
		Size = UDim2.fromOffset(20, 20),
		Position = UDim2.new(1, -8, 0.5, 0),
	})
	arrow.AnchorPoint = Vector2.new(1, 0.5)

	-- build the floating menu in the popup holder
	Library:CreateScreenGui()
	local menu = New("Frame", {
		Name = "DropdownMenu", Visible = false,
		BackgroundColor3 = Library.Scheme.Background,
		Size = UDim2.fromOffset(100, 0), AutomaticSize = Enum.AutomaticSize.Y,
		ClipsDescendants = true, ZIndex = 5001, Parent = Library.PopupHolder,
	})
	Library:AddToRegistry(menu, { BackgroundColor3 = "Background" })
	Library:MakeCorner(menu, true)
	Library:MakeStroke(menu, true)
	local scroll = New("ScrollingFrame", {
		BackgroundTransparency = 1, BorderSizePixel = 0,
		Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y,
		AutomaticCanvasSize = Enum.AutomaticSize.Y, CanvasSize = UDim2.new(),
		ScrollBarThickness = 3, ScrollBarImageColor3 = Library.Scheme.Accent,
		ZIndex = 5002, Parent = menu,
	}, {
		New("UIListLayout", { Padding = UDim.new(0, 2), SortOrder = Enum.SortOrder.LayoutOrder }),
		New("UIPadding", {
			PaddingTop = UDim.new(0, 5), PaddingBottom = UDim.new(0, 5),
			PaddingLeft = UDim.new(0, 5), PaddingRight = UDim.new(0, 5),
		}),
	})

	local optionButtons = {}

	local function isSelected(v)
		if multi then return option.Value[v] == true end
		return option.Value == v
	end

	local function updateDisplay()
		if multi then
			local list = {}
			for _, v in next, values do if option.Value[v] then table.insert(list, v) end end
			display.Text = #list > 0 and table.concat(list, ", ") or (info.Placeholder or "None")
			display.TextColor3 = #list > 0 and Library.Scheme.Text or Library.Scheme.TextFaint
		else
			display.Text = option.Value ~= nil and tostring(option.Value) or (info.Placeholder or "…")
			display.TextColor3 = option.Value ~= nil and Library.Scheme.Text or Library.Scheme.TextFaint
		end
		for v, btn in next, optionButtons do
			local sel = isSelected(v)
			btn.fill.Visible = sel
			btn.check.Visible = sel
			btn.label.TextColor3 = sel and Library.Scheme.Accent or Library.Scheme.TextDim
		end
	end

	local function rebuild()
		for _, b in next, scroll:GetChildren() do
			if b:IsA("TextButton") then b:Destroy() end
		end
		optionButtons = {}
		for i, v in next, values do
			local opt = New("TextButton", {
				Name = tostring(v), Text = "", AutoButtonColor = false,
				BackgroundTransparency = 1, LayoutOrder = i,
				Size = UDim2.new(1, 0, 0, 28), ZIndex = 5003, Parent = scroll,
			})
			local fill = Library:MakeFill(opt, "Accent"); fill.Visible = false; fill.ZIndex = 5003
			local lbl = Library:MakeLabel({
				Parent = opt, Text = tostring(v), TextSize = 14, Color = "TextDim",
				Position = UDim2.new(0, 9, 0, 0), Size = UDim2.new(1, -28, 1, 0),
			})
			lbl.ZIndex = 5004
			local check = Library:MakeLabel({
				Parent = opt, Text = "✓", TextSize = 13, Color = "Accent",
				XAlign = Enum.TextXAlignment.Right,
				Position = UDim2.new(1, -9, 0, 0), Size = UDim2.new(0, 16, 1, 0),
			})
			check.AnchorPoint = Vector2.new(1, 0); check.Visible = false; check.ZIndex = 5004
			optionButtons[v] = { label = lbl, check = check, fill = fill }
			Library:Connect(opt.MouseButton1Click, function()
				if multi then
					option.Value[v] = (not option.Value[v]) or nil
				else
					option.Value = v
				end
				updateDisplay()
				option:_fire()
				if not multi then option:Close() end
			end)
		end
		updateDisplay()
	end

	function option:Open()
		Library:CloseOpenedFrames(menu)
		menu.Visible = true
		local pos = head.AbsolutePosition
		local size = head.AbsoluteSize
		menu.Position = UDim2.fromOffset(pos.X, pos.Y + size.Y + 4)
		menu.Size = UDim2.fromOffset(size.X, 0)
		Library:Tween(arrow, 0.15, { Rotation = 180 })
		Library:Tween(stroke, 0.15, { Color = Library.Scheme.Accent, Transparency = 0 })
		Library.OpenedFrames[menu] = function() option:Close() end
		Library:ShowCatcher()
	end
	function option:Close()
		menu.Visible = false
		Library:Tween(arrow, 0.15, { Rotation = 0 })
		Library:Tween(stroke, 0.15, { Color = Library.Scheme.Outline })
		Library.OpenedFrames[menu] = nil
		Library:RefreshCatcher()
	end

	Library:Connect(head.MouseButton1Click, function()
		if menu.Visible then option:Close() else option:Open() end
	end)

	function option:_fire()
		for _, cb in next, self.Callbacks do task.spawn(cb, self.Value) end
		if info.Callback then task.spawn(info.Callback, self.Value) end
	end
	function option:OnChanged(fn) table.insert(self.Callbacks, fn); return self end
	function option:SetValue(v)
		if multi then
			self.Value = {}
			if type(v) == "table" then
				for key, val in next, v do
					if val == true then self.Value[key] = true
					elseif type(key) == "number" then self.Value[val] = true end
				end
			end
		else
			self.Value = v
		end
		updateDisplay(); self:_fire()
	end
	function option:SetValues(newValues)
		values = newValues; self.Values = newValues; rebuild()
	end

	rebuild()
	-- keep menu following the header if window moves while open
	Library:Connect(head:GetPropertyChangedSignal("AbsolutePosition"), function()
		if menu.Visible then
			local pos = head.AbsolutePosition
			menu.Position = UDim2.fromOffset(pos.X, pos.Y + head.AbsoluteSize.Y + 4)
		end
	end)

	if idx and type(idx) == "string" then Library.Options[idx] = option end
	if info.Callback then task.spawn(info.Callback, option.Value) end
	return option
end

----------------------------------------------------------------------
-- ADDONS  (KeyPicker / ColorPicker attach to Toggle or Label rows)
----------------------------------------------------------------------
function AddonMethods:_addonHolder()
	if self._holder then return self._holder end
	local h = New("Frame", {
		Name = "Addons", BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, 0, 0.5, 0),
		Size = UDim2.new(0, 0, 1, 0), AutomaticSize = Enum.AutomaticSize.X,
		ZIndex = 4, Parent = self.Row,
	}, {
		New("UIListLayout", {
			FillDirection = Enum.FillDirection.Horizontal,
			VerticalAlignment = Enum.VerticalAlignment.Center,
			HorizontalAlignment = Enum.HorizontalAlignment.Right,
			Padding = UDim.new(0, 6), SortOrder = Enum.SortOrder.LayoutOrder,
		}),
	})
	self._holder = h
	return h
end

function AddonMethods:AddKeyPicker(idx, info)
	info = info or {}
	local picker = {
		Value = info.Default or "None",
		Mode = info.Mode or "Toggle",   -- Toggle | Hold | Always
		Type = "KeyPicker", Callbacks = {}, Clicked = {}, Listening = false,
		Toggled = false,
	}
	local holder = self:_addonHolder()
	local btn = New("TextButton", {
		Name = "KeyPicker", Text = "", AutoButtonColor = false,
		BackgroundColor3 = Library.Scheme.Surface,
		Size = UDim2.fromOffset(0, 22), AutomaticSize = Enum.AutomaticSize.X,
		ZIndex = 5, Parent = holder, LayoutOrder = 2,
	})
	Library:AddToRegistry(btn, { BackgroundColor3 = "Surface" })
	Library:MakeCorner(btn, true)
	local stroke = Library:MakeStroke(btn)
	New("UIPadding", { PaddingLeft = UDim.new(0, 9), PaddingRight = UDim.new(0, 9), Parent = btn })
	local lbl = Library:MakeLabel({
		Parent = btn, Mono = true, Text = picker.Value, TextSize = 13, Color = "Text",
		Size = UDim2.new(0, 0, 1, 0), AutomaticSize = Enum.AutomaticSize.X,
		XAlign = Enum.TextXAlignment.Center,
	})
	lbl.ZIndex = 6

	function picker:Update()
		lbl.Text = self.Listening and "[ … ]" or self.Value
		Library:Tween(lbl, 0.1, { TextColor3 = self.Listening and Library.Scheme.Accent2 or Library.Scheme.Text })
		Library:Tween(stroke, 0.1, { Color = self.Listening and Library.Scheme.Accent2 or Library.Scheme.Outline })
	end
	function picker:SetValue(v)
		if type(v) == "table" then self.Value, self.Mode = v[1] or "None", v[2] or self.Mode
		else self.Value = v end
		self:Update()
	end
	function picker:OnClick(fn) table.insert(self.Clicked, fn); return self end
	function picker:OnChanged(fn) table.insert(self.Callbacks, fn); return self end
	function picker:GetState()
		if self.Value == "None" then return false end
		local key = Enum.KeyCode[self.Value] or Enum.UserInputType[self.Value]
		if not key then return false end
		local down = UserInputService:IsKeyDown(key) or (pcall(function() return UserInputService:IsMouseButtonPressed(key) end) and UserInputService:IsMouseButtonPressed(key))
		if self.Mode == "Hold" then return down end
		return self.Toggled
	end

	Library:Connect(btn.MouseButton1Click, function()
		picker.Listening = true
		picker:Update()
		Library:CloseOpenedFrames()
	end)
	Library:Connect(UserInputService.InputBegan, function(input, gpe)
		if picker.Listening then
			local key
			if input.UserInputType == Enum.UserInputType.Keyboard then
				key = input.KeyCode.Name
				if key == "Escape" or key == "Backspace" then key = "None" end
			elseif input.UserInputType == Enum.UserInputType.MouseButton1 then key = "MB1"
			elseif input.UserInputType == Enum.UserInputType.MouseButton2 then key = "MB2" end
			if key then
				picker.Value = key
				picker.Listening = false
				picker:Update()
				for _, cb in next, picker.Callbacks do task.spawn(cb, picker.Value) end
			end
			return
		end
		if gpe then return end
		-- live activation
		local match = false
		if input.KeyCode ~= Enum.KeyCode.Unknown and input.KeyCode.Name == picker.Value then match = true end
		if input.UserInputType == Enum.UserInputType.MouseButton1 and picker.Value == "MB1" then match = true end
		if input.UserInputType == Enum.UserInputType.MouseButton2 and picker.Value == "MB2" then match = true end
		if match then
			if picker.Mode == "Toggle" then picker.Toggled = not picker.Toggled end
			for _, cb in next, picker.Clicked do task.spawn(cb, picker:GetState()) end
		end
	end)

	picker:Update()
	if idx and type(idx) == "string" then Library.Options[idx] = picker end
	return picker
end

function AddonMethods:AddColorPicker(idx, info)
	info = info or {}
	local picker = {
		Value = info.Default or Library.Scheme.Accent,
		Transparency = info.Transparency or 0,
		Type = "ColorPicker", Callbacks = {},
	}
	local holder = self:_addonHolder()
	local swatch = New("TextButton", {
		Name = "ColorPicker", Text = "", AutoButtonColor = false,
		BackgroundColor3 = picker.Value,
		Size = UDim2.fromOffset(30, 18), ZIndex = 5, Parent = holder, LayoutOrder = 1,
	})
	Library:MakeCorner(swatch, true)
	Library:MakeStroke(swatch)

	Library:CreateScreenGui()
	local pop = New("Frame", {
		Name = "ColorPop", Visible = false,
		BackgroundColor3 = Library.Scheme.Background,
		Size = UDim2.fromOffset(200, 0), AutomaticSize = Enum.AutomaticSize.Y,
		ZIndex = 5100, Parent = Library.PopupHolder,
	}, {
		New("UIListLayout", { Padding = UDim.new(0, 8), SortOrder = Enum.SortOrder.LayoutOrder }),
		New("UIPadding", {
			PaddingTop = UDim.new(0, 10), PaddingBottom = UDim.new(0, 10),
			PaddingLeft = UDim.new(0, 10), PaddingRight = UDim.new(0, 10),
		}),
	})
	Library:AddToRegistry(pop, { BackgroundColor3 = "Background" })
	Library:MakeCorner(pop, true)
	Library:MakeStroke(pop, true)

	local h, s, v = Color3.toHSV(picker.Value)

	-- SV box (base hue + white horizontal + black vertical overlays)
	local sv = New("ImageButton", {
		Name = "SV", BackgroundColor3 = Color3.fromHSV(h, 1, 1),
		Size = UDim2.new(1, 0, 0, 120), LayoutOrder = 1, ZIndex = 5101,
		AutoButtonColor = false, Parent = pop,
	})
	Library:MakeCorner(sv, true); sv.ClipsDescendants = true
	local whiteGrad = New("Frame", { BackgroundColor3 = Color3.new(1,1,1), Size = UDim2.fromScale(1,1), ZIndex = 5102, Parent = sv }, {
		New("UIGradient", { Color = ColorSequence.new(Color3.new(1,1,1)), Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0), NumberSequenceKeypoint.new(1, 1) }) }),
	})
	local blackGrad = New("Frame", { BackgroundColor3 = Color3.new(0,0,0), Size = UDim2.fromScale(1,1), ZIndex = 5103, Parent = sv }, {
		New("UIGradient", { Rotation = 90, Color = ColorSequence.new(Color3.new(0,0,0)), Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 1), NumberSequenceKeypoint.new(1, 0) }) }),
	})
	local svCursor = New("Frame", {
		BackgroundColor3 = Color3.new(1,1,1), Size = UDim2.fromOffset(8,8),
		AnchorPoint = Vector2.new(0.5,0.5), ZIndex = 5105, Parent = sv,
	})
	New("UICorner", { CornerRadius = UDim.new(1,0), Parent = svCursor })
	New("UIStroke", { Thickness = 1.5, Color = Color3.new(0,0,0), Parent = svCursor })

	-- hue strip
	local hue = New("ImageButton", {
		Name = "Hue", BackgroundColor3 = Color3.new(1,1,1),
		Size = UDim2.new(1, 0, 0, 12), LayoutOrder = 2, ZIndex = 5101,
		AutoButtonColor = false, Parent = pop,
	}, {
		New("UIGradient", { Color = ColorSequence.new({
			ColorSequenceKeypoint.new(0.00, Color3.fromRGB(255,0,0)),
			ColorSequenceKeypoint.new(0.17, Color3.fromRGB(255,255,0)),
			ColorSequenceKeypoint.new(0.33, Color3.fromRGB(0,255,0)),
			ColorSequenceKeypoint.new(0.50, Color3.fromRGB(0,255,255)),
			ColorSequenceKeypoint.new(0.67, Color3.fromRGB(0,0,255)),
			ColorSequenceKeypoint.new(0.83, Color3.fromRGB(255,0,255)),
			ColorSequenceKeypoint.new(1.00, Color3.fromRGB(255,0,0)),
		}) }),
	})
	Library:MakeCorner(hue, true)
	local hueCursor = New("Frame", {
		BackgroundColor3 = Color3.new(1,1,1), Size = UDim2.new(0, 3, 1, 4),
		AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.new(h, 0, 0.5, 0),
		ZIndex = 5105, Parent = hue,
	})
	New("UIStroke", { Thickness = 1, Color = Color3.new(0,0,0), Parent = hueCursor })

	-- hex label
	local hexRow = New("Frame", { BackgroundTransparency = 1, Size = UDim2.new(1,0,0,16), LayoutOrder = 3, ZIndex = 5101, Parent = pop })
	local hexLabel = Library:MakeLabel({ Parent = hexRow, Mono = true, TextSize = 12, Color = "TextDim", Text = "" })
	hexLabel.ZIndex = 5102

	local function refresh(fireCb)
		picker.Value = Color3.fromHSV(h, s, v)
		sv.BackgroundColor3 = Color3.fromHSV(h, 1, 1)
		svCursor.Position = UDim2.new(s, 0, 1 - v, 0)
		hueCursor.Position = UDim2.new(h, 0, 0.5, 0)
		swatch.BackgroundColor3 = picker.Value
		hexLabel.Text = string.format("#%02X%02X%02X",
			math.floor(picker.Value.R*255+0.5), math.floor(picker.Value.G*255+0.5), math.floor(picker.Value.B*255+0.5))
		if fireCb then
			for _, cb in next, picker.Callbacks do task.spawn(cb, picker.Value) end
			if info.Callback then task.spawn(info.Callback, picker.Value) end
		end
	end

	local function dragSV(input)
		local rx = math.clamp((input.Position.X - sv.AbsolutePosition.X)/sv.AbsoluteSize.X, 0, 1)
		local ry = math.clamp((input.Position.Y - sv.AbsolutePosition.Y)/sv.AbsoluteSize.Y, 0, 1)
		s, v = rx, 1 - ry
		refresh(true)
	end
	local function dragHue(input)
		h = math.clamp((input.Position.X - hue.AbsolutePosition.X)/hue.AbsoluteSize.X, 0, 1)
		refresh(true)
	end
	local svDrag, hueDrag = false, false
	Library:Connect(sv.InputBegan, function(i) if i.UserInputType == Enum.UserInputType.MouseButton1 then svDrag = true; dragSV(i) end end)
	Library:Connect(hue.InputBegan, function(i) if i.UserInputType == Enum.UserInputType.MouseButton1 then hueDrag = true; dragHue(i) end end)
	Library:Connect(UserInputService.InputEnded, function(i) if i.UserInputType == Enum.UserInputType.MouseButton1 then svDrag, hueDrag = false, false end end)
	Library:Connect(UserInputService.InputChanged, function(i)
		if i.UserInputType == Enum.UserInputType.MouseMovement then
			if svDrag then dragSV(i) elseif hueDrag then dragHue(i) end
		end
	end)

	function picker:Open()
		Library:CloseOpenedFrames(pop)
		pop.Visible = true
		local p = swatch.AbsolutePosition
		pop.Position = UDim2.fromOffset(p.X - 170, p.Y + swatch.AbsoluteSize.Y + 6)
		Library.OpenedFrames[pop] = function() pop.Visible = false end
		Library:ShowCatcher()
	end
	Library:Connect(swatch.MouseButton1Click, function()
		if pop.Visible then pop.Visible = false; Library.OpenedFrames[pop] = nil; Library:RefreshCatcher() else picker:Open() end
	end)

	function picker:SetValue(c, t)
		if typeof(c) == "table" then c = Color3.fromRGB(c[1], c[2], c[3]) end
		picker.Value = c
		h, s, v = Color3.toHSV(c)
		if t then picker.Transparency = t end
		refresh(true)
	end
	function picker:SetValueRGB(c) picker:SetValue(c) end
	function picker:OnChanged(fn) table.insert(self.Callbacks, fn); return self end

	refresh(false)
	if idx and type(idx) == "string" then Library.Options[idx] = picker end
	return picker
end

----------------------------------------------------------------------
-- GROUPBOX  /  TABBOX
----------------------------------------------------------------------
local function CreateGroupbox(parent, title)
	local d = Library:GetDensity()
	local box = New("Frame", {
		Name = "Groupbox",
		BackgroundColor3 = Library.Scheme.Background,
		BackgroundTransparency = 0.2,
		Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		Parent = parent,
	})
	Library:AddToRegistry(box, { BackgroundColor3 = "Background" })
	Library:MakeCorner(box)
	Library:MakeStroke(box)

	local pad = New("UIPadding", {
		PaddingTop = UDim.new(0, d.Pad), PaddingBottom = UDim.new(0, d.Pad),
		PaddingLeft = UDim.new(0, d.Pad), PaddingRight = UDim.new(0, d.Pad),
		Parent = box,
	})
	Library:BindDensity(pad, "PaddingTop", "Pad")
	Library:BindDensity(pad, "PaddingBottom", "Pad")
	Library:BindDensity(pad, "PaddingLeft", "Pad")
	Library:BindDensity(pad, "PaddingRight", "Pad")

	local layout = New("UIListLayout", {
		Padding = UDim.new(0, 8), SortOrder = Enum.SortOrder.LayoutOrder, Parent = box,
	})

	if title then
		local header = New("Frame", { BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 18), LayoutOrder = -1, Parent = box })
		Library:MakeLabel({ Parent = header, Text = title, TextSize = 15, Color = "Accent2" })
	end

	local self = setmetatable({ Container = box, Layout = layout }, Elements)
	return self
end

local function CreateTabbox(parent)
	local outer = New("Frame", {
		Name = "Tabbox",
		BackgroundColor3 = Library.Scheme.Background,
		BackgroundTransparency = 0.2,
		Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y,
		ClipsDescendants = true, Parent = parent,
	})
	Library:AddToRegistry(outer, { BackgroundColor3 = "Background" })
	Library:MakeCorner(outer)
	Library:MakeStroke(outer)

	local heads = New("Frame", {
		Name = "Heads", BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 0, 32), Parent = outer,
	}, {
		New("UIListLayout", { FillDirection = Enum.FillDirection.Horizontal, SortOrder = Enum.SortOrder.LayoutOrder }),
	})
	local indicator = New("Frame", {
		Name = "Indicator", BackgroundColor3 = Library.Scheme.Accent,
		Size = UDim2.new(0, 0, 0, 2), Position = UDim2.new(0, 0, 1, -2),
		ZIndex = 3, Parent = heads,
	})
	Library:AddToRegistry(indicator, { BackgroundColor3 = "Accent" })
	Library:MakeGlow(indicator)

	local body = New("Frame", { Name = "Body", BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, Parent = outer })

	local tabbox = { Tabs = {}, Heads = heads, Body = body, Indicator = indicator, Current = nil }

	function tabbox:AddTab(name)
		local th = New("TextButton", {
			Name = name, Text = "", AutoButtonColor = false, BackgroundTransparency = 1,
			Size = UDim2.new(0, 0, 1, 0), AutomaticSize = Enum.AutomaticSize.X, Parent = heads,
		}, { New("UIPadding", { PaddingLeft = UDim.new(0, 16), PaddingRight = UDim.new(0, 16) }) })
		local lbl = Library:MakeLabel({ Parent = th, Text = name, TextSize = 14, Color = "TextDim", XAlign = Enum.TextXAlignment.Center })

		local page = CreateGroupbox(body, nil)
		page.Container.Visible = false
		page.Container.BackgroundTransparency = 1
		local stroke = page.Container:FindFirstChildOfClass("UIStroke"); if stroke then stroke.Enabled = false end
		local corner = page.Container:FindFirstChildOfClass("UICorner"); if corner then corner.CornerRadius = UDim.new(0,0) end

		local tabData = { Button = th, Label = lbl, Page = page }
		table.insert(self.Tabs, tabData)

		Library:Connect(th.MouseButton1Click, function() tabbox:Activate(tabData) end)
		if not self.Current then tabbox:Activate(tabData) end
		return page
	end

	function tabbox:Activate(tabData)
		for _, t in next, self.Tabs do
			t.Page.Container.Visible = (t == tabData)
			Library:Tween(t.Label, 0.15, { TextColor3 = (t == tabData) and Library.Scheme.Accent or Library.Scheme.TextDim })
		end
		self.Current = tabData
		task.defer(function()
			Library:Tween(indicator, 0.25, {
				Position = UDim2.new(0, tabData.Button.AbsolutePosition.X - heads.AbsolutePosition.X, 1, -2),
				Size = UDim2.new(0, tabData.Button.AbsoluteSize.X, 0, 2),
			})
		end)
	end

	return tabbox
end

----------------------------------------------------------------------
-- TAB  (content area — two-column groupbox layout, Direction A)
----------------------------------------------------------------------
local function CreateTab(window, name, icon)
	-- rail nav item
	local railItem = New("TextButton", {
		Name = name, Text = "", AutoButtonColor = false, BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 0, 34), Parent = window.Rail,
	})
	local activeFill = Library:MakeFill(railItem, "Accent"); activeFill.Visible = false
	-- left accent indicator
	local indicator = New("Frame", {
		BackgroundColor3 = Library.Scheme.Accent, Visible = false,
		AnchorPoint = Vector2.new(0, 0.5), Position = UDim2.new(0, 0, 0.5, 0),
		Size = UDim2.new(0, 3, 0.6, 0), ZIndex = 3, Parent = railItem,
	})
	Library:AddToRegistry(indicator, { BackgroundColor3 = "Accent" })
	New("UICorner", { CornerRadius = UDim.new(1, 0), Parent = indicator })

	local iconLbl = Library:MakeLabel({
		Parent = railItem, Text = icon or "•", TextSize = 15, Color = "TextDim",
		XAlign = Enum.TextXAlignment.Center, Size = UDim2.fromOffset(28, 34),
		Position = UDim2.fromOffset(6, 0),
	})
	iconLbl.ZIndex = 3
	local nameLbl = Library:MakeLabel({
		Parent = railItem, Text = name, TextSize = 14, Color = "TextDim",
		Position = UDim2.fromOffset(36, 0), Size = UDim2.new(1, -40, 1, 0),
	})
	nameLbl.ZIndex = 3

	-- content page: two columns of groupboxes
	local page = New("ScrollingFrame", {
		Name = name .. "Page", Visible = false,
		BackgroundTransparency = 1, BorderSizePixel = 0,
		Size = UDim2.fromScale(1, 1), CanvasSize = UDim2.new(),
		AutomaticCanvasSize = Enum.AutomaticSize.Y, ScrollBarThickness = 4,
		ScrollBarImageColor3 = Library.Scheme.Accent, Parent = window.Content,
	}, {
		New("UIPadding", { PaddingTop = UDim.new(0,2), PaddingBottom = UDim.new(0,6), PaddingRight = UDim.new(0,6) }),
	})

	local columns = New("Frame", { BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, Parent = page })
	local left = New("Frame", {
		Name = "Left", BackgroundTransparency = 1,
		Size = UDim2.new(0.5, -7, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, Parent = columns,
	}, { New("UIListLayout", { Padding = UDim.new(0, 14), SortOrder = Enum.SortOrder.LayoutOrder }) })
	local right = New("Frame", {
		Name = "Right", BackgroundTransparency = 1,
		Position = UDim2.new(0.5, 7, 0, 0),
		Size = UDim2.new(0.5, -7, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, Parent = columns,
	}, { New("UIListLayout", { Padding = UDim.new(0, 14), SortOrder = Enum.SortOrder.LayoutOrder }) })

	local tab = {
		Name = name, Page = page, RailItem = railItem,
		Left = left, Right = right,
		ActiveFill = activeFill, Indicator = indicator,
		IconLabel = iconLbl, NameLabel = nameLbl,
	}

	function tab:Select()
		window:SelectTab(self)
	end
	function tab:_setActive(active)
		activeFill.Visible = active
		indicator.Visible = active
		page.Visible = active
		Library:Tween(iconLbl, 0.15, { TextColor3 = active and Library.Scheme.Accent or Library.Scheme.TextDim })
		Library:Tween(nameLbl, 0.15, { TextColor3 = active and Library.Scheme.Accent or Library.Scheme.TextDim })
	end

	function tab:AddLeftGroupbox(t)  return CreateGroupbox(left, t)  end
	function tab:AddRightGroupbox(t) return CreateGroupbox(right, t) end
	function tab:AddLeftTabbox()     return CreateTabbox(left)       end
	function tab:AddRightTabbox()    return CreateTabbox(right)      end

	Library:Connect(railItem.MouseButton1Click, function() tab:Select() end)
	Library:Connect(railItem.MouseEnter, function()
		if window.CurrentTab ~= tab then Library:Tween(nameLbl, 0.1, { TextColor3 = Library.Scheme.Text }) end
	end)
	Library:Connect(railItem.MouseLeave, function()
		if window.CurrentTab ~= tab then Library:Tween(nameLbl, 0.1, { TextColor3 = Library.Scheme.TextDim }) end
	end)

	table.insert(window.Tabs, tab)
	if not window.CurrentTab then window:SelectTab(tab) end
	return tab
end

----------------------------------------------------------------------
-- WINDOW
----------------------------------------------------------------------
function Library:CreateWindow(info)
	info = info or {}
	self:CreateScreenGui()
	local size = info.Size or UDim2.fromOffset(680, 520)

	local window = { Tabs = {}, CurrentTab = nil }

	-- root (CanvasGroup gives us a clean fade)
	local rootClass = "CanvasGroup"
	local ok = pcall(function() local c = Instance.new("CanvasGroup"); c:Destroy() end)
	if not ok then rootClass = "Frame" end

	local root = New(rootClass, {
		Name = "Window",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = info.Position or UDim2.fromScale(0.5, 0.5),
		Size = size,
		BackgroundColor3 = self.Scheme.Background,
		Parent = self.ScreenGui,
	})
	self:AddToRegistry(root, { BackgroundColor3 = "Background" })
	self:MakeCorner(root)
	self:MakeStroke(root)
	local scale = New("UIScale", { Name = "Scale", Parent = root })
	window.Root = root
	window.Scale = scale

	-- ===== title bar =====
	local titlebar = New("Frame", {
		Name = "TitleBar",
		BackgroundColor3 = self.Scheme.Surface, BackgroundTransparency = 0.5,
		Size = UDim2.new(1, 0, 0, 42), Parent = root,
	})
	self:AddToRegistry(titlebar, { BackgroundColor3 = "Surface" })
	-- only round top corners visually via a cover frame
	New("Frame", { BackgroundColor3 = self.Scheme.Surface, BackgroundTransparency = 0.5,
		Position = UDim2.new(0, 0, 1, -10), Size = UDim2.new(1, 0, 0, 10), BorderSizePixel = 0, Parent = titlebar })
	local tbBottom = New("Frame", { BackgroundColor3 = self.Scheme.Outline, BackgroundTransparency = 0.4,
		Position = UDim2.new(0, 0, 1, 0), Size = UDim2.new(1, 0, 0, 1), Parent = titlebar })
	self:AddToRegistry(tbBottom, { BackgroundColor3 = "Outline" })

	-- logo
	local logo = New("Frame", {
		BackgroundColor3 = self.Scheme.Accent,
		Position = UDim2.fromOffset(13, 11), Size = UDim2.fromOffset(20, 20), Parent = titlebar,
	})
	self:MakeCorner(logo, true)
	local logoGrad = New("UIGradient", {
		Color = ColorSequence.new(self.Scheme.Accent, self.Scheme.Accent2), Rotation = 135, Parent = logo,
	})
	self:OnThemeChanged(function(scheme)
		logoGrad.Color = ColorSequence.new(scheme.Accent, scheme.Accent2)
	end)
	if info.Icon then
		New("ImageLabel", { BackgroundTransparency = 1, Image = info.Icon, Size = UDim2.fromScale(1,1), Parent = logo })
	end

	self:MakeLabel({
		Parent = titlebar, Text = info.Title or "Project Lexia", TextSize = 15, Color = "Text",
		Position = UDim2.fromOffset(42, 0), Size = UDim2.new(1, -140, 1, 0),
	})

	-- window controls (minimize / close)
	local function ctlButton(x, accentKey, glyph)
		local b = New("TextButton", {
			Text = glyph or "", AutoButtonColor = false, BackgroundColor3 = self.Scheme.Surface,
			Font = self.Font, TextSize = 16, TextColor3 = self.Scheme[accentKey],
			AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, x, 0.5, 0),
			Size = UDim2.fromOffset(24, 24), Parent = titlebar,
		})
		self:AddToRegistry(b, { BackgroundColor3 = "Surface", TextColor3 = accentKey })
		self:MakeCorner(b, true)
		local st = self:MakeStroke(b)
		self:Connect(b.MouseEnter, function() self:Tween(st, 0.1, { Color = self.Scheme[accentKey], Transparency = 0 }) end)
		self:Connect(b.MouseLeave, function() self:Tween(st, 0.1, { Color = self.Scheme.Outline }) end)
		return b
	end
	local closeBtn = ctlButton(-12, "Accent2", "✕")
	local minBtn   = ctlButton(-44, "Accent", "—")

	self:Connect(closeBtn.MouseButton1Click, function() self:Unload() end)
	self:Connect(minBtn.MouseButton1Click, function() window:Minimize() end)

	self:MakeDraggable(titlebar, root)

	-- ===== body: rail + content =====
	local body = New("Frame", {
		Name = "Body", BackgroundTransparency = 1,
		Position = UDim2.fromOffset(0, 42), Size = UDim2.new(1, 0, 1, -42-26), Parent = root,
	})

	local rail = New("ScrollingFrame", {
		Name = "Rail", BackgroundColor3 = self.Scheme.Backdrop, BackgroundTransparency = 0.4,
		BorderSizePixel = 0, Size = UDim2.new(0, 150, 1, 0), CanvasSize = UDim2.new(),
		AutomaticCanvasSize = Enum.AutomaticSize.Y, ScrollBarThickness = 0, Parent = body,
	}, {
		New("UIListLayout", { Padding = UDim.new(0, 4), SortOrder = Enum.SortOrder.LayoutOrder }),
		New("UIPadding", { PaddingTop = UDim.new(0,10), PaddingLeft = UDim.new(0,8), PaddingRight = UDim.new(0,8) }),
	})
	self:AddToRegistry(rail, { BackgroundColor3 = "Backdrop" })
	local railLine = New("Frame", { BackgroundColor3 = self.Scheme.Outline, BackgroundTransparency = 0.4,
		Position = UDim2.new(1, 0, 0, 0), Size = UDim2.new(0, 1, 1, 0), Parent = rail })
	self:AddToRegistry(railLine, { BackgroundColor3 = "Outline" })
	window.Rail = rail

	local content = New("Frame", {
		Name = "Content", BackgroundTransparency = 1,
		Position = UDim2.fromOffset(150, 0), Size = UDim2.new(1, -150, 1, 0), Parent = body,
	}, { New("UIPadding", {
		PaddingTop = UDim.new(0, 14), PaddingBottom = UDim.new(0, 10),
		PaddingLeft = UDim.new(0, 14), PaddingRight = UDim.new(0, 10),
	}) })
	window.Content = content

	-- ===== footer =====
	local footer = New("Frame", {
		Name = "Footer", BackgroundColor3 = self.Scheme.Backdrop, BackgroundTransparency = 0.4,
		Position = UDim2.new(0, 0, 1, -26), Size = UDim2.new(1, 0, 0, 26), Parent = root,
	})
	self:AddToRegistry(footer, { BackgroundColor3 = "Backdrop" })
	local footLine = New("Frame", { BackgroundColor3 = self.Scheme.Outline, BackgroundTransparency = 0.4,
		Size = UDim2.new(1, 0, 0, 1), Parent = footer })
	self:AddToRegistry(footLine, { BackgroundColor3 = "Outline" })
	self:MakeLabel({
		Parent = footer, Mono = true, Text = "Project Lexia · " .. (info.Footer or "v" .. self.Version),
		TextSize = 11, Color = "TextFaint", Position = UDim2.fromOffset(14, 0), Size = UDim2.new(0.6, 0, 1, 0),
	})
	local clock = self:MakeLabel({
		Parent = footer, Mono = true, Text = "", TextSize = 11, Color = "TextFaint",
		XAlign = Enum.TextXAlignment.Right, AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -14, 0, 0), Size = UDim2.new(0.4, 0, 1, 0),
	})
	local lastClock = 0
	self:Connect(RunService.Heartbeat, function()
		local now = os.clock()
		if now - lastClock >= 1 then
			lastClock = now
			clock.Text = os.date("%I:%M %p")
		end
	end)
	clock.Text = os.date("%I:%M %p")

	-- ===== window methods =====
	function window:SelectTab(tab)
		for _, t in next, self.Tabs do t:_setActive(t == tab) end
		self.CurrentTab = tab
	end
	function window:AddTab(name, icon) return CreateTab(self, name, icon) end

	window.Minimized = false
	function window:Minimize()
		self.Minimized = not self.Minimized
		if self.Minimized then
			self._restoreSize = root.Size
			Library:Tween(root, 0.2, { Size = UDim2.new(root.Size.X.Scale, root.Size.X.Offset, 0, 42) })
			body.Visible = false; footer.Visible = false
		else
			body.Visible = true; footer.Visible = true
			Library:Tween(root, 0.2, { Size = self._restoreSize or size })
		end
	end

	-- entrance animation: scale 0.92 -> 1, fade in
	window.Scale.Scale = 0.92
	if root:IsA("CanvasGroup") then
		root.GroupTransparency = 1
		self:Tween(root, 0.25, { GroupTransparency = 0 })
	end
	self:Tween(window.Scale, 0.25, { Scale = 1 })

	self.Window = window
	table.insert(self.Windows, window)
	return window
end

----------------------------------------------------------------------
-- WINDOW TRANSPARENCY  (used by ThemeManager)
----------------------------------------------------------------------
function Library:SetWindowTransparency(t)
	self.WindowTransparency = t
	if not self.Window then return end
	local root = self.Window.Root
	if root:IsA("CanvasGroup") then
		root.GroupTransparency = t
	else
		root.BackgroundTransparency = t
	end
end

----------------------------------------------------------------------
-- GLOBAL TOGGLE / UNLOAD
----------------------------------------------------------------------
function Library:Toggle(state)
	if state == nil then state = not self.Toggled end
	self.Toggled = state
	if not self.Window then return end
	local root = self.Window.Root
	if state then
		root.Visible = true
		self.Window.Scale.Scale = 0.92
		self:Tween(self.Window.Scale, 0.2, { Scale = 1 })
		if root:IsA("CanvasGroup") then root.GroupTransparency = 1; self:Tween(root, 0.2, { GroupTransparency = 0 }) end
	else
		local t = self:Tween(self.Window.Scale, 0.18, { Scale = 0.92 })
		if root:IsA("CanvasGroup") then self:Tween(root, 0.18, { GroupTransparency = 1 }) end
		task.delay(0.18, function() if not self.Toggled then root.Visible = false end end)
	end
end

function Library:Unload()
	for _, c in next, self.Connections do pcall(function() c:Disconnect() end) end
	self.Connections = {}
	if self.OnUnload then pcall(self.OnUnload) end
	if self.ScreenGui then self.ScreenGui:Destroy() end
	self.Unloaded = true
end

-- listen for the global toggle keybind
Library:Connect(UserInputService.InputBegan, function(input, gpe)
	if gpe then return end
	if input.KeyCode == Library.ToggleKeybind then
		Library:Toggle()
	end
end)

return Library
