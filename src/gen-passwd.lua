#!/usr/bin/env lua5.4
-- Password Generator

-- Usage: gen-passwd.lua <length>
if #arg > 1 or #arg < 1 or arg[1]:match('%D') then
	io.stderr:write('Usage: gen-passwd.lua <length>\n')
	os.exit(1)
end local chars, pass = table.pack({}, {}, {}, {}), {}

-- Get the ASCII printable characters (32-126)
for i = 32, 126 do
	local c = string.char(i)
	table.insert(chars[(c:match('%l') and 1)
	or (c:match('%u') and 2) or (c:match('%d') and 3) or 4], c)
end

-- Generate a random number from '/dev/urandom'
local function urandom(range)
	local n, sum, file, bytes = 4, 0
	file = assert(io.open('/dev/urandom', 'rb'))
	bytes = table.pack(assert(file:read(n)):byte(1, n))
	assert(file:close())

	for i, byte in ipairs(bytes) do
		sum = sum + byte * (2 ^ ((i - 1) * 8))
	end return sum % range + 1
end

-- Fisher-Yates shuffle algorithm
local function shuffle(tb)
	for i = #tb, 2, -1 do
		local j = urandom(i)
		tb[i], tb[j] = tb[j], tb[i]
	end return tb
end

-- Generate password
for i = 1, tonumber(arg[1]) do
	local subchars = shuffle(shuffle(chars)[urandom(#chars)])
	table.insert(pass, subchars[urandom(#subchars)])
end io.stdout:write(table.concat(pass) .. '\n')
