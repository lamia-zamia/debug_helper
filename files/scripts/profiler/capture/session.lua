local ffi = require("ffi")
local hook_block = dofile_once("mods/debug_helper/files/scripts/profiler/native/hook_block.lua") ---@type profiler_hook_block_module
---@alias profiler_category_key "world"|"post"|"update"|"systems"|"scripts"|"compile"|"draw"|"swap"|"own"|"other"

---@class profiler_category
---@field key profiler_category_key
---@field label string
---@field red number
---@field green number
---@field blue number

---@class profiler_category_ticks
---@field world number update before the first system
---@field post number update after the systems
---@field update number update when no system ran
---@field systems number
---@field scripts number
---@field compile number
---@field draw number
---@field swap number
---@field own number the profiler itself
---@field other number busy time nothing accounts for

---@class profiler_frame: profiler_category_ticks
---@field item_ticks table<string, number> breakdown; nil once the frame is older than ITEM_HISTORY
---@field material_ticks table<string, number> nil once the frame is older than ITEM_HISTORY
---@field first_event number
---@field last_event number
---@field frame_ticks number
---@field busy_ticks number frame minus SDL_Delay
---@field wait_ticks number
---@field end_timestamp number
---@field top_item string?
---@field top_item_ticks number
---@field lua_pcalls integer
---@field entities_spawned integer
---@field update_ran boolean
---@field seen_system boolean
---@field material_cpu_ticks number
---@field ticks_before_first_system number
---@field swap_buffers_calls integer
---@field entity_count integer
---@field memory_mb number

---@class profiler_totals: profiler_category_ticks
---@field frame_ticks number
---@field busy_ticks number
---@field wait_ticks number

---@class profiler_item_stats
---@field ticks number
---@field calls integer
---@field worst_ticks number

---@class profiler_material_stats
---@field cells number
---@field ticks number

---@class profiler_entity_samples
---@field samples integer
---@field samples_by_file table<string, integer>

---Totals over a stretch of frames. The window and every table read these
---@class profiler_bucket
---@field first_frame integer
---@field last_frame integer
---@field frame_count integer
---@field busy_ticks number
---@field wait_ticks number
---@field entities_spawned integer
---@field spike_count integer
---@field stretch_count integer
---@field category_ticks table<profiler_category_key, number>
---@field item_stats table<string, profiler_item_stats>
---@field material_stats table<string, profiler_material_stats>
---@field entity_samples table<string, profiler_entity_samples> by system name

---@class profiler_ranked_ticks
---@field key string
---@field ticks number

---@class profiler_spike
---@field frame profiler_frame
---@field frame_number integer
---@field top_items profiler_ranked_ticks[]
---@field top_materials profiler_ranked_ticks[]
---@field owners profiler_ranked_ticks[] largest first

---@class profiler_owner_group
---@field frame_count integer
---@field owner_ticks table<string, number>

---@class profiler_pending_trace
---@field busy_ticks number
---@field frame_number integer
---@field due_frame integer
---@field due_event number
---@field frame profiler_frame
---@field owners profiler_ranked_ticks[]

---@class profiler_trace_slot
---@field busy_ticks number
---@field frame_number integer
---@field file string

---@class profiler_last_trace
---@field frame_number integer
---@field busy_ticks number

---One thread's hooked calls still open. Parallel arrays: a stack gets millions of writes
---@class profiler_call_stack
---@field depth integer
---@field hook_ids integer[]
---@field start_times number[]
---@field child_ticks number[]
---@field paths string[]
---@field lines integer[]
---@field stack_slots integer[]

---@class profiler_lua_thread
---@field lua_pcalls integer
---@field events integer

---@class profiler_own_cost
---@field total_ticks number
---@field worst_ticks number

---@class profiler_call_stats: profiler_own_cost
---@field calls integer
---@field self_ticks number

---@class profiler_script_label
---@field key string
---@field category profiler_category_key

---@class profiler_cell_baseline
---@field count integer
---@field ticks integer
---@field samples integer
---@field ticks_per_sample number

---@class profiler_cpu_thread
---@field handle ffi.cdata*
---@field cpu_seconds number?
---@field percent number

---@class profiler_session
---@field block profiler_hook_block
---@field event_cursor number
---@field sample_cursor number
---@field samples_read integer
---@field samples_lost integer
---@field events_dropped integer
---@field events_unmatched integer
---@field hook_names table<integer, string>
---@field stacks_by_thread table<integer, profiler_call_stack>
---@field lua_threads table<integer, profiler_lua_thread>
---@field script_stats table<string, profiler_call_stats>
---@field compile_stats table<string, profiler_call_stats>
---@field hook_stats table<integer, profiler_call_stats>
---@field script_labels table<string, table<integer, profiler_script_label>>
---@field compile_labels table<string, string>
---@field owner_by_item table<string, string>
---@field callers_by_item table<string, table<string, number>>
---@field frames profiler_frame[] ring of FRAME_HISTORY
---@field frame_count integer
---@field current_frame profiler_frame
---@field last_frame_end number 0 until the first frame ends
---@field totals profiler_totals
---@field worst_frame_ticks number
---@field worst_busy_ticks number
---@field most_lua_pcalls integer
---@field spikes profiler_spike[] worst first
---@field spike_count integer
---@field last_slow_frame integer?
---@field slow_frames profiler_owner_group
---@field normal_frames profiler_owner_group
---@field pending_trace profiler_pending_trace?
---@field last_trace profiler_last_trace?
---@field trace_slots profiler_trace_slot[]
---@field tick_count integer
---@field own_ticks_total number
---@field own_ticks_worst number
---@field own_costs table<string, profiler_own_cost>
---@field wall_clock_frequency number
---@field wall_clock_start number
---@field timestamp_start number
---@field ticks_per_ms number 0 until calibrated
---@field entity_count integer
---@field memory_mb number
---@field highest_entity_id integer?
---@field entity_files_by_id table<entity_id, string>
---@field entity_files_cached integer
---@field frames_over_call_limit integer
---@field cell_baselines table<integer, profiler_cell_baseline>
---@field active_cell_slots integer[]
---@field material_names table<integer, string>
---@field material_owners table<string, string>?
---@field cell_loop_thread_reads table<integer, integer>
---@field open_bucket profiler_bucket
---@field lifetime_bucket profiler_bucket
---@field closed_buckets profiler_bucket[] ring of BUCKET_COUNT
---@field closed_bucket_count integer
---@field cpu_threads table<integer, profiler_cpu_thread>
---@field cpu_sample_wall_clock number?
---@field function_labels table<string, string>
---@field file_lines table<string, string[]>
---@field main_thread_id integer 0 until the first tick
---@field census_failed boolean?
---@field last_swap_buffers_calls integer?

---@class profiler_sessions_module
---@field CATEGORIES profiler_category[] bar order, bottom to top. SDL_Delay is idle time, which is why it has no bar
local sessions = {}

sessions.FRAME_HISTORY = 18000
sessions.BUCKET_FRAMES = 60 -- tables merge these and not every frame, to keep 5 minutes cheap
sessions.BUCKET_COUNT = sessions.FRAME_HISTORY / sessions.BUCKET_FRAMES
sessions.NOT_HOOKED_ITEM = "(not hooked: input, engine loop, other threads' waits)"

sessions.CATEGORIES = {
	{ key = "world", label = "world", red = 0.30, green = 0.55, blue = 0.95 },
	{ key = "post", label = "post", red = 0.45, green = 0.75, blue = 0.95 },
	{ key = "update", label = "update", red = 0.60, green = 0.60, blue = 0.85 },
	{ key = "systems", label = "systems", red = 0.95, green = 0.60, blue = 0.20 },
	{ key = "scripts", label = "lua", red = 0.95, green = 0.25, blue = 0.25 },
	{ key = "compile", label = "compile", red = 0.80, green = 0.30, blue = 0.90 },
	{ key = "draw", label = "draw", red = 0.25, green = 0.80, blue = 0.35 },
	{ key = "swap", label = "swap", red = 0.70, green = 0.90, blue = 0.40 },
	{ key = "own", label = "profiler", red = 0.75, green = 0.75, blue = 0.75 },
	{ key = "other", label = "other", red = 0.35, green = 0.35, blue = 0.35 },
}

---An empty frame starting at this event
---@param first_event number
---@return profiler_frame
function sessions.new_frame(first_event)
	return {
		item_ticks = {},
		material_ticks = {},
		first_event = first_event,
		last_event = first_event,
		world = 0,
		post = 0,
		update = 0,
		systems = 0,
		scripts = 0,
		compile = 0,
		draw = 0,
		swap = 0,
		own = 0,
		other = 0,
		frame_ticks = 0,
		busy_ticks = 0,
		wait_ticks = 0,
		end_timestamp = 0,
		top_item_ticks = 0,
		lua_pcalls = 0,
		entities_spawned = 0,
		update_ran = false,
		seen_system = false,
		material_cpu_ticks = 0,
		ticks_before_first_system = 0,
		swap_buffers_calls = 0,
		entity_count = 0,
		memory_mb = 0,
	}
end

---An empty bucket starting at this frame
---@param first_frame integer
---@return profiler_bucket
function sessions.new_bucket(first_frame)
	local category_ticks = {}
	for _, category in ipairs(sessions.CATEGORIES) do
		category_ticks[category.key] = 0
	end
	return {
		first_frame = first_frame,
		last_frame = first_frame - 1,
		frame_count = 0,
		busy_ticks = 0,
		wait_ticks = 0,
		entities_spawned = 0,
		spike_count = 0,
		stretch_count = 0,
		category_ticks = category_ticks,
		item_stats = {},
		material_stats = {},
		entity_samples = {},
	}
end

---A session reading a block from where its writers are now
---@param block profiler_hook_block
---@return profiler_session
function sessions.new(block)
	local frequency = ffi.new("int64_t[1]")
	ffi.C.QueryPerformanceFrequency(frequency)
	local hook_names = {}
	for index = 0, block.control.hook_count - 1 do
		hook_names[block.hooks[index].id] = ffi.string(block.hooks[index].name)
	end
	local event_cursor = block.control.event_write
	local totals = { frame_ticks = 0, busy_ticks = 0, wait_ticks = 0 }
	for _, category in ipairs(sessions.CATEGORIES) do
		totals[category.key] = 0
	end
	return {
		block = block,
		event_cursor = event_cursor,
		sample_cursor = block.control.sample_write,
		samples_read = 0,
		samples_lost = 0,
		events_dropped = 0,
		events_unmatched = 0,
		hook_names = hook_names,
		stacks_by_thread = {},
		lua_threads = {},
		script_stats = {},
		compile_stats = {},
		hook_stats = {},
		script_labels = {},
		compile_labels = {},
		owner_by_item = {},
		callers_by_item = {},
		frames = {},
		frame_count = 0,
		current_frame = sessions.new_frame(event_cursor),
		last_frame_end = 0,
		totals = totals,
		worst_frame_ticks = 0,
		worst_busy_ticks = 0,
		most_lua_pcalls = 0,
		spikes = {},
		spike_count = 0,
		slow_frames = { frame_count = 0, owner_ticks = {} },
		normal_frames = { frame_count = 0, owner_ticks = {} },
		trace_slots = {},
		tick_count = 0,
		own_ticks_total = 0,
		own_ticks_worst = 0,
		own_costs = {},
		wall_clock_frequency = tonumber(frequency[0]) or 0,
		wall_clock_start = hook_block.read_wall_clock(),
		timestamp_start = block.read_timestamp(),
		ticks_per_ms = 0,
		entity_count = 0,
		memory_mb = 0,
		entity_files_by_id = {},
		entity_files_cached = 0,
		frames_over_call_limit = 0,
		cell_baselines = {},
		active_cell_slots = {},
		material_names = {},
		cell_loop_thread_reads = {},
		open_bucket = sessions.new_bucket(1),
		lifetime_bucket = sessions.new_bucket(1),
		closed_buckets = {},
		closed_bucket_count = 0,
		cpu_threads = {},
		function_labels = {},
		file_lines = {},
		main_thread_id = 0,
	}
end

---A finished frame, or nil if it left the history
---@param session profiler_session
---@param frame_number integer
---@return profiler_frame?
function sessions.frame_at(session, frame_number)
	if frame_number < 1 or frame_number > session.frame_count or frame_number <= session.frame_count - sessions.FRAME_HISTORY then return nil end
	return session.frames[(frame_number - 1) % sessions.FRAME_HISTORY + 1]
end

---Adds to a material's totals
---@param bucket profiler_bucket
---@param name string
---@param cells number
---@param ticks number
function sessions.add_material(bucket, name, cells, ticks)
	local stats = bucket.material_stats[name]
	if not stats then
		stats = { cells = 0, ticks = 0 }
		bucket.material_stats[name] = stats
	end
	stats.cells, stats.ticks = stats.cells + cells, stats.ticks + ticks
end

---Adds to the profiler's cost of itself, listed separately in the report
---@param session profiler_session
---@param name string
---@param ticks number
function sessions.add_own_cost(session, name, ticks)
	local cost = session.own_costs[name]
	if not cost then
		cost = { total_ticks = 0, worst_ticks = 0 }
		session.own_costs[name] = cost
	end
	cost.total_ticks = cost.total_ticks + ticks
	if ticks > cost.worst_ticks then cost.worst_ticks = ticks end
end

return sessions
