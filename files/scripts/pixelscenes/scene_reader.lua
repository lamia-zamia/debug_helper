-- Reads the game's own two pixel scene lists, so scenes from Lua, XML, biomes and the save all show up.

local ffi = require("ffi")
local win32 = dofile_once("mods/debug_helper/files/scripts/shared/win32.lua") ---@type win32_module

-- mov ecx, [eax+0x10]; mov ecx, [ecx+0x458]; call: how the game gets the manager before adding a scene
local MANAGER_LOAD = "\x8B\x48\x10\x8B\x89\x58\x04\x00\x00\xE8"
local WORLD_OFFSET, MANAGER_OFFSET = 0x10, 0x458
local MAX_CALL_GAP = 16 -- bytes allowed between the getter's call and MANAGER_LOAD
local SCENE_SIZE = 0x90
local FILE_OFFSET = 0x0C
local X_INDEX, Y_INDEX, WIDTH_INDEX, HEIGHT_INDEX = 1, 2, 34, 35 -- dwords into a scene
local SHORT_STRING_CAPACITY = 15 -- MSVC std::string keeps up to this many chars inside itself
local MAX_FILE_LENGTH = 1024
local REFRESH_FRAMES = 30
local image_size_gui = nil

---@alias pixelscene_state "queued"|"old"

---@class pixelscene
---@field file string
---@field x number
---@field y number
---@field width number
---@field height number
---@field state pixelscene_state queued: waiting for its chunks. old: processed by the game

---@class pixelscene_reader
---@field queued pixelscene[]
---@field old pixelscene[]
---@field failed boolean the manager's search failed, and it does not get retried
---@field last_refresh number
---@field manager number?
---@field get_global ffi.cdata*?
local scene_reader = {
	queued = {},
	old = {},
	failed = false,
	last_refresh = -REFRESH_FRAMES,
}

---Target of the call that ends just before MANAGER_LOAD, nil if none is there
---@param image win32_loaded_image
---@param section win32_image_section
---@param offset integer MANAGER_LOAD's offset in the section
---@return number?
local function call_target_before(image, section, offset)
	for gap = 0, MAX_CALL_GAP do
		local call = section.relative_address + offset - gap - 5
		if image.bytes[call] == 0xE8 then
			local target = call + 5 + ffi.cast("int32_t*", image.bytes + call + 1)[0]
			if target >= section.relative_address and target < section.relative_address + section.size then return image.image_base + target end
		end
	end
	return nil
end

---Finds the function returning the game's global object. Every site loading the manager has to agree on it
---@param module ffi.cdata* the module, laid out as loaded
---@param image_base number
---@return number? address
function scene_reader.find_global_getter(module, image_base)
	local image = win32.open_image(module, image_base)
	local getter = nil
	for _, section in ipairs(image.code_sections) do
		local code = ffi.string(image.bytes + section.relative_address, section.size)
		local start = code:find(MANAGER_LOAD, 1, true)
		while start do
			local target = call_target_before(image, section, start - 1)
			if not target or (getter and getter ~= target) then return nil end
			getter = target
			start = code:find(MANAGER_LOAD, start + 1, true)
		end
	end
	return getter
end

---Reads an MSVC std::string
---@param address number
---@return string? text nil if it does not look like one
local function read_string(address)
	local fields = ffi.cast("uint32_t*", address)
	local size, capacity = fields[4], fields[5]
	if size > MAX_FILE_LENGTH or capacity < size then return nil end
	local text = capacity > SHORT_STRING_CAPACITY and fields[0] or address
	if ffi.C.IsBadReadPtr(ffi.cast("void*", text), size) ~= 0 then return nil end
	return ffi.string(ffi.cast("const char*", text), size)
end

---Size of a scene's image. The game does not save a scene's size, so a scene restored from a save has none
---@param file string
---@return number width
---@return number height
local function image_size(file)
	image_size_gui = image_size_gui or GuiCreate()
	return GuiGetImageDimensions(image_size_gui, file, 1)
end

---Reads list entries from `first` (from 1) on and appends them. The game may be adding to the list on another
---thread, so this stops at the first entry that fails its checks and the next refresh tries again
---@param list pixelscene[]
---@param vector number address of the std::vector
---@param first integer
---@param state pixelscene_state
local function read_scenes(list, vector, first, state)
	local pointers = ffi.cast("uint32_t*", vector)
	local begin, finish = pointers[0], pointers[1]
	local bytes = finish - begin
	if bytes % SCENE_SIZE ~= 0 or ffi.C.IsBadReadPtr(ffi.cast("void*", begin), bytes) ~= 0 then return end
	for index = first, bytes / SCENE_SIZE do
		local address = begin + (index - 1) * SCENE_SIZE
		local file = read_string(address + FILE_OFFSET)
		if not file then return end
		local fields = ffi.cast("int32_t*", address)
		local width, height = fields[WIDTH_INDEX], fields[HEIGHT_INDEX]
		if width == 0 then
			width, height = image_size(file)
		end
		list[index] = {
			file = file,
			x = fields[X_INDEX],
			y = fields[Y_INDEX],
			width = width,
			height = height,
			state = state,
		}
	end
end

---Brings both lists up to date with a manager. The old list only grows, so only its new entries get read
---@param manager number
function scene_reader:read_manager(manager)
	local old_vector = manager + 0x0C
	local pointers = ffi.cast("uint32_t*", old_vector)
	local old_count = (pointers[1] - pointers[0]) / SCENE_SIZE
	if manager ~= self.manager or old_count < #self.old then
		self.manager = manager
		self.old = {}
	end
	self.queued = {}
	read_scenes(self.queued, manager, 1, "queued")
	read_scenes(self.old, old_vector, #self.old + 1, "old")
end

---Calls the getter once found. It logs a failed search once and stops trying
---@return number? manager
function scene_reader:find_manager()
	if self.failed then return nil end
	if not self.get_global then
		local module = ffi.C.GetModuleHandleA(nil)
		local getter = self.find_global_getter(module, win32.address_of(module))
		if not getter then
			print("[debug_helper] pixel scene manager not found in this build, overlay disabled")
			self.failed = true
			return nil
		end
		self.get_global = ffi.cast("uint32_t(__cdecl*)(void)", getter)
	end
	local global = self.get_global()
	local world = ffi.cast("uint32_t*", global + WORLD_OFFSET)[0]
	if world == 0 then return nil end
	local manager = ffi.cast("uint32_t*", world + MANAGER_OFFSET)[0]
	return manager ~= 0 and manager or nil
end

---Refreshes the lists every REFRESH_FRAMES frames
---@private
function scene_reader:refresh()
	local frame = GameGetFrameNum()
	if frame >= self.last_refresh and frame - self.last_refresh < REFRESH_FRAMES then return end
	self.last_refresh = frame
	local manager = self:find_manager()
	if manager then self:read_manager(manager) end
end

---Returns pixelscene name with coordinates
---@param scene pixelscene
---@return string
function scene_reader:get_text(scene)
	return string.format("[%s] x: %d, y: %d, width: %d, height: %d (%s)", scene.file, scene.x, scene.y, scene.width, scene.height, scene.state)
end

---Whether a scene overlaps a world rectangle
---@param scene pixelscene
---@param left number
---@param top number
---@param right number
---@param bottom number
---@return boolean
local function overlaps(scene, left, top, right, bottom)
	return scene.x <= right and scene.y <= bottom and scene.x + scene.width >= left and scene.y + scene.height >= top
end

---Returns the scenes overlapping a world rectangle
---@param left number
---@param top number
---@param right number
---@param bottom number
---@return pixelscene[]
function scene_reader:in_rectangle(left, top, right, bottom)
	self:refresh()
	local found = {}
	for _, list in ipairs({ self.queued, self.old }) do
		for _, scene in ipairs(list) do
			if overlaps(scene, left, top, right, bottom) then found[#found + 1] = scene end
		end
	end
	return found
end

return scene_reader
