-- Frame profiler entry point: starts the hooks and folds their data into the session once a frame.
-- Design and limits: docs/profiler.md in this mod. Needs request_no_api_restrictions="1" for require("ffi").

local ffi = require("ffi")
local hook_installer = dofile_once("mods/debug_helper/files/scripts/profiler/native/hook_installer.lua") ---@type profiler_hook_installer_module
local sessions = dofile_once("mods/debug_helper/files/scripts/profiler/capture/session.lua") ---@type profiler_sessions_module
local event_reader = dofile_once("mods/debug_helper/files/scripts/profiler/capture/event_reader.lua") ---@type profiler_event_reader_module
local samplers = dofile_once("mods/debug_helper/files/scripts/profiler/capture/samplers.lua") ---@type profiler_samplers_module
local census = dofile_once("mods/debug_helper/files/scripts/profiler/capture/census.lua") ---@type profiler_census_module
local file_export = dofile_once("mods/debug_helper/files/scripts/profiler/output/file_export.lua") ---@type profiler_file_export_module
local report = dofile_once("mods/debug_helper/files/scripts/profiler/output/report.lua") ---@type profiler_report_module
local REPORT_EVERY_TICKS = 600

---@class profiler
---@field session profiler_session? nil while the profiler is off
local profiler = {}

---Applies the mod setting: installs, attaches to hooks an old Lua state left, or removes them
---@param enabled boolean
function profiler.start(enabled)
	local block = hook_installer.start(enabled)
	if block then profiler.session = sessions.new(block) end
end

---The session, once it is calibrated and has readable times
---@return profiler_session?
function profiler.running_session()
	local session = profiler.session
	return session and session.ticks_per_ms > 0 and session or nil
end

---Hands the hooks what they read directly, and counts frames that hit the Lua call limit
---@param running profiler_session
local function sync_control_block(running)
	-- Taken here and not at start: OnModPostInit runs on a different thread from the game loop.
	if running.main_thread_id == 0 then running.main_thread_id = ffi.C.GetCurrentThreadId() end
	local control = running.block.control
	control.main_thread_id = running.main_thread_id
	control.reader_lua_state = control.last_lua_state
	if control.function_calls >= control.function_call_limit and control.function_call_limit > 0 then
		running.frames_over_call_limit = running.frames_over_call_limit + 1
	end
	control.function_calls = 0
end

---Runs the census, which reads live game data and must not take the profiler down with it
---@param running profiler_session
local function step_census(running)
	local succeeded, census_error = pcall(census.step)
	if not succeeded and not running.census_failed then
		running.census_failed = true
		print("[profiler] census error: " .. tostring(census_error))
	end
end

---Call once per frame, gameplay or paused
function profiler.tick()
	local running = profiler.session
	if not running then return end
	sync_control_block(running)
	local control = running.block.control
	local read_timestamp = running.block.read_timestamp
	local started = read_timestamp()
	running.tick_count = running.tick_count + 1
	if running.ticks_per_ms == 0 or running.tick_count % samplers.SAMPLE_EVERY_TICKS == 0 then
		samplers.calibrate(running)
		local before_threads = read_timestamp()
		pcall(samplers.sample_threads, running)
		sessions.add_own_cost(running, "thread CPU", read_timestamp() - before_threads)
	end
	event_reader.read_events(running)
	local after_read = read_timestamp()
	sessions.add_own_cost(running, "read events", after_read - started)
	if control.cell_hooks_installed ~= 0 then
		local cell_thread = control.cell_loop_thread_id
		if cell_thread ~= 0 then running.cell_loop_thread_reads[cell_thread] = (running.cell_loop_thread_reads[cell_thread] or 0) + 1 end
		samplers.read_cell_counters(running)
		sessions.add_own_cost(running, "read material table", read_timestamp() - after_read)
	end
	samplers.sample_game(running)
	local before_entities = read_timestamp()
	sessions.add_own_cost(running, "sample game", before_entities - after_read)
	if control.sampler_enabled ~= 0 then samplers.read_entity_samples(running) end
	local after_samples = read_timestamp()
	sessions.add_own_cost(running, "entity samples", after_samples - before_entities)
	file_export.start_due_trace(running)
	file_export.step()
	local after_export = read_timestamp()
	sessions.add_own_cost(running, "write trace or CSV", after_export - after_samples)
	step_census(running)
	sessions.add_own_cost(running, "component census", read_timestamp() - after_export)
	if running.tick_count % REPORT_EVERY_TICKS == 0 and running.ticks_per_ms > 0 then
		report.write(running)
		sessions.add_own_cost(running, "text report", read_timestamp() - after_export)
	end
	local spent = read_timestamp() - started
	running.own_ticks_total = running.own_ticks_total + spent
	if spent > running.own_ticks_worst then running.own_ticks_worst = spent end
end

return profiler
