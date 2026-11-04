-- The ImGui window, listed in Component Explorer's View menu when that mod is on, and the entry point for drawing.

local profiler = dofile_once("mods/debug_helper/files/scripts/profiler/profiler.lua") ---@type profiler
local sessions = dofile_once("mods/debug_helper/files/scripts/profiler/capture/session.lua") ---@type profiler_sessions_module
local file_export = dofile_once("mods/debug_helper/files/scripts/profiler/output/file_export.lua") ---@type profiler_file_export_module
local view = dofile_once("mods/debug_helper/files/scripts/profiler/viewer/view_state.lua") ---@type profiler_view_state
local graph = dofile_once("mods/debug_helper/files/scripts/profiler/viewer/graph.lua") ---@type profiler_graph_module
local overview_tab = dofile_once("mods/debug_helper/files/scripts/profiler/viewer/overview_tab.lua") ---@type profiler_overview_tab_module
local detail_tabs = dofile_once("mods/debug_helper/files/scripts/profiler/viewer/detail_tabs.lua") ---@type profiler_detail_tabs_module
local overlay = dofile_once("mods/debug_helper/files/scripts/profiler/viewer/overlay.lua") ---@type profiler_overlay_module
---@class profiler_viewer_module
local viewer = {}

---One tab. The ID after ### keeps a tab selected while its label's count changes
---@param tab_id string
---@param label string
---@param session profiler_session
---@param height number
---@param draw_contents fun(session: profiler_session, height: number)
local function draw_tab(tab_id, label, session, height, draw_contents)
	local imgui = view.imgui
	local flags = view.tab_to_open == tab_id and imgui.TabItemFlags.SetSelected or 0
	if flags ~= 0 then view.tab_to_open = nil end
	if imgui.BeginTabItem(label .. "###" .. tab_id, nil, flags) then
		draw_contents(session, height)
		imgui.EndTabItem()
	end
end

---The tab bar and its tabs
---@param session profiler_session
local function draw_tabs(session)
	local imgui = view.imgui
	local _, available_height = imgui.GetContentRegionAvail()
	local height = math.max(available_height - 30, 60)
	if not imgui.BeginTabBar("tabs") then return end
	draw_tab("overview", "What's lagging", session, height, overview_tab.draw_lagging)
	draw_tab("mods", "Mods", session, height, overview_tab.draw_mods)
	draw_tab("spikes", "Spikes (" .. view:usage(session).totals.spike_count .. ")", session, height, detail_tabs.draw_spikes)
	draw_tab("entities", "Entities", session, height, detail_tabs.draw_entities)
	draw_tab("components", "Components", session, height, detail_tabs.draw_components)
	draw_tab("items", "All items", session, height, detail_tabs.draw_items)
	imgui.EndTabBar()
end

---The row of buttons under the header
---@param session profiler_session
local function draw_controls(session)
	local imgui = view.imgui
	local _
	if imgui.Button(view.frozen and "Resume" or "Freeze") then view:toggle_freeze(session) end
	imgui.SameLine()
	if imgui.Button("Span: " .. view.SPANS[view.span_index].label) then view.span_index = view.span_index % #view.SPANS + 1 end
	imgui.SameLine()
	local y_scale = graph.Y_SCALES[view.y_scale_index]
	local y_label = y_scale == 0 and "auto" or ("%.0f ms"):format(y_scale)
	if imgui.Button("Height: " .. y_label) then view.y_scale_index = view.y_scale_index % #graph.Y_SCALES + 1 end
	imgui.SameLine()
	imgui.SetNextItemWidth(90)
	_, view.window_opacity = imgui.SliderFloat("Opacity", view.window_opacity, 0.1, 1, "%.2f")
	imgui.SameLine()
	local overlay_open = view:is_overlay_open()
	local changed, new_overlay_open = imgui.Checkbox("Overlay", overlay_open)
	if changed and new_overlay_open ~= overlay_open then view:toggle_overlay() end
	imgui.SameLine()
	imgui.SetNextItemWidth(90)
	_, view.overlay_alpha = imgui.SliderFloat("Overlay alpha", view.overlay_alpha, 0.1, 1, "%.2f")
	imgui.SameLine()
	if imgui.Button("Save trace") then file_export.start_trace(session, nil, "manual.json") end
	imgui.SameLine()
	if imgui.Button("Save CSV") then file_export.start_csv(session) end
	imgui.SameLine()
	imgui.TextDisabled(file_export.status())
end

---The summary line
---@param session profiler_session
local function draw_header(session)
	local usage = view:usage(session)
	local entity_count, memory_mb = view:game_stats(session)
	view.imgui.Text(
		("%s: real work %.1f ms of the 16.7 ms budget (%.1f is this profiler)  |  %d entities  |  %.0f MB  |  %d hitches%s"):format(
			view:span_label(),
			usage.busy_ms,
			usage.own_ms,
			entity_count,
			memory_mb,
			usage.totals.spike_count,
			view.frozen and "  |  FROZEN, hover the graph to inspect" or ""
		)
	)
end

---Everything inside the window
---@param session profiler_session
local function draw_body(session)
	draw_header(session)
	draw_controls(session)
	local _, available_height = view.imgui.GetContentRegionAvail()
	graph.draw(session, math.max(available_height * 0.4, 80))
	draw_tabs(session)
end

---A failure closes the window and does not break the game
---@param session profiler_session
local function draw_window(session)
	local imgui = view.imgui
	imgui.SetNextWindowSize(900, 600, imgui.Cond.FirstUseEver)
	imgui.SetNextWindowBgAlpha(view.window_opacity)
	local show, open = imgui.Begin("Profiler###debug_helper_profiler", true)
	if show then
		local succeeded, draw_error = pcall(draw_body, session)
		if not succeeded then
			print("[profiler] viewer error: " .. tostring(draw_error))
			open = false
		end
	end
	imgui.End()
	if not open then view:close_window() end
end

---Draws whichever views are open. Call once per frame, gameplay or paused
function viewer.draw()
	local session = profiler.running_session()
	if not session or not view.imgui then return end
	view:sync()
	if view:is_overlay_open() then
		local started = session.block.read_timestamp()
		overlay.draw(session)
		sessions.add_own_cost(session, "overlay", session.block.read_timestamp() - started)
	end
	if view:is_window_open() then
		local started = session.block.read_timestamp()
		draw_window(session)
		sessions.add_own_cost(session, "main window", session.block.read_timestamp() - started)
	end
end

return viewer
