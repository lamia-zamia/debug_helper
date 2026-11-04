-- Perfetto traces and the per-frame CSV. They get written within a time budget per frame, or saving one would cause
-- the hitch it records. A trace first copies the event ring, because the game fills it faster than the budget drains it.

local ffi = require("ffi")
local hook_block = dofile_once("mods/debug_helper/files/scripts/profiler/native/hook_block.lua") ---@type profiler_hook_block_module
local sessions = dofile_once("mods/debug_helper/files/scripts/profiler/capture/session.lua") ---@type profiler_sessions_module
local OUTPUT_DIRECTORY = "mods/debug_helper/profiler_output"
local STEP_BUDGET_MS = 2
local BUDGET_CHECK_EVERY = 16
local QUEUE_SIZE = 3 -- each waiting trace holds an 8 MB copy of the ring
local TRACK_SPIKE, TRACK_FRAMES = 1, 2
local TWO_TO_32 = 4294967296
local TRACE_CONTEXT_FRAMES = 60
local TRACE_MIN_GAP_FRAMES = 1800
local TRACE_REPLACE_RATIO = 1.25
local TRACE_SLOT_COUNT = 8

local EVENT_COUNT = hook_block.EVENT_COUNT
local HOOK_ID = hook_block.HOOK_ID

---@class profiler_trace_stack
---@field depth integer
---@field names string[]
---@field stack_slots (integer|false)[] the Lua stack slot, false for anything but a Lua function

---@class profiler_trace_spike
---@field first_timestamp number
---@field last_timestamp number
---@field label string

---@class profiler_trace_job
---@field events profiler_event[] private copy of the ring
---@field event_index number
---@field stop_index number
---@field stacks table<integer, profiler_trace_stack>
---@field first_timestamp number?
---@field last_microseconds number
---@field frame_start_microseconds number?
---@field ticks_per_microsecond number one rate per file: recalibrating between slices would make timestamps jump backwards
---@field spike profiler_trace_spike?

---@class profiler_csv_job
---@field header string
---@field next_frame integer
---@field last_frame integer

---@class profiler_export_job
---@field name string
---@field session profiler_session
---@field file file*?
---@field quiet boolean? leaves the status text alone, for traces nobody asked for
---@field trace profiler_trace_job?
---@field csv profiler_csv_job?

---@class profiler_export_state
---@field queue profiler_export_job[] oldest first
---@field spare_ring_copies profiler_event[][]
---@field escaped_names table<string, string>
---@field last_status string
local state = { queue = {}, spare_ring_copies = {}, escaped_names = {}, last_status = "" }

---@class profiler_file_export_module
local file_export = {}

file_export.OUTPUT_DIRECTORY = OUTPUT_DIRECTORY

---Opens a file in the output folder, creating the folder if needed
---@param name string
---@return file*?
local function open_output(name)
	ffi.C.CreateDirectoryA(OUTPUT_DIRECTORY, nil)
	return io.open(OUTPUT_DIRECTORY .. "/" .. name, "w")
end

---Makes text safe inside a JSON string
---@param text string
---@return string
local function escape_json(text)
	return (text:gsub('[%c"\\]', function(char)
		return char == '"' and '\\"' or char == "\\" and "\\\\" or " "
	end))
end

---Whether another file fits in the queue
---@return boolean
local function can_queue()
	return #state.queue < QUEUE_SIZE
end

---What the last save the player asked for did
---@return string
function file_export.status()
	return state.last_status
end

---Starts a Perfetto / chrome://tracing file from a position in the event ring
---@param session profiler_session
---@param first_event number? ring position, nil for everything still in the ring
---@param name string file name
---@param quiet boolean? leaves the status text alone, for traces nobody asked for
---@param spike profiler_trace_spike? the frame this trace is about
---@return boolean started
function file_export.start_trace(session, first_event, name, quiet, spike)
	if not can_queue() then return false end
	local block = session.block
	local write_position = block.control.event_write
	local oldest = math.max(0, write_position - EVENT_COUNT + hook_block.RING_MARGIN)
	local ring_copy = table.remove(state.spare_ring_copies) or hook_block.new_array("profiler_event", EVENT_COUNT)
	ffi.copy(ring_copy, block.events, EVENT_COUNT * ffi.sizeof("profiler_event"))
	state.queue[#state.queue + 1] = {
		name = name,
		session = session,
		quiet = quiet,
		trace = {
			events = ring_copy,
			event_index = math.max(first_event or oldest, oldest),
			stop_index = write_position,
			stacks = {},
			last_microseconds = 0,
			ticks_per_microsecond = session.ticks_per_ms / 1000,
			spike = spike,
		},
	}
	if not quiet then state.last_status = "writing " .. name end
	return true
end

---Opens a job's file when its turn comes, since a queued trace may reuse the file of the one before it
---@param job profiler_export_job
---@return file*?
local function open_job(job)
	local file = open_output(job.name)
	if not file then return nil end
	job.file = file
	if job.trace then
		file:write('{"displayTimeUnit":"ms","traceEvents":[\n')
		file:write('{"name":"thread_name","ph":"M","pid":1,"tid":', tostring(job.session.main_thread_id), ',"args":{"name":"game thread"}}')
		-- Two extra tracks, listed first: which frame this file is about, and how long each frame took.
		for _, track in ipairs({ { id = TRACK_SPIKE, name = "the spike", sort_index = -2 }, { id = TRACK_FRAMES, name = "frames", sort_index = -1 } }) do
			file:write((',\n{"name":"thread_name","ph":"M","pid":1,"tid":%d,"args":{"name":"%s"}}'):format(track.id, track.name))
			file:write((',\n{"name":"thread_sort_index","ph":"M","pid":1,"tid":%d,"args":{"sort_index":%d}}'):format(track.id, track.sort_index))
		end
	elseif job.csv then
		file:write(job.csv.header, "\n")
	end
	return file
end

---Closes a job's file and takes it off the queue
---@param job profiler_export_job
---@param status string
local function finish_job(job, status)
	if job.file then job.file:close() end
	if job.trace then state.spare_ring_copies[#state.spare_ring_copies + 1] = job.trace.events end
	table.remove(state.queue, 1)
	if not job.quiet then state.last_status = status end
end

---Ends the innermost slice
---@param trace_lines string[]
---@param microseconds number
---@param thread_id integer
local function write_slice_end(trace_lines, microseconds, thread_id)
	trace_lines[#trace_lines + 1] = (',\n{"ph":"E","ts":%.1f,"pid":1,"tid":%d}'):format(microseconds, thread_id)
end

---Function events can lack a return after a tail call or an error, so function slices close by stack slot
---@param trace_lines string[]
---@param stack profiler_trace_stack
---@param from_slot integer
---@param microseconds number
---@param thread_id integer
local function close_functions(trace_lines, stack, from_slot, microseconds, thread_id)
	while stack.depth > 0 and stack.stack_slots[stack.depth] and stack.stack_slots[stack.depth] >= from_slot do
		write_slice_end(trace_lines, microseconds, thread_id)
		stack.depth = stack.depth - 1
	end
end

---Starts a slice
---@param trace_lines string[]
---@param stack profiler_trace_stack
---@param name string
---@param stack_slot integer|false
---@param microseconds number
---@param thread_id integer
local function push_slice(trace_lines, stack, name, stack_slot, microseconds, thread_id)
	local escaped = state.escaped_names[name]
	if not escaped then
		escaped = escape_json(name)
		state.escaped_names[name] = escaped
	end
	trace_lines[#trace_lines + 1] = (',\n{"name":"%s","ph":"B","ts":%.1f,"pid":1,"tid":%d}'):format(escaped, microseconds, thread_id)
	stack.depth = stack.depth + 1
	stack.names[stack.depth], stack.stack_slots[stack.depth] = name, stack_slot
end

---Trace text for a Lua function's call or return
---@param trace_lines string[]
---@param stack profiler_trace_stack
---@param event profiler_event
---@param is_enter boolean
---@param microseconds number
local function write_function_event(trace_lines, stack, event, is_enter, microseconds)
	local thread_id, stack_slot = event.thread_id, event.stack_slot
	if not is_enter then
		close_functions(trace_lines, stack, stack_slot + 1, microseconds, thread_id)
		local top_slot = stack.depth > 0 and stack.stack_slots[stack.depth]
		if top_slot then close_functions(trace_lines, stack, top_slot, microseconds, thread_id) end
		return
	end
	close_functions(trace_lines, stack, stack_slot, microseconds, thread_id)
	local name = ffi.string(event.path)
	if event.line > 0 then name = name .. ":" .. event.line end
	-- The function lua_pcall started is the same slice as the lua_pcall.
	if stack.depth == 0 or stack.stack_slots[stack.depth] or stack.names[stack.depth] ~= name then
		push_slice(trace_lines, stack, name, stack_slot, microseconds, thread_id)
	end
end

---Slice name for a hook's enter event
---@param session profiler_session
---@param hook_id integer
---@param event profiler_event
---@return string
local function hook_slice_name(session, hook_id, event)
	if hook_id == HOOK_ID.PCALL then
		local name = ffi.string(event.path)
		if name:find("^__load%a*=") then return "(lua state setup)" end
		return event.line > 0 and name .. ":" .. event.line or name
	elseif hook_id == HOOK_ID.LOAD then
		return "compile: " .. ffi.string(event.path)
	end
	return session.hook_names[hook_id] or "?"
end

---Ends a hook's slice, plus the frames track's slice if it was the swap
---@param job profiler_export_job
---@param trace profiler_trace_job
---@param trace_lines string[]
---@param stack profiler_trace_stack
---@param hook_id integer
---@param thread_id integer
---@param microseconds number
local function write_hook_exit(job, trace, trace_lines, stack, hook_id, thread_id, microseconds)
	close_functions(trace_lines, stack, -1, microseconds, thread_id)
	if stack.depth > 0 then
		write_slice_end(trace_lines, microseconds, thread_id)
		stack.depth = stack.depth - 1
	end
	if hook_id == HOOK_ID.SWAP and thread_id == job.session.main_thread_id then
		if trace.frame_start_microseconds then
			trace_lines[#trace_lines + 1] = (',\n{"name":"%.1f ms","ph":"X","ts":%.1f,"dur":%.1f,"pid":1,"tid":%d}'):format(
				(microseconds - trace.frame_start_microseconds) / 1000,
				trace.frame_start_microseconds,
				microseconds - trace.frame_start_microseconds,
				TRACK_FRAMES
			)
		end
		trace.frame_start_microseconds = microseconds
	end
end

---Converts one event to trace text
---@param job profiler_export_job
---@param trace profiler_trace_job
---@param trace_lines string[]
---@param event profiler_event
local function write_trace_event(job, trace, trace_lines, event)
	local kind, thread_id = event.kind, event.thread_id
	local timestamp = event.timestamp_high * TWO_TO_32 + event.timestamp_low
	trace.first_timestamp = trace.first_timestamp or timestamp
	local microseconds = (timestamp - trace.first_timestamp) / trace.ticks_per_microsecond
	trace.last_microseconds = microseconds
	local stack = trace.stacks[thread_id]
	if not stack then
		stack = { depth = 0, names = {}, stack_slots = {} }
		trace.stacks[thread_id] = stack
	end
	local hook_id = (kind - kind % 2) / 2
	local is_enter = kind % 2 == 0
	if hook_id == HOOK_ID.FUNCTION then
		write_function_event(trace_lines, stack, event, is_enter, microseconds)
	elseif is_enter then
		close_functions(trace_lines, stack, -1, microseconds, thread_id)
		push_slice(trace_lines, stack, hook_slice_name(job.session, hook_id, event), false, microseconds, thread_id)
	else
		write_hook_exit(job, trace, trace_lines, stack, hook_id, thread_id, microseconds)
	end
end

---Closes what is still open and ends the file
---@param job profiler_export_job
---@param trace profiler_trace_job
---@param file file*
local function finish_trace(job, trace, file)
	for thread_id, stack in pairs(trace.stacks) do
		for _ = 1, stack.depth do
			file:write((',\n{"ph":"E","ts":%.1f,"pid":1,"tid":%d}'):format(trace.last_microseconds, thread_id))
		end
	end
	local spike = trace.spike
	if spike and trace.first_timestamp and spike.first_timestamp >= trace.first_timestamp then
		file:write(
			(',\n{"name":"%s","ph":"X","ts":%.1f,"dur":%.1f,"pid":1,"tid":%d}'):format(
				escape_json(spike.label),
				(spike.first_timestamp - trace.first_timestamp) / trace.ticks_per_microsecond,
				(spike.last_timestamp - spike.first_timestamp) / trace.ticks_per_microsecond,
				TRACK_SPIKE
			)
		)
	end
	file:write("\n]}\n")
	finish_job(job, "saved " .. job.name)
end

---Writes events until the deadline
---@param job profiler_export_job
---@param trace profiler_trace_job
---@param file file*
---@param deadline number timestamp to stop at
local function trace_step(job, trace, file, deadline)
	local read_timestamp = job.session.block.read_timestamp
	local trace_lines = {}
	local event_index, stop_index = trace.event_index, trace.stop_index
	local events_done = 0
	while event_index ~= stop_index do
		events_done = events_done + 1
		if events_done % BUDGET_CHECK_EVERY == 0 and read_timestamp() > deadline then break end
		local event = trace.events[event_index % EVENT_COUNT]
		if event.sequence ~= (event_index + 1) % TWO_TO_32 then
			-- The ring lapped this writer: close what was written.
			stop_index = event_index
			break
		end
		write_trace_event(job, trace, trace_lines, event)
		event_index = (event_index + 1) % TWO_TO_32
	end
	trace.event_index = event_index
	file:write(table.concat(trace_lines))
	if event_index == stop_index then finish_trace(job, trace, file) end
end

---Starts the per-frame CSV of everything still in the history
---@param session profiler_session
---@return boolean started
function file_export.start_csv(session)
	if not can_queue() then return false end
	local columns = { "frame", "frame_ms", "busy_ms", "wait_ms" }
	for _, category in ipairs(sessions.CATEGORIES) do
		columns[#columns + 1] = category.key .. "_ms"
	end
	for _, name in ipairs({ "material_cpu_ms", "lua_pcalls", "spawned", "entities", "memory_mb", "top_item", "top_ms" }) do
		columns[#columns + 1] = name
	end
	state.queue[#state.queue + 1] = {
		name = "frames.csv",
		session = session,
		csv = {
			header = table.concat(columns, ","),
			next_frame = math.max(1, session.frame_count - (sessions.FRAME_HISTORY - 1)),
			last_frame = session.frame_count,
		},
	}
	state.last_status = "writing frames.csv"
	return true
end

---One CSV line
---@param frame_number integer
---@param frame profiler_frame
---@param ticks_per_ms number
---@return string
local function csv_line(frame_number, frame, ticks_per_ms)
	local cells = {
		frame_number,
		("%.3f"):format(frame.frame_ticks / ticks_per_ms),
		("%.3f"):format(frame.busy_ticks / ticks_per_ms),
		("%.3f"):format(frame.wait_ticks / ticks_per_ms),
	}
	for _, category in ipairs(sessions.CATEGORIES) do
		cells[#cells + 1] = ("%.3f"):format(frame[category.key] / ticks_per_ms)
	end
	cells[#cells + 1] = ("%.3f"):format(frame.material_cpu_ticks / ticks_per_ms)
	cells[#cells + 1] = frame.lua_pcalls
	cells[#cells + 1] = frame.entities_spawned
	cells[#cells + 1] = frame.entity_count
	cells[#cells + 1] = ("%.0f"):format(frame.memory_mb)
	cells[#cells + 1] = '"' .. escape_json(frame.top_item or "") .. '"'
	cells[#cells + 1] = ("%.3f"):format(frame.top_item_ticks / ticks_per_ms)
	return table.concat(cells, ",")
end

---Writes lines until the deadline
---@param job profiler_export_job
---@param csv profiler_csv_job
---@param file file*
---@param deadline number timestamp to stop at
local function csv_step(job, csv, file, deadline)
	local session = job.session
	local csv_lines = {}
	local frame_number = csv.next_frame
	local frames_done = 0
	while frame_number <= csv.last_frame do
		frames_done = frames_done + 1
		if frames_done % BUDGET_CHECK_EVERY == 0 and session.block.read_timestamp() > deadline then break end
		local frame = sessions.frame_at(session, frame_number)
		if frame then csv_lines[#csv_lines + 1] = csv_line(frame_number, frame, session.ticks_per_ms) end
		frame_number = frame_number + 1
	end
	csv.next_frame = frame_number
	if #csv_lines > 0 then file:write(table.concat(csv_lines, "\n"), "\n") end
	if frame_number > csv.last_frame then finish_job(job, "saved frames.csv") end
end

---Advances the file in progress. Call once per frame
function file_export.step()
	local job = state.queue[1]
	if not job then return end
	local file = job.file or open_job(job)
	if not file then
		finish_job(job, "cannot write " .. job.name)
		return
	end
	local session = job.session
	local deadline = session.block.read_timestamp() + STEP_BUDGET_MS * session.ticks_per_ms
	if job.trace then
		trace_step(job, job.trace, file, deadline)
	elseif job.csv then
		csv_step(job, job.csv, file, deadline)
	end
end

---Which of the kept traces this one goes into, nil if it is not worth replacing one
---@param slots profiler_trace_slot[]
---@param busy_ticks number
---@return integer?
local function choose_trace_slot(slots, busy_ticks)
	if #slots < TRACE_SLOT_COUNT then return #slots + 1 end
	local smallest = 1
	for index, slot in ipairs(slots) do
		if slot.busy_ticks < slots[smallest].busy_ticks then smallest = index end
	end
	-- In a long slowdown many frames are nearly equal, and replacing a trace for each costs time.
	if slots[smallest].busy_ticks * TRACE_REPLACE_RATIO >= busy_ticks then return nil end
	return smallest
end

---Starts the trace of the worst spike waiting, once enough frames have passed for context after it
---@param session profiler_session
function file_export.start_due_trace(session)
	local pending = session.pending_trace
	if not pending or not can_queue() then return end
	if session.frame_count < pending.due_frame and session.block.control.event_write < pending.due_event then return end
	session.pending_trace = nil
	-- A long slowdown always has a spike due, and writing a trace for each just slows the game further.
	local last = session.last_trace
	if last and session.frame_count - last.frame_number < TRACE_MIN_GAP_FRAMES and pending.busy_ticks < last.busy_ticks * 2 then return end
	local slot = choose_trace_slot(session.trace_slots, pending.busy_ticks)
	if not slot then return end
	local file = "spike_" .. slot .. ".json"
	session.last_trace = { frame_number = session.frame_count, busy_ticks = pending.busy_ticks }
	session.trace_slots[slot] = { busy_ticks = pending.busy_ticks, frame_number = pending.frame_number, file = file }
	local first = sessions.frame_at(session, pending.frame_number - TRACE_CONTEXT_FRAMES) or sessions.frame_at(session, pending.frame_number)
	local parts = {}
	for index, owner in ipairs(pending.owners) do
		if index > 4 then break end
		parts[#parts + 1] = ("%s %.0f ms"):format(owner.key, owner.ticks / session.ticks_per_ms)
	end
	local frame = pending.frame
	file_export.start_trace(session, first and first.first_event or session.event_cursor, file, true, {
		first_timestamp = frame.end_timestamp - frame.frame_ticks,
		last_timestamp = frame.end_timestamp,
		label = ("SPIKE, %.0f ms of work: %s"):format(frame.busy_ticks / session.ticks_per_ms, table.concat(parts, ", ")),
	})
end

return file_export
