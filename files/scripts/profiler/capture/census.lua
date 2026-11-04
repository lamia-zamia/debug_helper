-- Component census: which entities carry which components and scripts, walked a few entities per frame.

local ENTITIES_PER_STEP = 15
local PAUSE_TICKS = 120 -- between finished passes

---@class profiler_census_component
---@field count integer
---@field owners table<string, integer>

---@class profiler_census_script
---@field copies integer
---@field enabled integer
---@field every_frame integer
---@field files table<string, integer>

---@class profiler_census_pass
---@field queue entity_id[]
---@field position integer
---@field entities integer
---@field components table<string, profiler_census_component>
---@field scripts table<string, profiler_census_script>
---@field files table<string, integer>
---@field seen table<entity_id, boolean>

---@class profiler_census_module
local census = {}

local current_pass = nil
local latest_pass = nil
local idle_ticks = PAUSE_TICKS
local owner_by_file = {}

---Which mod an entity file belongs to: its own path, or the mod that last patched a vanilla file
---@param file string
---@return string
function census.file_owner(file)
	local owner = owner_by_file[file]
	if owner then return owner end
	owner = file:match("^mods/([^/]+)/")
	if not owner then
		if file == "" then
			owner = "created at runtime"
		else
			local patched_by = ModTextFileWhoSetContent and ModTextFileWhoSetContent(file)
			owner = patched_by and patched_by ~= "" and patched_by or "vanilla"
		end
	end
	owner_by_file[file] = owner
	return owner
end

---Queues everything alive for a new walk
---@return profiler_census_pass
local function start_pass()
	local roots = EntityGetInRadius and EntityGetInRadius(0, 0, 1e9) or {}
	-- The radius query may already include children, and each entity should only count once.
	local seen = {}
	for _, entity in ipairs(roots) do
		seen[entity] = true
	end
	return { queue = roots, position = 1, entities = 0, components = {}, scripts = {}, files = {}, seen = seen }
end

---Counts one script instance
---@param pass profiler_census_pass
---@param component component_id
---@param file string
local function add_lua_component(pass, component, file)
	local script = ComponentGetValue2(component, "script_source_file") or ""
	if script == "" then return end
	local entry = pass.scripts[script]
	if not entry then
		entry = { copies = 0, enabled = 0, every_frame = 0, files = {} }
		pass.scripts[script] = entry
	end
	entry.copies = entry.copies + 1
	if ComponentGetIsEnabled(component) then entry.enabled = entry.enabled + 1 end
	local every = ComponentGetValue2(component, "execute_every_n_frame") or -1
	if every >= 0 and every <= 1 then entry.every_frame = entry.every_frame + 1 end
	entry.files[file] = (entry.files[file] or 0) + 1
end

---Counts one entity's components and queues its children
---@param pass profiler_census_pass
---@param entity entity_id
local function walk_entity(pass, entity)
	local file = EntityGetFilename(entity) or ""
	local owner = census.file_owner(file)
	pass.entities = pass.entities + 1
	pass.files[file] = (pass.files[file] or 0) + 1
	for _, component in ipairs(EntityGetAllComponents(entity) or {}) do
		local kind = ComponentGetTypeName(component)
		if kind then
			local entry = pass.components[kind]
			if not entry then
				entry = { count = 0, owners = {} }
				pass.components[kind] = entry
			end
			entry.count = entry.count + 1
			entry.owners[owner] = (entry.owners[owner] or 0) + 1
			if kind == "LuaComponent" then add_lua_component(pass, component, file) end
		end
	end
	for _, child in ipairs(EntityGetAllChildren(entity) or {}) do
		if not pass.seen[child] then
			pass.seen[child] = true
			pass.queue[#pass.queue + 1] = child
		end
	end
end

---Walks a few more entities. Call once per frame
function census.step()
	if not current_pass then
		idle_ticks = idle_ticks + 1
		if idle_ticks < PAUSE_TICKS then return end
		current_pass = start_pass()
	end
	local pass = current_pass
	for _ = 1, ENTITIES_PER_STEP do
		local entity = pass.queue[pass.position]
		if not entity then
			latest_pass, current_pass, idle_ticks = pass, nil, 0
			return
		end
		pass.position = pass.position + 1
		walk_entity(pass, entity)
	end
end

---The last finished walk, nil before the first one finishes
---@return profiler_census_pass?
function census.latest()
	return latest_pass
end

return census
