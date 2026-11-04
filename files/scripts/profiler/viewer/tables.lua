-- The two table shapes the tabs use: a flat sortable one, and a tree of grouped rows.

local view = dofile_once("mods/debug_helper/files/scripts/profiler/viewer/view_state.lua") ---@type profiler_view_state
local TREE_ROW_LIMIT = 25
local TREE_COLUMNS = { { "What", 4 }, { "ms/frame", 0.7 }, { "% of busy", 0.7 }, { "Calls/frame", 0.7 }, { "Worst ms", 0.7 }, { "Detail", 1.6 } }

---@class profiler_table_column
---@field label string
---@field format string?
---@field text boolean? sorts ascending first
---@field weight number?

---@class profiler_table_definition
---@field columns profiler_table_column[]
---@field default_sort integer?

---@class profiler_table_sort
---@field column integer
---@field ascending boolean

---@class profiler_table_order
---@field rows table[]
---@field column integer
---@field ascending boolean
---@field order integer[]

---A row of the tree. Negative ms_per_frame marks a row that only holds a count: it sorts last, in that order
---@class profiler_tree_item
---@field label string
---@field ms_per_frame number?
---@field calls number?
---@field worst_ms number?
---@field detail string?
---@field children profiler_tree_item[]?
---@field file string? the script's path, for rows the census can add to
---@field key string? id of a top-level row
---@field files table<string, profiler_tree_item>? a mod's scripts by path
---@field engine_row profiler_tree_item? a mod's engine work
---@field count integer?

---@class profiler_tables_module
local tables = {}

local sort_by_table = {}
local order_by_table = {}

---Declares the columns and draws the header
---@param definition profiler_table_definition
local function setup_columns(definition)
	local imgui = view.imgui
	imgui.TableSetupScrollFreeze(0, 1)
	for index, column in ipairs(definition.columns) do
		local flags = column.text and 0 or imgui.TableColumnFlags.PreferSortDescending
		-- Without this flag, ImGui reports its own first-frame sort: the first column, ascending.
		if index == definition.default_sort then flags = bit.bor(flags, imgui.TableColumnFlags.DefaultSort) end
		imgui.TableSetupColumn(column.label, flags, column.weight or 1)
	end
	imgui.TableHeadersRow()
end

---The table's sort, following any click on a header
---@param table_id string
---@param definition profiler_table_definition
---@return profiler_table_sort
local function current_sort(table_id, definition)
	local imgui = view.imgui
	local sort = sort_by_table[table_id]
	if not sort then
		sort = { column = definition.default_sort or 1, ascending = false }
		sort_by_table[table_id] = sort
	end
	local dirty, specs = imgui.TableGetSortSpecs()
	if dirty and specs then
		sort.column = specs.Specs[1].ColumnIndex + 1
		sort.ascending = specs.Specs[1].SortDirection == imgui.SortDirection.Ascending
	end
	return sort
end

---Row indexes in display order, kept until the rows or the sort change
---@param table_id string
---@param rows table[]
---@param sort profiler_table_sort
---@return integer[]
local function row_order(table_id, rows, sort)
	local cached = order_by_table[table_id]
	if cached and cached.rows == rows and cached.column == sort.column and cached.ascending == sort.ascending then return cached.order end
	local order = {}
	for index = 1, #rows do
		order[index] = index
	end
	local column, ascending = sort.column, sort.ascending
	table.sort(order, function(left, right)
		local left_value, right_value = rows[left][column], rows[right][column]
		if left_value == right_value then return left < right end
		if ascending then return left_value < right_value end
		return left_value > right_value
	end)
	order_by_table[table_id] = { rows = rows, column = column, ascending = ascending, order = order }
	return order
end

---One row of a sortable table
---@param definition profiler_table_definition
---@param row table
---@param selected_row integer?
---@return integer? clicked_row
local function draw_row(definition, row, selected_row)
	local imgui = view.imgui
	local clicked = nil
	imgui.TableNextRow()
	for index, column in ipairs(definition.columns) do
		imgui.TableSetColumnIndex(index - 1)
		local text = column.format and column.format:format(row[index]) or tostring(row[index])
		if index == 1 and selected_row ~= nil then
			if imgui.Selectable(text .. "###" .. tostring(row.id), selected_row == row.id, imgui.SelectableFlags.SpanAllColumns) then
				clicked = row.id
			end
		else
			imgui.Text(text)
		end
	end
	return clicked
end

---Draws a scrolling, sortable table. Rows hold one value per column
---@param table_id string
---@param definition profiler_table_definition
---@param rows table[]
---@param height number
---@param selected_row integer? set to make rows selectable by their `table_id`
---@return integer? clicked_row
function tables.draw_sortable(table_id, definition, rows, height, selected_row)
	local imgui = view.imgui
	local flags = bit.bor(
		imgui.TableFlags.Resizable,
		imgui.TableFlags.RowBg,
		imgui.TableFlags.BordersInnerV,
		imgui.TableFlags.ScrollY,
		imgui.TableFlags.Sortable,
		imgui.TableFlags.SizingStretchProp
	)
	if not imgui.BeginTable(table_id, #definition.columns, flags, 0, height) then return nil end
	setup_columns(definition)
	local order = row_order(table_id, rows, current_sort(table_id, definition))
	local clicked = nil
	local clipper = imgui.ListClipper.new()
	clipper:Begin(#rows)
	while clipper:Step() do
		for position = clipper.DisplayStart, clipper.DisplayEnd - 1 do
			clicked = draw_row(definition, rows[order[position + 1]], selected_row) or clicked
		end
	end
	clipper:End()
	imgui.EndTable()
	return clicked
end

---Starts the table every grouped tab uses
---@param table_id string
---@param height number
---@return boolean open call EndTable if true
function tables.begin_tree(table_id, height)
	local imgui = view.imgui
	local flags = bit.bor(
		imgui.TableFlags.Resizable,
		imgui.TableFlags.RowBg,
		imgui.TableFlags.BordersInnerV,
		imgui.TableFlags.ScrollY,
		imgui.TableFlags.SizingStretchProp
	)
	if not imgui.BeginTable(table_id, #TREE_COLUMNS, flags, 0, height) then return false end
	imgui.TableSetupScrollFreeze(0, 1)
	for _, column in ipairs(TREE_COLUMNS) do
		imgui.TableSetupColumn(column[1], 0, column[2])
	end
	imgui.TableHeadersRow()
	return true
end

---One tree row. ImGui keeps a node's open state under its ID, and the text before ### is not part of that:
---the row stays open while its label changes
---@param node_id string
---@param label string
---@param has_children boolean
---@param item {ms_per_frame:number?, calls:number?, worst_ms:number?}
---@param busy_ms number? total for the share column, nil when a share would mean nothing
---@param detail string?
---@return boolean open true if the caller must add children and call TreePop
function tables.tree_row(node_id, label, has_children, item, busy_ms, detail)
	local imgui = view.imgui
	local flags = imgui.TreeNodeFlags.SpanFullWidth
	if not has_children then flags = bit.bor(flags, imgui.TreeNodeFlags.Leaf, imgui.TreeNodeFlags.NoTreePushOnOpen) end
	imgui.TableNextRow()
	imgui.TableSetColumnIndex(0)
	local open = imgui.TreeNode(label .. "###" .. node_id, flags)
	if item.ms_per_frame and item.ms_per_frame >= 0 then
		imgui.TableSetColumnIndex(1)
		imgui.Text(("%.2f"):format(item.ms_per_frame))
		if busy_ms then
			imgui.TableSetColumnIndex(2)
			imgui.Text(("%.1f"):format(100 * item.ms_per_frame / math.max(busy_ms, 0.001)))
		end
	end
	if item.calls and item.calls > 0 then
		imgui.TableSetColumnIndex(3)
		imgui.Text(("%.1f"):format(item.calls))
	end
	if item.worst_ms and item.worst_ms > 0 then
		imgui.TableSetColumnIndex(4)
		imgui.Text(("%.2f"):format(item.worst_ms))
	end
	if detail then
		imgui.TableSetColumnIndex(5)
		imgui.Text(detail)
	end
	return open and has_children
end

---Tree rows and whatever is open below them, up to a limit per level
---@param items profiler_tree_item[]
---@param busy_ms number?
---@param parent_id string
function tables.draw_tree_items(items, busy_ms, parent_id)
	for index, item in ipairs(items) do
		if index > TREE_ROW_LIMIT then break end
		local node_id = parent_id .. "/" .. item.label
		local children = item.children
		local has_children = children ~= nil and #children > 0
		if tables.tree_row(node_id, item.label, has_children, item, busy_ms, item.detail) and children then
			tables.draw_tree_items(children, busy_ms, node_id)
			view.imgui.TreePop()
		end
	end
end

return tables
