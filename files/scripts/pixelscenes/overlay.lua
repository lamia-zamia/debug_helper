local scene_reader = dofile_once("mods/debug_helper/files/scripts/pixelscenes/scene_reader.lua") ---@type pixelscene_reader

local ENABLED_SETTING = "debug_helper.show_pixelscenes"
local FIRST_WIDGET_ID = 1000
local Z_ORDER = -3000
local BOX_SPRITE = "mods/debug_helper/files/gfx/nine_piece.png"
local FONT = "data/fonts/generated/notosans_ko_36.bin"
local LINE_HEIGHT = 11

---@class (exact) pixelscene_overlay
---@field gui gui
---@field last_widget_id number
---@field virtual_width number
---@field virtual_height number
---@field screen_width number
---@field screen_height number
---@field camera_x number
---@field camera_y number
local overlay = {
	gui = GuiCreate(),
	last_widget_id = FIRST_WIDGET_ID,
}

---Fetches data
function overlay:init()
	self.virtual_width = tonumber(MagicNumbersGetValue("VIRTUAL_RESOLUTION_X")) or 0
	self.virtual_height = tonumber(MagicNumbersGetValue("VIRTUAL_RESOLUTION_Y")) or 0
end

---Updates what the frame's drawing depends on
function overlay:update_view()
	self.last_widget_id = FIRST_WIDGET_ID
	self.screen_width, self.screen_height = GuiGetScreenDimensions(self.gui)
	self.camera_x, self.camera_y = GameGetCameraPos()
end

---Incremental id
---@return number id
function overlay:next_widget_id()
	self.last_widget_id = self.last_widget_id + 1
	return self.last_widget_id
end

---Converts a world size to a gui size
---@param world_width number
---@param world_height number
---@return number width, number height
function overlay:world_to_gui_size(world_width, world_height)
	return world_width * self.screen_width / self.virtual_width, world_height * self.screen_height / self.virtual_height
end

---Converts a world position to a gui position
---@param world_x number
---@param world_y number
---@return number x, number y
function overlay:world_to_gui_position(world_x, world_y)
	local camera_relative_x = world_x - self.camera_x + self.virtual_width / 2
	local camera_relative_y = world_y - self.camera_y + self.virtual_height / 2
	return self:world_to_gui_size(camera_relative_x, camera_relative_y)
end

---Draws text, moved down past text already at that spot
---@param x number
---@param y number
---@param text string
---@param used_spots table<string, boolean>
function overlay:draw_stacked_text(x, y, text, used_spots)
	while used_spots[x .. y] do
		y = y + LINE_HEIGHT
	end
	used_spots[x .. y] = true
	GuiText(self.gui, x, y, text, 1, FONT, false)
end

---Draws a scene's box, and its details if the mouse is on it
---@param scene pixelscene
---@param used_spots table<string, boolean>
function overlay:draw_scene(scene, used_spots)
	local x, y = self:world_to_gui_position(scene.x, scene.y)
	local width, height = self:world_to_gui_size(scene.width, scene.height)
	GuiImageNinePiece(self.gui, self:next_widget_id(), x + 1, y + 1, math.max(width - 1, 1), math.max(height - 1, 1), 1, BOX_SPRITE)
	local _, _, hovered = GuiGetPreviousWidgetInfo(self.gui)
	if hovered then self:draw_stacked_text(math.max(x, 0) + 2, math.max(y, 0) + 1, scene_reader:get_text(scene), used_spots) end
end

---Call once per frame. The frame starts even while off, or the last boxes drawn could stay on screen
function overlay:draw()
	GuiStartFrame(self.gui)
	if ModSettingGet(ENABLED_SETTING) ~= true then return end
	self:update_view()
	GuiZSet(self.gui, Z_ORDER)
	local half_width, half_height = self.virtual_width / 2, self.virtual_height / 2
	local scenes =
		scene_reader:in_rectangle(self.camera_x - half_width, self.camera_y - half_height, self.camera_x + half_width, self.camera_y + half_height)
	local used_spots = {}
	for _, scene in ipairs(scenes) do
		self:draw_scene(scene, used_spots)
	end
end

return overlay
