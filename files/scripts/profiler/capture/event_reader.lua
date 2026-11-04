-- Turns the event ring into per-frame time: matches enters with exits on a stack per thread, and credits self time.

local ffi = require("ffi")
local hook_block = dofile_once("mods/debug_helper/files/scripts/profiler/native/hook_block.lua") ---@type profiler_hook_block_module
local frame_history = dofile_once("mods/debug_helper/files/scripts/profiler/capture/frame_history.lua") ---@type profiler_frame_history_module
local EVENT_COUNT = hook_block.EVENT_COUNT
local HOOK_ID = hook_block.HOOK_ID
local ID_PCALL, ID_SWAP, ID_DELAY, ID_LOAD = HOOK_ID.PCALL, HOOK_ID.SWAP, HOOK_ID.DELAY, HOOK_ID.LOAD
local ID_UPDATE, ID_DRAW, ID_FIRST_SYSTEM = HOOK_ID.UPDATE, HOOK_ID.DRAW, HOOK_ID.FIRST_SYSTEM
local ID_GDI_SWAP, ID_FUNCTION = HOOK_ID.GDI_SWAP, HOOK_ID.FUNCTION
local TWO_TO_32 = 4294967296
local LUA_STATE_SETUP = "(lua state setup)"

---@class profiler_event_reader_module
local event_reader = {}

---Adds one finished call
---@generic Key
---@param stats table<Key, profiler_call_stats>
---@param key Key
---@param self_ticks number
---@param total_ticks number
local function add_call_stat(stats, key, self_ticks, total_ticks)
	local stat = stats[key]
	if not stat then
		stat = { calls = 0, self_ticks = 0, total_ticks = 0, worst_ticks = 0 }
		stats[key] = stat
	end
	stat.calls = stat.calls + 1
	stat.self_ticks = stat.self_ticks + self_ticks
	stat.total_ticks = stat.total_ticks + total_ticks
	if total_ticks > stat.worst_ticks then stat.worst_ticks = total_ticks end
end

---The thread's stack, created on its first event
---@param session profiler_session
---@param thread_id integer
---@return profiler_call_stack
local function stack_of(session, thread_id)
	local stack = session.stacks_by_thread[thread_id]
	if not stack then
		stack = { depth = 0, hook_ids = {}, start_times = {}, child_ticks = {}, paths = {}, lines = {}, stack_slots = {} }
		session.stacks_by_thread[thread_id] = stack
		session.lua_threads[thread_id] = { lua_pcalls = 0, events = 0 }
	end
	return stack
end

---Adds one finished call to a bucket's per-item totals
---@param bucket profiler_bucket
---@param key string
---@param ticks number
---@param total_ticks number
local function add_item_stat(bucket, key, ticks, total_ticks)
	local stat = bucket.item_stats[key]
	if not stat then
		stat = { ticks = 0, calls = 0, worst_ticks = 0 }
		bucket.item_stats[key] = stat
	end
	stat.ticks = stat.ticks + ticks
	stat.calls = stat.calls + 1
	if total_ticks > stat.worst_ticks then stat.worst_ticks = total_ticks end
end

---Books time to an item, in its frame and its buckets
---@param session profiler_session
---@param frame profiler_frame
---@param category profiler_category_key
---@param key string
---@param ticks number
---@param total_ticks number
local function credit(session, frame, category, key, ticks, total_ticks)
	add_item_stat(session.open_bucket, key, ticks, total_ticks)
	add_item_stat(session.lifetime_bucket, key, ticks, total_ticks)
	frame[category] = frame[category] + ticks
	local item_ticks = frame.item_ticks
	local value = (item_ticks[key] or 0) + ticks
	item_ticks[key] = value
	if value > frame.top_item_ticks then
		frame.top_item, frame.top_item_ticks = key, value
	end
end

---Display key and category for a script's chunk name
---@param session profiler_session
---@param path string
---@param line integer
---@return profiler_script_label
local function script_label(session, path, line)
	local labels_by_line = session.script_labels[path]
	if not labels_by_line then
		labels_by_line = {}
		session.script_labels[path] = labels_by_line
	end
	local label = labels_by_line[line]
	if not label then
		local category, key = "scripts", path
		if path:find("^@?mods/debug_helper/") then category = "own" end
		-- The game's own dofile and dofile_once, whose source is their code. They load files, mostly for new states.
		if path:find("^__load%a*=") then
			key = LUA_STATE_SETUP
		elseif line > 0 then
			key = path .. ":" .. line
		end
		label = { key = key, category = category }
		labels_by_line[line] = label
	end
	return label
end

---Breakdown key of a compile
---@param session profiler_session
---@param path string
---@return string
local function compile_label(session, path)
	local key = session.compile_labels[path]
	if not key then
		key = "compile: " .. path
		session.compile_labels[path] = key
	end
	return key
end

---Remembers what started a compile, a new Lua state or a game file load: the outermost frame below the update or draw
---@param session profiler_session
---@param stack profiler_call_stack
---@param key string
---@param depth integer frames still on the stack, below the one that ended
---@param ticks number
local function add_caller(session, stack, key, depth, ticks)
	local caller = "the engine, outside any system or script"
	for level = 1, depth do
		local hook_id = stack.hook_ids[level]
		if hook_id == ID_PCALL or hook_id == ID_FUNCTION then
			caller = script_label(session, stack.paths[level], stack.lines[level]).key
			break
		elseif hook_id >= ID_FIRST_SYSTEM then
			caller = session.hook_names[hook_id] or "?"
			break
		end
	end
	local callers = session.callers_by_item[key]
	if not callers then
		callers = {}
		session.callers_by_item[key] = callers
	end
	callers[caller] = (callers[caller] or 0) + ticks
end

---Closes the Lua function on top of the stack
---@param session profiler_session
---@param stack profiler_call_stack
---@param frame profiler_frame
---@param timestamp number
local function pop_function(session, stack, frame, timestamp)
	local depth = stack.depth
	local total_ticks = timestamp - stack.start_times[depth]
	local label = script_label(session, stack.paths[depth], stack.lines[depth])
	add_call_stat(session.script_stats, label.key, total_ticks - stack.child_ticks[depth], total_ticks)
	credit(session, frame, label.category, label.key, total_ticks - stack.child_ticks[depth], total_ticks)
	if label.key == LUA_STATE_SETUP then add_caller(session, stack, label.key, depth - 1, total_ticks) end
	stack.depth = depth - 1
	if depth > 1 then stack.child_ticks[depth - 1] = stack.child_ticks[depth - 1] + total_ticks end
end

---Closes Lua functions at or above a stack slot. A frame still here at such a slot has ended without a return
---event, through a tail call or an error
---@param session profiler_session
---@param stack profiler_call_stack
---@param frame profiler_frame
---@param timestamp number
---@param slot integer
local function pop_functions_from(session, stack, frame, timestamp, slot)
	while stack.depth > 0 and stack.hook_ids[stack.depth] == ID_FUNCTION and stack.stack_slots[stack.depth] >= slot do
		pop_function(session, stack, frame, timestamp)
	end
end

---Opens a Lua function on the stack
---@param session profiler_session
---@param stack profiler_call_stack
---@param frame profiler_frame
---@param event profiler_event
---@param timestamp number
local function on_function_enter(session, stack, frame, event, timestamp)
	local slot = event.stack_slot
	pop_functions_from(session, stack, frame, timestamp, slot)
	local path, line = ffi.string(event.path), event.line
	local depth = stack.depth
	-- The function lua_pcall started is the same row as the lua_pcall.
	if depth > 0 and stack.hook_ids[depth] == ID_PCALL and stack.paths[depth] == path and stack.lines[depth] == line then return end
	depth = depth + 1
	stack.depth = depth
	stack.hook_ids[depth], stack.start_times[depth], stack.child_ticks[depth] = ID_FUNCTION, timestamp, 0
	stack.paths[depth], stack.lines[depth], stack.stack_slots[depth] = path, line, slot
end

---A vararg function's frame moves after its call event, and then its return names a higher slot than its call.
---Whatever is on top after dropping frames above the slot is the one returning
---@param session profiler_session
---@param stack profiler_call_stack
---@param frame profiler_frame
---@param event profiler_event
---@param timestamp number
local function on_function_exit(session, stack, frame, event, timestamp)
	pop_functions_from(session, stack, frame, timestamp, event.stack_slot + 1)
	if stack.depth > 0 and stack.hook_ids[stack.depth] == ID_FUNCTION then pop_function(session, stack, frame, timestamp) end
end

---Opens a hooked call on the stack
---@param session profiler_session
---@param stack profiler_call_stack
---@param frame profiler_frame
---@param hook_id integer
---@param event profiler_event
---@param timestamp number
---@param is_main boolean
local function on_enter(session, stack, frame, hook_id, event, timestamp, is_main)
	if hook_id == ID_FUNCTION then
		on_function_enter(session, stack, frame, event, timestamp)
		return
	end
	if is_main and hook_id >= ID_FIRST_SYSTEM and hook_id ~= ID_GDI_SWAP and not frame.seen_system then
		frame.seen_system = true
		local parent = stack.depth
		if parent > 0 and stack.hook_ids[parent] == ID_UPDATE then
			frame.ticks_before_first_system = timestamp - stack.start_times[parent] - stack.child_ticks[parent]
		end
	end
	local depth = stack.depth + 1
	stack.depth = depth
	stack.hook_ids[depth], stack.start_times[depth], stack.child_ticks[depth] = hook_id, timestamp, 0
	if hook_id == ID_PCALL or hook_id == ID_LOAD then stack.paths[depth] = ffi.string(event.path) end
	if hook_id == ID_PCALL then
		stack.lines[depth] = event.line
		local thread = session.lua_threads[event.thread_id]
		thread.lua_pcalls = thread.lua_pcalls + 1
		if is_main then frame.lua_pcalls = frame.lua_pcalls + 1 end
	end
end

---SDL_GL_SwapWindow ended, which ends the frame. SwapBuffers runs once per OS window, so a changed count means
---ImGui opened or closed one
---@param session profiler_session
---@param frame profiler_frame
---@param self_ticks number
---@param total_ticks number
---@param timestamp number
---@param event_index number
local function on_swap_exit(session, frame, self_ticks, total_ticks, timestamp, event_index)
	local key = "swap: ImGui and SDL"
	local last_calls = session.last_swap_buffers_calls
	if last_calls and frame.swap_buffers_calls > last_calls then
		key = "swap: ImGui opening a window"
	elseif last_calls and frame.swap_buffers_calls > 0 and frame.swap_buffers_calls < last_calls then
		key = "swap: ImGui closing a window"
	end
	if frame.swap_buffers_calls > 0 then session.last_swap_buffers_calls = frame.swap_buffers_calls end
	credit(session, frame, "swap", key, self_ticks, total_ticks)
	frame_history.finish_frame(session, timestamp, event_index + 1)
end

---Credits a native hook that ended on the game thread
---@param session profiler_session
---@param frame profiler_frame
---@param hook_id integer
---@param self_ticks number
---@param total_ticks number
---@param timestamp number
---@param event_index number
local function on_main_thread_hook_exit(session, frame, hook_id, self_ticks, total_ticks, timestamp, event_index)
	if hook_id == ID_DELAY then
		frame.wait_ticks = frame.wait_ticks + total_ticks
	elseif hook_id == ID_SWAP then
		on_swap_exit(session, frame, self_ticks, total_ticks, timestamp, event_index)
	elseif hook_id == ID_GDI_SWAP then
		frame.swap_buffers_calls = frame.swap_buffers_calls + 1
		credit(session, frame, "swap", "swap: driver and GPU", self_ticks, total_ticks)
	elseif hook_id == ID_UPDATE then
		frame.update_ran = true
		if frame.seen_system then
			local world_ticks = math.min(frame.ticks_before_first_system, self_ticks)
			credit(session, frame, "world", "update: world simulation", world_ticks, world_ticks)
			credit(session, frame, "post", "update: after systems", self_ticks - world_ticks, self_ticks - world_ticks)
		else
			credit(session, frame, "update", "update: engine", self_ticks, self_ticks)
		end
	elseif hook_id == ID_DRAW then
		credit(session, frame, "draw", "draw", self_ticks, total_ticks)
	else
		credit(session, frame, "systems", session.hook_names[hook_id] or "?", self_ticks, total_ticks)
	end
end

---Closes a hooked call and credits its time
---@param session profiler_session
---@param stack profiler_call_stack
---@param frame profiler_frame
---@param hook_id integer
---@param event profiler_event
---@param timestamp number
---@param is_main boolean
---@param event_index number
local function on_exit(session, stack, frame, hook_id, event, timestamp, is_main, event_index)
	if hook_id == ID_FUNCTION then
		on_function_exit(session, stack, frame, event, timestamp)
		return
	end
	pop_functions_from(session, stack, frame, timestamp, -1)
	local depth = stack.depth
	while depth > 0 and stack.hook_ids[depth] ~= hook_id do
		depth = depth - 1
		session.events_unmatched = session.events_unmatched + 1
	end
	if depth == 0 then
		session.events_unmatched = session.events_unmatched + 1
		stack.depth = 0
		return
	end
	local total_ticks = timestamp - stack.start_times[depth]
	local self_ticks = total_ticks - stack.child_ticks[depth]
	local path = stack.paths[depth]
	local line = stack.lines[depth]
	depth = depth - 1
	stack.depth = depth
	if depth > 0 then stack.child_ticks[depth] = stack.child_ticks[depth] + total_ticks end

	if hook_id == ID_PCALL then
		local label = script_label(session, path, line)
		add_call_stat(session.script_stats, label.key, self_ticks, total_ticks)
		if is_main then
			credit(session, frame, label.category, label.key, self_ticks, total_ticks)
			if label.key == LUA_STATE_SETUP then add_caller(session, stack, label.key, depth, total_ticks) end
		end
		return
	end
	add_call_stat(session.hook_stats, hook_id, self_ticks, total_ticks)
	if hook_id == ID_LOAD then
		add_call_stat(session.compile_stats, path, self_ticks, total_ticks)
		if is_main then
			credit(session, frame, "compile", compile_label(session, path), self_ticks, total_ticks)
			add_caller(session, stack, compile_label(session, path), depth, total_ticks)
		end
	elseif is_main then
		on_main_thread_hook_exit(session, frame, hook_id, self_ticks, total_ticks, timestamp, event_index)
	end
end

---Reads every complete event since the last read
---@param session profiler_session
function event_reader.read_events(session)
	local block = session.block
	local write_position = block.control.event_write
	local unread = (write_position - session.event_cursor) % TWO_TO_32
	if unread > EVENT_COUNT then
		session.events_dropped = session.events_dropped + (unread - EVENT_COUNT)
		session.event_cursor = (write_position - EVENT_COUNT) % TWO_TO_32
		for _, stack in pairs(session.stacks_by_thread) do
			stack.depth = 0
		end
	end
	local events = block.events
	local event_index = session.event_cursor
	local main_thread_id = session.main_thread_id
	while event_index ~= write_position do
		local event = events[event_index % EVENT_COUNT]
		if event.sequence ~= (event_index + 1) % TWO_TO_32 then break end
		local kind, thread_id = event.kind, event.thread_id
		local timestamp = event.timestamp_high * TWO_TO_32 + event.timestamp_low
		local stack = stack_of(session, thread_id)
		local hook_id = (kind - kind % 2) / 2
		local thread = session.lua_threads[thread_id]
		thread.events = thread.events + 1
		if kind % 2 == 0 then
			on_enter(session, stack, session.current_frame, hook_id, event, timestamp, thread_id == main_thread_id)
		else
			on_exit(session, stack, session.current_frame, hook_id, event, timestamp, thread_id == main_thread_id, event_index)
		end
		event_index = (event_index + 1) % TWO_TO_32
	end
	session.event_cursor = event_index
end

return event_reader
