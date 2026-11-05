-- The text report: the summary first, then the detail behind it. Rewritten whole, with totals since the hooks attached.

local ffi = require("ffi")
local hook_block = dofile_once("mods/debug_helper/files/scripts/profiler/native/hook_block.lua") ---@type profiler_hook_block_module
local sessions = dofile_once("mods/debug_helper/files/scripts/profiler/capture/session.lua") ---@type profiler_sessions_module
local queries = dofile_once("mods/debug_helper/files/scripts/profiler/capture/queries.lua") ---@type profiler_queries_module
local census = dofile_once("mods/debug_helper/files/scripts/profiler/capture/census.lua") ---@type profiler_census_module
local file_export = dofile_once("mods/debug_helper/files/scripts/profiler/output/file_export.lua") ---@type profiler_file_export_module
local REPORT_PATH = "mods/debug_helper/profiler_report.txt"

---@class profiler_report_module
local report = {}

local report_lines = {}
local ticks_per_ms = 1

---Adds a formatted line
---@param format string
---@param ... any
local function line(format, ...)
	report_lines[#report_lines + 1] = string.format(format, ...)
end

---Ticks in milliseconds
---@param ticks number
---@return number
local function to_ms(ticks)
	return ticks / ticks_per_ms
end

---Stats as a list, largest first by one field
---@generic Key, Stats
---@param stats table<Key, Stats>
---@param field string
---@return {key:Key, stats:Stats}[]
local function sorted_by(stats, field)
	local list = {}
	for key, stat in pairs(stats) do
		list[#list + 1] = { key = key, stats = stat }
	end
	table.sort(list, function(left, right)
		return left.stats[field] > right.stats[field]
	end)
	return list
end

---Script totals merged per mod
---@param session profiler_session
---@return table<string, profiler_call_stats>
local function mod_groups(session)
	local groups = {}
	for path, stat in pairs(session.script_stats) do
		local name = path:match("^@?mods/([^/]+)/") or (path:match("^@?data/") and "(vanilla data/)") or "(other)"
		if name == "debug_helper" then name = "(this profiler, not a mod's cost)" end
		local group = groups[name] or { calls = 0, self_ticks = 0, total_ticks = 0, worst_ticks = 0 }
		groups[name] = group
		group.calls, group.self_ticks = group.calls + stat.calls, group.self_ticks + stat.self_ticks
		if stat.worst_ticks > group.worst_ticks then group.worst_ticks = stat.worst_ticks end
	end
	return groups
end

---Who used the frame, over the whole session
---@param session profiler_session
local function write_summary_owners(session)
	local owners = {}
	local counted_frames = session.slow_frames.frame_count + session.normal_frames.frame_count
	for _, group in ipairs({ session.slow_frames, session.normal_frames }) do
		for owner, ticks in pairs(group.owner_ticks) do
			owners[owner] = (owners[owner] or 0) + ticks
		end
	end
	local rows = {}
	for owner, ticks in pairs(owners) do
		rows[#rows + 1] = { owner = owner, milliseconds = to_ms(ticks) / math.max(counted_frames, 1) }
	end
	table.sort(rows, function(left, right)
		return left.milliseconds > right.milliseconds
	end)
	line("")
	line("Who uses the frame, ms per frame. Engine work a mod causes counts under the engine rows:")
	for index, row in ipairs(rows) do
		if index > 8 then break end
		line("  %7.2f  %s", row.milliseconds, row.owner)
	end
end

---The part to read first: who used the frame, then what to look at inside that
---@param session profiler_session
---@param frames integer
local function write_summary(session, frames)
	local busy_ms = to_ms(session.totals.busy_ticks / frames)
	line("SUMMARY")
	line(
		"%s: %.1f ms of work per frame against the 16.7 ms budget. %d frames over 33.3 ms, in %d stretches. %d entities.",
		busy_ms > 16.7 and "Over budget" or "Keeping up",
		busy_ms,
		session.spike_count,
		session.lifetime_bucket.stretch_count,
		session.entity_count
	)
	write_summary_owners(session)
	line("")
	line("Slowest Lua functions and scripts, ms per frame | calls per frame:")
	local shown = 0
	for _, row in ipairs(sorted_by(session.script_stats, "self_ticks")) do
		if not row.key:find("^@?mods/debug_helper/") then
			shown = shown + 1
			if shown > 8 then break end
			line("  %7.2f %8.1f  %s", to_ms(row.stats.self_ticks / frames), row.stats.calls / frames, row.key)
		end
	end
	if queries.sampler_active(session) then
		line("")
		line("Entity files costing the engine the most, ms per frame:")
		for index, row in ipairs(queries.entity_rows(session, session.lifetime_bucket).files) do
			if index > 5 then break end
			line("  %7.2f  %s", row.ms_per_frame, row.file)
		end
	end
	line("")
	line("Worst hitches, largest owners in ms. The first few are often the world loading:")
	for index, spike in ipairs(session.spikes) do
		if index > 8 then break end
		local parts = {}
		for owner_index, owner in ipairs(spike.owners) do
			if owner_index > 3 then break end
			parts[#parts + 1] = ("%s %.0f"):format(owner.key, to_ms(owner.ticks))
		end
		line("  frame %6d, %6.0f ms: %s", spike.frame_number, to_ms(spike.frame.busy_ticks), table.concat(parts, ", "))
	end
end

---Totals, counters and how the reader is doing
---@param session profiler_session
---@param frames integer
local function write_header(session, frames)
	local control = session.block.control
	local main_thread = session.lua_threads[session.main_thread_id]
	line("")
	line("Everything below is the detail behind that.")
	line("build: %s", ffi.string(control.build))
	line("hooks: %d  tsc ticks/ms: %.0f", control.hook_count, ticks_per_ms)
	line("frames: %d  avg %.2f ms  max %.2f ms", session.frame_count, to_ms(session.totals.frame_ticks / frames), to_ms(session.worst_frame_ticks))
	line(
		"busy (frame minus SDL_Delay on the game thread): avg %.2f ms  worst %.2f ms",
		to_ms(session.totals.busy_ticks / frames),
		to_ms(session.worst_busy_ticks)
	)
	line("lua_pcall per frame: avg %.1f  max %d", (main_thread and main_thread.lua_pcalls or 0) / frames, session.most_lua_pcalls)
	line("events: dropped %d  unmatched %d", session.events_dropped, session.events_unmatched)
	line(
		"reader: %d ticks  avg %.3f ms  max %.3f ms",
		session.tick_count,
		to_ms(session.own_ticks_total / math.max(session.tick_count, 1)),
		to_ms(session.own_ticks_worst)
	)
	line("game: entities %d  memory %.0f MB", session.entity_count, session.memory_mb)
	line(
		"lua function timing: %s now, %d frames hit the call limit",
		session.block.control.function_hooks_enabled ~= 0 and "on, JIT off, Lua times inflated," or "off",
		session.frames_over_call_limit
	)
	line("entity sampler: %s, %d samples, %d lost", queries.sampler_active(session) and "on" or "off", session.samples_read, session.samples_lost)
end

---What the profiler itself costs
---@param session profiler_session
---@param frames integer
local function write_own_cost(session, frames)
	line("")
	line("profiler's own cost: ms per frame | worst ms. Its Lua heap: %.1f MB", collectgarbage("count") / 1024)
	for _, row in ipairs(sorted_by(session.own_costs, "total_ticks")) do
		line("  %8.3f %9.2f  %s", to_ms(row.stats.total_ticks / frames), to_ms(row.stats.worst_ticks), row.key)
	end
end

---Time per category
---@param session profiler_session
---@param frames integer
local function write_frame_breakdown(session, frames)
	line("")
	line("frame breakdown, game thread: ms per frame")
	line("  %8.2f  wait (SDL_Delay)", to_ms(session.totals.wait_ticks / frames))
	local parts = {}
	for _, category in ipairs(sessions.CATEGORIES) do
		parts[#parts + 1] = { label = category.label, ticks = session.totals[category.key] }
	end
	table.sort(parts, function(left, right)
		return left.ticks > right.ticks
	end)
	for _, part in ipairs(parts) do
		line("  %8.2f  %s", to_ms(part.ticks / frames), part.label)
	end
end

---Which threads run Lua, and thread CPU
---@param session profiler_session
local function write_threads(session)
	line("")
	line("threads running Lua (game thread is %s):", tostring(session.main_thread_id))
	for thread_id, thread in pairs(session.lua_threads) do
		line(
			"  %d: %d events, %d lua_pcall%s",
			thread_id,
			thread.events,
			thread.lua_pcalls,
			thread_id == session.main_thread_id and " [game thread]" or ""
		)
	end
	line("")
	line("thread CPU, percent of one core, last sample:")
	for _, thread in ipairs(queries.thread_rows(session)) do
		line(
			"  %6.1f%%  %d%s%s",
			thread.percent,
			thread.thread_id,
			thread.is_game and " [game thread]" or "",
			thread.is_cell_loop and " [ran the cell loop]" or ""
		)
	end
	local reads = {}
	for thread_id, count in pairs(session.cell_loop_thread_reads) do
		reads[#reads + 1] = ("%d: %d reads"):format(thread_id, count)
	end
	if #reads > 0 then line("threads seen running the cell loop: %s", table.concat(reads, ", ")) end
end

---The worst spikes in full
---@param session profiler_session
local function write_spikes(session)
	line("")
	line("spikes over 33.3 ms busy: %d, worst %d below", session.spike_count, #session.spikes)
	for _, spike in ipairs(session.spikes) do
		local frame = spike.frame
		line(
			"  frame %d: busy %.2f ms, frame %.2f ms, spawned %d, lua_pcall %d",
			spike.frame_number,
			to_ms(frame.busy_ticks),
			to_ms(frame.frame_ticks),
			frame.entities_spawned,
			frame.lua_pcalls
		)
		for index, item in ipairs(spike.top_items) do
			if index > 8 then break end
			line("    %9.2f  %s", to_ms(item.ticks), item.key)
		end
		local owners = {}
		for index, owner in ipairs(spike.owners) do
			if index > 4 then break end
			owners[#owners + 1] = ("%s %.1f"):format(owner.key, to_ms(owner.ticks))
		end
		line("    by owner: %s", table.concat(owners, ", "))
		for index, material in ipairs(spike.top_materials) do
			if index > 4 then break end
			line("    %9.2f  material CPU: %s", to_ms(material.ticks), material.key)
		end
	end
end

---The systems under an entity file, largest first
---@param systems profiler_entity_file_system[]
---@param limit integer
local function write_entity_file_systems(systems, limit)
	table.sort(systems, function(left, right)
		return left.ms_per_frame > right.ms_per_frame
	end)
	for index, system in ipairs(systems) do
		if index > limit then break end
		line("           %8.3f  %s", system.ms_per_frame, system.name)
	end
end

---Engine time by entity file
---@param session profiler_session
local function write_entity_files(session)
	if not queries.sampler_active(session) then return end
	local rows = queries.entity_rows(session, session.lifetime_bucket)
	line("")
	line("engine time by entity file, sampled: ms per frame | samples | owner | file. LuaSystem includes its scripts.")
	for index, row in ipairs(rows.files) do
		if index > 40 then break end
		line("  %8.3f %8d  %-20s %s", row.ms_per_frame, row.samples, row.owner, row.file)
		write_entity_file_systems(row.systems, 4)
	end
	local system_wide = rows.system_wide
	if system_wide then
		line("  %8.3f %8d  work before and after systems' per-entity loops, in no single entity", system_wide.ms_per_frame, system_wide.samples)
		write_entity_file_systems(system_wide.systems, 8)
	end
end

---Owners in slow frames against normal ones, and the kept traces
---@param session profiler_session
local function write_slow_against_normal(session)
	line("")
	line(
		"slow frames against normal ones, by owner: %d slow frames in %d stretches, %d normal",
		session.slow_frames.frame_count,
		session.lifetime_bucket.stretch_count,
		session.normal_frames.frame_count
	)
	line("  slow ms | normal ms | extra ms")
	for _, row in ipairs(queries.slow_rows(session)) do
		line("  %8.2f %8.2f %8.2f  %s", row.slow_ms, row.normal_ms, row.extra_ms, row.owner)
	end
	if #session.trace_slots > 0 then
		line("spike traces (open in ui.perfetto.dev), in %s:", file_export.OUTPUT_DIRECTORY)
		for _, slot in ipairs(session.trace_slots) do
			line("  %s: frame %d, busy %.2f ms", slot.file, slot.frame_number, to_ms(slot.busy_ticks))
		end
	end
end

---Simulation time by material
---@param session profiler_session
local function write_materials(session)
	if not queries.has_cell_hooks(session) then return end
	line("")
	local material_total = 0
	local rows = queries.material_rows(session, session.lifetime_bucket)
	for _, row in ipairs(rows) do
		material_total = material_total + row.ms_per_frame
	end
	line(
		"simulation by material: %.2f ms per frame of CPU in total, across all threads. Says what burned the time, not who caused it.",
		material_total
	)
	line("CPU ms per frame | cells per frame | which mod's file defined it")
	for index, row in ipairs(rows) do
		if index > 40 then break end
		line("  %10.3f %10.0f  %-20s %s", row.ms_per_frame, row.cells_per_frame, row.owner, row.name)
	end
end

---Component and script counts from the last census
local function write_census()
	local pass = census.latest()
	if not pass then return end
	line("")
	line("component census: %d entities", pass.entities)
	local kinds = {}
	for kind, entry in pairs(pass.components) do
		kinds[#kinds + 1] = { key = kind, count = entry.count }
	end
	table.sort(kinds, function(left, right)
		return left.count > right.count
	end)
	for index, kind in ipairs(kinds) do
		if index > 15 then break end
		line("  %7d  %s", kind.count, kind.key)
	end
	line("LuaComponent scripts: copies | enabled | running every frame")
	local scripts = {}
	for path, entry in pairs(pass.scripts) do
		scripts[#scripts + 1] = { path = path, entry = entry }
	end
	table.sort(scripts, function(left, right)
		return left.entry.copies > right.entry.copies
	end)
	for index, script in ipairs(scripts) do
		if index > 25 then break end
		line("  %5d %5d %5d  %s", script.entry.copies, script.entry.enabled, script.entry.every_frame, script.path)
	end
end

---Lua and compile time by mod, script and file
---@param session profiler_session
local function write_lua_totals(session)
	line("")
	line("by mod, own Lua only: self ms total | calls | worst call ms. Engine work a mod causes is not included.")
	for _, row in ipairs(sorted_by(mod_groups(session), "self_ticks")) do
		line("  %10.2f %9d %9.2f  %s", to_ms(row.stats.self_ticks), row.stats.calls, to_ms(row.stats.worst_ticks), row.key)
	end
	line("")
	line("scripts: self ms total | calls | worst call ms")
	for index, row in ipairs(sorted_by(session.script_stats, "self_ticks")) do
		if index > 60 then break end
		line("  %10.2f %9d %9.2f  %s", to_ms(row.stats.self_ticks), row.stats.calls, to_ms(row.stats.worst_ticks), row.key)
	end
	local setup_caller, setup_share = queries.main_caller(session, "(lua state setup)")
	if setup_caller then
		line(
			"(lua state setup) is new Lua states and the game's dofile and dofile_once, mostly started by %s (%.0f%%)",
			setup_caller,
			setup_share * 100
		)
	end
	line("")
	line("compile (luaL_loadbufferx): ms total | calls | worst call ms | file, and what mostly started it")
	for index, row in ipairs(sorted_by(session.compile_stats, "total_ticks")) do
		if index > 30 then break end
		local caller, share = queries.main_caller(session, "compile: " .. row.key)
		line(
			"  %10.2f %9d %9.2f  %s  <- %s (%.0f%%)",
			to_ms(row.stats.total_ticks),
			row.stats.calls,
			to_ms(row.stats.worst_ticks),
			row.key,
			caller or "?",
			share * 100
		)
	end
end

---Native hook totals, and the hooks that never ran
---@param session profiler_session
local function write_native_hooks(session)
	line("")
	line("native hooks: self ms total | total ms | calls | worst call ms")
	local silent = {}
	for hook_id, name in pairs(session.hook_names) do
		-- Cell hooks count in their own table instead of writing events.
		if hook_id ~= hook_block.HOOK_ID.PCALL and not session.hook_stats[hook_id] and not name:find("Cell update$") then
			silent[#silent + 1] = name
		end
	end
	for _, row in ipairs(sorted_by(session.hook_stats, "self_ticks")) do
		line(
			"  %10.2f %10.2f %9d %9.2f  %s",
			to_ms(row.stats.self_ticks),
			to_ms(row.stats.total_ticks),
			row.stats.calls,
			to_ms(row.stats.worst_ticks),
			session.hook_names[row.key] or "?"
		)
	end
	line("")
	line("hooks with zero calls (%d): %s", #silent, table.concat(silent, ", "))
end

---Rewrites the report
---@param session profiler_session
function report.write(session)
	report_lines = {}
	ticks_per_ms = session.ticks_per_ms
	local frames = math.max(session.frame_count, 1)
	write_summary(session, frames)
	write_header(session, frames)
	write_own_cost(session, frames)
	write_frame_breakdown(session, frames)
	write_threads(session)
	write_spikes(session)
	write_entity_files(session)
	write_slow_against_normal(session)
	write_materials(session)
	write_census()
	write_lua_totals(session)
	write_native_hooks(session)
	local file = io.open(REPORT_PATH, "w")
	if file then
		file:write(table.concat(report_lines, "\n"), "\n")
		file:close()
	end
end

return report
