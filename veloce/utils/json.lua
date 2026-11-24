local json = {}

local controlEscapes = {
    ["\b"] = "\\b",
    ["\f"] = "\\f",
    ["\n"] = "\\n",
    ["\r"] = "\\r",
    ["\t"] = "\\t"
}

local function escapeString(value)
    return value
        :gsub("\\", "\\\\")
        :gsub('"', '\\"')
        :gsub("[%z\1-\31]", function(char)
            return controlEscapes[char] or ("\\u%04x"):format(char:byte())
        end)
end

local function isArray(value)
    local count = 0

    for key in pairs(value) do
        if type(key) ~= "number" or key < 1 or key % 1 ~= 0 then
            return false
        end

        count = count + 1
    end

    for i = 1, count do
        if value[i] == nil then
            return false
        end
    end

    return true
end

local function encodeValue(value)
    local valueType = type(value)

    if value == nil then
        return "null"
    end

    if valueType == "string" then
        return '"' .. escapeString(value) .. '"'
    end

    if valueType == "number" then
        if value ~= value or value == math.huge or value == -math.huge then
            error("Cannot encode NaN or Infinity as JSON")
        end

        return tostring(value)
    end

    if valueType == "boolean" then
        return value and "true" or "false"
    end

    if valueType == "table" then
        local result = {}

        if isArray(value) then
            for i = 1, #value do
                result[#result + 1] = encodeValue(value[i])
            end

            return "[" .. table.concat(result, ",") .. "]"
        end

        for key, item in pairs(value) do
            if type(key) ~= "string" then
                error("JSON object keys must be strings")
            end

            result[#result + 1] =
                '"' .. escapeString(key) .. '":' .. encodeValue(item)
        end

        return "{" .. table.concat(result, ",") .. "}"
    end

    error("Unsupported type: " .. valueType)
end

function json.encode(value)
    return encodeValue(value)
end

function json.decode(input)
    if type(input) ~= "string" then
        error("json.decode expects a string")
    end

    local position = 1
    local length = #input

    local function skipWhitespace()
        while position <= length do
            local char = input:sub(position, position)

            if char == " "
                or char == "\t"
                or char == "\n"
                or char == "\r"
            then
                position = position + 1
            else
                break
            end
        end
    end

    local parseValue

    local function parseString()
        position = position + 1

        local result = {}

        while position <= length do
            local char = input:sub(position, position)

            if char == '"' then
                position = position + 1
                return table.concat(result)
            end

            if char == "\\" then
                position = position + 1

                if position > length then
                    error("Invalid JSON string")
                end

                local escaped = input:sub(position, position)

                local replacements = {
                    ['"'] = '"',
                    ["\\"] = "\\",
                    ["/"] = "/",
                    ["b"] = "\b",
                    ["f"] = "\f",
                    ["n"] = "\n",
                    ["r"] = "\r",
                    ["t"] = "\t"
                }

                if replacements[escaped] then
                    result[#result + 1] = replacements[escaped]
                    position = position + 1

                elseif escaped == "u" then
                    local hex = input:sub(position + 1, position + 4)

                    if not hex:match("^%x%x%x%x$") then
                        error("Invalid Unicode escape")
                    end

                    local code = tonumber(hex, 16)

                    if code < 0x80 then
                        result[#result + 1] = string.char(code)

                    elseif code < 0x800 then
                        result[#result + 1] = string.char(
                            0xC0 + math.floor(code / 0x40),
                            0x80 + code % 0x40
                        )

                    else
                        result[#result + 1] = string.char(
                            0xE0 + math.floor(code / 0x1000),
                            0x80 + math.floor(code / 0x40) % 0x40,
                            0x80 + code % 0x40
                        )
                    end

                    position = position + 5

                else
                    error("Invalid escape sequence: \\" .. escaped)
                end

            else
                if char:byte() < 0x20 then
                    error("Unescaped control character in JSON string")
                end

                result[#result + 1] = char
                position = position + 1
            end
        end

        error("Unterminated JSON string")
    end

    local function parseNumber()
        local start = position
        local char = input:sub(position, position)

        if char == "-" then
            position = position + 1
        end

        char = input:sub(position, position)
        if char == "0" then
            position = position + 1
            if input:sub(position, position):match("%d") then
                error("Invalid JSON number at position " .. start)
            end
        elseif char:match("[1-9]") then
            repeat
                position = position + 1
                char = input:sub(position, position)
            until not char:match("%d")
        else
            error("Invalid JSON number at position " .. start)
        end

        if input:sub(position, position) == "." then
            position = position + 1
            if not input:sub(position, position):match("%d") then
                error("Invalid JSON number at position " .. start)
            end
            repeat
                position = position + 1
            until not input:sub(position, position):match("%d")
        end

        char = input:sub(position, position)
        if char == "e" or char == "E" then
            position = position + 1
            char = input:sub(position, position)
            if char == "+" or char == "-" then
                position = position + 1
            end
            if not input:sub(position, position):match("%d") then
                error("Invalid JSON number at position " .. start)
            end
            repeat
                position = position + 1
            until not input:sub(position, position):match("%d")
        end

        local number = input:sub(start, position - 1)

        local value = tonumber(number)

        if value == nil then
            error("Invalid JSON number")
        end

        return value
    end

    local function parseArray()
        position = position + 1

        local result = {}

        skipWhitespace()

        if input:sub(position, position) == "]" then
            position = position + 1
            return result
        end

        while true do
            skipWhitespace()

            result[#result + 1] = parseValue()

            skipWhitespace()

            local char = input:sub(position, position)

            if char == "]" then
                position = position + 1
                return result
            end

            if char ~= "," then
                error("Expected ',' or ']' at position " .. position)
            end

            position = position + 1
        end
    end

    local function parseObject()
        position = position + 1

        local result = {}

        skipWhitespace()

        if input:sub(position, position) == "}" then
            position = position + 1
            return result
        end

        while true do
            skipWhitespace()

            if input:sub(position, position) ~= '"' then
                error("Expected string key at position " .. position)
            end

            local key = parseString()

            skipWhitespace()

            if input:sub(position, position) ~= ":" then
                error("Expected ':' at position " .. position)
            end

            position = position + 1

            skipWhitespace()

            result[key] = parseValue()

            skipWhitespace()

            local char = input:sub(position, position)

            if char == "}" then
                position = position + 1
                return result
            end

            if char ~= "," then
                error("Expected ',' or '}' at position " .. position)
            end

            position = position + 1
        end
    end

    local function parseLiteral(literal, value)
        if input:sub(position, position + #literal - 1) ~= literal then
            error("Invalid JSON at position " .. position)
        end

        position = position + #literal

        return value
    end

    parseValue = function()
        skipWhitespace()

        local char = input:sub(position, position)

        if char == '"' then
            return parseString()
        end

        if char == "{" then
            return parseObject()
        end

        if char == "[" then
            return parseArray()
        end

        if char == "t" then
            return parseLiteral("true", true)
        end

        if char == "f" then
            return parseLiteral("false", false)
        end

        if char == "n" then
            return parseLiteral("null", nil)
        end

        if char:match("[%d%-]") then
            return parseNumber()
        end

        error("Unexpected character at position " .. position)
    end

    local result = parseValue()

    skipWhitespace()

    if position <= length then
        error("Unexpected data at position " .. position)
    end

    return result
end


return json
