-- The click-through overlay across the game window: no title, background or hitboxes.

local view = dofile_once("mods/debug_helper/files/scripts/profiler/viewer/view_state.lua") ---@type profiler_view_state
local graph = dofile_once("mods/debug_helper/files/scripts/profiler/viewer/graph.lua") ---@type profiler_graph_module
local OFFENDER_ROWS = 5
local GRAPH_SHARE = 0.2
local TEXT_MARGIN = 8

---@class profiler_overlay_module
local overlay = {}

---Text with a dark outline: there is no background, and the game can be any colour
---@param x number
---@param y number
---@param text string
local function outlined_text(x, y, text)
	local imgui = view.imgui
	imgui.SetCursorPos(x + 1, y + 1)
	imgui.TextColored(0, 0, 0, 1, text)
	imgui.SetCursorPos(x, y)
	imgui.TextColored(1, 1, 1, 1, text)
end

---The graph, with no frame or background
---@param session profiler_session
---@param y number
---@param width number
---@param height number
local function draw_plot(session, y, width, height)
	local imgui = view.imgui
	local implot = imgui.implot
	local y_max = graph.y_limit(graph.update_columns(session))
	for _, color in ipairs({ implot.PlotCol.FrameBg, implot.PlotCol.PlotBg, implot.PlotCol.PlotBorder }) do
		implot.PushStyleColor(color, 0, 0, 0, 0)
	end
	imgui.SetCursorPos(0, y)
	if implot.BeginPlot("##hud_frames", width, height, bit.bor(implot.PlotFlags.CanvasOnly, implot.PlotFlags.NoFrame)) then
		local axis = bit.bor(implot.PlotAxisFlags.NoDecorations, implot.PlotAxisFlags.Lock)
		implot.SetupAxes("", "", axis, axis)
		graph.setup_limits(y_max)
		graph.plot_layers(session, view.overlay_alpha)
		implot.EndPlot()
	end
	implot.PopStyleColor(3)
end

---The graph and text along the bottom of the game window
---@param session profiler_session
---@param width number
---@param height number
local function draw_body(session, width, height)
	local usage = view:usage(session)
	local offenders = {}
	for _, row in ipairs(usage.rows) do
		if row.kind ~= "phase" and row.kind ~= "other" and row.owner ~= "this profiler" then offenders[#offenders + 1] = row end
	end
	table.sort(offenders, function(left, right)
		return left.ms_per_frame > right.ms_per_frame
	end)

	local line_height = view.imgui.GetTextLineHeightWithSpacing()
	local text_height = line_height * (OFFENDER_ROWS + 2)
	local graph_height = height * GRAPH_SHARE
	draw_plot(session, height - text_height - graph_height, width, graph_height)

	local y = height - text_height
	outlined_text(
		TEXT_MARGIN,
		y,
		("%s: real work %.1f / 16.7 ms (%.1f is this profiler)  |  %d entities  |  %.0f MB  |  %d hitches"):format(
			view:span_label(),
			usage.busy_ms,
			usage.own_ms,
			session.entity_count,
			session.memory_mb,
			usage.totals.spike_count
		)
	)
	y = y + line_height
	local latest = view.latest_spike(session)
	if latest then outlined_text(TEXT_MARGIN, y, view.last_hitch_text(session, latest)) end
	for index = 1, OFFENDER_ROWS do
		local row = offenders[index]
		if not row then break end
		y = y + line_height
		outlined_text(TEXT_MARGIN, y, ("%6.2f ms %5.1f%%  [%s]  %s"):format(row.ms_per_frame, row.busy_percent, row.owner, row.key))
	end
end

---Draws the overlay. A failure turns it off and does not break the game
---@param session profiler_session
function overlay.draw(session)
	local imgui = view.imgui
	local x, y = imgui.GetMainViewportPos()
	local width, height = imgui.GetMainViewportSize()
	imgui.SetNextWindowViewport(imgui.GetMainViewportID())
	imgui.SetNextWindowPos(x, y, imgui.Cond.Always)
	imgui.SetNextWindowSize(width, height, imgui.Cond.Always)
	imgui.PushStyleVar(imgui.StyleVar.WindowPadding, 0, 0)
	imgui.PushStyleVar(imgui.StyleVar.WindowBorderSize, 0)
	local flags = bit.bor(
		imgui.WindowFlags.NoDecoration,
		imgui.WindowFlags.NoInputs,
		imgui.WindowFlags.NoBackground,
		imgui.WindowFlags.NoSavedSettings,
		imgui.WindowFlags.NoDocking,
		imgui.WindowFlags.NoFocusOnAppearing,
		imgui.WindowFlags.NoBringToFrontOnFocus
	)
	local show = imgui.Begin("##debug_helper_profiler_hud", nil, flags)
	imgui.PopStyleVar(2)
	if show then
		local succeeded, draw_error = pcall(draw_body, session, width, height)
		if not succeeded then
			print("[profiler] viewer error: " .. tostring(draw_error))
			view:close_overlay()
		end
	end
	imgui.End()
end

return overlay
