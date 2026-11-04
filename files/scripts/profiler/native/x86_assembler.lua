-- The x86 subset the hook stubs use. Operands go destination first, like Intel syntax.
-- Encodings match what a real assembler picks, so a disassembly of the output reads like the source.

local bit = require("bit")

---@class x86_operand
---@field kind "register"|"memory"
---@field code integer register number, 0 for memory
---@field is_byte boolean
---@field base x86_operand? nil for an absolute address
---@field displacement integer
---@field segment_prefix integer?

---@class x86_assembler_module
local x86 = {}

---A register operand
---@param code integer
---@param is_byte boolean?
---@return x86_operand
local function register(code, is_byte)
	return { kind = "register", code = code, is_byte = is_byte or false, displacement = 0 }
end

x86.eax = register(0)
x86.ecx = register(1)
x86.edx = register(2)
x86.ebx = register(3)
x86.esp = register(4)
x86.ebp = register(5)
x86.esi = register(6)
x86.edi = register(7)
x86.al = register(0, true)

---dword ptr [base + displacement]
---@param base x86_operand
---@param displacement integer?
---@return x86_operand
function x86.at(base, displacement)
	return { kind = "memory", code = 0, is_byte = false, base = base, displacement = displacement or 0 }
end

---byte ptr [base + displacement]
---@param base x86_operand
---@param displacement integer?
---@return x86_operand
function x86.byte_at(base, displacement)
	return { kind = "memory", code = 0, is_byte = true, base = base, displacement = displacement or 0 }
end

---dword ptr [address]
---@param address number
---@return x86_operand
function x86.at_address(address)
	return { kind = "memory", code = 0, is_byte = false, displacement = address }
end

---dword ptr fs:[offset]
---@param offset integer
---@return x86_operand
function x86.fs_at(offset)
	return { kind = "memory", code = 0, is_byte = false, displacement = offset, segment_prefix = 0x64 }
end

---Whether a value encodes in one signed byte
---@param value number
---@return boolean
local function fits_signed_byte(value)
	return value >= -128 and value <= 127
end

---@class x86_assembler
---@field base_address number where the code will run
---@field bytes integer[]
---@field labels table<string, integer> byte count at each label of the current routine
---@field unresolved_jumps {label:string, position:integer}[]
local assembler = {}
assembler.__index = assembler

---An empty assembler
---@param base_address number where the code will run
---@return x86_assembler
function x86.new_assembler(base_address)
	return setmetatable({ base_address = base_address, bytes = {}, labels = {}, unresolved_jumps = {} }, assembler)
end

---Raw bytes
---@param ... integer
function assembler:emit(...)
	for _, byte in ipairs({ ... }) do
		self.bytes[#self.bytes + 1] = byte
	end
end

---Little-endian 32 bits, wrapping signed and unsigned the same way
---@param value number
function assembler:emit_dword(value)
	for shift = 0, 24, 8 do
		self:emit(bit.band(bit.rshift(value, shift), 0xFF))
	end
end

---Immediate byte
---@param value integer
function assembler:emit_byte(value)
	self:emit(bit.band(value, 0xFF))
end

---ModRM, plus SIB and displacement when the operand needs them
---@param middle_field integer a register number, or an opcode extension
---@param operand x86_operand
function assembler:emit_modrm(middle_field, operand)
	local middle_bits = middle_field * 8
	if operand.kind == "register" then
		self:emit(0xC0 + middle_bits + operand.code)
		return
	end
	local base = operand.base
	if not base then
		self:emit(middle_bits + 5)
		self:emit_dword(operand.displacement)
		return
	end
	local displacement = operand.displacement
	-- ebp with no displacement encodes an absolute address instead
	local mode = 2
	if displacement == 0 and base ~= x86.ebp then
		mode = 0
	elseif fits_signed_byte(displacement) then
		mode = 1
	end
	self:emit(mode * 64 + middle_bits + base.code)
	if base == x86.esp then self:emit(0x24) end -- esp as a base only encodes through a SIB byte
	if mode == 1 then
		self:emit_byte(displacement)
	elseif mode == 2 then
		self:emit_dword(displacement)
	end
end

---Address of the next byte
---@return number
function assembler:here()
	return self.base_address + #self.bytes
end

---Starts a routine with its own set of labels
---@return number entry_address
function assembler:begin_routine()
	assert(
		#self.unresolved_jumps == 0,
		"jump to a label that was never placed: " .. tostring(self.unresolved_jumps[1] and self.unresolved_jumps[1].label)
	)
	self.labels = {}
	return self:here()
end

---Fills in a short jump's distance
---@param position integer index of the distance byte
---@param target integer byte count at the label
function assembler:patch_jump(position, target)
	local distance = target - position
	assert(fits_signed_byte(distance), "short jump out of range")
	self.bytes[position] = bit.band(distance, 0xFF)
end

---Places a label here, for the jumps in this routine
---@param name string
function assembler:label(name)
	local target = #self.bytes
	self.labels[name] = target
	local unresolved = {}
	for _, jump in ipairs(self.unresolved_jumps) do
		if jump.label == name then
			self:patch_jump(jump.position, target)
		else
			unresolved[#unresolved + 1] = jump
		end
	end
	self.unresolved_jumps = unresolved
end

---Two-byte jump to a label, placed already or not yet
---@param opcode integer
---@param label string
function assembler:short_jump(opcode, label)
	self:emit(opcode, 0)
	local position = #self.bytes
	local target = self.labels[label]
	if target then
		self:patch_jump(position, target)
	else
		self.unresolved_jumps[#self.unresolved_jumps + 1] = { label = label, position = position }
	end
end

---je label
---@param label string
function assembler:je(label)
	self:short_jump(0x74, label)
end

---jne label
---@param label string
function assembler:jne(label)
	self:short_jump(0x75, label)
end

---jae label
---@param label string
function assembler:jae(label)
	self:short_jump(0x73, label)
end

---jmp label, or jmp [memory]
---@param target string|x86_operand
function assembler:jmp(target)
	if type(target) == "string" then
		self:short_jump(0xEB, target)
	else
		self:emit(0xFF)
		self:emit_modrm(4, target)
	end
end

---call address, or call [memory]
---@param target number|x86_operand
function assembler:call(target)
	if type(target) == "number" then
		self:emit(0xE8)
		self:emit_dword(target - (self:here() + 4))
	else
		self:emit(0xFF)
		self:emit_modrm(2, target)
	end
end

---Segment override, when the operand has one
---@param operand x86_operand
function assembler:emit_segment(operand)
	if operand.segment_prefix then self:emit(operand.segment_prefix) end
end

---mov destination, source
---@param destination x86_operand
---@param source x86_operand|number
function assembler:mov(destination, source)
	if type(source) == "number" then
		if destination.kind == "register" then
			self:emit(0xB8 + destination.code)
			self:emit_dword(source)
		elseif destination.is_byte then
			self:emit(0xC6)
			self:emit_modrm(0, destination)
			self:emit_byte(source)
		else
			self:emit(0xC7)
			self:emit_modrm(0, destination)
			self:emit_dword(source)
		end
	elseif source.kind == "memory" then
		self:emit_segment(source)
		if destination == x86.eax and not source.base then
			self:emit(0xA1)
			self:emit_dword(source.displacement)
		else
			self:emit(destination.is_byte and 0x8A or 0x8B)
			self:emit_modrm(destination.code, source)
		end
	elseif destination.kind == "memory" then
		self:emit_segment(destination)
		if source == x86.eax and not destination.base then
			self:emit(0xA3)
			self:emit_dword(destination.displacement)
		else
			self:emit(source.is_byte and 0x88 or 0x89)
			self:emit_modrm(source.code, destination)
		end
	else
		self:emit(0x8B)
		self:emit_modrm(destination.code, source)
	end
end

---lea destination, [memory]
---@param destination x86_operand
---@param memory x86_operand
function assembler:lea(destination, memory)
	self:emit(0x8D)
	self:emit_modrm(destination.code, memory)
end

---The arithmetic group: every member has the same encodings, told apart by this number
---@param group_member integer
---@param destination x86_operand
---@param source x86_operand|number
function assembler:arithmetic(group_member, destination, source)
	local opcode_base = group_member * 8
	if type(source) ~= "number" then
		if destination.kind == "memory" then
			self:emit(opcode_base + 1)
			self:emit_modrm(source.code, destination)
		else
			self:emit(opcode_base + 3)
			self:emit_modrm(destination.code, source)
		end
	elseif destination.is_byte then
		self:emit(0x80)
		self:emit_modrm(group_member, destination)
		self:emit_byte(source)
	elseif fits_signed_byte(source) then
		self:emit(0x83)
		self:emit_modrm(group_member, destination)
		self:emit_byte(source)
	elseif destination == x86.eax then
		self:emit(opcode_base + 5)
		self:emit_dword(source)
	else
		self:emit(0x81)
		self:emit_modrm(group_member, destination)
		self:emit_dword(source)
	end
end

---add destination, source
---@param destination x86_operand
---@param source x86_operand|number
function assembler:add(destination, source)
	self:arithmetic(0, destination, source)
end

---and destination, source
---@param destination x86_operand
---@param source x86_operand|number
function assembler:and_(destination, source)
	self:arithmetic(4, destination, source)
end

---sub destination, source
---@param destination x86_operand
---@param source x86_operand|number
function assembler:sub(destination, source)
	self:arithmetic(5, destination, source)
end

---xor destination, source
---@param destination x86_operand
---@param source x86_operand|number
function assembler:xor(destination, source)
	self:arithmetic(6, destination, source)
end

---cmp left, right
---@param left x86_operand
---@param right x86_operand|number
function assembler:cmp(left, right)
	self:arithmetic(7, left, right)
end

---test left, right. An immediate only goes with byte memory, the one form the stubs use
---@param left x86_operand
---@param right x86_operand|number
function assembler:test(left, right)
	if type(right) == "number" then
		self:emit(0xF6)
		self:emit_modrm(0, left)
		self:emit_byte(right)
	else
		self:emit(right.is_byte and 0x84 or 0x85)
		self:emit_modrm(right.code, left)
	end
end

---inc register, or inc dword ptr [memory]
---@param operand x86_operand
function assembler:inc(operand)
	if operand.kind == "register" then
		self:emit(0x40 + operand.code)
	else
		self:emit(0xFF)
		self:emit_modrm(0, operand)
	end
end

---dec register
---@param target x86_operand
function assembler:dec(target)
	self:emit(0x48 + target.code)
end

---not register
---@param target x86_operand
function assembler:not_(target)
	self:emit(0xF7)
	self:emit_modrm(2, target)
end

---imul destination, source, factor
---@param destination x86_operand
---@param source x86_operand
---@param factor number
function assembler:imul(destination, source, factor)
	self:emit(0x69)
	self:emit_modrm(destination.code, source)
	self:emit_dword(factor)
end

---shl target, count
---@param target x86_operand
---@param count integer
function assembler:shl(target, count)
	self:emit(0xC1)
	self:emit_modrm(4, target)
	self:emit(count)
end

---shr target, count
---@param target x86_operand
---@param count integer
function assembler:shr(target, count)
	self:emit(0xC1)
	self:emit_modrm(5, target)
	self:emit(count)
end

---push register, immediate or dword ptr [memory]
---@param source x86_operand|number
function assembler:push(source)
	if type(source) == "number" then
		if fits_signed_byte(source) then
			self:emit(0x6A)
			self:emit_byte(source)
		else
			self:emit(0x68)
			self:emit_dword(source)
		end
	elseif source.kind == "register" then
		self:emit(0x50 + source.code)
	else
		self:emit(0xFF)
		self:emit_modrm(6, source)
	end
end

---pop register
---@param target x86_operand
function assembler:pop(target)
	self:emit(0x58 + target.code)
end

---lock xadd [memory], register
---@param memory x86_operand
---@param source x86_operand
function assembler:lock_xadd(memory, source)
	self:emit(0xF0, 0x0F, 0xC1)
	self:emit_modrm(source.code, memory)
end

---rdtsc
function assembler:rdtsc()
	self:emit(0x0F, 0x31)
end

---leave
function assembler:leave()
	self:emit(0xC9)
end

---ret, or ret stack_bytes
---@param stack_bytes integer?
function assembler:ret(stack_bytes)
	if stack_bytes then
		self:emit(0xC2, stack_bytes, 0)
	else
		self:emit(0xC3)
	end
end

---The finished machine code
---@return string
function assembler:finish()
	assert(#self.unresolved_jumps == 0, "jump to a label that was never placed")
	local chars = {}
	for index, byte in ipairs(self.bytes) do
		chars[index] = string.char(byte)
	end
	return table.concat(chars)
end

return x86
