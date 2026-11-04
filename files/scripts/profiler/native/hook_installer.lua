-- Puts the hooks in place: scans the game, writes the stubs, patches the slots, starts the sampler thread.
-- Hooks are process-wide and outlive a mod's Lua state, so a new state attaches to them instead of installing again.

local ffi = require("ffi")
local win32 = dofile_once("mods/debug_helper/files/scripts/shared/win32.lua") ---@type win32_module
local hook_block = dofile_once("mods/debug_helper/files/scripts/profiler/native/hook_block.lua") ---@type profiler_hook_block_module
local image_scanner = dofile_once("mods/debug_helper/files/scripts/profiler/native/image_scanner.lua") ---@type profiler_image_scanner_module
local stubs = dofile_once("mods/debug_helper/files/scripts/profiler/native/stubs.lua") ---@type profiler_stubs_module
local ENVIRONMENT_VARIABLE = "DEBUG_HELPER_PROFILER"
local LOG_PATH = "mods/debug_helper/profiler_install.log"
local FUNCTION_CALLS_PER_FRAME = 30000
local MEM_COMMIT_AND_RESERVE = 0x3000
local PAGE_EXECUTE_READWRITE = 0x40

local HOOK_ID = hook_block.HOOK_ID

---@class profiler_hook_installer_module
local hook_installer = {}

---Appends to the install log, flushed per line: the last one shows how far a crash got
---@param line string
local function log(line)
	local file = io.open(LOG_PATH, "a")
	if file then
		file:write(line, "\n")
		file:close()
	end
	print("[profiler] " .. line)
end

---Overwrites a pointer in read-only memory
---@param slot number
---@param value number
---@return boolean written
local function write_slot(slot, value)
	local address = ffi.cast("void*", slot)
	local old_protection = ffi.new("uint32_t[1]")
	if ffi.C.VirtualProtect(address, 4, PAGE_EXECUTE_READWRITE, old_protection) == 0 then return false end
	ffi.cast("uint32_t*", slot)[0] = value
	ffi.C.VirtualProtect(address, 4, old_protection[0], old_protection)
	return true
end

---Points a slot at its stub. A stub still in the slot's chain stays there: whatever went on top may call it, and
---installing above that would make the two call each other forever
---@param hook profiler_hook_entry
local function enable_hook(hook)
	local current = ffi.cast("uint32_t*", hook.slot)[0]
	if current == hook.stub then return end
	if hook.in_chain ~= 0 then
		log("another mod hooked over it, staying under it: " .. ffi.string(hook.name))
		return
	end
	hook.original = current
	if write_slot(hook.slot, hook.stub) then
		hook.in_chain = 1
	else
		log("VirtualProtect failed for " .. ffi.string(hook.name))
	end
end

---Points every slot at its stub
---@param block profiler_hook_block
local function enable_hooks(block)
	for index = 0, block.control.hook_count - 1 do
		enable_hook(block.hooks[index])
	end
end

---Points every slot back at the original, unless another mod hooked on top
---@param block profiler_hook_block
local function disable_hooks(block)
	for index = 0, block.control.hook_count - 1 do
		local hook = block.hooks[index]
		if ffi.cast("uint32_t*", hook.slot)[0] ~= hook.stub then
			log("left in place, another mod hooked over it: " .. ffi.string(hook.name))
		elseif write_slot(hook.slot, hook.original) then
			hook.in_chain = 0
		end
	end
end

---Adds a hook, or logs that its slot was not found
---@param hooks profiler_planned_hook[]
---@param hook_type "pcall"|"cdecl1"|"stdcall1"|"load"|"cell"|"system"
---@param hook_id integer
---@param name string
---@param slot number?
---@param material_offset integer?
local function add_hook(hooks, hook_type, hook_id, name, slot, material_offset)
	if slot then
		hooks[#hooks + 1] = { type = hook_type, id = hook_id, name = name, slot = slot, material_offset = material_offset }
	else
		log("not found, skipped: " .. name)
	end
end

---Everything to hook, in id order per kind
---@param found profiler_scan_result
---@return profiler_planned_hook[] hooks
---@return boolean has_cells
local function plan_hooks(found)
	local hooks = {}
	add_hook(hooks, "pcall", HOOK_ID.PCALL, "lua_pcall", found.imports["lua51.dll!lua_pcall"])
	add_hook(hooks, "cdecl1", HOOK_ID.SWAP, "SDL_GL_SwapWindow", found.imports["sdl2.dll!SDL_GL_SwapWindow"])
	add_hook(hooks, "cdecl1", HOOK_ID.DELAY, "SDL_Delay", found.imports["sdl2.dll!SDL_Delay"])
	add_hook(hooks, "load", HOOK_ID.LOAD, "luaL_loadbufferx", found.imports["lua51.dll!luaL_loadbufferx"])
	add_hook(hooks, "system", HOOK_ID.UPDATE, "DeathMatch update", found.update_slot)
	add_hook(hooks, "system", HOOK_ID.DRAW, "DeathMatch draw", found.draw_slot)
	-- The real swap, one level below SDL. Whatever else runs inside SDL_GL_SwapWindow stays outside it.
	local sdl = ffi.C.GetModuleHandleA("SDL2.dll")
	if sdl ~= nil then
		local sdl_imports = win32.imports_of(sdl, win32.address_of(sdl))
		add_hook(hooks, "stdcall1", HOOK_ID.GDI_SWAP, "SwapBuffers", sdl_imports["gdi32.dll!SwapBuffers"])
	end
	local has_cells = false
	for index, cell in ipairs(found.cells) do
		if not found.failures[cell.name] then
			add_hook(hooks, "cell", HOOK_ID.FIRST_SYSTEM + #found.systems + index - 1, cell.name .. " update", cell.slot, cell.material_offset)
			has_cells = true
		end
	end
	for index, system in ipairs(found.systems) do
		if #hooks < hook_block.MAX_HOOKS then add_hook(hooks, "system", HOOK_ID.FIRST_SYSTEM + index - 1, system.name, system.slot) end
	end
	return hooks, has_cells
end

---Copies the hook list into the block, remembering what each slot held
---@param block profiler_hook_block
---@param hooks profiler_planned_hook[]
local function fill_hook_entries(block, hooks)
	for index, hook in ipairs(hooks) do
		local entry = block.hooks[index - 1]
		entry.slot, entry.stub, entry.id = hook.slot, hook.stub, hook.id
		entry.original = ffi.cast("uint32_t*", hook.slot)[0]
		ffi.copy(entry.name, hook.name:sub(1, 43))
	end
end

---Function timing is optional: without these exports, Lua is timed per callback only
---@param control profiler_control_block
---@param lua_library ffi.cdata*
local function enable_function_hooks(control, lua_library)
	local lua_gethook = ffi.C.GetProcAddress(lua_library, "lua_gethook")
	local lua_sethook = ffi.C.GetProcAddress(lua_library, "lua_sethook")
	local jit_setmode = ffi.C.GetProcAddress(lua_library, "luaJIT_setmode")
	if lua_gethook ~= nil and lua_sethook ~= nil and jit_setmode ~= nil then
		control.lua_gethook = win32.address_of(lua_gethook)
		control.lua_sethook = win32.address_of(lua_sethook)
		control.jit_setmode = win32.address_of(jit_setmode)
		control.function_hooks_available, control.function_hooks_enabled = 1, 1
	else
		log("Lua hook exports not found, so Lua is timed per callback only")
	end
	control.function_call_limit = FUNCTION_CALLS_PER_FRAME
end

---Starts the thread that samples which entity is being updated
---@param control profiler_control_block
---@param updated_entity number?
---@param sampler_entry number
local function start_sampler(control, updated_entity, sampler_entry)
	local sleep_function = ffi.C.GetProcAddress(ffi.C.GetModuleHandleA("kernel32.dll"), "Sleep")
	if not updated_entity or sleep_function == nil then
		log("no entity sampler in this build")
		return
	end
	control.updated_entity_global = updated_entity
	control.sleep_function = win32.address_of(sleep_function)
	control.sampler_enabled = 1
	local thread = ffi.C.CreateThread(nil, 0, ffi.cast("void*", sampler_entry), nil, 0, nil)
	if thread ~= nil then
		ffi.C.CloseHandle(thread)
		log(("entity sampler started, global at 0x%x"):format(updated_entity))
	else
		control.sampler_enabled = 0
		log("CreateThread failed, no entity sampler")
	end
end

---Scans the game and installs everything
---@return profiler_hook_block?
local function install()
	local main_module = ffi.C.GetModuleHandleA(nil)
	local started = os.clock()
	local found = image_scanner.scan(main_module, win32.address_of(main_module))
	log(("resolved in %.3f s, build %s"):format(os.clock() - started, found.build))
	for name, reason in pairs(found.failures) do
		log("unresolved system " .. name .. ": " .. reason)
	end
	log("systems resolved: " .. #found.systems)
	local hooks, has_cells = plan_hooks(found)

	local lua_library = ffi.C.GetModuleHandleA("lua51.dll")
	local lua_type = ffi.C.GetProcAddress(lua_library, "lua_type")
	local lua_pushvalue = ffi.C.GetProcAddress(lua_library, "lua_pushvalue")
	local lua_getinfo = ffi.C.GetProcAddress(lua_library, "lua_getinfo")
	if lua_type == nil or lua_pushvalue == nil or lua_getinfo == nil then
		log("lua51.dll exports not found, not hooking")
		return nil
	end

	local memory = ffi.C.VirtualAlloc(nil, hook_block.BLOCK_SIZE, MEM_COMMIT_AND_RESERVE, PAGE_EXECUTE_READWRITE)
	if memory == nil then
		log("VirtualAlloc failed, not hooking")
		return nil
	end
	local address = win32.address_of(memory)
	local generated = stubs.generate(address, hooks)
	local memory_bytes = ffi.cast("uint8_t*", memory)
	ffi.copy(memory_bytes + hook_block.CODE_OFFSET, generated.code, #generated.code)
	ffi.copy(memory_bytes + hook_block.LITERALS_OFFSET, ">S\0\0?\0", 6)
	log(("code at 0x%x, %d bytes, %d hooks"):format(address + hook_block.CODE_OFFSET, #generated.code, #hooks))

	local control = hook_block.struct_at("profiler_control_block", memory)
	control.read_timestamp_stub = generated.read_timestamp_stub
	local block = hook_block.open(memory)
	control.magic, control.hook_count = hook_block.MAGIC, #hooks
	control.cell_hooks_installed = has_cells and 1 or 0
	control.lua_type = win32.address_of(lua_type)
	control.lua_pushvalue = win32.address_of(lua_pushvalue)
	control.lua_getinfo = win32.address_of(lua_getinfo)
	enable_function_hooks(control, lua_library)
	ffi.copy(control.build, found.build:sub(1, 63))
	fill_hook_entries(block, hooks)
	ffi.C.SetEnvironmentVariableA(ENVIRONMENT_VARIABLE, ffi.C.GetCurrentProcessId() .. ":" .. address)
	log("patching slots")
	enable_hooks(block)
	log("hooks installed")
	start_sampler(control, found.updated_entity, generated.sampler_entry)
	return block
end

---Address of a block left by an earlier Lua state of this process
---@return number?
local function find_existing_block()
	local buffer = ffi.new("char[32]")
	if ffi.C.GetEnvironmentVariableA(ENVIRONMENT_VARIABLE, buffer, 32) == 0 then return nil end
	-- A child process inherits the variable, so the address only counts under our own process id.
	local process_id, address = ffi.string(buffer):match("^(%d+):(%d+)$")
	return tonumber(process_id) == ffi.C.GetCurrentProcessId() and tonumber(address) or nil
end

---Takes over hooks that outlived the old Lua state, or removes them if the profiler got turned off
---@param address number
---@param enabled boolean
---@return profiler_hook_block?
local function attach(address, enabled)
	local block = hook_block.open(ffi.cast("void*", address))
	local control = block.control
	if control.magic ~= hook_block.MAGIC then
		log("environment pointer is not ours, ignoring")
		return nil
	end
	if not enabled then
		disable_hooks(block)
		control.sampler_enabled = 0
		control.function_hooks_enabled = 0
		log("hooks removed")
		return nil
	end
	enable_hooks(block)
	if control.updated_entity_global ~= 0 then control.sampler_enabled = 1 end
	if control.lua_sethook ~= 0 then control.function_hooks_enabled = 1 end
	log("attached to existing hooks")
	return block
end

---Installs or attaches
---@param enabled boolean
---@return profiler_hook_block? block nil when the profiler is off or could not install
function hook_installer.start(enabled)
	local existing = find_existing_block()
	if existing then return attach(existing, enabled) end
	if not enabled then return nil end
	local log_file = io.open(LOG_PATH, "w")
	if log_file then log_file:close() end
	log("installing")
	return install()
end

return hook_installer
