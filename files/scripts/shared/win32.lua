local ffi = require("ffi")
local bit = require("bit")

local SECTION_IS_CODE = 0x20000000

ffi.cdef([[
typedef struct { uint32_t size, usage, thread_id, owner_process, base_priority, delta_priority, flags; } win32_thread_entry;

void* GetModuleHandleA(const char* name);
void* GetProcAddress(void* module, const char* name);
void* VirtualAlloc(void* address, size_t size, uint32_t type, uint32_t protect);
int VirtualProtect(void* address, size_t size, uint32_t protect, uint32_t* old);
int QueryPerformanceCounter(int64_t* out);
int QueryPerformanceFrequency(int64_t* out);
uint32_t GetCurrentThreadId(void);
uint32_t GetCurrentProcessId(void);
int K32GetProcessMemoryInfo(void* process, uint32_t* counters, uint32_t size);
void* GetCurrentProcess(void);
void* CreateToolhelp32Snapshot(uint32_t flags, uint32_t process);
int Thread32First(void* snapshot, win32_thread_entry* entry);
int Thread32Next(void* snapshot, win32_thread_entry* entry);
void* OpenThread(uint32_t access, int inherit, uint32_t thread_id);
int GetThreadTimes(void* thread, uint64_t* created, uint64_t* exited, uint64_t* kernel, uint64_t* user);
int CloseHandle(void* handle);
uint32_t GetEnvironmentVariableA(const char* name, char* out, uint32_t size);
int SetEnvironmentVariableA(const char* name, const char* value);
void* CreateThread(void* attributes, size_t stack, void* start, void* parameter, uint32_t flags, uint32_t* id);
int CreateDirectoryA(const char* path, void* attributes);
int IsBadReadPtr(const void* address, size_t size);
]])

---@class win32_thread_entry
---@field size integer
---@field thread_id integer
---@field owner_process integer

---@class win32_image_section
---@field relative_address integer
---@field size integer rounded down to whole dwords

---@class win32_loaded_image
---@field bytes ffi.cdata*
---@field dwords ffi.cdata*
---@field image_base number the base its stored pointers are relative to
---@field data_sections win32_image_section[]
---@field code_sections win32_image_section[]

---@class win32_module
local win32 = {}

---Pointer as a Lua number
---@param pointer ffi.cdata*
---@return number
function win32.address_of(pointer)
	return tonumber(ffi.cast("uintptr_t", pointer)) or 0
end

---32 bits at a byte offset
---@param bytes ffi.cdata*
---@param offset integer
---@return integer
function win32.read_dword(bytes, offset)
	return ffi.cast("uint32_t*", bytes + offset)[0]
end

---Import slots of a loaded module, as "dll!name" to slot address
---@param module ffi.cdata* the module, laid out as loaded
---@param image_base number
---@return table<string, number>
function win32.imports_of(module, image_base)
	local read_dword = win32.read_dword
	local bytes = ffi.cast("uint8_t*", module)
	local imports = {}
	local descriptor = read_dword(bytes, read_dword(bytes, 0x3C) + 0x80)
	while read_dword(bytes, descriptor + 12) ~= 0 do
		local dll = ffi.string(bytes + read_dword(bytes, descriptor + 12)):lower()
		local name_table, address_table = read_dword(bytes, descriptor), read_dword(bytes, descriptor + 16)
		local names = name_table ~= 0 and name_table or address_table
		local index = 0
		while read_dword(bytes, names + index * 4) ~= 0 do
			local name_entry = read_dword(bytes, names + index * 4)
			if name_entry < 0x80000000 then imports[dll .. "!" .. ffi.string(bytes + name_entry + 2)] = image_base + address_table + index * 4 end
			index = index + 1
		end
		descriptor = descriptor + 20
	end
	return imports
end

---Reads the section table
---@param module ffi.cdata* the module, laid out as loaded
---@param image_base number
---@return win32_loaded_image
function win32.open_image(module, image_base)
	local read_dword = win32.read_dword
	local bytes = ffi.cast("uint8_t*", module)
	local pe_header = read_dword(bytes, 0x3C)
	local section_count = ffi.cast("uint16_t*", bytes + pe_header + 6)[0]
	local optional_header_size = ffi.cast("uint16_t*", bytes + pe_header + 20)[0]
	local image = {
		bytes = bytes,
		dwords = ffi.cast("uint32_t*", module),
		image_base = image_base,
		data_sections = {},
		code_sections = {},
	}
	for index = 0, section_count - 1 do
		local header = pe_header + 24 + optional_header_size + index * 40
		local virtual_size = read_dword(bytes, header + 8)
		local section = { relative_address = read_dword(bytes, header + 12), size = virtual_size - virtual_size % 4 }
		local list = bit.band(read_dword(bytes, header + 36), SECTION_IS_CODE) ~= 0 and image.code_sections or image.data_sections
		list[#list + 1] = section
	end
	return image
end

---Whether an address lies in an executable section
---@param image win32_loaded_image
---@param address number
---@return boolean
function win32.is_code(image, address)
	local relative_address = address - image.image_base
	for _, section in ipairs(image.code_sections) do
		if relative_address >= section.relative_address and relative_address < section.relative_address + section.size then return true end
	end
	return false
end

---Reads a stored pointer through its address
---@param image win32_loaded_image
---@param address number
---@return integer
function win32.read_pointer(image, address)
	return win32.read_dword(image.bytes, address - image.image_base)
end

return win32
