-- platform/urls.lua
--
-- Tiny shared URL helpers (used by tab_switcher, usage_stats, text_actions).

local urls = {}

-- RFC 3986 percent-encode for a single URL path/query component. Encodes every
-- byte except the unreserved set (A-Z a-z 0-9 - _ . ~) -- so spaces, punctuation
-- and multi-byte UTF-8 (e.g. CJK words) survive a dict:// / query round-trip.
-- Encodes per BYTE (gsub matches one byte at a time), which is the correct
-- per-octet UTF-8 encoding. Parens drop gsub's count return.
---@param s string|number
---@return string
function urls.encodeComponent(s)
    return (tostring(s):gsub("[^%w%-_%.~]", function(c)
        return string.format("%%%02X", string.byte(c))
    end))
end

-- "https://sub.host.tld/path?q" -> "sub.host.tld". nil for non-http URLs,
-- localhost, or anything that does not look like a host.
function urls.getDomain(url)
    if not url or url:sub(1, 4) ~= "http" then return nil end
    local domain = (url .. "/"):match("://(.-)/")
    if not domain then return nil end
    domain = domain:gsub("[^%w%-_%.]", "")
    if domain == "" or domain:find("localhost") then return nil end
    return domain
end

return urls
