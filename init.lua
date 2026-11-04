local pixelscene_overlay = dofile_once("mods/debug_helper/files/scripts/pixelscenes/overlay.lua") ---@type pixelscene_overlay
local profiler = dofile_once("mods/debug_helper/files/scripts/profiler/profiler.lua") ---@type profiler
local profiler_viewer = dofile_once("mods/debug_helper/files/scripts/profiler/viewer/viewer.lua") ---@type profiler_viewer_module

ModLuaFileAppend("mods/component-explorer/menu_extensions.lua", "mods/debug_helper/files/scripts/component_explorer_menu.lua")

--- Hooking
function OnModPostInit()
	pixelscene_overlay:init()
	profiler.start(ModSettingGet("debug_helper.PROFILER_ENABLED") == true)
end

--- Looping go brr
function OnWorldPostUpdate()
	pixelscene_overlay:draw()
	profiler.tick()
	profiler_viewer.draw()
end

function OnPausePreUpdate()
	profiler.tick()
	profiler_viewer.draw()
end
