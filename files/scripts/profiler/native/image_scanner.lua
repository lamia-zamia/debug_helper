-- Finds hook points in a loaded module by import name and RTTI class name only: no address is specific to a build.

local ffi = require("ffi")
local bit = require("bit")
local win32 = dofile_once("mods/debug_helper/files/scripts/shared/win32.lua") ---@type win32_module

local read_dword, is_code, read_pointer = win32.read_dword, win32.is_code, win32.read_pointer

local CELL_CLASSES = { "CLiquidCell", "CGasCell", "CFireCell", "CSolidCell" }
local UPDATE_VFTABLE_OFFSET = 12
local DRAW_VFTABLE_OFFSET = 16
local CELL_GET_MATERIAL_VFTABLE_OFFSET = 0x30
local CELL_UPDATE_VFTABLE_OFFSET = 0x54

---@class profiler_found_system
---@field name string
---@field slot number

---@class profiler_found_cell
---@field name string
---@field slot number
---@field material_offset integer

---@class profiler_scan_result
---@field imports table<string, number> "dll!name" to slot address
---@field systems profiler_found_system[]
---@field cells profiler_found_cell[]
---@field failures table<string, string> what was not found, and why
---@field build string
---@field updated_entity number? address of the updated-entity global
---@field update_slot number?
---@field draw_slot number?

---@class profiler_image_scanner_module
local image_scanner = {}

---RTTI type descriptors by mangled name, false where a name is not unique. A descriptor's name is at +8 and
---dword aligned, so scanning aligned dwords finds them all
---@param image win32_loaded_image
---@return table<string, number|false>
local function find_type_descriptors(image)
	local descriptors = {}
	for _, section in ipairs(image.data_sections) do
		for index = section.relative_address / 4, (section.relative_address + section.size) / 4 - 2 do
			if image.dwords[index] == 0x56413F2E then -- ".?AV"
				local name = ffi.string(image.bytes + index * 4)
				if descriptors[name] == nil then
					descriptors[name] = image.image_base + index * 4 - 8
				else
					descriptors[name] = false
				end
			end
		end
	end
	return descriptors
end

---Engine systems, from the SystemAutoCreator template each one instantiates
---@param descriptors table<string, number|false>
---@return string[]
local function find_system_names(descriptors)
	local names = {}
	for mangled in pairs(descriptors) do
		local name = mangled:match("^%.%?AV%?%$TSystemAutoCreator@V([%w_]+)@@@SystemManager@@$")
		if name then names[#names + 1] = name end
	end
	table.sort(names)
	return names
end

---Descriptor addresses of every class that gets a hook, to its name
---@param descriptors table<string, number|false>
---@param system_names string[]
---@param failures table<string, string>
---@return table<number, string>
local function wanted_classes(descriptors, system_names, failures)
	local wanted = {}
	for _, name in ipairs(system_names) do
		local descriptor = descriptors[".?AV" .. name .. "@@"]
		if descriptor then
			wanted[descriptor] = name
		else
			failures[name] = "no unique type descriptor"
		end
	end
	local death_match = descriptors[".?AVDeathMatch@@"]
	if death_match then wanted[death_match] = "DeathMatch" end
	for _, name in ipairs(CELL_CLASSES) do
		local descriptor = descriptors[".?AV" .. name .. "@grid@@"]
		if descriptor then wanted[descriptor] = name end
	end
	return wanted
end

---Complete object locators for the wanted classes: zero signature and offset, the descriptor at +12
---@param image win32_loaded_image
---@param wanted table<number, string>
---@return table<number, string>
local function find_object_locators(image, wanted)
	local locators = {}
	for _, section in ipairs(image.data_sections) do
		for index = section.relative_address / 4, (section.relative_address + section.size) / 4 - 4 do
			if image.dwords[index] == 0 and image.dwords[index + 1] == 0 then
				local name = wanted[image.dwords[index + 3]]
				if name then locators[image.image_base + index * 4] = name end
			end
		end
	end
	return locators
end

---Anything that looks like a vftable: a locator pointer followed by a code pointer
---@param image win32_loaded_image
---@param locators table<number, string>
---@return table<number, string>
local function find_vftable_candidates(image, locators)
	local candidates = {}
	for _, section in ipairs(image.data_sections) do
		for index = section.relative_address / 4, (section.relative_address + section.size) / 4 - 2 do
			local name = locators[image.dwords[index]]
			if name and is_code(image, image.dwords[index + 1]) then candidates[image.image_base + (index + 1) * 4] = name end
		end
	end
	return candidates
end

---Walks the code for `mov dword ptr [...], immediate`. A real vftable gets installed that way by a constructor,
---and every system resets the updated-entity global that way with -1
---@param image win32_loaded_image
---@param candidates table<number, string>
---@return table<number, boolean> written vftables that a constructor installs
---@return table<number, integer> resets how many times each address is set to -1
local function scan_immediate_writes(image, candidates)
	local bytes = image.bytes
	local written, resets = {}, {}
	for _, section in ipairs(image.code_sections) do
		for offset = section.relative_address, section.relative_address + section.size - 11 do
			if bytes[offset] == 0xC7 and bit.band(bit.rshift(bytes[offset + 1], 3), 7) == 0 then
				if bytes[offset + 1] == 0x05 and read_dword(bytes, offset + 6) == 0xFFFFFFFF then
					local address = read_dword(bytes, offset + 2)
					resets[address] = (resets[address] or 0) + 1
				end
				for _, immediate_offset in ipairs({ offset + 2, offset + 3, offset + 6 }) do
					local vftable = read_dword(bytes, immediate_offset)
					if candidates[vftable] then written[vftable] = true end
				end
			end
		end
	end
	return written, resets
end

---Each class's vftable, false where several of them got installed
---@param written table<number, boolean>
---@param candidates table<number, string>
---@return table<string, number|false>
local function unique_vftables(written, candidates)
	local vftables = {}
	for vftable in pairs(written) do
		local name = candidates[vftable]
		if vftables[name] == nil then
			vftables[name] = vftable
		else
			vftables[name] = false
		end
	end
	return vftables
end

---Every system resets the updated-entity global once, and no other address comes close to that count
---@param resets table<number, integer>
---@param result profiler_scan_result
local function find_updated_entity(resets, result)
	local best, best_count, next_count = nil, 0, 0
	for address, count in pairs(resets) do
		if count > best_count then
			best, best_count, next_count = address, count, best_count
		elseif count > next_count then
			next_count = count
		end
	end
	if best and best_count >= #result.systems / 2 and best_count > next_count * 10 then
		result.updated_entity = best
	else
		result.failures.updated_entity = "no clear reset target"
	end
end

---Adds each system whose vftable was found, or records why not
---@param image win32_loaded_image
---@param vftables table<string, number|false>
---@param system_names string[]
---@param result profiler_scan_result
local function add_systems(image, vftables, system_names, result)
	for _, name in ipairs(system_names) do
		local vftable = vftables[name]
		if vftable and is_code(image, read_pointer(image, vftable + UPDATE_VFTABLE_OFFSET)) then
			result.systems[#result.systems + 1] = { name = name, slot = vftable + UPDATE_VFTABLE_OFFSET }
		elseif not result.failures[name] then
			result.failures[name] = vftable == false and "several vftables" or "no vftable"
		end
	end
end

---The getter's bytes are mov eax, [ecx+offset]; ret. Taking the offset from the game's own code means a changed
---cell layout disables this rather than reading the wrong field
---@param image win32_loaded_image
---@param vftables table<string, number|false>
---@param result profiler_scan_result
local function add_cells(image, vftables, result)
	local bytes = image.bytes
	for _, name in ipairs(CELL_CLASSES) do
		local vftable = vftables[name]
		if vftable then
			local getter = read_pointer(image, vftable + CELL_GET_MATERIAL_VFTABLE_OFFSET) - image.image_base
			if bytes[getter] == 0x8B and bytes[getter + 1] == 0x41 and bytes[getter + 3] == 0xC3 then
				result.cells[#result.cells + 1] = { name = name, slot = vftable + CELL_UPDATE_VFTABLE_OFFSET, material_offset = bytes[getter + 2] }
			else
				result.failures[name] = "get_material has an unknown shape"
			end
		else
			result.failures[name] = "no unique vftable"
		end
	end
end

---Finds the update and draw slots on DeathMatch
---@param image win32_loaded_image
---@param vftables table<string, number|false>
---@param result profiler_scan_result
local function add_game_loop(image, vftables, result)
	local vftable = vftables.DeathMatch
	if
		vftable
		and is_code(image, read_pointer(image, vftable + UPDATE_VFTABLE_OFFSET))
		and is_code(image, read_pointer(image, vftable + DRAW_VFTABLE_OFFSET))
	then
		result.update_slot = vftable + UPDATE_VFTABLE_OFFSET
		result.draw_slot = vftable + DRAW_VFTABLE_OFFSET
	else
		result.failures.DeathMatch = "no unique vftable"
	end
end

---The build string the game prints, "?" if it has none
---@param image win32_loaded_image
---@return string
local function find_build_name(image)
	local build = "?"
	for _, section in ipairs(image.data_sections) do
		for index = section.relative_address / 4, (section.relative_address + section.size) / 4 - 4 do
			if image.dwords[index] == 0x74696F4E and image.dwords[index + 1] == 0x75422D61 then -- "Noita-Bu"
				build = ffi.string(image.bytes + index * 4)
				break
			end
		end
	end
	return build
end

---Scans a loaded module for everything the hooks need
---@param module ffi.cdata* the module, laid out as loaded
---@param image_base number the base its stored pointers are relative to
---@return profiler_scan_result
function image_scanner.scan(module, image_base)
	local image = win32.open_image(module, image_base)
	local result = {
		imports = win32.imports_of(module, image_base),
		systems = {},
		cells = {},
		failures = {},
		build = "?",
	}
	local descriptors = find_type_descriptors(image)
	local system_names = find_system_names(descriptors)
	local wanted = wanted_classes(descriptors, system_names, result.failures)
	local candidates = find_vftable_candidates(image, find_object_locators(image, wanted))
	local written, resets = scan_immediate_writes(image, candidates)
	local vftables = unique_vftables(written, candidates)
	add_systems(image, vftables, system_names, result)
	find_updated_entity(resets, result)
	add_cells(image, vftables, result)
	add_game_loop(image, vftables, result)
	result.build = find_build_name(image) .. (descriptors[".?AVSimpleProfilerViewer@@"] and " (dev)" or "")
	return result
end

return image_scanner
