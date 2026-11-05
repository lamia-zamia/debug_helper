local sessions = dofile_once("mods/debug_helper/files/scripts/profiler/capture/session.lua") ---@type profiler_sessions_module
local samplers = dofile_once("mods/debug_helper/files/scripts/profiler/capture/samplers.lua") ---@type profiler_samplers_module
local census = dofile_once("mods/debug_helper/files/scripts/profiler/capture/census.lua") ---@type profiler_census_module
---@class profiler_entity_file_share
---@field file string
---@field ms_per_frame number
---@field samples integer

---@class profiler_entity_system_row
---@field name string
---@field ms_per_frame number
---@field samples integer
---@field files profiler_entity_file_share[] largest first

---@class profiler_entity_file_system
---@field name string
---@field ms_per_frame number
---@field samples integer

---@class profiler_entity_file_row
---@field file string
---@field owner string
---@field ms_per_frame number
---@field samples integer
---@field systems profiler_entity_file_system[]

---@class profiler_entity_rows
---@field systems table<string, profiler_entity_system_row>
---@field files profiler_entity_file_row[] largest first, without system_wide
---@field samples integer
---@field system_wide profiler_entity_file_row? work before and after a system's per-entity loop

---@class profiler_slow_row
---@field owner string
---@field slow_ms number
---@field normal_ms number
---@field extra_ms number

---@class profiler_material_row
---@field name string
---@field owner string
---@field cells_per_frame number
---@field ms_per_frame number

---@class profiler_thread_row
---@field thread_id integer
---@field percent number
---@field is_game boolean
---@field is_cell_loop boolean

---@class profiler_frame_item
---@field key string
---@field milliseconds number

---@class profiler_queries_module
local queries = {}

---Sort order: most time first
---@param left {ms_per_frame: number}
---@param right {ms_per_frame: number}
---@return boolean
local function by_ms_per_frame(left, right)
	return left.ms_per_frame > right.ms_per_frame
end

---Merges per-item totals
---@param into profiler_bucket
---@param bucket profiler_bucket
local function merge_item_stats(into, bucket)
	for key, stat in pairs(bucket.item_stats) do
		local merged = into.item_stats[key]
		if not merged then
			merged = { ticks = 0, calls = 0, worst_ticks = 0 }
			into.item_stats[key] = merged
		end
		merged.ticks = merged.ticks + stat.ticks
		merged.calls = merged.calls + stat.calls
		if stat.worst_ticks > merged.worst_ticks then merged.worst_ticks = stat.worst_ticks end
	end
end

---Merges per-system samples
---@param into profiler_bucket
---@param bucket profiler_bucket
local function merge_entity_samples(into, bucket)
	for system, entry in pairs(bucket.entity_samples) do
		local merged = into.entity_samples[system]
		if not merged then
			merged = { samples = 0, samples_by_file = {} }
			into.entity_samples[system] = merged
		end
		merged.samples = merged.samples + entry.samples
		for file, count in pairs(entry.samples_by_file) do
			merged.samples_by_file[file] = (merged.samples_by_file[file] or 0) + count
		end
	end
end

---Adds one bucket to another
---@param into profiler_bucket
---@param bucket profiler_bucket
local function merge_bucket(into, bucket)
	into.frame_count = into.frame_count + bucket.frame_count
	into.busy_ticks = into.busy_ticks + bucket.busy_ticks
	into.wait_ticks = into.wait_ticks + bucket.wait_ticks
	into.entities_spawned = into.entities_spawned + bucket.entities_spawned
	into.spike_count = into.spike_count + bucket.spike_count
	into.stretch_count = into.stretch_count + bucket.stretch_count
	for key, value in pairs(bucket.category_ticks) do
		into.category_ticks[key] = into.category_ticks[key] + value
	end
	merge_item_stats(into, bucket)
	for name, material in pairs(bucket.material_stats) do
		sessions.add_material(into, name, material.cells, material.ticks)
	end
	merge_entity_samples(into, bucket)
end

---A copy of a bucket, which later frames leave alone
---@param bucket profiler_bucket
---@return profiler_bucket
function queries.copy_bucket(bucket)
	local copy = sessions.new_bucket(bucket.first_frame)
	merge_bucket(copy, bucket)
	copy.last_frame = bucket.last_frame
	return copy
end

---Everything recorded over a stretch of frames: one timeline behind every table
---@param history profiler_session|profiler_frozen_view
---@param span_frames integer? frames ending at the newest one, nil for the whole session
---@return profiler_bucket
function queries.span_totals(history, span_frames)
	if not span_frames then return history.lifetime_bucket end
	local oldest_frame = history.frame_count - span_frames + 1
	local merged = sessions.new_bucket(oldest_frame)
	---Merges a bucket that falls inside the span, whole blocks only
	---@param bucket profiler_bucket
	local function merge_if_inside(bucket)
		if bucket.frame_count > 0 and bucket.last_frame >= oldest_frame then merge_bucket(merged, bucket) end
	end
	merge_if_inside(history.open_bucket)
	for index = 1, math.min(history.closed_bucket_count, sessions.BUCKET_COUNT) do
		merge_if_inside(history.closed_buckets[index])
	end
	return merged
end

---Timestamp ticks per sample, measured over every system but LuaSystem. LuaSystem's own time leaves out its
---scripts while its samples include them, so it gets its time from this rate
---@param totals profiler_bucket
---@return number
local function ticks_per_sample(totals)
	local measured, sampled = 0, 0
	for system, entry in pairs(totals.entity_samples) do
		local stat = totals.item_stats[system]
		if stat and system ~= "LuaSystem" then
			measured, sampled = measured + stat.ticks, sampled + entry.samples
		end
	end
	return sampled > 0 and measured / sampled or 0
end

---Engine time by entity file: each system's measured time, split by where its samples landed
---@param session profiler_session
---@param totals profiler_bucket
---@return profiler_entity_rows
function queries.entity_rows(session, totals)
	local frames = math.max(totals.frame_count, 1)
	local rate = ticks_per_sample(totals)
	local rows = { systems = {}, files = {}, samples = 0 }
	local file_rows = {}
	for system, entry in pairs(totals.entity_samples) do
		local stat = totals.item_stats[system]
		local ticks = (stat and system ~= "LuaSystem") and stat.ticks or entry.samples * rate
		local system_ms = ticks / session.ticks_per_ms / frames
		local system_row = { name = system, ms_per_frame = system_ms, samples = entry.samples, files = {} }
		rows.systems[system] = system_row
		rows.samples = rows.samples + entry.samples
		for file, count in pairs(entry.samples_by_file) do
			local file_ms = system_ms * count / entry.samples
			system_row.files[#system_row.files + 1] = { file = file, ms_per_frame = file_ms, samples = count }
			local file_row = file_rows[file]
			if not file_row then
				local no_real_file = file == samplers.NO_ENTITY or file == samplers.GONE_ENTITY or file == samplers.RUNTIME_ENTITY
				file_row = { file = file, owner = no_real_file and "unknown" or census.file_owner(file), ms_per_frame = 0, samples = 0, systems = {} }
				file_rows[file] = file_row
				rows.files[#rows.files + 1] = file_row
			end
			file_row.ms_per_frame, file_row.samples = file_row.ms_per_frame + file_ms, file_row.samples + count
			file_row.systems[#file_row.systems + 1] = { name = system, ms_per_frame = file_ms, samples = count }
		end
		table.sort(system_row.files, by_ms_per_frame)
	end
	table.sort(rows.files, by_ms_per_frame)
	-- It belongs to no file, and ranking it with them would only hide them.
	rows.system_wide = file_rows[samplers.NO_ENTITY]
	for index, row in ipairs(rows.files) do
		if row.file == samplers.NO_ENTITY then
			table.remove(rows.files, index)
			break
		end
	end
	return rows
end

---What most often started a compile or a new Lua state, over the whole session
---@param session profiler_session
---@param key string a breakdown key: "compile: path" or "(lua state setup)"
---@return string? caller
---@return number share 0 to 1
function queries.main_caller(session, key)
	local callers = session.callers_by_item[key]
	if not callers then return nil, 0 end
	local best, best_ticks, total = nil, 0, 0
	for caller, ticks in pairs(callers) do
		total = total + ticks
		if ticks > best_ticks then
			best, best_ticks = caller, ticks
		end
	end
	return best, total > 0 and best_ticks / total or 0
end

---Whether the entity sampler is running
---@param session profiler_session
---@return boolean
function queries.sampler_active(session)
	return session.block.control.sampler_enabled ~= 0
end

---Whether this build has material data
---@param session profiler_session
---@return boolean
function queries.has_cell_hooks(session)
	return session.block.control.cell_hooks_installed ~= 0
end

---Who takes more time in the session's slow frames than in its normal ones, most extra time first
---@param session profiler_session
---@return profiler_slow_row[]
function queries.slow_rows(session)
	local slow, normal = session.slow_frames, session.normal_frames
	local rows = {}
	for owner, ticks in pairs(slow.owner_ticks) do
		local slow_ms = ticks / session.ticks_per_ms / math.max(slow.frame_count, 1)
		local normal_ms = (normal.owner_ticks[owner] or 0) / session.ticks_per_ms / math.max(normal.frame_count, 1)
		rows[#rows + 1] = { owner = owner, slow_ms = slow_ms, normal_ms = normal_ms, extra_ms = slow_ms - normal_ms }
	end
	table.sort(rows, function(left, right)
		return left.extra_ms > right.extra_ms
	end)
	return rows
end

---Which mod's material file last defined each material
---@return table<string, string>
local function load_material_owners()
	local owners = {}
	if not ModMaterialFilesGet or not ModTextFileGetContent then return owners end
	for _, file in ipairs(ModMaterialFilesGet() or {}) do
		local succeeded, content = pcall(ModTextFileGetContent, file)
		if succeeded and content then
			-- Not file_owner: a mod patching data/materials.xml did not define every material in it.
			local owner = file:match("^mods/([^/]+)/") or census.data_file_shipper(file) or "vanilla"
			for tag in content:gmatch("<CellData[^>]*>") do
				local name = tag:match('%sname%s*=%s*"([^"]+)"')
				if name then owners[name] = owner end
			end
		end
	end
	return owners
end

---Materials of a stretch of frames, largest first. Empty if the cell hooks were not found
---@param session profiler_session
---@param totals profiler_bucket
---@return profiler_material_row[]
function queries.material_rows(session, totals)
	local owners = session.material_owners or load_material_owners()
	session.material_owners = owners
	local frames = math.max(totals.frame_count, 1)
	local rows = {}
	for name, stats in pairs(totals.material_stats) do
		rows[#rows + 1] = {
			name = name,
			owner = owners[name] or "unknown",
			cells_per_frame = stats.cells / frames,
			ms_per_frame = stats.ticks / session.ticks_per_ms / frames,
		}
	end
	table.sort(rows, by_ms_per_frame)
	return rows
end

---Threads using CPU, busiest first
---@param session profiler_session
---@return profiler_thread_row[]
function queries.thread_rows(session)
	local rows = {}
	for thread_id, thread in pairs(session.cpu_threads) do
		if thread.percent >= 0.5 then
			rows[#rows + 1] = {
				thread_id = thread_id,
				percent = thread.percent,
				is_game = thread_id == session.main_thread_id,
				is_cell_loop = session.cell_loop_thread_reads[thread_id] ~= nil,
			}
		end
	end
	table.sort(rows, function(left, right)
		return left.percent > right.percent
	end)
	return rows
end

---A file's text as lines, read once
---@param session profiler_session
---@param path string
---@return string[]
local function lines_of_file(session, path)
	local lines = session.file_lines[path]
	if lines then return lines end
	lines = {}
	local succeeded, content = pcall(function()
		return ModTextFileGetContent and ModTextFileGetContent(path)
	end)
	if succeeded and content then
		for text in (content .. "\n"):gmatch("(.-)\r?\n") do
			lines[#lines + 1] = text
		end
	end
	session.file_lines[path] = lines
	return lines
end

---Name of the function starting at a line, from the file's own text. Only for display
---@param session profiler_session
---@param path string
---@param line integer
---@return string
function queries.function_label(session, path, line)
	local key = path .. ":" .. line
	local label = session.function_labels[key]
	if label then return label end
	local text = lines_of_file(session, path)[line] or ""
	local name = text:match("function%s+([%w_%.:]+)") or text:match("([%w_%.]+)%s*=%s*function")
	label = name and (name .. "()") or "function"
	session.function_labels[key] = label
	return label
end

---Items of a frame, largest first
---@param session profiler_session
---@param frame profiler_frame
---@param limit integer
---@return profiler_frame_item[]
function queries.top_items(session, frame, limit)
	local list = {}
	for key, ticks in pairs(frame.item_ticks or {}) do
		list[#list + 1] = { key = key, milliseconds = ticks / session.ticks_per_ms }
	end
	table.sort(list, function(left, right)
		return left.milliseconds > right.milliseconds
	end)
	for index = #list, limit + 1, -1 do
		list[index] = nil
	end
	return list
end

return queries
