-- The machine code behind the hooks. A stub timestamps the call into the event ring and calls the original,
-- so hooks run without Lua. Calling conventions and lua_Debug offsets come from noita.exe and lua51.dll.

local ffi = require("ffi")
local hook_block = dofile_once("mods/debug_helper/files/scripts/profiler/native/hook_block.lua") ---@type profiler_hook_block_module
local x86 = dofile_once("mods/debug_helper/files/scripts/profiler/native/x86_assembler.lua") ---@type x86_assembler_module
local eax, ecx, edx, ebx, esp, ebp, esi, edi, al = x86.eax, x86.ecx, x86.edx, x86.ebx, x86.esp, x86.ebp, x86.esi, x86.edi, x86.al
local at, byte_at, at_address = x86.at, x86.byte_at, x86.at_address

local HOOK_ID = hook_block.HOOK_ID
local CURRENT_THREAD_ID = x86.fs_at(0x24)
local CELL_HASH_FACTOR = 0x9E3779B1
local CELL_HASH_SHIFT = 20 -- leaves 12 bits: CELL_COUNTER_COUNT is 4096
local CELL_TIMING_MASK = 63 -- times 1 call in 64
local CELL_COUNTER_SIZE = 2 ^ hook_block.CELL_COUNTER_SHIFT
local CELL_COUNTERS_MASK = (hook_block.CELL_COUNTER_COUNT - 1) * CELL_COUNTER_SIZE
local MAX_PATH_CHARS = 99
local LUA_HOOKCALL, LUA_HOOKRET = 0, 1
local LUA_MASKCALL_AND_RET = 3
local LUA_TFUNCTION = 6
local LUAJIT_MODE_OFF, LUAJIT_MODE_ON, LUAJIT_MODE_FLUSH = 0, 0x100, 0x200 -- all with LUAJIT_MODE_ENGINE, which is 0
local LUA_DEBUG_ON_STACK = -0x80 -- lua_Debug is 100 bytes

local LUA_DEBUG_EVENT, LUA_DEBUG_WHAT, LUA_DEBUG_SOURCE, LUA_DEBUG_LINE_DEFINED, LUA_DEBUG_FRAME_SLOT = 0, 12, 16, 28, 96

---Byte offset of a profiler_event field
---@param field string
---@return integer
local function event_offset(field)
	return (ffi.offsetof("profiler_event", field))
end

---Byte offset of a profiler_cell_counter field
---@param field string
---@return integer
local function cell_offset(field)
	return (ffi.offsetof("profiler_cell_counter", field))
end

---@class profiler_planned_hook
---@field type "pcall"|"cdecl1"|"stdcall1"|"load"|"cell"|"system"
---@field id integer
---@field name string
---@field slot number
---@field stub number? set by stubs.generate
---@field material_offset integer? cell hooks only

---@class profiler_stub_context
---@field asm x86_assembler
---@field block_address number
---@field control fun(field: string): x86_operand
---@field info_string number address of ">S"
---@field unknown_string number address of "?"
---@field record number? routine entry
---@field state_gate number? routine entry

---@class profiler_generated_code
---@field code string
---@field read_timestamp_stub number
---@field sampler_entry number

---Writes one event. eax = kind, esi = string to copy or 0, edi = line, ebp = frame slot; the last two only
---matter for Lua functions. Keeps every register but eax, and esi if it was non-zero
---@param context profiler_stub_context
---@return number entry_address
local function emit_record(context)
	local asm = context.asm
	local entry = asm:begin_routine()
	asm:push(ebx)
	asm:push(ecx)
	asm:push(edx)
	asm:push(edi)
	asm:mov(ebx, eax)
	asm:mov(eax, 1)
	asm:lock_xadd(context.control("event_write"), eax)
	asm:mov(ecx, eax)
	asm:and_(ecx, hook_block.EVENT_COUNT - 1)
	asm:shl(ecx, hook_block.EVENT_SIZE_SHIFT)
	asm:add(ecx, context.block_address + hook_block.EVENTS_OFFSET)
	asm:mov(at(ecx, event_offset("kind")), ebx)
	asm:mov(ebx, CURRENT_THREAD_ID)
	asm:mov(at(ecx, event_offset("thread_id")), ebx)
	asm:mov(at(ecx, event_offset("line")), edi)
	asm:mov(at(ecx, event_offset("stack_slot")), ebp)
	asm:lea(ebx, at(eax, 1))
	asm:test(esi, esi)
	asm:je("stamp")
	asm:lea(edi, at(ecx, event_offset("path")))
	asm:mov(edx, MAX_PATH_CHARS)
	asm:label("copy")
	asm:mov(al, byte_at(esi))
	asm:mov(byte_at(edi), al)
	asm:test(al, al)
	asm:je("stamp")
	asm:inc(esi)
	asm:inc(edi)
	asm:dec(edx)
	asm:jne("copy")
	asm:mov(byte_at(edi), 0)
	asm:label("stamp")
	asm:rdtsc()
	asm:mov(at(ecx, event_offset("timestamp_low")), eax)
	asm:mov(at(ecx, event_offset("timestamp_high")), edx)
	-- Published last, since the reader trusts a slot once the sequence matches.
	asm:mov(at(ecx, event_offset("sequence")), ebx)
	asm:pop(edi)
	asm:pop(edx)
	asm:pop(ecx)
	asm:pop(ebx)
	asm:ret()
	return entry
end

---Thread body: never returns. Aligned dword reads need no locking, and only this thread writes samples
---@param context profiler_stub_context
---@return number entry_address
local function emit_sampler(context)
	local asm, control = context.asm, context.control
	local samples = context.block_address + hook_block.SAMPLES_OFFSET
	local entry = asm:begin_routine()
	asm:label("loop")
	asm:push(1)
	asm:call(control("sleep_function")) -- removes its own argument
	asm:cmp(control("sampler_enabled"), 0)
	asm:je("next")
	asm:mov(eax, control("current_system"))
	asm:test(eax, eax)
	asm:je("next")
	asm:mov(edx, control("updated_entity_global"))
	asm:mov(ecx, at(edx))
	asm:mov(edx, control("sample_write"))
	asm:mov(ebx, edx)
	asm:and_(ebx, hook_block.SAMPLE_COUNT - 1)
	asm:shl(ebx, hook_block.SAMPLE_SIZE_SHIFT)
	asm:mov(at(ebx, samples + ffi.offsetof("profiler_sample", "entity")), ecx)
	asm:mov(at(ebx, samples + ffi.offsetof("profiler_sample", "system")), eax)
	asm:inc(edx)
	asm:mov(control("sample_write"), edx)
	asm:label("next")
	asm:jmp("loop")
	return entry
end

---lua_Hook(L, ar): writes the same stream as lua_pcall. LuaJIT fires calls for C functions but no returns for
---them. Skipping them leaves their time in the Lua function that called them
---@param context profiler_stub_context
---@return number entry_address
local function emit_function_hook(context)
	local asm, control = context.asm, context.control
	local entry = asm:begin_routine()
	asm:mov(eax, CURRENT_THREAD_ID)
	asm:cmp(eax, control("main_thread_id"))
	asm:jne("out")
	asm:mov(eax, control("function_calls"))
	asm:cmp(eax, control("function_call_limit"))
	asm:jae("out") -- returns stop too past the limit, or they would close callers
	asm:mov(eax, at(esp, 8))
	asm:cmp(at(eax, LUA_DEBUG_EVENT), LUA_HOOKCALL)
	asm:jne("not_call")
	asm:inc(control("function_calls"))
	asm:push(eax)
	asm:push(context.info_string + 1) -- "S"
	asm:push(at(esp, 12))
	asm:call(control("lua_getinfo"))
	asm:add(esp, 12)
	asm:mov(eax, at(esp, 8))
	asm:mov(ecx, at(eax, LUA_DEBUG_WHAT))
	asm:cmp(byte_at(ecx), string.byte("C"))
	asm:je("out")
	asm:push(ebp)
	asm:push(esi)
	asm:push(edi)
	asm:mov(esi, at(eax, LUA_DEBUG_SOURCE))
	asm:mov(edi, at(eax, LUA_DEBUG_LINE_DEFINED))
	asm:mov(ebp, at(eax, LUA_DEBUG_FRAME_SLOT))
	asm:mov(eax, HOOK_ID.FUNCTION * 2)
	asm:call(context.record)
	asm:pop(edi)
	asm:pop(esi)
	asm:pop(ebp)
	asm:ret()
	asm:label("not_call")
	asm:cmp(at(eax, LUA_DEBUG_EVENT), LUA_HOOKRET)
	asm:jne("out")
	asm:push(ebp)
	asm:push(esi)
	asm:xor(esi, esi)
	asm:mov(ebp, at(eax, LUA_DEBUG_FRAME_SLOT))
	asm:mov(eax, HOOK_ID.FUNCTION * 2 + 1)
	asm:call(context.record)
	asm:pop(esi)
	asm:pop(ebp)
	asm:ret()
	asm:label("out")
	asm:ret()
	return entry
end

---state_gate(L): turns the function hook on or off for L. It runs where L is alive by definition, with no list
---of states to go stale. A state with someone else's hook keeps it. Compiled code would skip hooks, hence no JIT
---@param context profiler_stub_context
---@param function_hook number
---@return number entry_address
local function emit_state_gate(context, function_hook)
	local asm, control = context.asm, context.control
	local entry = asm:begin_routine()
	asm:push(ebx)
	asm:mov(ebx, at(esp, 8))
	asm:mov(eax, CURRENT_THREAD_ID)
	asm:cmp(eax, control("main_thread_id"))
	asm:jne("out")
	asm:cmp(ebx, control("reader_lua_state")) -- the reader's own state stays unhooked
	asm:je("out")
	asm:push(ebx)
	asm:call(control("lua_gethook"))
	asm:add(esp, 4)
	asm:cmp(control("function_hooks_enabled"), 0)
	asm:je("turn_off")
	asm:test(eax, eax)
	asm:jne("out")
	asm:push(LUAJIT_MODE_FLUSH)
	asm:push(0)
	asm:push(ebx)
	asm:call(control("jit_setmode"))
	asm:add(esp, 12)
	asm:push(LUAJIT_MODE_OFF)
	asm:push(0)
	asm:push(ebx)
	asm:call(control("jit_setmode"))
	asm:add(esp, 12)
	asm:push(0)
	asm:push(LUA_MASKCALL_AND_RET)
	asm:push(function_hook)
	asm:push(ebx)
	asm:call(control("lua_sethook"))
	asm:add(esp, 16)
	asm:jmp("out")
	asm:label("turn_off")
	asm:cmp(eax, function_hook)
	asm:jne("out")
	asm:push(LUAJIT_MODE_ON)
	asm:push(0)
	asm:push(ebx)
	asm:call(control("jit_setmode"))
	asm:add(esp, 12)
	asm:push(0)
	asm:push(0)
	asm:push(0)
	asm:push(ebx)
	asm:call(control("lua_sethook"))
	asm:add(esp, 16)
	asm:label("out")
	asm:pop(ebx)
	asm:ret()
	return entry
end

---Pushes a stack slot repeatedly: each push moves the next argument into that slot
---@param asm x86_assembler
---@param slot integer
---@param count integer
local function push_stack_slot(asm, slot, count)
	for _ = 1, count do
		asm:push(at(esp, slot))
	end
end

---Taken when a material is not in its hashed slot: its first sighting, or two materials sharing a hash. Walks to its
---own slot, claiming the first empty one, so each material keeps its own numbers. A full table shares the first slot
---@param asm x86_assembler
---@param cells number
local function emit_cell_slot_search(asm, cells)
	asm:label("find_slot")
	asm:push(ebx)
	asm:push(esi)
	asm:mov(ebx, eax)
	asm:mov(esi, hook_block.CELL_COUNTER_COUNT)
	asm:label("next_slot")
	asm:xor(eax, eax)
	asm:lock_cmpxchg(at(ebx, cells + cell_offset("material")), edx) -- worker threads race for the same empty slot
	asm:je("found")
	asm:cmp(eax, edx)
	asm:je("found")
	asm:add(ebx, CELL_COUNTER_SIZE)
	asm:and_(ebx, CELL_COUNTERS_MASK)
	asm:dec(esi)
	asm:jne("next_slot")
	asm:label("found")
	asm:mov(eax, ebx)
	asm:pop(esi)
	asm:pop(ebx)
	asm:jmp("count")
end

---Runs for every simulated cell, so the usual path stays small: always counts, times 1 call in 64
---@param context profiler_stub_context
---@param hook profiler_planned_hook
---@param original x86_operand
local function emit_cell_hook(context, hook, original)
	local asm = context.asm
	local cells = context.block_address + hook_block.CELLS_OFFSET
	asm:mov(edx, at(ecx, hook.material_offset))
	asm:imul(eax, edx, CELL_HASH_FACTOR)
	asm:shr(eax, CELL_HASH_SHIFT)
	asm:shl(eax, hook_block.CELL_COUNTER_SHIFT)
	asm:cmp(at(eax, cells + cell_offset("material")), edx)
	asm:jne("find_slot")
	asm:label("count")
	asm:add(eax, cells)
	asm:inc(at(eax, cell_offset("count")))
	asm:test(byte_at(eax, cell_offset("count")), CELL_TIMING_MASK)
	asm:je("timed")
	asm:jmp(original)
	asm:label("timed")
	asm:push(esi)
	asm:push(edi)
	asm:mov(esi, eax)
	asm:rdtsc()
	asm:mov(edi, eax)
	push_stack_slot(asm, 0x18, 4)
	asm:call(original) -- thiscall, ret 0x10
	asm:rdtsc()
	asm:sub(eax, edi)
	asm:add(at(esi, cell_offset("ticks")), eax)
	asm:inc(at(esi, cell_offset("samples")))
	asm:mov(eax, CURRENT_THREAD_ID)
	asm:mov(context.control("cell_loop_thread_id"), eax)
	asm:pop(edi)
	asm:pop(esi)
	asm:ret(0x10)
	emit_cell_slot_search(asm, cells)
end

---Pushes what lua_type and lua_pushvalue take for the function under the arguments of lua_pcall(L, nargs, ...).
---lua_getinfo(">") reads that value unchecked, and a bad value is lua_pcall's error to raise
---@param asm x86_assembler
local function push_called_function_index(asm)
	asm:mov(eax, at(ebp, 12))
	asm:not_(eax)
	asm:push(eax)
	asm:push(at(ebp, 8))
end

---lua_pcall: records the called function's source and line, after the state gate
---@param context profiler_stub_context
---@param hook profiler_planned_hook
---@param original x86_operand
local function emit_pcall_hook(context, hook, original)
	local asm, control = context.asm, context.control
	asm:push(ebp)
	asm:mov(ebp, esp)
	asm:sub(esp, -LUA_DEBUG_ON_STACK)
	asm:push(esi)
	asm:push(edi)
	asm:xor(edi, edi)
	asm:mov(esi, context.unknown_string)
	asm:mov(eax, at(ebp, 8))
	asm:mov(control("last_lua_state"), eax) -- while the reader runs, this is its own state
	asm:cmp(control("function_hooks_available"), 0)
	asm:je("past_gate")
	asm:push(eax)
	asm:call(context.state_gate)
	asm:add(esp, 4)
	asm:label("past_gate")
	push_called_function_index(asm)
	asm:call(control("lua_type"))
	asm:add(esp, 8)
	asm:cmp(eax, LUA_TFUNCTION)
	asm:jne("enter")
	push_called_function_index(asm)
	asm:call(control("lua_pushvalue"))
	asm:add(esp, 8)
	asm:lea(eax, at(ebp, LUA_DEBUG_ON_STACK))
	asm:push(eax)
	asm:push(context.info_string)
	asm:push(at(ebp, 8))
	asm:call(control("lua_getinfo"))
	asm:add(esp, 12)
	asm:mov(esi, at(ebp, LUA_DEBUG_ON_STACK + LUA_DEBUG_SOURCE))
	asm:mov(edi, at(ebp, LUA_DEBUG_ON_STACK + LUA_DEBUG_LINE_DEFINED))
	asm:test(esi, esi)
	asm:jne("enter")
	asm:mov(esi, context.unknown_string)
	asm:label("enter")
	asm:mov(eax, hook.id * 2)
	asm:call(context.record)
	asm:push(at(ebp, 20))
	asm:push(at(ebp, 16))
	asm:push(at(ebp, 12))
	asm:push(at(ebp, 8))
	asm:call(original)
	asm:add(esp, 16)
	asm:push(eax) -- keeps the result
	asm:xor(esi, esi)
	asm:mov(eax, hook.id * 2 + 1)
	asm:call(context.record)
	asm:pop(eax)
	asm:pop(edi)
	asm:pop(esi)
	asm:leave()
	asm:ret()
end

---One argument, callee cleans up: SwapBuffers
---@param context profiler_stub_context
---@param hook profiler_planned_hook
---@param original x86_operand
local function emit_stdcall1_hook(context, hook, original)
	local asm = context.asm
	asm:push(esi)
	asm:xor(esi, esi)
	asm:mov(eax, hook.id * 2)
	asm:call(context.record)
	asm:push(at(esp, 8))
	asm:call(original) -- removes its own argument
	asm:push(eax) -- keeps the result
	asm:mov(eax, hook.id * 2 + 1)
	asm:call(context.record)
	asm:pop(eax)
	asm:pop(esi)
	asm:ret(4)
end

---luaL_loadbufferx: the chunk name goes into the event
---@param context profiler_stub_context
---@param hook profiler_planned_hook
---@param original x86_operand
local function emit_load_hook(context, hook, original)
	local asm = context.asm
	asm:push(esi)
	asm:mov(esi, at(esp, 0x14))
	asm:test(esi, esi)
	asm:jne("enter")
	asm:mov(esi, context.unknown_string)
	asm:label("enter")
	asm:mov(eax, hook.id * 2)
	asm:call(context.record)
	push_stack_slot(asm, 0x18, 5)
	asm:call(original)
	asm:add(esp, 20)
	asm:push(eax) -- keeps the result
	asm:xor(esi, esi)
	asm:mov(eax, hook.id * 2 + 1)
	asm:call(context.record)
	asm:pop(eax)
	asm:pop(esi)
	asm:ret()
end

---One argument, no result, caller cleans up: SDL_GL_SwapWindow and SDL_Delay
---@param context profiler_stub_context
---@param hook profiler_planned_hook
---@param original x86_operand
local function emit_cdecl1_hook(context, hook, original)
	local asm = context.asm
	asm:push(esi)
	asm:xor(esi, esi)
	asm:mov(eax, hook.id * 2)
	asm:call(context.record)
	asm:push(at(esp, 8))
	asm:call(original)
	asm:add(esp, 4)
	asm:mov(eax, hook.id * 2 + 1)
	asm:call(context.record)
	asm:pop(esi)
	asm:ret()
end

---Every system update is thiscall with one float. Also tells the sampler what is running
---@param context profiler_stub_context
---@param hook profiler_planned_hook
---@param original x86_operand
local function emit_system_hook(context, hook, original)
	local asm, control = context.asm, context.control
	-- Systems run inside the update, and the update and draw run inside nothing.
	local is_outermost = hook.id == HOOK_ID.UPDATE or hook.id == HOOK_ID.DRAW
	asm:push(esi)
	asm:xor(esi, esi)
	asm:mov(eax, hook.id * 2)
	asm:call(context.record)
	asm:mov(control("current_system"), hook.id)
	asm:push(at(esp, 8))
	asm:call(original)
	asm:mov(control("current_system"), is_outermost and 0 or HOOK_ID.UPDATE)
	asm:mov(eax, hook.id * 2 + 1)
	asm:call(context.record)
	asm:pop(esi)
	asm:ret(4)
end

local HOOK_EMITTERS = {
	cell = emit_cell_hook,
	pcall = emit_pcall_hook,
	stdcall1 = emit_stdcall1_hook,
	load = emit_load_hook,
	cdecl1 = emit_cdecl1_hook,
	system = emit_system_hook,
}

---@class profiler_stubs_module
local stubs = {}

---Generates all the code for a block at this address, and fills in each hook's stub
---@param block_address number
---@param hooks profiler_planned_hook[] in hook table order
---@return profiler_generated_code
function stubs.generate(block_address, hooks)
	local asm = x86.new_assembler(block_address + hook_block.CODE_OFFSET)
	---Memory operand for a control block field
	---@param field string
	---@return x86_operand
	local function control(field)
		return at_address(block_address + ffi.offsetof("profiler_control_block", field))
	end
	local context = {
		asm = asm,
		block_address = block_address,
		control = control,
		info_string = block_address + hook_block.LITERALS_OFFSET,
		unknown_string = block_address + hook_block.LITERALS_OFFSET + 4,
	}

	local read_timestamp_stub = asm:begin_routine()
	asm:rdtsc()
	asm:ret()

	context.record = emit_record(context)
	local sampler_entry = emit_sampler(context)
	local function_hook = emit_function_hook(context)
	context.state_gate = emit_state_gate(context, function_hook)

	for index, hook in ipairs(hooks) do
		local entry = block_address + hook_block.HOOKS_OFFSET + (index - 1) * hook_block.HOOK_ENTRY_SIZE
		local original = at_address(entry + ffi.offsetof("profiler_hook_entry", "original"))
		hook.stub = asm:begin_routine()
		HOOK_EMITTERS[hook.type](context, hook, original)
	end

	local code = asm:finish()
	assert(#code <= hook_block.EVENTS_OFFSET - hook_block.CODE_OFFSET, "code does not fit")
	return { code = code, read_timestamp_stub = read_timestamp_stub, sampler_entry = sampler_entry }
end

return stubs
