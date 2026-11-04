local ffi = require("ffi")
local win32 = dofile_once("mods/debug_helper/files/scripts/shared/win32.lua") ---@type win32_module
local hook_block = dofile_once("mods/debug_helper/files/scripts/profiler/native/hook_block.lua") ---@type profiler_hook_block_module
local sessions = dofile_once("mods/debug_helper/files/scripts/profiler/capture/session.lua") ---@type profiler_sessions_module
local SAMPLE_COUNT = hook_block.SAMPLE_COUNT
local CELL_COUNTER_COUNT = hook_block.CELL_COUNTER_COUNT
local TWO_TO_31 = 2147483648
local TWO_TO_32 = 4294967296
local NO_ENTITY_ID = 0xFFFFFFFF
local ENTITY_FILE_CACHE_LIMIT = 20000
local CELL_SCAN_EVERY_TICKS = 30
local THREAD_QUERY_LIMITED_INFORMATION = 0x0800
local WORKING_SET_INDEX = 3
local PROCESS_COUNTERS_DWORDS = 10

---@class profiler_samplers_module
local samplers = {}

samplers.SAMPLE_EVERY_TICKS = 60
samplers.NO_ENTITY = "(system-wide work, no single entity)"
samplers.GONE_ENTITY = "(removed before it could be read)"
samplers.RUNTIME_ENTITY = "(created at runtime)"

---Which file an entity came from. Ids are not reused, one lookup per entity is enough
---@param session profiler_session
---@param entity_id entity_id
---@return string
local function entity_file(session, entity_id)
	if entity_id == NO_ENTITY_ID then return samplers.NO_ENTITY end
	local file = session.entity_files_by_id[entity_id]
	if file then return file end
	if session.entity_files_cached > ENTITY_FILE_CACHE_LIMIT then
		session.entity_files_by_id, session.entity_files_cached = {}, 0
	end
	if not EntityGetIsAlive(entity_id) then
		file = samplers.GONE_ENTITY
	else
		file = EntityGetFilename(entity_id) or ""
		if file == "" then file = samplers.RUNTIME_ENTITY end
	end
	session.entity_files_by_id[entity_id] = file
	session.entity_files_cached = session.entity_files_cached + 1
	return file
end

---Counts one sample for a system and file
---@param bucket profiler_bucket
---@param system string
---@param file string
local function add_entity_sample(bucket, system, file)
	local entry = bucket.entity_samples[system]
	if not entry then
		entry = { samples = 0, samples_by_file = {} }
		bucket.entity_samples[system] = entry
	end
	entry.samples = entry.samples + 1
	entry.samples_by_file[file] = (entry.samples_by_file[file] or 0) + 1
end

---Reads what the sampler thread wrote since the last read
---@param session profiler_session
function samplers.read_entity_samples(session)
	local write_position = session.block.control.sample_write
	local unread = (write_position - session.sample_cursor) % TWO_TO_32
	if unread > SAMPLE_COUNT then
		session.samples_lost = session.samples_lost + (unread - SAMPLE_COUNT)
		session.sample_cursor = (write_position - SAMPLE_COUNT) % TWO_TO_32
	end
	local samples = session.block.samples
	local sample_index = session.sample_cursor
	while sample_index ~= write_position do
		local sample = samples[sample_index % SAMPLE_COUNT]
		local system_id = sample.system
		local system = system_id >= hook_block.HOOK_ID.FIRST_SYSTEM and session.hook_names[system_id]
		if system then
			local file = entity_file(session, sample.entity)
			add_entity_sample(session.open_bucket, system, file)
			add_entity_sample(session.lifetime_bucket, system, file)
		end
		session.samples_read = session.samples_read + 1
		sample_index = (sample_index + 1) % TWO_TO_32
	end
	session.sample_cursor = sample_index
end

---Measures timestamp ticks per millisecond against the wall clock
---@param session profiler_session
function samplers.calibrate(session)
	local elapsed_ms = (hook_block.read_wall_clock() - session.wall_clock_start) * 1000 / session.wall_clock_frequency
	if elapsed_ms > 100 then session.ticks_per_ms = (session.block.read_timestamp() - session.timestamp_start) / elapsed_ms end
end

---Entity count, new entities and memory use
---@param session profiler_session
function samplers.sample_game(session)
	if EntitiesGetMaxID then
		local highest_id = EntitiesGetMaxID()
		if session.highest_entity_id then session.current_frame.entities_spawned = math.max(0, highest_id - session.highest_entity_id) end
		session.highest_entity_id = highest_id
	end
	if session.tick_count % samplers.SAMPLE_EVERY_TICKS ~= 0 then return end
	if EntityGetInRadius then session.entity_count = #(EntityGetInRadius(0, 0, 1e9) or {}) end
	local counters = ffi.new("uint32_t[?]", PROCESS_COUNTERS_DWORDS)
	counters[0] = PROCESS_COUNTERS_DWORDS * 4
	local succeeded, result = pcall(function()
		return ffi.C.K32GetProcessMemoryInfo(ffi.C.GetCurrentProcess(), counters, PROCESS_COUNTERS_DWORDS * 4)
	end)
	if succeeded and result ~= 0 then session.memory_mb = counters[WORKING_SET_INDEX] / 1048576 end
end

---Name of a material from its CellData, whose first field is an MSVC std::string. Every pointer gets checked
---first, since it comes from a hash table the game's threads are writing to
---@param session profiler_session
---@param material integer
---@return string
local function material_name(session, material)
	local cached = session.material_names[material]
	if cached then return cached end
	local base = ffi.cast("uint8_t*", material)
	local name = "?"
	if material ~= 0 and ffi.C.IsBadReadPtr(base, 24) == 0 then
		local size = ffi.cast("uint32_t*", base + 16)[0]
		local capacity = ffi.cast("uint32_t*", base + 20)[0]
		local text = capacity >= 16 and ffi.cast("uint8_t**", base)[0] or base
		if size > 0 and size < 128 and ffi.C.IsBadReadPtr(text, size) == 0 then
			local candidate = ffi.string(text, size)
			if candidate:find("^[%w_%-]+$") then name = candidate end
		end
	end
	session.material_names[material] = name
	return name
end

---Finds counter slots that came into use. Only those get read each frame
---@param session profiler_session
local function scan_for_new_cell_slots(session)
	local cells = session.block.cells
	-- Counters outlive a Lua state, so what the first scan finds is not this session's. Later finds are all new.
	local is_first_scan = session.tick_count == 1
	for slot = 0, CELL_COUNTER_COUNT - 1 do
		local counter = cells[slot]
		if counter.count ~= 0 and not session.cell_baselines[slot] then
			local baseline = { count = 0, ticks = 0, samples = 0, ticks_per_sample = 0 }
			if is_first_scan then
				baseline.count, baseline.ticks, baseline.samples = counter.count, counter.ticks, counter.samples
				if counter.samples > 0 then baseline.ticks_per_sample = counter.ticks / counter.samples end
			end
			session.cell_baselines[slot] = baseline
			session.active_cell_slots[#session.active_cell_slots + 1] = slot
		end
	end
end

---How far a cell counter moved since the last read. Counters wrap at 32 bits, and worker threads update them without
---a lock, so a late write can step one back a little. That is no movement, not a wrap of 4 billion
---@param now integer
---@param before integer
---@return integer
local function counter_moved(now, before)
	local moved = (now - before) % TWO_TO_32
	return moved < TWO_TO_31 and moved or 0
end

---Folds the cell table into the current frame
---@param session profiler_session
function samplers.read_cell_counters(session)
	if session.tick_count % CELL_SCAN_EVERY_TICKS == 1 then scan_for_new_cell_slots(session) end
	local cells = session.block.cells
	local frame = session.current_frame
	for _, slot in ipairs(session.active_cell_slots) do
		local counter = cells[slot]
		local baseline = session.cell_baselines[slot]
		local count, counted_ticks, samples = counter.count, counter.ticks, counter.samples
		local new_cells = counter_moved(count, baseline.count)
		if new_cells > 0 then
			local new_samples = counter_moved(samples, baseline.samples)
			if new_samples > 0 then baseline.ticks_per_sample = counter_moved(counted_ticks, baseline.ticks) / new_samples end
			baseline.count, baseline.ticks, baseline.samples = count, counted_ticks, samples
			local name = material_name(session, counter.material)
			local ticks = baseline.ticks_per_sample * new_cells
			frame.material_ticks[name] = (frame.material_ticks[name] or 0) + ticks
			frame.material_cpu_ticks = frame.material_cpu_ticks + ticks
			sessions.add_material(session.open_bucket, name, new_cells, ticks)
			sessions.add_material(session.lifetime_bucket, name, new_cells, ticks)
		end
	end
end

---A thread's CPU use since its last sample. One that ended stays listed while the game holds a handle to it, at 0%
---@param previous profiler_cpu_thread?
---@param cpu_seconds number
---@param elapsed_seconds number?
---@return profiler_cpu_thread
local function thread_usage(previous, cpu_seconds, elapsed_seconds)
	local percent = 0
	if previous and elapsed_seconds and elapsed_seconds > 0 then percent = 100 * (cpu_seconds - previous.cpu_seconds) / elapsed_seconds end
	return { cpu_seconds = cpu_seconds, percent = percent }
end

---CPU used by each thread since the last call, as a percentage of one core. Keeps no thread handle past this call:
---a Lua state can go at any time, and nothing would close what it held
---@param session profiler_session
function samplers.sample_threads(session)
	local wall_clock = hook_block.read_wall_clock()
	local elapsed_seconds = session.cpu_sample_wall_clock and (wall_clock - session.cpu_sample_wall_clock) / session.wall_clock_frequency or nil
	session.cpu_sample_wall_clock = wall_clock
	local process = ffi.C.GetCurrentProcess()
	local next_handle = ffi.new("void*[1]")
	local created, exited, kernel, user = ffi.new("uint64_t[1]"), ffi.new("uint64_t[1]"), ffi.new("uint64_t[1]"), ffi.new("uint64_t[1]")
	local threads = {}
	local handle = nil
	while win32.ntdll.NtGetNextThread(process, handle, THREAD_QUERY_LIMITED_INFORMATION, 0, 0, next_handle) == 0 do
		if handle then ffi.C.CloseHandle(handle) end
		handle = next_handle[0]
		if ffi.C.GetThreadTimes(handle, created, exited, kernel, user) ~= 0 then
			local thread_id = ffi.C.GetThreadId(handle)
			local cpu_seconds = (tonumber(kernel[0] + user[0]) or 0) / 1e7 -- 100 ns units
			threads[thread_id] = thread_usage(session.cpu_threads[thread_id], cpu_seconds, elapsed_seconds)
		end
	end
	if handle then ffi.C.CloseHandle(handle) end
	session.cpu_threads = threads
end

return samplers
