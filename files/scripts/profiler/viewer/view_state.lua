-- What the window, the overlay and the tabs share: the settings on screen, cached rows, and the frame usage they all read.
-- Needs NoitaDearImGui for drawing only. Hooks, report and exports work without it.

local sessions = dofile_once("mods/debug_helper/files/scripts/profiler/capture/session.lua") ---@type profiler_sessions_module
local queries = dofile_once("mods/debug_helper/files/scripts/profiler/capture/queries.lua") ---@type profiler_queries_module
local WINDOW_SETTING = "debug_helper.profiler_overlay"
local OVERLAY_SETTING = "debug_helper.profiler_hud"
local LUA_FUNCTIONS_SETTING = "debug_helper.PROFILER_LUA_FUNCTIONS"

---@class profiler_span
---@field label string
---@field frames_per_column integer
---@field all boolean? makes the tables cover the whole session

---@class profiler_usage_row
---@field owner string
---@field kind "lua"|"compile"|"lua state setup"|"system"|"phase"|"other"
---@field ms_per_frame number
---@field busy_percent number
---@field worst_ms number
---@field key string
---@field calls_per_frame number

---@class profiler_usage
---@field rows profiler_usage_row[]
---@field totals profiler_bucket
---@field busy_ms number
---@field own_ms number

---What the view reads from a session, as it was at the freeze, because the session goes on underneath it
---@class profiler_frozen_view
---@field frame_count integer
---@field last_frame_end number
---@field entity_count integer
---@field memory_mb number
---@field spikes profiler_spike[]
---@field lifetime_bucket profiler_bucket
---@field open_bucket profiler_bucket
---@field closed_buckets profiler_bucket[]
---@field closed_bucket_count integer

---@class profiler_view_state
---@field imgui ImGui only read after viewer.draw has checked that it loaded
---@field span_index integer
---@field y_scale_index integer
---@field window_opacity number
---@field overlay_alpha number
---@field frozen profiler_frozen_view?
---@field selected_spike_frame integer?
---@field tab_to_open string?
---@field item_filter string?
---@field refreshed_at table<string, integer>
---@field cached table<string, any>
---@field view_key string?
---@field SPANS profiler_span[]
local view = {
	span_index = 1,
	y_scale_index = 1,
	window_opacity = 0.75,
	overlay_alpha = 0.7,
	refreshed_at = {},
	cached = {},
}

view.GRAPH_COLUMNS = 300
view.BUDGET_MS = 16.67
view.SPANS = {
	{ label = "5s", frames_per_column = 1 },
	{ label = "20s", frames_per_column = 4 },
	{ label = "60s", frames_per_column = 12 },
	{ label = "5m", frames_per_column = 60 },
	{ label = "All", frames_per_column = 60, all = true },
}

if load_imgui then
	local succeeded, imgui = pcall(load_imgui, { version = "1.24.0", mod = "Debug Helper" })
	if succeeded then view.imgui = imgui end
end

---Whether the main window is on
---@return boolean
function view:is_window_open()
	return ModSettingGet(WINDOW_SETTING) == true
end

---Whether the overlay is on
---@return boolean
function view:is_overlay_open()
	return ModSettingGet(OVERLAY_SETTING) == true
end

---Shows or hides the overlay
function view:toggle_overlay()
	ModSettingSet(OVERLAY_SETTING, not self:is_overlay_open())
end

---Whether each Lua function is timed
---@return boolean
function view:is_timing_lua_functions()
	return ModSettingGet(LUA_FUNCTIONS_SETTING) == true
end

---Turns timing of each Lua function on or off. Closing the settings menu copies the next value over the current one
---@param enabled boolean
function view:set_timing_lua_functions(enabled)
	ModSettingSet(LUA_FUNCTIONS_SETTING, enabled)
	ModSettingSetNextValue(LUA_FUNCTIONS_SETTING, enabled, false)
end

---Hides the overlay, for when drawing it fails
function view:close_overlay()
	ModSettingSet(OVERLAY_SETTING, false)
end

---Hides the main window
function view:close_window()
	ModSettingSet(WINDOW_SETTING, false)
end

---Rows rebuilt at most this often, or never while frozen
---@generic Rows
---@param name string
---@param session profiler_session
---@param every_ticks integer
---@param build fun(): Rows
---@return Rows
function view:cached_rows(name, session, every_ticks, build)
	if not self.cached[name] or (not self.frozen and session.tick_count - (self.refreshed_at[name] or -1e9) >= every_ticks) then
		self.cached[name] = build()
		self.refreshed_at[name] = session.tick_count
	end
	return self.cached[name]
end

---Drops cached tables when the span or freeze changes, or they would show a different stretch of frames
function view:sync()
	local key = self.span_index .. ":" .. tostring(self.frozen and self.frozen.frame_count) .. ":" .. tostring(self.item_filter)
	if key ~= self.view_key then
		self.view_key = key
		self.cached = {}
		self.refreshed_at = {}
	end
end

---Stops the view at the current frame, or lets it go again. Closed buckets never change, so they can be shared
---@param session profiler_session
function view:toggle_freeze(session)
	if self.frozen then
		self.frozen = nil
		return
	end
	self.frozen = {
		frame_count = session.frame_count,
		last_frame_end = session.last_frame_end,
		entity_count = session.entity_count,
		memory_mb = session.memory_mb,
		spikes = { unpack(session.spikes) },
		lifetime_bucket = queries.copy_bucket(session.lifetime_bucket),
		open_bucket = queries.copy_bucket(session.open_bucket),
		closed_buckets = { unpack(session.closed_buckets) },
		closed_bucket_count = session.closed_bucket_count,
	}
end

---When the view's newest frame ended, for "ago" times
---@param session profiler_session
---@return number
function view:end_timestamp(session)
	return (self.frozen or session).last_frame_end
end

---The entity count and memory use at the view's newest frame
---@param session profiler_session
---@return integer entity_count
---@return number memory_mb
function view:game_stats(session)
	local source = self.frozen or session
	return source.entity_count, source.memory_mb
end

---The spikes the view shows, worst first
---@param session profiler_session
---@return profiler_spike[]
function view:spikes(session)
	return (self.frozen or session).spikes
end

---Spikes in the whole session, up to the freeze
---@param session profiler_session
---@return integer
function view:session_spike_count(session)
	return (self.frozen or session).lifetime_bucket.spike_count
end

---The frame the view ends at
---@param session profiler_session
---@return integer
function view:newest_frame(session)
	return (self.frozen or session).frame_count
end

---The selected Span, ending at the frozen frame or the newest one. Every table reads this
---@param session profiler_session
---@return profiler_bucket
function view:selected_totals(session)
	local span = self.SPANS[self.span_index]
	return queries.span_totals(self.frozen or session, not span.all and span.frames_per_column * self.GRAPH_COLUMNS or nil)
end

---The selected Span in words
---@return string
function view:span_label()
	local span = self.SPANS[self.span_index]
	local label = span.all and "whole session" or ("last " .. span.label)
	return self.frozen and (label .. " up to the freeze") or label
end

---Which mod, or which part of the engine, a breakdown item belongs to
---@param key string
---@return string owner
---@return "lua"|"compile"|"lua state setup"|"system"|"phase"|"other" kind
function view.describe_item(key)
	local path = key:match("^compile: (.*)$")
	local kind = path and "compile" or "lua"
	path = path or key
	local mod = path:match("^@?mods/([^/]+)/")
	if mod == "debug_helper" then return "this profiler", kind end
	if mod then return mod, kind end
	if path:find("^@?data/") then return "vanilla scripts", kind end
	if key == "(lua state setup)" then return "new Lua states", "lua state setup" end
	if key == sessions.NOT_HOOKED_ITEM then return "engine", "other" end
	if key:find("^update: ") or key == "draw" or key:find("^swap: ") then return "engine", "phase" end
	return "engine", "system"
end

---One row per item over the selected Span
---@param session profiler_session
---@return profiler_usage
local function build_usage(session)
	local totals = view:selected_totals(session)
	local frames = math.max(totals.frame_count, 1)
	local ticks_per_ms = session.ticks_per_ms
	local rows = {}
	for key, stat in pairs(totals.item_stats) do
		local owner, kind = view.describe_item(key)
		rows[#rows + 1] = {
			owner = owner,
			kind = kind,
			ms_per_frame = stat.ticks / ticks_per_ms / frames,
			busy_percent = 100 * stat.ticks / math.max(totals.busy_ticks, 1),
			worst_ms = stat.worst_ticks / ticks_per_ms,
			key = key,
			calls_per_frame = stat.calls / frames,
		}
	end
	rows[#rows + 1] = {
		owner = "engine",
		kind = "other",
		ms_per_frame = totals.category_ticks.other / ticks_per_ms / frames,
		busy_percent = 100 * totals.category_ticks.other / math.max(totals.busy_ticks, 1),
		worst_ms = 0,
		key = sessions.NOT_HOOKED_ITEM,
		calls_per_frame = 0,
	}
	return {
		rows = rows,
		totals = totals,
		busy_ms = totals.busy_ticks / ticks_per_ms / frames,
		own_ms = totals.category_ticks.own / ticks_per_ms / frames,
	}
end

---Who used the frame over the selected Span, rebuilt every half second
---@param session profiler_session
---@return profiler_usage
function view:usage(session)
	return self:cached_rows("usage", session, 30, function()
		return build_usage(session)
	end)
end

---A spike's largest owners, because one engine phase would outrank a mod's many scripts item by item
---@param spike profiler_spike
---@param ticks_per_ms number
---@return string
function view.spike_cause(spike, ticks_per_ms)
	local parts = {}
	for index, owner in ipairs(spike.owners) do
		if index > 3 then break end
		parts[#parts + 1] = ("%s %.0f ms"):format(owner.key, owner.ticks / ticks_per_ms)
	end
	return #parts > 0 and table.concat(parts, ", ") or "nothing recorded"
end

---The most recent spike kept
---@param session profiler_session
---@return profiler_spike?
function view.latest_spike(session)
	local latest = nil
	for _, spike in ipairs(view:spikes(session)) do
		if not latest or spike.frame_number > latest.frame_number then latest = spike end
	end
	return latest
end

---One line about a spike
---@param session profiler_session
---@param spike profiler_spike
---@return string
function view.last_hitch_text(session, spike)
	return ("Last hitch %.0fs ago, %.0f ms: %s"):format(
		(view:end_timestamp(session) - spike.frame.end_timestamp) / session.ticks_per_ms / 1000,
		spike.frame.busy_ticks / session.ticks_per_ms,
		view.spike_cause(spike, session.ticks_per_ms)
	)
end

return view
