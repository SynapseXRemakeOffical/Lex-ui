--[[
	Project Lexia — SaveManager addon
	================================================================
	Serializes Library.Toggles / Library.Options to JSON config files
	via the executor filesystem (writefile / readfile / …). Mirrors the
	LinoriaLib SaveManager API.

	Usage:
		local SaveManager = loadstring(game:HttpGet(".../SaveManager.luau"))()
		SaveManager:SetLibrary(Library)
		SaveManager:SetFolder("LexiaHub/SolsRNG")
		SaveManager:BuildConfigSection(Tabs.Settings)   -- adds the UI
		SaveManager:LoadAutoloadConfig()
]]

local HttpService = game:GetService("HttpService")

local SaveManager = {
	Folder = "LexiaHub",
	SubFolder = "configs",
	Library = nil,
	Ignore = {},          -- flag indexes to skip
	IgnoreTheme = false,
}

----------------------------------------------------------------------
-- filesystem shims (no-ops in Studio so the UI still builds)
----------------------------------------------------------------------
local fs = {}
fs.writefile = (writefile or function() end)
fs.readfile  = (readfile  or function() return "" end)
fs.isfile    = (isfile    or function() return false end)
fs.isfolder  = (isfolder  or function() return false end)
fs.makefolder = (makefolder or function() end)
fs.listfiles = (listfiles or function() return {} end)
fs.delfile   = (delfile   or function() end)

----------------------------------------------------------------------
-- config setup
----------------------------------------------------------------------
function SaveManager:SetLibrary(lib) self.Library = lib end

function SaveManager:SetFolder(folder)
	self.Folder = folder
	self:BuildFolderTree()
end

function SaveManager:SetSubFolder(sub)
	self.SubFolder = sub
	self:BuildFolderTree()
end

function SaveManager:BuildFolderTree()
	local paths = { self.Folder, self.Folder .. "/" .. self.SubFolder, self.Folder .. "/themes" }
	for _, p in next, paths do
		if not fs.isfolder(p) then pcall(fs.makefolder, p) end
	end
end

function SaveManager:IgnoreThemeSettings() self.IgnoreTheme = true end

function SaveManager:SetIgnoreIndexes(list)
	for _, key in next, list do self.Ignore[key] = true end
end

function SaveManager:_configPath(name)
	return ("%s/%s/%s.json"):format(self.Folder, self.SubFolder, name)
end

----------------------------------------------------------------------
-- (de)serialization
----------------------------------------------------------------------
local function colorToHex(c)
	return string.format("#%02X%02X%02X",
		math.floor(c.R * 255 + 0.5), math.floor(c.G * 255 + 0.5), math.floor(c.B * 255 + 0.5))
end
local function hexToColor(hex)
	hex = hex:gsub("#", "")
	return Color3.fromRGB(
		tonumber(hex:sub(1, 2), 16) or 0,
		tonumber(hex:sub(3, 4), 16) or 0,
		tonumber(hex:sub(5, 6), 16) or 0)
end

function SaveManager:_collect()
	local data = { objects = {} }
	local L = self.Library

	for idx, toggle in next, L.Toggles do
		if not self.Ignore[idx] then
			table.insert(data.objects, { type = "Toggle", idx = idx, value = toggle.Value })
		end
	end
	for idx, opt in next, L.Options do
		if not self.Ignore[idx] then
			local t = opt.Type
			if t == "Slider" then
				table.insert(data.objects, { type = "Slider", idx = idx, value = opt.Value })
			elseif t == "Input" then
				table.insert(data.objects, { type = "Input", idx = idx, value = opt.Value })
			elseif t == "Dropdown" then
				table.insert(data.objects, { type = "Dropdown", idx = idx, multi = opt.Multi, value = opt.Value })
			elseif t == "KeyPicker" then
				table.insert(data.objects, { type = "KeyPicker", idx = idx, value = { opt.Value, opt.Mode } })
			elseif t == "ColorPicker" then
				table.insert(data.objects, { type = "ColorPicker", idx = idx, value = colorToHex(opt.Value), transparency = opt.Transparency })
			end
		end
	end
	return data
end

function SaveManager:_apply(data)
	local L = self.Library
	for _, obj in next, data.objects do
		local idx = obj.idx
		if obj.type == "Toggle" and L.Toggles[idx] then
			L.Toggles[idx]:SetValue(obj.value)
		elseif L.Options[idx] then
			local opt = L.Options[idx]
			if obj.type == "ColorPicker" then
				opt:SetValue(hexToColor(obj.value), obj.transparency)
			elseif obj.type == "KeyPicker" then
				opt:SetValue(obj.value)
			else
				opt:SetValue(obj.value)
			end
		end
	end
end

----------------------------------------------------------------------
-- save / load / delete
----------------------------------------------------------------------
function SaveManager:Save(name)
	if not name or name == "" then return false, "no config name" end
	local ok, encoded = pcall(HttpService.JSONEncode, HttpService, self:_collect())
	if not ok then return false, "encode failed" end
	local ok2 = pcall(fs.writefile, self:_configPath(name), encoded)
	if not ok2 then return false, "write failed" end
	return true
end

function SaveManager:Load(name)
	local path = self:_configPath(name)
	if not fs.isfile(path) then return false, "config does not exist" end
	local ok, raw = pcall(fs.readfile, path)
	if not ok then return false, "read failed" end
	local ok2, decoded = pcall(HttpService.JSONDecode, HttpService, raw)
	if not ok2 then return false, "decode failed" end
	self:_apply(decoded)
	return true
end

function SaveManager:Delete(name)
	local path = self:_configPath(name)
	if not fs.isfile(path) then return false, "config does not exist" end
	local ok = pcall(fs.delfile, path)
	return ok
end

function SaveManager:RefreshList()
	local out = {}
	local ok, files = pcall(fs.listfiles, self.Folder .. "/" .. self.SubFolder)
	if ok and files then
		for _, file in next, files do
			if file:sub(-5) == ".json" then
				local name = file:match("([^/\\]+)%.json$")
				if name then table.insert(out, name) end
			end
		end
	end
	return out
end

----------------------------------------------------------------------
-- autoload
----------------------------------------------------------------------
function SaveManager:SetAutoload(name)
	pcall(fs.writefile, self.Folder .. "/" .. self.SubFolder .. "/autoload.txt", name)
	self.AutoloadName = name
end

function SaveManager:GetAutoload()
	local path = self.Folder .. "/" .. self.SubFolder .. "/autoload.txt"
	if fs.isfile(path) then
		local ok, raw = pcall(fs.readfile, path)
		if ok then return raw end
	end
	return nil
end

function SaveManager:LoadAutoloadConfig()
	local name = self:GetAutoload()
	if name and name ~= "" then
		local ok, err = self:Load(name)
		if ok then
			self.Library:Notify({ Title = "SaveManager", Description = "Autoloaded config: " .. name })
		else
			self.Library:Notify({ Title = "SaveManager", Description = "Autoload failed: " .. tostring(err), Accent = "Accent2" })
		end
	end
end

----------------------------------------------------------------------
-- UI builder
----------------------------------------------------------------------
function SaveManager:BuildConfigSection(tab)
	assert(self.Library, "SaveManager: call SetLibrary first")
	self:BuildFolderTree()
	local L = self.Library

	local box = tab:AddRightGroupbox("SaveManager")
	local selected = nil

	local configDropdown = box:AddDropdown("SaveManager_List", {
		Text = "Saved configs", Values = self:RefreshList(),
		AllowNull = true, Placeholder = "none",
		Callback = function(v) selected = v end,
	})
	selected = configDropdown.Value

	local nameInput = box:AddInput("SaveManager_Name", {
		Text = "Config name", Placeholder = "new config name…",
	})

	box:AddButton({ Text = "Create", Func = function()
		local name = nameInput.Value
		local ok, err = self:Save(name)
		if ok then
			L:Notify({ Title = "SaveManager", Description = "Created config: " .. name })
			configDropdown:SetValues(self:RefreshList())
		else
			L:Notify({ Title = "SaveManager", Description = "Create failed: " .. tostring(err), Accent = "Accent2" })
		end
	end }):AddButton({ Text = "Load", Func = function()
		if not selected then return L:Notify({ Title = "SaveManager", Description = "No config selected", Accent = "Accent2" }) end
		local ok, err = self:Load(selected)
		L:Notify({ Title = "SaveManager", Description = ok and ("Loaded: " .. selected) or ("Load failed: " .. tostring(err)), Accent = ok and "Accent" or "Accent2" })
	end })

	box:AddButton({ Text = "Overwrite", Func = function()
		if not selected then return L:Notify({ Title = "SaveManager", Description = "No config selected", Accent = "Accent2" }) end
		local ok = self:Save(selected)
		L:Notify({ Title = "SaveManager", Description = ok and ("Overwrote: " .. selected) or "Overwrite failed", Accent = ok and "Accent" or "Accent2" })
	end }):AddButton({ Text = "Delete", Func = function()
		if not selected then return L:Notify({ Title = "SaveManager", Description = "No config selected", Accent = "Accent2" }) end
		local ok = self:Delete(selected)
		if ok then configDropdown:SetValues(self:RefreshList()) end
		L:Notify({ Title = "SaveManager", Description = ok and ("Deleted: " .. selected) or "Delete failed", Accent = "Accent2" })
	end })

	box:AddButton({ Text = "Refresh list", Func = function()
		configDropdown:SetValues(self:RefreshList())
		L:Notify({ Title = "SaveManager", Description = "Config list refreshed" })
	end })

	box:AddToggle("SaveManager_Autoload", {
		Text = "Set as autoload", Default = false,
		Callback = function(state)
			if state and selected then
				self:SetAutoload(selected)
				L:Notify({ Title = "SaveManager", Description = "Autoload set: " .. selected })
			end
		end,
	})

	box:AddLabel("Autoload runs the chosen config on next inject.", true)

	self.ConfigDropdown = configDropdown
	return box
end

return SaveManager
