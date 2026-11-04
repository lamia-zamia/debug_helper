-- The drill-down tabs: Spikes, Entities, Components and All items.

local queries = dofile_once("mods/debug_helper/files/scripts/profiler/capture/queries.lua") ---@type profiler_queries_module
local census = dofile_once("mods/debug_helper/files/scripts/profiler/capture/census.lua") ---@type profiler_census_module
local view = dofile_once("mods/debug_helper/files/scripts/profiler/viewer/view_state.lua") ---@type profiler_view_state
local tables = dofile_once("mods/debug_helper/files/scripts/profiler/viewer/tables.lua") ---@type profiler_tables_module
local CENSUS_SCRIPTS_SHOWN = 25

local SPIKE_TABLE = {
	default_sort = 2,
	columns = {
		{ label = "When", format = "%.0fs ago", weight = 0.6 },
		{ label = "Busy ms", format = "%.1f", weight = 0.6 },
		{ label = "Lua calls", weight = 0.5 },
		{ label = "+Entities", weight = 0.5 },
		{ label = "Trace", text = true, weight = 0.7 },
		{ label = "Mostly", text = true, weight = 4 },
	},
}

-- The flat list behind every filter: one row per thing that used time, all in the same columns.
local ITEM_TABLE = {
	default_sort = 4,
	columns = {
		{ label = "What", text = true, weight = 4 },
		{ label = "Type", text = true, weight = 0.8 },
		{ label = "Belongs to", text = true, weight = 1.2 },
		{ label = "ms/frame", format = "%.3f", weight = 0.7 },
		{ label = "% of busy", format = "%.1f", weight = 0.7 },
		{ label = "Calls/frame", format = "%.1f", weight = 0.7 },
		{ label = "Worst ms", format = "%.2f", weight = 0.7 },
	},
}

local ITEM_FILTERS = {
	{ label = "All", kind = nil },
	{ label = "Lua", kind = "Lua" },
	{ label = "Compile", kind = "Compile" },
	{ label = "Systems", kind = "System" },
	{ label = "Materials", kind = "Material" },
	{ label = "Engine phases", kind = "Phase" },
}

local KIND_LABELS = {
	lua = "Lua",
	compile = "Compile",
	["lua state setup"] = "Lua",
	system = "System",
	phase = "Phase",
	other = "Other",
}

---@class profiler_detail_tabs_module
local detail_tabs = {}

---Rows of the Spikes table
---@param session profiler_session
---@param in_view fun(spike: profiler_spike): boolean
---@return table[]
local function build_spike_rows(session, in_view)
	local trace_files = {}
	for _, slot in ipairs(session.trace_slots) do
		trace_files[slot.frame_number] = slot.file
	end
	local rows = {}
	for _, spike in ipairs(session.spikes) do
		if in_view(spike) then
			rows[#rows + 1] = {
				(session.last_frame_end - spike.frame.end_timestamp) / session.ticks_per_ms / 1000,
				spike.frame.busy_ticks / session.ticks_per_ms,
				spike.frame.lua_pcalls,
				spike.frame.entities_spawned,
				trace_files[spike.frame_number] or "-",
				view.spike_cause(spike, session.ticks_per_ms),
				id = spike.frame_number,
			}
		end
	end
	return rows
end

---The full breakdown of the selected spike
---@param session profiler_session
---@param spike profiler_spike
local function draw_spike_breakdown(session, spike)
	local imgui = view.imgui
	local frame = spike.frame
	local ticks_per_ms = session.ticks_per_ms
	imgui.Text(
		("Frame %d: busy %.2f ms, idle %.2f ms, %d Lua calls, +%d entities"):format(
			spike.frame_number,
			frame.busy_ticks / ticks_per_ms,
			frame.wait_ticks / ticks_per_ms,
			frame.lua_pcalls,
			frame.entities_spawned
		)
	)
	for _, item in ipairs(spike.top_items) do
		local owner, kind = view.describe_item(item.key)
		imgui.Text(("%8.2f ms %5.1f%%  [%s, %s]  %s"):format(item.ticks / ticks_per_ms, 100 * item.ticks / frame.busy_ticks, owner, kind, item.key))
	end
	for _, material in ipairs(spike.top_materials) do
		imgui.Text(("%8.2f ms CPU across threads  [material]  %s"):format(material.ticks / ticks_per_ms, material.key))
	end
end

---Spikes tab
---@param session profiler_session
---@param height number
function detail_tabs.draw_spikes(session, height)
	local imgui = view.imgui
	local span = view.SPANS[view.span_index]
	local newest = view:newest_frame(session)
	local oldest = span.all and 0 or newest - span.frames_per_column * view.GRAPH_COLUMNS + 1
	---Whether a spike falls inside the span
	---@param spike profiler_spike
	---@return boolean
	local function in_view(spike)
		return spike.frame_number >= oldest and spike.frame_number <= newest
	end
	local rows = view:cached_rows("spikes", session, 30, function()
		return build_spike_rows(session, in_view)
	end)
	local totals = view:usage(session).totals
	imgui.Text(
		("%d frames took over 33.3 ms of real work in the %s, in %d stretches. %d in the session. The worst 20 are listed; select one for its breakdown."):format(
			totals.spike_count,
			view:span_label(),
			totals.stretch_count,
			session.spike_count
		)
	)
	local selected = nil
	for _, spike in ipairs(session.spikes) do
		if spike.frame_number == view.selected_spike_frame and in_view(spike) then selected = spike end
	end
	local table_height = selected and height * 0.45 or height - 22
	local clicked = tables.draw_sortable("spikes_table", SPIKE_TABLE, rows, table_height, view.selected_spike_frame or -1)
	if clicked then view.selected_spike_frame = clicked ~= view.selected_spike_frame and clicked or nil end
	if selected then draw_spike_breakdown(session, selected) end
end

---Rows of the All items table, after the filter
---@param session profiler_session
---@return table[]
local function build_item_rows(session)
	local usage = view:usage(session)
	local rows = {}
	local wanted = view.item_filter
	for _, row in ipairs(usage.rows) do
		local kind = KIND_LABELS[row.kind] or row.kind
		if not wanted or wanted == kind then
			local owner = row.owner == "engine" and "Engine" or row.owner
			rows[#rows + 1] = { row.key, kind, owner, row.ms_per_frame, row.busy_percent, row.calls_per_frame, row.worst_ms }
		end
	end
	if queries.has_cell_hooks(session) and (not wanted or wanted == "Material") then
		for _, material in ipairs(queries.material_rows(session, usage.totals)) do
			-- CPU across threads, and a share of the game thread's busy time would mislead.
			rows[#rows + 1] = { material.name, "Material", "defined by " .. material.owner, material.ms_per_frame, 0, material.cells_per_frame, 0 }
		end
	end
	return rows
end

---All items tab
---@param session profiler_session
---@param height number
function detail_tabs.draw_items(session, height)
	local imgui = view.imgui
	imgui.Text("Show:")
	for _, filter in ipairs(ITEM_FILTERS) do
		if filter.kind ~= "Material" or queries.has_cell_hooks(session) then
			imgui.SameLine()
			if imgui.RadioButton(filter.label .. "###" .. filter.label .. "_filter", view.item_filter == filter.kind) then
				view.item_filter = filter.kind
				view.cached.items = nil
			end
		end
	end
	local rows = view:cached_rows("items", session, 30, function()
		return build_item_rows(session)
	end)
	tables.draw_sortable("items_table", ITEM_TABLE, rows, math.max(height - 26, 40))
end

---One component type from the census, with the matching engine system's time
---@param session profiler_session
---@param usage profiler_usage
---@param census_pass profiler_census_pass
---@param kind string
---@param entry profiler_census_component
---@return profiler_tree_item
local function component_row(session, usage, census_pass, kind, entry)
	local frames = math.max(usage.totals.frame_count, 1)
	local stat = usage.totals.item_stats[(kind:gsub("Component$", "System"))]
	local item = {
		label = kind,
		ms_per_frame = stat and stat.ticks / session.ticks_per_ms / frames or 0,
		count = entry.count,
		calls = stat and stat.calls / frames or 0,
		worst_ms = stat and stat.worst_ticks / session.ticks_per_ms or 0,
		detail = ("%d components"):format(entry.count),
		children = {},
	}
	local owners = {}
	for owner, count in pairs(entry.owners) do
		owners[#owners + 1] = { owner = owner, count = count }
	end
	table.sort(owners, function(left, right)
		return left.count > right.count
	end)
	for index, owner in ipairs(owners) do
		item.children[#item.children + 1] = { label = owner.owner, ms_per_frame = -1 - index, detail = ("%d components"):format(owner.count) }
	end
	if kind == "LuaComponent" then
		local scripts = {}
		for path, script in pairs(census_pass.scripts) do
			scripts[#scripts + 1] = { path = path, script = script }
		end
		table.sort(scripts, function(left, right)
			return left.script.copies > right.script.copies
		end)
		for index, entry_script in ipairs(scripts) do
			if index > CENSUS_SCRIPTS_SHOWN then break end
			item.children[#item.children + 1] = {
				label = entry_script.path,
				ms_per_frame = -1 - index,
				detail = ("%d copies, %d every frame"):format(entry_script.script.copies, entry_script.script.every_frame),
			}
		end
	end
	return item
end

---Every component type, most time first
---@param session profiler_session
---@return {items:profiler_tree_item[], entities:integer}
local function build_component_rows(session)
	local usage = view:usage(session)
	local census_pass = census.latest()
	local items = {}
	if not census_pass then return { items = items, entities = 0 } end
	for kind, entry in pairs(census_pass.components) do
		items[#items + 1] = component_row(session, usage, census_pass, kind, entry)
	end
	table.sort(items, function(left, right)
		if left.ms_per_frame ~= right.ms_per_frame then return left.ms_per_frame > right.ms_per_frame end
		if left.count ~= right.count then return left.count > right.count end
		return left.label < right.label
	end)
	return { items = items, entities = census_pass.entities }
end

---Components tab
---@param session profiler_session
---@param height number
function detail_tabs.draw_components(session, height)
	local imgui = view.imgui
	local rows = view:cached_rows("components", session, 30, function()
		return build_component_rows(session)
	end)
	imgui.Text(
		("%s: time is each engine system's. Counts are from the last walk over %d entities. See Entities for time per entity file."):format(
			view:span_label(),
			rows.entities
		)
	)
	if not tables.begin_tree("components", math.max(height - 22, 40)) then return end
	tables.draw_tree_items(rows.items, view:usage(session).busy_ms, "components")
	imgui.EndTable()
end

---Largest first
---@param systems profiler_entity_file_system[]
local function sort_systems(systems)
	table.sort(systems, function(left, right)
		return left.ms_per_frame > right.ms_per_frame
	end)
end

---Engine time per entity file, from the sampler
---@param session profiler_session
---@return {items:profiler_tree_item[], samples:integer}
local function build_entity_rows(session)
	local rows = queries.entity_rows(session, view:usage(session).totals)
	local census_pass = census.latest()
	local items = {}
	for _, file in ipairs(rows.files) do
		local count = census_pass and census_pass.files[file.file]
		local item = {
			label = file.file,
			ms_per_frame = file.ms_per_frame,
			children = {},
			detail = count and ("%s, %d entities, %.0f us each"):format(file.owner, count, 1000 * file.ms_per_frame / count) or file.owner,
		}
		sort_systems(file.systems)
		for _, system in ipairs(file.systems) do
			item.children[#item.children + 1] = {
				label = system.name,
				ms_per_frame = system.ms_per_frame,
				detail = ("%d samples%s"):format(system.samples, system.name == "LuaSystem" and ", includes its scripts" or ""),
			}
		end
		items[#items + 1] = item
	end
	-- Pinned last: it is not an entity file, and ranking it with them would only hide them.
	local system_wide = rows.system_wide
	if system_wide then
		local item = {
			label = system_wide.file,
			ms_per_frame = system_wide.ms_per_frame,
			children = {},
			detail = "work before and after each system's per-entity loop",
		}
		sort_systems(system_wide.systems)
		for _, system in ipairs(system_wide.systems) do
			item.children[#item.children + 1] =
				{ label = system.name, ms_per_frame = system.ms_per_frame, detail = ("%d samples"):format(system.samples) }
		end
		items[#items + 1] = item
	end
	return { items = items, samples = rows.samples }
end

---Entities tab
---@param session profiler_session
---@param height number
function detail_tabs.draw_entities(session, height)
	local imgui = view.imgui
	if not queries.sampler_active(session) then
		imgui.Text("Not available: the updated-entity global was not found in this build.")
		return
	end
	local rows = view:cached_rows("entities", session, 30, function()
		return build_entity_rows(session)
	end)
	imgui.Text(
		("%s: time engine systems spent per entity file, from %d samples of which entity is being updated."):format(view:span_label(), rows.samples)
	)
	if not tables.begin_tree("entities", math.max(height - 22, 40)) then return end
	tables.draw_tree_items(rows.items, view:usage(session).busy_ms, "entities")
	imgui.EndTable()
end

return detail_tabs
