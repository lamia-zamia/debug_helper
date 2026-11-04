-- The "What's lagging" and "Mods" tabs: everyone using the frame, each mod beside each part of the engine.

local queries = dofile_once("mods/debug_helper/files/scripts/profiler/capture/queries.lua") ---@type profiler_queries_module
local census = dofile_once("mods/debug_helper/files/scripts/profiler/capture/census.lua") ---@type profiler_census_module
local view = dofile_once("mods/debug_helper/files/scripts/profiler/viewer/view_state.lua") ---@type profiler_view_state
local tables = dofile_once("mods/debug_helper/files/scripts/profiler/viewer/tables.lua") ---@type profiler_tables_module
local CENSUS_CARRIERS_SHOWN = 8
local MATERIALS_SHOWN = 25
local THREADS_SHOWN = 6

-- Where each area's Open button goes in the All items tab.
local AREA_LINKS = {
	system = { label = "Systems", filter = "System" },
	sim = { label = "Materials", filter = "Material", needs_cell_hooks = true },
}

---@class profiler_overview
---@field busy_ms number
---@field areas profiler_tree_item[] largest first
---@field materials profiler_material_row[]
---@field material_ms number
---@field mods profiler_tree_item[]

---@class profiler_mod_rows
---@field by_owner table<string, profiler_tree_item>
---@field list profiler_tree_item[]

---@class profiler_engine_areas
---@field sim profiler_tree_item
---@field system profiler_tree_item
---@field render profiler_tree_item
---@field other profiler_tree_item
---@field own profiler_tree_item

---@class profiler_overview_tab_module
local overview_tab = {}

---Sort order: most time first
---@param left profiler_tree_item
---@param right profiler_tree_item
---@return boolean
local function by_ms_per_frame(left, right)
	return left.ms_per_frame > right.ms_per_frame
end

---A mod's row, added on first use
---@param mods profiler_mod_rows
---@param owner string
---@return profiler_tree_item
local function mod_row(mods, owner)
	local mod = mods.by_owner[owner]
	if not mod then
		mod = { label = owner, key = "mod/" .. owner, ms_per_frame = 0, calls = 0, worst_ms = 0, children = {}, files = {} }
		mods.by_owner[owner] = mod
		table.insert(mods.list, mod)
	end
	return mod
end

---Files a Lua or compile row under its mod. One script file can hold several callbacks, grouped under the file
---@param session profiler_session
---@param mods profiler_mod_rows
---@param row profiler_usage_row
---@param item profiler_tree_item
local function add_to_mod(session, mods, row, item)
	local mod = mod_row(mods, row.owner)
	mod.ms_per_frame = mod.ms_per_frame + row.ms_per_frame
	mod.calls = mod.calls + row.calls_per_frame
	mod.worst_ms = math.max(mod.worst_ms, row.worst_ms)
	local caller, share = queries.main_caller(session, row.key)
	if caller then item.detail = ("started by %s (%.0f%% of session)"):format(caller, 100 * share) end
	local file, line = row.key:match("^(.*):(%d+)$")
	if file and row.kind == "lua" then
		local group = mod.files[file]
		if not group then
			group = { label = file, ms_per_frame = 0, calls = 0, worst_ms = 0, children = {}, file = file }
			mod.files[file] = group
			table.insert(mod.children, group)
		end
		group.ms_per_frame = group.ms_per_frame + row.ms_per_frame
		group.calls = group.calls + row.calls_per_frame
		group.worst_ms = math.max(group.worst_ms, row.worst_ms)
		item.label = ("line %s: %s"):format(line, queries.function_label(session, file, tonumber(line) or 0))
		table.insert(group.children, item)
	else
		item.file = row.kind == "lua" and row.key or nil
		table.insert(mod.children, item)
	end
end

---Puts one usage row where it belongs: under a mod, or under a part of the engine
---@param session profiler_session
---@param mods profiler_mod_rows
---@param areas profiler_engine_areas
---@param entity_rows profiler_entity_rows?
---@param row profiler_usage_row
local function place_usage_row(session, mods, areas, entity_rows, row)
	local key, kind = row.key, row.kind
	local item = { label = key, ms_per_frame = row.ms_per_frame, calls = row.calls_per_frame, worst_ms = row.worst_ms }
	local area = nil
	if row.owner == "this profiler" then
		area = areas.own
	elseif kind == "lua" or kind == "compile" or kind == "lua state setup" then
		add_to_mod(session, mods, row, item)
	elseif kind == "system" then
		area = areas.system
		local sampled = entity_rows and entity_rows.systems[key]
		if sampled then
			item.children = {}
			for _, file in ipairs(sampled.files) do
				item.children[#item.children + 1] = {
					label = file.file,
					ms_per_frame = file.ms_per_frame,
					detail = key == "LuaSystem" and "includes its scripts" or nil,
				}
			end
		end
	elseif key == "draw" or key:find("^swap: ") then
		area = areas.render
	elseif kind == "phase" then
		area = areas.sim
	end
	if area then table.insert(area.children, item) end
end

---Engine work on a mod's entities. Shown under the mod but not added to its total, because Engine systems already
---counts this time
---@param mods profiler_mod_rows
---@param entity_rows profiler_entity_rows?
local function add_engine_work(mods, entity_rows)
	for _, file in ipairs(entity_rows and entity_rows.files or {}) do
		if file.owner ~= "vanilla" and file.owner ~= "unknown" and file.owner ~= "created at runtime" then
			local mod = mod_row(mods, file.owner)
			local engine = mod.engine_row
			if not engine then
				engine = { label = "Engine work on its entities", ms_per_frame = 0, children = {}, detail = "also counted under Engine systems" }
				mod.engine_row = engine
				table.insert(mod.children, engine)
			end
			engine.ms_per_frame = engine.ms_per_frame + file.ms_per_frame
			table.insert(engine.children, { label = file.file, ms_per_frame = file.ms_per_frame })
		end
	end
end

---Copies and carriers from the census, shown beside a script's time
---@param item profiler_tree_item
---@param census_pass profiler_census_pass?
local function add_census_rows(item, census_pass)
	local entry = census_pass and item.file and census_pass.scripts[item.file]
	if not entry then return end
	item.detail = ("%d copies, %d every frame"):format(entry.copies, entry.every_frame)
	local carriers = {}
	for file, count in pairs(entry.files) do
		carriers[#carriers + 1] = { file = file, count = count }
	end
	table.sort(carriers, function(left, right)
		return left.count > right.count
	end)
	item.children = item.children or {}
	for index, carrier in ipairs(carriers) do
		if index > CENSUS_CARRIERS_SHOWN then break end
		-- A time cannot be split by carrier, these rows only hold a count.
		item.children[#item.children + 1] = {
			label = ("on %s"):format(carrier.file == "" and "entities created at runtime" or carrier.file),
			detail = ("%d copies"):format(carrier.count),
			ms_per_frame = -1 - index,
		}
	end
end

---Sorts a tree and finishes each row's detail text
---@param items profiler_tree_item[]
---@param census_pass profiler_census_pass?
local function finish_tree(items, census_pass)
	table.sort(items, by_ms_per_frame)
	for _, child in ipairs(items) do
		add_census_rows(child, census_pass)
		if child.children then finish_tree(child.children, census_pass) end
		if (child.file or not child.children) and child.calls and child.calls >= 2 and child.ms_per_frame > 0 then
			local cost = ("%.0f us per call"):format(1000 * child.ms_per_frame / child.calls)
			child.detail = child.detail and (cost .. ", " .. child.detail) or cost
		end
	end
end

---Who uses the frame over the selected Span, biggest first: each mod beside each part of the engine
---@param session profiler_session
---@return profiler_overview
local function build_overview(session)
	local usage = view:usage(session)
	local totals = usage.totals
	local frames = math.max(totals.frame_count, 1)
	local category_ticks = totals.category_ticks
	---Ticks summed over the span, per frame
	---@param ticks number
	---@return number
	local function to_ms_per_frame(ticks)
		return ticks / session.ticks_per_ms / frames
	end
	local engine_areas = {
		sim = {
			label = "World simulation",
			ms_per_frame = to_ms_per_frame(category_ticks.world + category_ticks.post + category_ticks.update),
			children = {},
			key = "sim",
		},
		system = { label = "Engine systems", ms_per_frame = to_ms_per_frame(category_ticks.systems), children = {}, key = "system" },
		render = { label = "Rendering", ms_per_frame = to_ms_per_frame(category_ticks.draw + category_ticks.swap), children = {}, key = "render" },
		other = { label = "Not hooked", ms_per_frame = to_ms_per_frame(category_ticks.other), children = {}, key = "other" },
		own = { label = "This profiler", ms_per_frame = to_ms_per_frame(category_ticks.own), children = {}, key = "own" },
	}
	local areas = { engine_areas.sim, engine_areas.system, engine_areas.render, engine_areas.other, engine_areas.own }

	local entity_rows = queries.sampler_active(session) and queries.entity_rows(session, totals) or nil
	local mods = { by_owner = {}, list = {} }
	for _, row in ipairs(usage.rows) do
		place_usage_row(session, mods, engine_areas, entity_rows, row)
	end
	add_engine_work(mods, entity_rows)
	for _, mod in ipairs(mods.list) do
		table.insert(areas, mod)
	end
	for _, area in ipairs(areas) do
		area.calls, area.worst_ms = 0, 0
		for _, child in ipairs(area.children) do
			area.calls = area.calls + (child.calls or 0)
			area.worst_ms = math.max(area.worst_ms, child.worst_ms or 0)
		end
	end

	local materials = queries.has_cell_hooks(session) and queries.material_rows(session, totals) or {}
	local material_ms = 0
	for _, row in ipairs(materials) do
		material_ms = material_ms + row.ms_per_frame
	end

	local census_pass = census.latest()
	for _, area in ipairs(areas) do
		finish_tree(area.children, census_pass)
	end
	table.sort(areas, by_ms_per_frame)
	return { busy_ms = usage.busy_ms, areas = areas, materials = materials, material_ms = material_ms, mods = mods.list }
end

---The overview, rebuilt every half second
---@param session profiler_session
---@return profiler_overview
local function cached_overview(session)
	return view:cached_rows("overview", session, 30, function()
		return build_overview(session)
	end)
end

---One sentence: is the game keeping up, and who is biggest
---@param overview profiler_overview
---@return string
local function verdict(overview)
	local biggest = overview.areas[1]
	local share = 100 * overview.busy_ms / view.BUDGET_MS
	if overview.busy_ms > view.BUDGET_MS then
		return ("Over budget: %.1f ms of work per frame against 16.7 ms. Biggest: %s, %.1f ms per frame."):format(
			overview.busy_ms,
			biggest.label,
			biggest.ms_per_frame
		)
	end
	return ("Keeping up: %.1f ms of 16.7 ms used (%.0f%%). Biggest: %s, %.1f ms per frame."):format(
		overview.busy_ms,
		share,
		biggest.label,
		biggest.ms_per_frame
	)
end

---Material rows inside World simulation. CPU on all threads, and silent about who put the material there, which
---is why it stays apart from the game thread's time beside it
---@param session profiler_session
---@param overview profiler_overview
local function draw_material_rows(session, overview)
	if not queries.has_cell_hooks(session) then
		tables.tree_row("sim_hint", "Material time is not available: the cell hooks were not found in this build", false, {})
		return
	end
	local open = tables.tree_row(
		"materials",
		"Cell updates by material, all threads",
		true,
		{ ms_per_frame = overview.material_ms },
		nil,
		"What burned the time, not who caused it"
	)
	if not open then return end
	for index, row in ipairs(overview.materials) do
		if index > MATERIALS_SHOWN then break end
		tables.tree_row(
			"material/" .. row.name,
			row.name,
			false,
			{ ms_per_frame = row.ms_per_frame, calls = row.cells_per_frame },
			nil,
			"defined by " .. row.owner
		)
	end
	view.imgui.TreePop()
end

---A top-level row and everything under it
---@param session profiler_session
---@param area profiler_tree_item
---@param overview profiler_overview
local function draw_area(session, area, overview)
	local imgui = view.imgui
	local open = tables.tree_row(area.key, area.label, true, area, overview.busy_ms)
	local link = AREA_LINKS[area.key]
	if link and (not link.needs_cell_hooks or queries.has_cell_hooks(session)) then
		imgui.TableSetColumnIndex(5)
		if imgui.Button("Open " .. link.label .. "##" .. area.key) then
			view.tab_to_open = "items"
			view.item_filter = link.filter
			view.cached.items = nil
		end
	end
	if not open then return end
	if area.key == "sim" then draw_material_rows(session, overview) end
	tables.draw_tree_items(area.children, overview.busy_ms, area.key)
	imgui.TreePop()
end

---The busiest threads in one line
---@param session profiler_session
---@return string
local function build_thread_text(session)
	local parts = {}
	for index, thread in ipairs(queries.thread_rows(session)) do
		if index > THREADS_SHOWN then break end
		local name = thread.is_game and "game" or (thread.is_cell_loop and "cells" or "thread")
		parts[#parts + 1] = ("%s %.0f%%"):format(name, thread.percent)
	end
	return #parts > 0 and "CPU, % of one core: " .. table.concat(parts, ", ") or ""
end

---The latest spike, with a button to its details
---@param session profiler_session
local function draw_last_hitch(session)
	local imgui = view.imgui
	local latest = view.latest_spike(session)
	if not latest then
		imgui.Text("No hitches over 33.3 ms so far.")
		return
	end
	if imgui.Button("Open##last_hitch") then
		view.selected_spike_frame = latest.frame_number
		view.tab_to_open = "spikes"
	end
	imgui.SameLine()
	imgui.Text(view.last_hitch_text(session, latest))
end

---What's lagging tab
---@param session profiler_session
---@param height number
function overview_tab.draw_lagging(session, height)
	local imgui = view.imgui
	local overview = cached_overview(session)
	imgui.Text(view:span_label() .. ": " .. verdict(overview))
	local thread_text = view:cached_rows("threads", session, 60, function()
		return build_thread_text(session)
	end)
	if thread_text ~= "" then imgui.TextDisabled(thread_text) end
	draw_last_hitch(session)
	if not tables.begin_tree("overview", math.max(height - 70, 40)) then return end
	for _, area in ipairs(overview.areas) do
		draw_area(session, area, overview)
	end
	imgui.EndTable()
end

---Mods tab
---@param session profiler_session
---@param height number
function overview_tab.draw_mods(session, height)
	local imgui = view.imgui
	local overview = cached_overview(session)
	imgui.Text(view:span_label() .. ": each mod's own Lua and compile time. Engine work a mod causes lands in World simulation and Engine systems.")
	if not tables.begin_tree("mods", math.max(height - 22, 40)) then return end
	tables.draw_tree_items(overview.mods, overview.busy_ms, "mods")
	imgui.EndTable()
end

return overview_tab
