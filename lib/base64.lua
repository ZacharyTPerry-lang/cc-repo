-- %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
-- lib/base64.lua
-- Base64 encoding for the GitHub Contents
-- API. Encodes Lua strings to base64 for
-- use in JSON PUT request bodies.
-- Decoding is not implemented; not needed
-- for this application.
-- Uses bit32, available in CC:Tweaked.
--
-- Branches : reactor-1, reactor-2,
--            reactor-3, reactor-4,
--            reactor-5, reactor-6,
--            reactor-7, reactor-8,
--            reactor-9, reactor-10
-- Depends  : none
-- %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
--
-- [1] LOOKUP TABLE        ln. 24
-- [2] ENCODE              ln. 43
--
-- %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

-- =========================================
-- [1] LOOKUP TABLE
-- =========================================

-- Pre-computed character table avoids
-- repeated string slicing during encoding.
local LOOKUP = {}
for index = 0, 25 do
    LOOKUP[index] = string.char(65 + index)
end
for index = 26, 51 do
    LOOKUP[index] = string.char(
        97 + index - 26
    )
end
for index = 52, 61 do
    LOOKUP[index] = string.char(
        48 + index - 52
    )
end
LOOKUP[62] = "+"
LOOKUP[63] = "/"

-- =========================================
-- [2] ENCODE
-- =========================================

-- encode_string
-- Accepts any Lua string. Returns the
-- base64 representation padded to a
-- multiple of 4 characters with "=".
local function encode_string(input)
    local output   = {}
    local length   = #input
    local position = 1

    while position <= length do
        local b1 = input:byte(position) or 0
        local b2 =
            input:byte(position + 1) or 0
        local b3 =
            input:byte(position + 2) or 0
        local remaining = length - position + 1

        local combined = bit32.bor(
            bit32.lshift(b1, 16),
            bit32.lshift(b2, 8),
            b3
        )

        local index1 =
            bit32.rshift(combined, 18)
        local index2 = bit32.band(
            bit32.rshift(combined, 12), 63
        )
        local index3 = bit32.band(
            bit32.rshift(combined, 6), 63
        )
        local index4 =
            bit32.band(combined, 63)

        output[#output + 1] = LOOKUP[index1]
        output[#output + 1] = LOOKUP[index2]

        if remaining > 1 then
            output[#output + 1] =
                LOOKUP[index3]
        else
            output[#output + 1] = "="
        end

        if remaining > 2 then
            output[#output + 1] =
                LOOKUP[index4]
        else
            output[#output + 1] = "="
        end

        position = position + 3
    end

    return table.concat(output)
end

return { encode = encode_string }
