--[[
	Project Lexia — ESP library  (executor Drawing API)
	================================================================
	In-game overlay drawn over the viewport, updated on RenderStepped
	and throttled (~30 fps) for mobile performance. Mirrors the design's
	ESP spec: boxes, name·rarity, distance, health bar, tracers, off-screen
	arrows, chams (Highlight) and skeleton.

	A single ESPSettings table drives the render loop. Drawing objects are
	pooled per tracked instance: hidden (Visible=false) instead of
	recreated, and destroyed when the target is removed.

	Usage:
		local ESP = loadstring(game:HttpGet(".../ESP.luau"))()
		ESP:Init()
		ESP.Settings.Enabled = true
		ESP:Add(workspace.SomeModel, { Name = "Aura Egg", Rarity = "1/99",
			Color = Color3.fromRGB(25,215,245) })
		-- or auto-track a folder:
		ESP:TrackContainer(workspace.Eggs, function(inst)
			return { Name = inst.Name, Color = ESP.Settings.RarityColors[1] }
		end)
]]

local RunService    = game:GetService("RunService")
local Players        = game:GetService("Players")
local Workspace      = game:GetService("Workspace")

local LocalPlayer = Players.LocalPlayer

local ESP = {}
ESP.__index = ESP

-- Drawing shim so the module at least loads in Studio (no overlay there)
local DrawingLib = Drawing or {
	new = function()
		return setmetatable({ Remove = function() end, Destroy = function() end },
			{ __index = function() return nil end, __newindex = function() end })
	end,
}

ESP.Settings = {
	Enabled = false,

	-- elements
	Boxes = true,
	Names = true,
	Distance = true,
	HealthBar = true,
	Tracers = true,
	Skeleton = false,
	Chams = false,
	OffScreen = true,

	BoxStyle = "Corner",      -- Corner | Full | Filled
	TracerOrigin = "Bottom",  -- Bottom | Center | Mouse

	MaxDistance = 250,
	TextSize = 13,

	-- rarity / target colours (config-driven list)
	RarityColors = {
		Color3.fromRGB(25, 215, 245),   -- cyan
		Color3.fromRGB(185, 166, 255),  -- lavender
		Color3.fromRGB(52, 231, 200),   -- teal
		Color3.fromRGB(255, 210, 77),   -- gold
	},

	RefreshRate = 1 / 30,  -- throttle ~30fps
}

ESP.Objects = {}     -- [instance] = espObject
ESP._running = false
ESP._lastUpdate = 0

----------------------------------------------------------------------
-- drawing pool helpers
----------------------------------------------------------------------
local function newLine(props)
	local l = DrawingLib.new("Line")
	l.Visible = false; l.Thickness = 1; l.Transparency = 1
	for k, v in next, props or {} do l[k] = v end
	return l
end
local function newSquare(props)
	local s = DrawingLib.new("Square")
	s.Visible = false; s.Thickness = 1; s.Filled = false; s.Transparency = 1
	for k, v in next, props or {} do s[k] = v end
	return s
end
local function newText(props)
	local t = DrawingLib.new("Text")
	t.Visible = false; t.Center = true; t.Outline = true; t.Size = 13
	for k, v in next, props or {} do t[k] = v end
	return t
end

----------------------------------------------------------------------
-- per-target ESP object
----------------------------------------------------------------------
local R15_BONES = {
	{ "Head", "UpperTorso" }, { "UpperTorso", "LowerTorso" },
	{ "UpperTorso", "LeftUpperArm" }, { "LeftUpperArm", "LeftLowerArm" }, { "LeftLowerArm", "LeftHand" },
	{ "UpperTorso", "RightUpperArm" }, { "RightUpperArm", "RightLowerArm" }, { "RightLowerArm", "RightHand" },
	{ "LowerTorso", "LeftUpperLeg" }, { "LeftUpperLeg", "LeftLowerLeg" }, { "LeftLowerLeg", "LeftFoot" },
	{ "LowerTorso", "RightUpperLeg" }, { "RightUpperLeg", "RightLowerLeg" }, { "RightLowerLeg", "RightFoot" },
}

function ESP:Add(instance, info)
	if not instance then return end
	info = info or {}
	if self.Objects[instance] then return self.Objects[instance] end

	local obj = {
		Instance = instance,
		Name = info.Name or instance.Name,
		Rarity = info.Rarity,
		Color = info.Color or self.Settings.RarityColors[1],
		Player = info.Player,         -- optional Player for health/skeleton
		Drawings = {
			box = newSquare(),
			boxLines = { newLine(), newLine(), newLine(), newLine(),
			             newLine(), newLine(), newLine(), newLine() }, -- corner segments
			name = newText(),
			distance = newText(),
			tracer = newLine(),
			arrow = newText(),
			hpBg = newSquare({ Filled = true }),
			hpFg = newSquare({ Filled = true }),
			skeleton = {},
		},
		Highlight = nil,
	}

	if self.Settings.Chams then self:_ensureCham(obj) end
	self.Objects[instance] = obj
	return obj
end

function ESP:Remove(instance)
	local obj = self.Objects[instance]
	if not obj then return end
	for _, d in next, obj.Drawings do
		if type(d) == "table" then
			for _, sub in next, d do pcall(function() sub:Remove() end) end
		else
			pcall(function() d:Remove() end)
		end
	end
	if obj.Highlight then pcall(function() obj.Highlight:Destroy() end) end
	self.Objects[instance] = nil
end

function ESP:Clear()
	for inst in next, self.Objects do self:Remove(inst) end
end

function ESP:_ensureCham(obj)
	if obj.Highlight then return end
	local ok, hl = pcall(function()
		local h = Instance.new("Highlight")
		h.FillColor = obj.Color
		h.OutlineColor = obj.Color
		h.FillTransparency = 0.6
		h.OutlineTransparency = 0
		h.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
		h.Adornee = obj.Instance
		h.Parent = obj.Instance
		return h
	end)
	if ok then obj.Highlight = hl end
end

----------------------------------------------------------------------
-- container auto-tracking
----------------------------------------------------------------------
function ESP:TrackContainer(container, infoFn)
	if not container then return end
	infoFn = infoFn or function() return {} end
	for _, child in next, container:GetChildren() do
		self:Add(child, infoFn(child))
	end
	local addConn = container.ChildAdded:Connect(function(child)
		task.wait()
		self:Add(child, infoFn(child))
	end)
	local remConn = container.ChildRemoved:Connect(function(child)
		self:Remove(child)
	end)
	table.insert(self._connections, addConn)
	table.insert(self._connections, remConn)
end

----------------------------------------------------------------------
-- geometry helpers
----------------------------------------------------------------------
local function getPivot(instance)
	if instance:IsA("Model") then
		local ok, cf = pcall(function() return instance:GetPivot() end)
		if ok then return cf, instance:GetExtentsSize() end
	elseif instance:IsA("BasePart") then
		return instance.CFrame, instance.Size
	end
	local part = instance:FindFirstChildWhichIsA("BasePart", true)
	if part then return part.CFrame, part.Size end
	return nil
end

----------------------------------------------------------------------
-- main render
----------------------------------------------------------------------
function ESP:_render()
	local camera = Workspace.CurrentCamera
	if not camera then return end
	local S = self.Settings
	local viewport = camera.ViewportSize

	local origin
	if S.TracerOrigin == "Mouse" then
		local m = LocalPlayer:GetMouse()
		origin = Vector2.new(m.X, m.Y)
	elseif S.TracerOrigin == "Center" then
		origin = viewport / 2
	else
		origin = Vector2.new(viewport.X / 2, viewport.Y)
	end

	for instance, obj in next, self.Objects do
		local d = obj.Drawings
		local hide = function()
			d.box.Visible = false
			for _, l in next, d.boxLines do l.Visible = false end
			d.name.Visible = false
			d.distance.Visible = false
			d.tracer.Visible = false
			d.arrow.Visible = false
			d.hpBg.Visible = false
			d.hpFg.Visible = false
			for _, l in next, d.skeleton do l.Visible = false end
		end

		if not (S.Enabled and instance.Parent) then
			hide()
		else
			local cf, size = getPivot(instance)
			if not cf then
				hide()
			else
				local worldPos = cf.Position
				local dist = (camera.CFrame.Position - worldPos).Magnitude
				if dist > S.MaxDistance then
					hide()
				else
					local screenPos, onScreen = camera:WorldToViewportPoint(worldPos)

					-- compute a 2D bounding box from extents
					size = size or Vector3.new(3, 5, 3)
					local topW = camera:WorldToViewportPoint((cf * CFrame.new(0, size.Y/2, 0)).Position)
					local botW = camera:WorldToViewportPoint((cf * CFrame.new(0, -size.Y/2, 0)).Position)
					local h = math.abs(topW.Y - botW.Y)
					local w = h * 0.62
					local cx, cy = screenPos.X, screenPos.Y
					local left, top = cx - w/2, cy - h/2

					if onScreen and screenPos.Z > 0 then
						d.arrow.Visible = false
						-- ----- Box -----
						if S.Boxes then
							self:_drawBox(d, left, top, w, h, obj.Color, S.BoxStyle)
						else
							d.box.Visible = false
							for _, l in next, d.boxLines do l.Visible = false end
						end

						-- ----- Name · rarity -----
						if S.Names then
							d.name.Visible = true
							d.name.Text = obj.Rarity and (obj.Name .. " · " .. obj.Rarity) or obj.Name
							d.name.Size = S.TextSize
							d.name.Color = obj.Color
							d.name.Position = Vector2.new(cx, top - S.TextSize - 2)
						else d.name.Visible = false end

						-- ----- Distance -----
						if S.Distance then
							d.distance.Visible = true
							d.distance.Text = string.format("%dm", math.floor(dist))
							d.distance.Size = S.TextSize - 1
							d.distance.Color = Color3.fromRGB(214, 226, 240)
							d.distance.Position = Vector2.new(cx, top + h + 2)
						else d.distance.Visible = false end

						-- ----- Tracer -----
						if S.Tracers then
							d.tracer.Visible = true
							d.tracer.Color = obj.Color
							d.tracer.From = origin
							d.tracer.To = Vector2.new(cx, top + h)
						else d.tracer.Visible = false end

						-- ----- Health bar -----
						if S.HealthBar and obj.Player then
							self:_drawHealth(d, obj, left, top, h)
						else
							d.hpBg.Visible = false; d.hpFg.Visible = false
						end

						-- ----- Skeleton -----
						if S.Skeleton and obj.Player then
							self:_drawSkeleton(d, obj, camera)
						else
							for _, l in next, d.skeleton do l.Visible = false end
						end
					else
						-- off-screen: hide box/labels, draw edge arrow
						d.box.Visible = false
						for _, l in next, d.boxLines do l.Visible = false end
						d.name.Visible = false; d.distance.Visible = false
						d.tracer.Visible = false; d.hpBg.Visible = false; d.hpFg.Visible = false
						if S.OffScreen then
							self:_drawArrow(d, viewport, cx, cy, screenPos.Z, obj, dist)
						else
							d.arrow.Visible = false
						end
					end

					-- chams toggle sync
					if S.Chams then self:_ensureCham(obj)
					elseif obj.Highlight then obj.Highlight.Enabled = false end
				end
			end
		end
	end
end

function ESP:_drawBox(d, left, top, w, h, color, style)
	if style == "Full" or style == "Filled" then
		d.box.Visible = true
		d.box.Position = Vector2.new(left, top)
		d.box.Size = Vector2.new(w, h)
		d.box.Color = color
		d.box.Filled = (style == "Filled")
		d.box.Transparency = (style == "Filled") and 0.7 or 1
		for _, l in next, d.boxLines do l.Visible = false end
	else
		-- Corner style: 8 short segments
		d.box.Visible = false
		local len = math.min(w, h) * 0.28
		local corners = {
			{ Vector2.new(left, top), Vector2.new(left + len, top) },
			{ Vector2.new(left, top), Vector2.new(left, top + len) },
			{ Vector2.new(left + w, top), Vector2.new(left + w - len, top) },
			{ Vector2.new(left + w, top), Vector2.new(left + w, top + len) },
			{ Vector2.new(left, top + h), Vector2.new(left + len, top + h) },
			{ Vector2.new(left, top + h), Vector2.new(left, top + h - len) },
			{ Vector2.new(left + w, top + h), Vector2.new(left + w - len, top + h) },
			{ Vector2.new(left + w, top + h), Vector2.new(left + w, top + h - len) },
		}
		for i, seg in next, corners do
			local l = d.boxLines[i]
			l.Visible = true
			l.Color = color
			l.Thickness = 1
			l.From = seg[1]
			l.To = seg[2]
		end
	end
end

function ESP:_drawHealth(d, obj, left, top, h)
	local hum = obj.Player.Character and obj.Player.Character:FindFirstChildOfClass("Humanoid")
	if not hum then d.hpBg.Visible = false; d.hpFg.Visible = false; return end
	local frac = math.clamp(hum.Health / math.max(hum.MaxHealth, 1), 0, 1)
	local barX = left - 6
	d.hpBg.Visible = true
	d.hpBg.Position = Vector2.new(barX, top)
	d.hpBg.Size = Vector2.new(3, h)
	d.hpBg.Color = Color3.fromRGB(0, 0, 0)
	d.hpBg.Transparency = 0.7
	d.hpFg.Visible = true
	d.hpFg.Size = Vector2.new(3, h * frac)
	d.hpFg.Position = Vector2.new(barX, top + h * (1 - frac))
	-- green→yellow→red lerp
	local c
	if frac > 0.5 then
		c = Color3.fromRGB(255, 210, 77):Lerp(Color3.fromRGB(77, 255, 136), (frac - 0.5) * 2)
	else
		c = Color3.fromRGB(255, 77, 77):Lerp(Color3.fromRGB(255, 210, 77), frac * 2)
	end
	d.hpFg.Color = c
end

function ESP:_drawSkeleton(d, obj, camera)
	local char = obj.Player.Character
	if not char then for _, l in next, d.skeleton do l.Visible = false end return end
	local idx = 0
	for _, bone in next, R15_BONES do
		local a, b = char:FindFirstChild(bone[1]), char:FindFirstChild(bone[2])
		idx = idx + 1
		local l = d.skeleton[idx]
		if not l then l = newLine(); d.skeleton[idx] = l end
		if a and b then
			local pa, va = camera:WorldToViewportPoint(a.Position)
			local pb, vb = camera:WorldToViewportPoint(b.Position)
			if va and vb then
				l.Visible = true
				l.Color = obj.Color
				l.From = Vector2.new(pa.X, pa.Y)
				l.To = Vector2.new(pb.X, pb.Y)
			else l.Visible = false end
		else l.Visible = false end
	end
end

function ESP:_drawArrow(d, viewport, cx, cy, z, obj, dist)
	local center = viewport / 2
	local dir = Vector2.new(cx, cy) - center
	if z < 0 then dir = -dir end
	if dir.Magnitude < 1 then dir = Vector2.new(0, -1) end
	dir = dir.Unit
	local edge = center + dir * (math.min(viewport.X, viewport.Y) * 0.42)
	d.arrow.Visible = true
	d.arrow.Text = "▶"
	d.arrow.Size = 18
	d.arrow.Color = obj.Color
	d.arrow.Position = edge
end

----------------------------------------------------------------------
-- lifecycle
----------------------------------------------------------------------
ESP._connections = {}

function ESP:Init()
	if self._running then return end
	self._running = true
	local conn = RunService.RenderStepped:Connect(function()
		local now = os.clock()
		if now - self._lastUpdate < self.Settings.RefreshRate then return end
		self._lastUpdate = now
		local ok, err = pcall(function() self:_render() end)
		if not ok then warn("[Lexia ESP]", err) end
	end)
	table.insert(self._connections, conn)
	return self
end

function ESP:Unload()
	self._running = false
	for _, c in next, self._connections do pcall(function() c:Disconnect() end) end
	self._connections = {}
	self:Clear()
end

return ESP
