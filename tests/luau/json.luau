--!strict
-- A stand-in for `tern.json` in the Luau tests, as tern.d.luau describes it: decoded arrays come back tagged with a
-- protected metatable (so `table.clone` on one raises, as it does in Tern), null object members are dropped, and
-- member order is lost. `encode` writes tables with keys 1..n (or tagged with `array`) as arrays.
local json = {}

local ARRAY_TAG = { __metatable = "tern.json array (test double)" }
local tagged: { [any]: boolean } = setmetatable({}, { __mode = "k" }) :: any

-- Tags `t` as an array, so an empty one encodes as `[]` (as `tern.json.array` does).
function json.array(t: { any }?): { any }
	local out = t or {}
	tagged[out] = true
	return out
end

json.null = setmetatable({}, { __metatable = "tern.json.null (test double)", __tostring = function()
	return "null"
end })

local function is_array(t: { [any]: any }): boolean
	if tagged[t] or getmetatable(t) == ARRAY_TAG.__metatable then
		return true
	end
	local n = 0
	for key in t do
		if type(key) ~= "number" then
			return false
		end
		n += 1
	end
	return n > 0 and n == #t
end

local ESCAPES: { [string]: string } = { ['"'] = '\\"', ["\\"] = "\\\\", ["\b"] = "\\b", ["\f"] = "\\f", ["\n"] = "\\n", ["\r"] = "\\r", ["\t"] = "\\t" }

local function encode_string(s: string): string
	return '"' .. string.gsub(s, '[%c"\\]', function(c: string): string
		return ESCAPES[c] or string.format("\\u%04x", string.byte(c))
	end) .. '"'
end

local function encode_value(value: any, out: { string })
	local kind = type(value)
	if value == nil or value == json.null then
		table.insert(out, "null")
	elseif kind == "boolean" then
		table.insert(out, if value then "true" else "false")
	elseif kind == "number" then
		assert(value == value and value ~= math.huge and value ~= -math.huge, "json.encode: number not finite")
		if value == math.floor(value) and math.abs(value) < 2 ^ 53 then
			table.insert(out, string.format("%d", value))
		else
			table.insert(out, string.format("%.17g", value))
		end
	elseif kind == "string" then
		table.insert(out, encode_string(value))
	elseif kind == "table" then
		if is_array(value) then
			table.insert(out, "[")
			for i = 1, #value do
				if i > 1 then
					table.insert(out, ",")
				end
				encode_value(value[i], out)
			end
			table.insert(out, "]")
		else
			local keys: { string } = {}
			for key in value do
				assert(type(key) == "string", "json.encode: object key is not a string")
				table.insert(keys, key)
			end
			table.sort(keys)
			table.insert(out, "{")
			for i, key in keys do
				if i > 1 then
					table.insert(out, ",")
				end
				table.insert(out, encode_string(key))
				table.insert(out, ":")
				encode_value(value[key], out)
			end
			table.insert(out, "}")
		end
	else
		error("json.encode: can't encode a " .. kind)
	end
end

function json.encode(value: any, _pretty: boolean?): string
	local out: { string } = {}
	encode_value(value, out)
	return table.concat(out)
end

local function utf8_of(code: number): string
	return utf8.char(code)
end

-- Decodes `text`; raises on malformed input, as `tern.json.decode` does (callers pcall it).
function json.decode(text: string): any
	local pos = 1
	local len = #text
	local function fail(what: string): never
		error(string.format("json.decode: %s at byte %d", what, pos))
	end
	local function skip()
		local _, last = string.find(text, "^[ \t\r\n]*", pos)
		pos = (last :: number) + 1
	end
	local value: () -> any
	local function str(): string
		pos += 1 -- the opening quote
		local parts: { string } = {}
		while true do
			if pos > len then
				fail("unterminated string")
			end
			local c = string.sub(text, pos, pos)
			if c == '"' then
				pos += 1
				return table.concat(parts)
			elseif c == "\\" then
				local e = string.sub(text, pos + 1, pos + 1)
				local simple = ({ ['"'] = '"', ["\\"] = "\\", ["/"] = "/", b = "\b", f = "\f", n = "\n", r = "\r", t = "\t" } :: { [string]: string })[e]
				if simple then
					table.insert(parts, simple)
					pos += 2
				elseif e == "u" then
					local hex = string.sub(text, pos + 2, pos + 5)
					local code = tonumber(hex, 16)
					if code == nil or #hex ~= 4 then
						fail("bad \\u escape")
					end
					pos += 6
					local cp = code :: number
					if cp >= 0xD800 and cp <= 0xDBFF and string.sub(text, pos, pos + 1) == "\\u" then
						local low = tonumber(string.sub(text, pos + 2, pos + 5), 16)
						if low and low >= 0xDC00 and low <= 0xDFFF then
							cp = 0x10000 + (cp - 0xD800) * 0x400 + (low - 0xDC00)
							pos += 6
						end
					end
					table.insert(parts, utf8_of(cp))
				else
					fail("bad escape")
				end
			else
				local _, last = string.find(text, '^[^"\\]+', pos)
				table.insert(parts, string.sub(text, pos, last :: number))
				pos = (last :: number) + 1
			end
		end
	end
	value = function(): any
		skip()
		local c = string.sub(text, pos, pos)
		if c == "{" then
			pos += 1
			local obj: { [string]: any } = {}
			skip()
			if string.sub(text, pos, pos) == "}" then
				pos += 1
				return obj
			end
			while true do
				skip()
				if string.sub(text, pos, pos) ~= '"' then
					fail("expected a key")
				end
				local key = str()
				skip()
				if string.sub(text, pos, pos) ~= ":" then
					fail("expected ':'")
				end
				pos += 1
				local item = value()
				if item ~= json.null then -- null members are dropped
					obj[key] = item
				end
				skip()
				local sep = string.sub(text, pos, pos)
				pos += 1
				if sep == "}" then
					return obj
				elseif sep ~= "," then
					fail("expected ',' or '}'")
				end
			end
		elseif c == "[" then
			pos += 1
			local arr: { any } = {}
			skip()
			if string.sub(text, pos, pos) == "]" then
				pos += 1
				return setmetatable(arr, ARRAY_TAG)
			end
			while true do
				table.insert(arr, value())
				skip()
				local sep = string.sub(text, pos, pos)
				pos += 1
				if sep == "]" then
					return setmetatable(arr, ARRAY_TAG)
				elseif sep ~= "," then
					fail("expected ',' or ']'")
				end
			end
		elseif c == '"' then
			return str()
		elseif string.sub(text, pos, pos + 3) == "true" then
			pos += 4
			return true
		elseif string.sub(text, pos, pos + 4) == "false" then
			pos += 5
			return false
		elseif string.sub(text, pos, pos + 3) == "null" then
			pos += 4
			return json.null
		end
		local number = string.match(text, "^-?%d+%.?%d*[eE]?[-+]?%d*", pos)
		if number == nil or number == "" then
			fail("unexpected character")
		end
		pos += #(number :: string)
		local n = tonumber(number)
		if n == nil then
			fail("bad number")
		end
		return n
	end
	local result = value()
	skip()
	if pos <= len then
		fail("trailing characters")
	end
	return if result == json.null then nil else result
end

return json
