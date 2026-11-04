local menu_extensions = dofile_once("mods/component-explorer/menu_extensions.lua")

---Adds a View menu entry, checked while the setting is on
---@param name string
---@param setting string
local function add_toggle(name, setting)
	menu_extensions.list[#menu_extensions.list + 1] = {
		category = "Debug Helper",
		name = name,
		is_enabled = function()
			return ModSettingGet(setting) == true
		end,
		set_enabled = function(enabled)
			ModSettingSet(setting, enabled)
		end,
	}
end

add_toggle("Pixel scenes", "debug_helper.show_pixelscenes")
if ModSettingGet("debug_helper.PROFILER_ENABLED") == true then
	add_toggle("Profiler", "debug_helper.profiler_overlay")
	add_toggle("Profiler overlay", "debug_helper.profiler_hud")
end
