-- The layout of the memory block Lua shares with the generated stubs, as C structs and offsets.

local ffi = require("ffi")
dofile_once("mods/debug_helper/files/scripts/shared/win32.lua") -- the rest of the profiler relies on its declarations

ffi.cdef([[
typedef struct {
	uint32_t sequence, kind, thread_id, line, timestamp_low, timestamp_high;
	char path[100];
	uint32_t stack_slot;
} profiler_event;
typedef struct { uint32_t entity, system; } profiler_sample;
typedef struct { uint32_t material, count, ticks, samples; } profiler_cell_counter;
typedef struct { uint32_t slot, original, stub, id; char name[48]; } profiler_hook_entry;
typedef struct {
	uint32_t magic, event_write, hook_count, cell_hooks_installed, read_timestamp_stub;
	uint32_t lua_type, lua_pushvalue, lua_getinfo;
	char build[64];
	uint32_t cell_loop_thread_id;
	uint32_t sampler_enabled, sample_write, current_system, updated_entity_global, sleep_function;
	uint32_t function_hooks_available, function_hooks_enabled, function_calls, function_call_limit;
	uint32_t last_lua_state, reader_lua_state, main_thread_id;
	uint32_t lua_gethook, lua_sethook, jit_setmode;
} profiler_control_block;
]])

---@class profiler_event
---@field sequence integer event index + 1, written last: a slot is complete once this matches
---@field kind integer hook id * 2, plus 1 on exit
---@field thread_id integer
---@field line integer where the Lua function starts
---@field timestamp_low integer
---@field timestamp_high integer
---@field path ffi.cdata* char[100]
---@field stack_slot integer the Lua frame's stack slot, function events only

---@class profiler_sample
---@field entity entity_id
---@field system integer hook id of the system that was running

---@class profiler_cell_counter
---@field material integer CellData pointer
---@field count integer
---@field ticks integer
---@field samples integer calls timed so far

---@class profiler_hook_entry
---@field slot integer address of the patched pointer
---@field original integer
---@field stub integer
---@field id integer
---@field name ffi.cdata* char[48]

---@class profiler_control_block
---@field magic integer
---@field event_write integer
---@field hook_count integer
---@field cell_hooks_installed integer
---@field read_timestamp_stub integer
---@field lua_type integer
---@field lua_pushvalue integer
---@field lua_getinfo integer
---@field build ffi.cdata* char[64]
---@field cell_loop_thread_id integer last thread seen running the cell loop
---@field sampler_enabled integer
---@field sample_write integer
---@field current_system integer
---@field updated_entity_global integer
---@field sleep_function integer
---@field function_hooks_available integer checked first by lua_pcall's stub, normal play skips the state gate on it
---@field function_hooks_enabled integer
---@field function_calls integer this frame's count
---@field function_call_limit integer
---@field last_lua_state integer
---@field reader_lua_state integer
---@field main_thread_id integer
---@field lua_gethook integer
---@field lua_sethook integer
---@field jit_setmode integer

---@class profiler_hook_block
---@field control profiler_control_block
---@field hooks profiler_hook_entry[] from 0
---@field events profiler_event[] ring, from 0
---@field cells profiler_cell_counter[] hash table, from 0
---@field samples profiler_sample[] ring, from 0
---@field read_timestamp fun(): number

---@class profiler_hook_block_module
local hook_block = {}

hook_block.MAGIC = 0x50524F46
hook_block.LITERALS_OFFSET = 0x100 -- ">S\0" at +0, "?\0" at +4
hook_block.HOOKS_OFFSET = 0x1000
hook_block.HOOK_ENTRY_SIZE = 64
hook_block.CODE_OFFSET = 0x6000
hook_block.MAX_HOOKS = (hook_block.CODE_OFFSET - hook_block.HOOKS_OFFSET) / hook_block.HOOK_ENTRY_SIZE
hook_block.EVENTS_OFFSET = 0x10000
hook_block.EVENT_SIZE_SHIFT = 7 -- 128 bytes
hook_block.EVENT_COUNT = 0x10000 -- power of two: the record stub masks with it
hook_block.RING_MARGIN = 8192 -- the game keeps writing, so a slow reader stays this far behind the oldest slot
hook_block.CELLS_OFFSET = hook_block.EVENTS_OFFSET + hook_block.EVENT_COUNT * 128
hook_block.CELL_COUNTER_SHIFT = 4 -- 16 bytes
hook_block.CELL_COUNTER_COUNT = 4096 -- power of two: the cell stub keeps the top 12 bits of the hash
hook_block.SAMPLES_OFFSET = hook_block.CELLS_OFFSET + hook_block.CELL_COUNTER_COUNT * 16
hook_block.SAMPLE_SIZE_SHIFT = 3 -- 8 bytes
hook_block.SAMPLE_COUNT = 0x2000 -- power of two: the sampler stub masks with it
hook_block.BLOCK_SIZE = hook_block.SAMPLES_OFFSET + hook_block.SAMPLE_COUNT * 8

---Event kinds. Cell hooks count in their own table and write no events.
hook_block.HOOK_ID = {
	PCALL = 0,
	SWAP = 1,
	DELAY = 2,
	LOAD = 3,
	UPDATE = 4,
	DRAW = 5,
	FIRST_SYSTEM = 6,
	GDI_SWAP = 5000, -- outside the system range: not an engine system
	FUNCTION = 5001, -- a Lua function, from the lua_sethook hook
}

---Views memory as one C struct
---@generic Struct
---@param struct_name `Struct`
---@param address ffi.cdata*
---@return Struct
function hook_block.struct_at(struct_name, address)
	return ffi.cast(struct_name .. "*", address)
end

---Views memory as an array of C structs, indexed from 0
---@generic Struct
---@param struct_name `Struct`
---@param address ffi.cdata*
---@return Struct[]
function hook_block.array_at(struct_name, address)
	return ffi.cast(struct_name .. "*", address)
end

---Allocates one zeroed C struct
---@generic Struct
---@param struct_name `Struct`
---@return Struct
function hook_block.new_struct(struct_name)
	return ffi.new(struct_name)
end

---Allocates a zeroed array of C structs, indexed from 0
---@generic Struct
---@param struct_name `Struct`
---@param count integer
---@return Struct[]
function hook_block.new_array(struct_name, count)
	return ffi.new(struct_name .. "[?]", count)
end

---QueryPerformanceCounter, the clock timestamps get calibrated against
---@return number
function hook_block.read_wall_clock()
	local counter = ffi.new("int64_t[1]")
	ffi.C.QueryPerformanceCounter(counter)
	return tonumber(counter[0]) or 0
end

---Typed views of an existing block. Its read_timestamp_stub has to be set already
---@param address ffi.cdata*
---@return profiler_hook_block
function hook_block.open(address)
	local bytes = ffi.cast("uint8_t*", address)
	local control = hook_block.struct_at("profiler_control_block", bytes)
	local read_counter = ffi.cast("uint64_t(*)(void)", control.read_timestamp_stub)
	return {
		control = control,
		hooks = hook_block.array_at("profiler_hook_entry", bytes + hook_block.HOOKS_OFFSET),
		events = hook_block.array_at("profiler_event", bytes + hook_block.EVENTS_OFFSET),
		cells = hook_block.array_at("profiler_cell_counter", bytes + hook_block.CELLS_OFFSET),
		samples = hook_block.array_at("profiler_sample", bytes + hook_block.SAMPLES_OFFSET),
		read_timestamp = function()
			return tonumber(read_counter()) or 0
		end,
	}
end

return hook_block
