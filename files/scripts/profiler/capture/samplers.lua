local ffi = require("ffi")
local hook_block = dofile_once("mods/debug_helper/files/scripts/profiler/native/hook_block.lua") ---@type profiler_hook_block_module
local sessions = dofile_once("mods/debug_helper/files/scripts/profiler/capture/session.lua") ---@type profiler_sessions_module
local SAMPLE_COUNT = hook_block.SAMPLE_COUNT
local CELL_COUNTER_COUNT = hook_block.CELL_COUNTER_COUNT
local TWO_TO_32 = 4294967296
local NO_ENTITY_ID = 0xFFFFFFFF
local ENTITY_FILE_CACHE_LIMIT = 20000
local CELL_SCAN_EVERY_TICKS = 30
local TH32CS_SNAPTHREAD = 4
local THREAD_ENTRY_SIZE = 28
local THREAD_QUERY_LIMITED_INFORMATION = 0x0800
local WORKING_SET_INDEX = 3
local PROCESS_COUNTERS_DWORDS = 10

---@class profiler_samplers_module
local samplers = {}

samplers.SAMPLE_EVERY_TICKS = 60
-- A thread snapshot walks the whole system. Has to land on a sampling tick, the only ticks sample_threads runs on.
local THREAD_LIST_EVERY_TICKS = samplers.SAMPLE_EVERY_TICKS * 10
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
	if write_position - session.sample_cursor > SAMPLE_COUNT then
		session.samples_lost = session.samples_lost + (write_position - session.sample_cursor - SAMPLE_COUNT)
		session.sample_cursor = write_position - SAMPLE_COUNT
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
	for slot = 0, CELL_COUNTER_COUNT - 1 do
		if cells[slot].count ~= 0 and not session.cell_baselines[slot] then
			session.cell_baselines[slot] = { count = 0, ticks = 0, samples = 0, ticks_per_sample = 0 }
			session.active_cell_slots[#session.active_cell_slots + 1] = slot
		end
	end
end

---Folds the cell table into the current frame. Counters wrap at 32 bits, hence only differences get used
---@param session profiler_session
function samplers.read_cell_counters(session)
	if session.tick_count % CELL_SCAN_EVERY_TICKS == 1 then scan_for_new_cell_slots(session) end
	local cells = session.block.cells
	local frame = session.current_frame
	for _, slot in ipairs(session.active_cell_slots) do
		local counter = cells[slot]
		local baseline = session.cell_baselines[slot]
		local count = counter.count
		local new_cells = (count - baseline.count) % TWO_TO_32
		if new_cells > 0 then
			local new_samples = (counter.samples - baseline.samples) % TWO_TO_32
			local new_ticks = (counter.ticks - baseline.ticks) % TWO_TO_32
			if new_samples > 0 then baseline.ticks_per_sample = new_ticks / new_samples end
			baseline.count, baseline.ticks, baseline.samples = count, counter.ticks, counter.samples
			local name = material_name(session, counter.material)
			local ticks = baseline.ticks_per_sample * new_cells
			frame.material_ticks[name] = (frame.material_ticks[name] or 0) + ticks
			frame.material_cpu_ticks = frame.material_cpu_ticks + ticks
			sessions.add_material(session.open_bucket, name, new_cells, ticks)
			sessions.add_material(session.lifetime_bucket, name, new_cells, ticks)
		end
	end
end

---Opens handles for this process's threads and closes those of threads that ended
---@param session profiler_session
local function list_threads(session)
	local snapshot = ffi.C.CreateToolhelp32Snapshot(TH32CS_SNAPTHREAD, 0)
	if snapshot == nil or snapshot == ffi.cast("void*", -1) then return end
	local entry = hook_block.new_struct("win32_thread_entry")
	entry.size = THREAD_ENTRY_SIZE
	local alive = {}
	local process_id = ffi.C.GetCurrentProcessId()
	local more = ffi.C.Thread32First(snapshot, entry)
	while more ~= 0 do
		if entry.owner_process == process_id then
			local thread_id = entry.thread_id
			alive[thread_id] = true
			if not session.cpu_threads[thread_id] then
				local handle = ffi.C.OpenThread(THREAD_QUERY_LIMITED_INFORMATION, 0, thread_id)
				if handle ~= nil then session.cpu_threads[thread_id] = { handle = handle, percent = 0 } end
			end
		end
		more = ffi.C.Thread32Next(snapshot, entry)
	end
	ffi.C.CloseHandle(snapshot)
	for thread_id, thread in pairs(session.cpu_threads) do
		if not alive[thread_id] then
			ffi.C.CloseHandle(thread.handle)
			session.cpu_threads[thread_id] = nil
		end
	end
end

---CPU used by each thread since the last call, as a percentage of one core
---@param session profiler_session
function samplers.sample_threads(session)
	if not session.cpu_sample_wall_clock or session.tick_count % THREAD_LIST_EVERY_TICKS == 0 then list_threads(session) end
	local wall_clock = hook_block.read_wall_clock()
	local elapsed_seconds = session.cpu_sample_wall_clock and (wall_clock - session.cpu_sample_wall_clock) / session.wall_clock_frequency or nil
	session.cpu_sample_wall_clock = wall_clock
	local created, exited, kernel, user = ffi.new("uint64_t[1]"), ffi.new("uint64_t[1]"), ffi.new("uint64_t[1]"), ffi.new("uint64_t[1]")
	for _, thread in pairs(session.cpu_threads) do
		if ffi.C.GetThreadTimes(thread.handle, created, exited, kernel, user) ~= 0 then
			local cpu_seconds = (tonumber(kernel[0] + user[0]) or 0) / 1e7 -- 100 ns units
			if thread.cpu_seconds and elapsed_seconds and elapsed_seconds > 0 then
				thread.percent = 100 * (cpu_seconds - thread.cpu_seconds) / elapsed_seconds
			end
			thread.cpu_seconds = cpu_seconds
		end
	end
end

return samplers
