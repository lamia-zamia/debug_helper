dofile("data/scripts/lib/mod_settings.lua")

local mod_id = "debug_helper"

mod_settings = {
	{
		id = "PROFILER_ENABLED",
		ui_name = "Profiler",
		ui_description = "Unsafe: patches the running game. Applies on the next game restart.\nWrites mods/debug_helper/profiler_report.txt. Send that file when reporting lag.",
		value_default = false,
		scope = MOD_SETTING_SCOPE_RUNTIME_RESTART,
	},
	{
		id = "PROFILER_LUA_FUNCTIONS",
		ui_name = "Time every Lua function (disables JIT)",
		ui_description = "Times each Lua function, not only each callback the game runs. Applies right away.\nLua runs without the JIT while this is on, and every call pays for being recorded,\nso Lua timings are inflated, most of all for code making many small calls.",
		value_default = false,
		scope = MOD_SETTING_SCOPE_RUNTIME,
	},
}

---Makes the values visible to ModSettingGet. Settings don't work without this
---@param init_scope integer
function ModSettingsUpdate(init_scope)
	mod_settings_update(mod_id, mod_settings, init_scope)
end

---How many settings the menu shows. Without this they don't show at all
---@return integer
function ModSettingsGuiCount()
	return mod_settings_gui_count(mod_id, mod_settings)
end

---Draws the settings. Without this they don't show at all
---@param gui gui
---@param in_main_menu boolean
function ModSettingsGui(gui, in_main_menu)
	mod_settings_gui(mod_id, mod_settings, gui, in_main_menu)
end
