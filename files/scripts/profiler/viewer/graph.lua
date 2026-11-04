-- The frame graph: one stacked bar per column, each column showing the worst frame in its slice.

local sessions = dofile_once("mods/debug_helper/files/scripts/profiler/capture/session.lua") ---@type profiler_sessions_module
local queries = dofile_once("mods/debug_helper/files/scripts/profiler/capture/queries.lua") ---@type profiler_queries_module
local view = dofile_once("mods/debug_helper/files/scripts/profiler/viewer/view_state.lua") ---@type profiler_view_state
local COLUMNS = view.GRAPH_COLUMNS
local NOTE_MATERIALS = 3

---@class profiler_graph_module
local graph = {}

graph.Y_SCALES = { 33.3, 100, 0 } -- 0 fits the worst visible frame

local column_numbers, material_heights, category_heights = {}, {}, {}
local column_frames = {}
local columns_key = nil
local worst_whole_column = 0
local unfinished_share = 0

-- One extra column holds the frames that have not filled a whole column yet.
for column = 1, COLUMNS + 1 do
	column_numbers[column] = column
	material_heights[column] = 0
end
for _, category in ipairs(sessions.CATEGORIES) do
	category_heights[category.key] = {}
	for column = 1, COLUMNS + 1 do
		category_heights[category.key][column] = 0
	end
end

---Bars drawn from zero, tallest first, so each visible part shows one category. ImPlot has no per-bar base in
---these bindings. With alpha below 1 the lower layers show through, and bars get more solid toward the bottom
---@param session profiler_session
---@param alpha number
function graph.plot_layers(session, alpha)
	local implot = view.imgui.implot
	for index = #sessions.CATEGORIES, 1, -1 do
		local category = sessions.CATEGORIES[index]
		implot.SetNextFillStyle(category.red, category.green, category.blue, alpha, 1)
		implot.PlotBars(category.label, column_numbers, category_heights[category.key], 1)
	end
	implot.SetNextLineStyle(1, 1, 1, 0.8, 1)
	implot.PlotInfLines("60 FPS", { view.BUDGET_MS }, implot.PlotInfLinesFlags.Horizontal)
	if queries.has_cell_hooks(session) then
		implot.SetNextLineStyle(0.2, 1, 1, 1, 1.5)
		implot.PlotLine("material CPU", column_numbers, material_heights)
	end
end

---Top of the y axis
---@param worst number tallest visible bar
---@return number
function graph.y_limit(worst)
	local y_max = graph.Y_SCALES[view.y_scale_index]
	if y_max == 0 then return math.max(worst * 1.05, view.BUDGET_MS * 1.5) end
	return y_max
end

---Fills one column from its worst frame: each category's top edge, for the tall-bars-first drawing above
---@param session profiler_session
---@param column integer
---@param last_frame integer newest frame in the column
---@param frame_count integer how many frames it covers
---@return number height
local function fill_column(session, column, last_frame, frame_count)
	local worst = nil
	for frame_number = last_frame, last_frame - frame_count + 1, -1 do
		local candidate = sessions.frame_at(session, frame_number)
		if candidate and (not worst or candidate.busy_ticks > worst.busy_ticks) then worst = candidate end
	end
	column_frames[column] = worst or false
	local height = 0
	for _, category in ipairs(sessions.CATEGORIES) do
		if worst then height = height + worst[category.key] / session.ticks_per_ms end
		category_heights[category.key][column] = height
	end
	material_heights[column] = worst and worst.material_cpu_ticks / session.ticks_per_ms or 0
	return height
end

---Refills the columns that changed
---@param session profiler_session
---@return number worst tallest visible bar
function graph.update_columns(session)
	local frames_per_column = view.SPANS[view.span_index].frames_per_column
	local newest = view:newest_frame(session)
	local unfinished = newest % frames_per_column
	local whole = newest - unfinished
	-- Whole columns only change this rarely. A 5 minute span would otherwise rescan 18,000 frames every frame.
	local key = whole .. ":" .. frames_per_column
	if key ~= columns_key then
		columns_key = key
		local worst = 0
		for column = COLUMNS, 1, -1 do
			worst = math.max(worst, fill_column(session, column, whole - (COLUMNS - column) * frames_per_column, frames_per_column))
		end
		worst_whole_column = worst
	end
	-- The unfinished column slides in from the right, and the graph moves every frame at any span.
	unfinished_share = unfinished / frames_per_column
	return math.max(worst_whole_column, fill_column(session, COLUMNS + 1, newest, unfinished))
end

---Sets the axes to the columns on screen
---@param y_max number
function graph.setup_limits(y_max)
	local implot = view.imgui.implot
	implot.SetupAxesLimits(0.5 + unfinished_share, COLUMNS + 0.5 + unfinished_share, 0, y_max, implot.PlotCond.Always)
end

---One frame's breakdown, sized to the graph. Drawn inside the plot and not as a tooltip: with multi-viewport on,
---a tooltip can become its own OS window, and opening one stalls the game for about 170 ms
---@param session profiler_session
---@param frame profiler_frame
---@param height number
---@return string
local function frame_note(session, frame, height)
	local ticks_per_ms = session.ticks_per_ms
	local rows = math.max(math.floor(height / view.imgui.GetTextLineHeightWithSpacing()) - 1, 3)
	local lines = {
		("busy %.2f ms, idle %.2f ms, %d Lua calls, +%d entities"):format(
			frame.busy_ticks / ticks_per_ms,
			frame.wait_ticks / ticks_per_ms,
			frame.lua_pcalls,
			frame.entities_spawned
		),
	}
	if not frame.item_ticks then
		lines[2] = "Breakdown too old. Largest item: " .. tostring(frame.top_item)
		return table.concat(lines, "\n")
	end
	local has_materials = frame.material_ticks and next(frame.material_ticks) ~= nil
	for _, item in ipairs(queries.top_items(session, frame, rows - 1 - (has_materials and NOTE_MATERIALS + 1 or 0))) do
		lines[#lines + 1] = ("%8.2f  %s"):format(item.milliseconds, item.key)
	end
	if has_materials then
		lines[#lines + 1] = ("Cell updates, all threads: %.2f ms"):format(frame.material_cpu_ticks / ticks_per_ms)
		local materials = {}
		for name, ticks in pairs(frame.material_ticks) do
			materials[#materials + 1] = { name = name, milliseconds = ticks / ticks_per_ms }
		end
		table.sort(materials, function(left, right)
			return left.milliseconds > right.milliseconds
		end)
		for index = 1, math.min(NOTE_MATERIALS, #materials) do
			lines[#lines + 1] = ("%8.2f  %s"):format(materials[index].milliseconds, materials[index].name)
		end
	end
	return table.concat(lines, "\n")
end

---The main window's graph, with a frame's breakdown under the mouse
---@param session profiler_session
---@param height number
function graph.draw(session, height)
	local implot = view.imgui.implot
	local y_max = graph.y_limit(graph.update_columns(session))
	local flags = bit.bor(implot.PlotFlags.NoTitle, implot.PlotFlags.NoMenus, implot.PlotFlags.NoBoxSelect, implot.PlotFlags.NoMouseText)
	if not implot.BeginPlot("##frames", -1, height, flags) then return end
	implot.SetupAxes("", "ms", bit.bor(implot.PlotAxisFlags.NoTickLabels, implot.PlotAxisFlags.NoGridLines), 0)
	graph.setup_limits(y_max)
	implot.SetupLegend(implot.PlotLocation.North, bit.bor(implot.PlotLegendFlags.Horizontal, implot.PlotLegendFlags.Outside))
	graph.plot_layers(session, 1)
	if implot.IsPlotHovered() then
		local x, y = implot.GetPlotMousePos()
		local hovered = column_frames[math.floor(x + 0.5)]
		if hovered then implot.Annotation(x, y, 0.05, 0.05, 0.05, 0.92, 14, 14, true, frame_note(session, hovered, height)) end
	end
	implot.EndPlot()
end

return graph
