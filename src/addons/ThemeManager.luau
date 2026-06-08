--[[
	Project Lexia — ThemeManager addon
	================================================================
	Runtime customization of the design tokens. Changing the accent /
	background / density / radius re-tweens every registered instance
	through Library's theme registry (Library:UpdateColors / SetDensity
	/ SetRadius).

	Usage:
		local ThemeManager = loadstring(game:HttpGet(".../ThemeManager.luau"))()
		ThemeManager:SetLibrary(Library)
		ThemeManager:SetFolder("LexiaHub")
		ThemeManager:BuildThemeSection(Tabs.Settings)
		ThemeManager:LoadDefault()
]]

local HttpService = game:GetService("HttpService")

local ThemeManager = {
	Library = nil,
	Folder = "LexiaHub",
}

local fs = {}
fs.writefile  = (writefile  or function() end)
fs.readfile   = (readfile   or function() return "" end)
fs.isfile     = (isfile     or function() return false end)
fs.isfolder   = (isfolder   or function() return false end)
fs.makefolder = (makefolder or function() end)

-- built-in presets (Color3 token bundles, mapped from the wireframe palette)
ThemeManager.BuiltInThemes = {
	["Lexia · Elaina"] = {
		Accent = Color3.fromRGB(25, 215, 245), Accent2 = Color3.fromRGB(185, 166, 255),
		Background = Color3.fromRGB(12, 24, 48), Backdrop = Color3.fromRGB(7, 14, 28),
		Surface = Color3.fromRGB(18, 34, 68), SurfaceHover = Color3.fromRGB(24, 48, 92),
	},
	["Lavender"] = {
		Accent = Color3.fromRGB(185, 166, 255), Accent2 = Color3.fromRGB(25, 215, 245),
		Background = Color3.fromRGB(18, 16, 36), Backdrop = Color3.fromRGB(10, 9, 22),
		Surface = Color3.fromRGB(30, 26, 56), SurfaceHover = Color3.fromRGB(44, 38, 80),
	},
	["Teal"] = {
		Accent = Color3.fromRGB(52, 231, 200), Accent2 = Color3.fromRGB(156, 201, 255),
		Background = Color3.fromRGB(8, 26, 28), Backdrop = Color3.fromRGB(4, 16, 18),
		Surface = Color3.fromRGB(14, 40, 44), SurfaceHover = Color3.fromRGB(20, 58, 62),
	},
	["Midnight"] = {
		Accent = Color3.fromRGB(120, 170, 255), Accent2 = Color3.fromRGB(185, 166, 255),
		Background = Color3.fromRGB(14, 16, 26), Backdrop = Color3.fromRGB(8, 9, 16),
		Surface = Color3.fromRGB(24, 27, 42), SurfaceHover = Color3.fromRGB(36, 40, 60),
	},
}

function ThemeManager:SetLibrary(lib) self.Library = lib end
function ThemeManager:SetFolder(folder)
	self.Folder = folder
	if not fs.isfolder(folder) then pcall(fs.makefolder, folder) end
	if not fs.isfolder(folder .. "/themes") then pcall(fs.makefolder, folder .. "/themes") end
end

-- apply a named built-in preset
function ThemeManager:ApplyTheme(name)
	local theme = self.BuiltInThemes[name]
	if not theme then return end
	for key, color in next, theme do
		self.Library.Scheme[key] = color
	end
	self.Library:UpdateColors()
	if self.AccentPicker then self.AccentPicker:SetValue(theme.Accent) end
end

function ThemeManager:SetAccent(color)
	self.Library.Scheme.Accent = color
	self.Library:UpdateColors()
end

----------------------------------------------------------------------
-- persistence
----------------------------------------------------------------------
local function colorToHex(c)
	return string.format("#%02X%02X%02X",
		math.floor(c.R*255+0.5), math.floor(c.G*255+0.5), math.floor(c.B*255+0.5))
end
local function hexToColor(hex)
	hex = hex:gsub("#", "")
	return Color3.fromRGB(tonumber(hex:sub(1,2),16) or 0, tonumber(hex:sub(3,4),16) or 0, tonumber(hex:sub(5,6),16) or 0)
end

function ThemeManager:_serialize()
	local s = self.Library.Scheme
	return {
		Accent = colorToHex(s.Accent), Accent2 = colorToHex(s.Accent2),
		Background = colorToHex(s.Background), Backdrop = colorToHex(s.Backdrop),
		Surface = colorToHex(s.Surface), SurfaceHover = colorToHex(s.SurfaceHover),
		Density = self.Library.Density, Radius = self.Library.Radius,
		Transparency = self.Library.WindowTransparency or 0,
	}
end

function ThemeManager:_deserialize(data)
	local s = self.Library.Scheme
	for _, key in next, { "Accent", "Accent2", "Background", "Backdrop", "Surface", "SurfaceHover" } do
		if data[key] then s[key] = hexToColor(data[key]) end
	end
	if data.Density then self.Library:SetDensity(data.Density) end
	if data.Radius then self.Library:SetRadius(data.Radius) end
	self.Library:UpdateColors()
	if data.Transparency and self.Library.SetWindowTransparency then
		self.Library:SetWindowTransparency(data.Transparency)
	end
end

function ThemeManager:SaveDefault()
	local ok, encoded = pcall(HttpService.JSONEncode, HttpService, self:_serialize())
	if ok then pcall(fs.writefile, self.Folder .. "/themes/default.json", encoded) end
end

function ThemeManager:LoadDefault()
	local path = self.Folder .. "/themes/default.json"
	if fs.isfile(path) then
		local ok, raw = pcall(fs.readfile, path)
		if ok then
			local ok2, decoded = pcall(HttpService.JSONDecode, HttpService, raw)
			if ok2 then self:_deserialize(decoded) end
		end
	end
end

----------------------------------------------------------------------
-- UI builder
----------------------------------------------------------------------
function ThemeManager:BuildThemeSection(tab)
	assert(self.Library, "ThemeManager: call SetLibrary first")
	self:SetFolder(self.Folder)
	local L = self.Library

	local box = tab:AddLeftGroupbox("ThemeManager")

	local themeNames = {}
	for name in next, self.BuiltInThemes do table.insert(themeNames, name) end
	table.sort(themeNames)

	box:AddDropdown("ThemeManager_Theme", {
		Text = "Theme", Values = themeNames, Default = "Lexia · Elaina",
		Callback = function(v) self:ApplyTheme(v) end,
	})

	self.AccentPicker = box:AddLabel("Accent color"):AddColorPicker("ThemeManager_Accent", {
		Default = L.Scheme.Accent,
		Callback = function(c) self:SetAccent(c) end,
	})

	box:AddLabel("Background"):AddColorPicker("ThemeManager_Background", {
		Default = L.Scheme.Background,
		Callback = function(c) L.Scheme.Background = c; L:UpdateColors() end,
	})

	box:AddDropdown("ThemeManager_Density", {
		Text = "Density", Values = { "Compact", "Balanced", "Spacious" }, Default = L.Density,
		Callback = function(v) L:SetDensity(v) end,
	})

	box:AddDropdown("ThemeManager_Radius", {
		Text = "Corners", Values = { "Sharp", "Soft" }, Default = L.Radius,
		Callback = function(v) L:SetRadius(v) end,
	})

	if L.SetWindowTransparency then
		box:AddSlider("ThemeManager_Transparency", {
			Text = "Window transparency", Min = 0, Max = 100, Default = 0, Suffix = "%",
			Callback = function(v) L:SetWindowTransparency(v / 100) end,
		})
	end

	box:AddButton({ Text = "Set as default", Func = function()
		self:SaveDefault()
		L:Notify({ Title = "ThemeManager", Description = "Saved as default theme" })
	end }):AddButton({ Text = "Reset", Func = function()
		self:ApplyTheme("Lexia · Elaina")
		L:SetDensity("Balanced"); L:SetRadius("Soft")
		L:Notify({ Title = "ThemeManager", Description = "Theme reset to default" })
	end })

	return box
end

return ThemeManager
