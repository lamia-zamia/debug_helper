local hook_block = dofile_once("mods/debug_helper/files/scripts/profiler/native/hook_block.lua") ---@type profiler_hook_block_module
local sessions = dofile_once("mods/debug_helper/files/scripts/profiler/capture/session.lua") ---@type profiler_sessions_module
local census = dofile_once("mods/debug_helper/files/scripts/profiler/capture/census.lua") ---@type profiler_census_module
local ITEM_HISTORY = 1800 -- frames that keep their full per-item breakdown
local SPIKE_MS = 33.3
local SPIKE_SKIP_FRAMES = 60
local SPIKE_LIST_SIZE = 20
local SPIKE_ITEMS = 12
local SPIKE_MATERIALS = 6
local TRACE_CONTEXT_FRAMES = 60

---@class profiler_frame_history_module
local frame_history = {}

---Who a breakdown item that is not a script belongs to
---@param key string
---@return string
local function engine_owner_of(key)
	if key == "(lua state setup)" then return "new Lua states" end
	if key:find("^update: ") then return "world simulation" end
	if key == "draw" or key:find("^swap: ") then return "rendering" end
	return "engine systems"
end

---Who a breakdown item belongs to. A mod's many small scripts have to add up, or they never compare with the
---engine's few large phases
---@param session profiler_session
---@param key string
---@return string
local function owner_of(session, key)
	local owner = session.owner_by_item[key]
	if owner then return owner end
	owner = census.script_owner(key:match("^compile: (.*)$") or key) or engine_owner_of(key)
	session.owner_by_item[key] = owner
	return owner
end

---One frame's time by owner
---@param session profiler_session
---@param frame profiler_frame
---@return table<string, number>
local function frame_owners(session, frame)
	local owners = { ["not hooked"] = frame.other }
	for key, ticks in pairs(frame.item_ticks) do
		local owner = owner_of(session, key)
		owners[owner] = (owners[owner] or 0) + ticks
	end
	return owners
end

---Adds one frame's owners to the slow or normal totals
---@param group profiler_owner_group
---@param owners table<string, number>
local function add_to_owner_group(group, owners)
	group.frame_count = group.frame_count + 1
	for owner, ticks in pairs(owners) do
		group.owner_ticks[owner] = (group.owner_ticks[owner] or 0) + ticks
	end
end

---Sort order: most ticks first
---@param left profiler_ranked_ticks
---@param right profiler_ranked_ticks
---@return boolean
local function by_ticks(left, right)
	return left.ticks > right.ticks
end

---A key-to-ticks table as a sorted list, cut to a size if one is given
---@param ticks_by_key table<string, number>
---@param limit integer?
---@return profiler_ranked_ticks[]
local function ranked(ticks_by_key, limit)
	local list = {}
	for key, ticks in pairs(ticks_by_key) do
		list[#list + 1] = { key = key, ticks = ticks }
	end
	table.sort(list, by_ticks)
	for index = #list, (limit or #list) + 1, -1 do
		list[index] = nil
	end
	return list
end

---Half of the ring's remaining room goes after the spike, or a busy frame rate overwrites it first
---@param session profiler_session
---@param frame profiler_frame
---@param owners profiler_ranked_ticks[]
local function plan_spike_trace(session, frame, owners)
	local events_used = frame.last_event - frame.first_event
	local room = math.max(0, hook_block.EVENT_COUNT - hook_block.RING_MARGIN - events_used)
	session.pending_trace = {
		busy_ticks = frame.busy_ticks,
		frame_number = session.frame_count,
		due_frame = session.frame_count + TRACE_CONTEXT_FRAMES,
		due_event = frame.last_event + math.floor(room / 2),
		frame = frame,
		owners = owners,
	}
end

---Keeps a frame in the worst-spikes list, and queues a trace for it if it is the worst one waiting
---@param session profiler_session
---@param frame profiler_frame
---@param owner_ticks table<string, number>
local function capture_spike(session, frame, owner_ticks)
	session.spike_count = session.spike_count + 1
	local owners = ranked(owner_ticks)
	local items_with_unhooked = { [sessions.NOT_HOOKED_ITEM] = frame.other }
	for key, ticks in pairs(frame.item_ticks) do
		items_with_unhooked[key] = ticks
	end
	session.open_bucket.spike_count = session.open_bucket.spike_count + 1
	session.lifetime_bucket.spike_count = session.lifetime_bucket.spike_count + 1
	session.spikes[#session.spikes + 1] = {
		frame = frame,
		frame_number = session.frame_count,
		top_items = ranked(items_with_unhooked, SPIKE_ITEMS),
		top_materials = ranked(frame.material_ticks, SPIKE_MATERIALS),
		owners = owners,
	}
	table.sort(session.spikes, function(left, right)
		return left.frame.busy_ticks > right.frame.busy_ticks
	end)
	session.spikes[SPIKE_LIST_SIZE + 1] = nil
	local pending = session.pending_trace
	if not pending or frame.busy_ticks > pending.busy_ticks then plan_spike_trace(session, frame, owners) end
end

---Adds a frame to the session totals and worst values
---@param session profiler_session
---@param frame profiler_frame
local function add_to_totals(session, frame)
	local totals = session.totals
	totals.frame_ticks = totals.frame_ticks + frame.frame_ticks
	totals.busy_ticks = totals.busy_ticks + frame.busy_ticks
	totals.wait_ticks = totals.wait_ticks + frame.wait_ticks
	for _, category in ipairs(sessions.CATEGORIES) do
		totals[category.key] = totals[category.key] + frame[category.key]
	end
	if frame.frame_ticks > session.worst_frame_ticks then session.worst_frame_ticks = frame.frame_ticks end
	if frame.busy_ticks > session.worst_busy_ticks then session.worst_busy_ticks = frame.busy_ticks end
	if frame.lua_pcalls > session.most_lua_pcalls then session.most_lua_pcalls = frame.lua_pcalls end
end

---Adds a frame to a bucket
---@param session profiler_session
---@param bucket profiler_bucket
---@param frame profiler_frame
local function add_to_bucket(session, bucket, frame)
	bucket.frame_count = bucket.frame_count + 1
	bucket.last_frame = session.frame_count
	bucket.busy_ticks = bucket.busy_ticks + frame.busy_ticks
	bucket.wait_ticks = bucket.wait_ticks + frame.wait_ticks
	bucket.entities_spawned = bucket.entities_spawned + frame.entities_spawned
	for _, category in ipairs(sessions.CATEGORIES) do
		bucket.category_ticks[category.key] = bucket.category_ticks[category.key] + frame[category.key]
	end
end

---Counts a frame as slow or normal, and starts a new stretch if the frame before it was not slow
---@param session profiler_session
---@param frame profiler_frame
local function classify_frame(session, frame)
	-- Leaves out the profiler's own time: a trace it writes could otherwise count as a spike and start another trace.
	local calibrated = session.ticks_per_ms > 0
	local is_slow = calibrated
		and frame.update_ran
		and session.frame_count > SPIKE_SKIP_FRAMES
		and (frame.busy_ticks - frame.own) / session.ticks_per_ms >= SPIKE_MS
	local owners = frame_owners(session, frame)
	if is_slow then
		capture_spike(session, frame, owners)
		if session.last_slow_frame ~= session.frame_count - 1 then
			session.open_bucket.stretch_count = session.open_bucket.stretch_count + 1
			session.lifetime_bucket.stretch_count = session.lifetime_bucket.stretch_count + 1
		end
		session.last_slow_frame = session.frame_count
	end
	if calibrated and frame.update_ran then add_to_owner_group(is_slow and session.slow_frames or session.normal_frames, owners) end
end

---Fills in a frame whose length is known and files it everywhere
---@param session profiler_session
---@param frame profiler_frame
---@param timestamp number
local function record_frame(session, frame, timestamp)
	frame.frame_ticks = timestamp - session.last_frame_end
	frame.busy_ticks = frame.frame_ticks - frame.wait_ticks
	frame.end_timestamp = timestamp
	frame.other = math.max(
		0,
		frame.busy_ticks
			- frame.world
			- frame.post
			- frame.update
			- frame.systems
			- frame.scripts
			- frame.compile
			- frame.draw
			- frame.swap
			- frame.own
	)
	frame.entity_count = session.entity_count
	frame.memory_mb = session.memory_mb
	session.frame_count = session.frame_count + 1
	session.frames[(session.frame_count - 1) % sessions.FRAME_HISTORY + 1] = frame
	local aged = sessions.frame_at(session, session.frame_count - ITEM_HISTORY)
	if aged then
		aged.item_ticks, aged.material_ticks = nil, nil
	end
	add_to_totals(session, frame)
	classify_frame(session, frame)
	add_to_bucket(session, session.open_bucket, frame)
	add_to_bucket(session, session.lifetime_bucket, frame)
	if session.open_bucket.frame_count >= sessions.BUCKET_FRAMES then
		session.closed_bucket_count = session.closed_bucket_count + 1
		session.closed_buckets[(session.closed_bucket_count - 1) % sessions.BUCKET_COUNT + 1] = session.open_bucket
		session.open_bucket = sessions.new_bucket(session.frame_count + 1)
	end
end

---Ends the current frame and starts the next one. The very first end only sets the clock
---@param session profiler_session
---@param timestamp number
---@param next_event number the first event of the next frame
function frame_history.finish_frame(session, timestamp, next_event)
	local frame = session.current_frame
	frame.last_event = next_event
	if session.last_frame_end ~= 0 then record_frame(session, frame, timestamp) end
	session.last_frame_end = timestamp
	session.current_frame = sessions.new_frame(next_event)
end

return frame_history
