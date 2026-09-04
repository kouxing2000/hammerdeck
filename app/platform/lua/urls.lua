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

-- "https://user@sub.host.tld:8443/path?q" -> "sub.host.tld". nil for non-http
-- URLs, localhost, or anything that does not look like a host.
--
-- Peel userinfo and port, then REJECT whatever is left if it is not host-shaped.
-- Rejecting matters more here than in most parsers: the result is not merely
-- displayed, it is PERSISTED -- as the `context` column of the user's daily usage
-- CSV and as a favicon cache filename. Deleting the stray bytes instead folded
-- them into the name, so `host.com:8443` was recorded as `host.com8443`.
---@param url string|nil
---@return string|nil
function urls.getDomain(url)
    if not url or url:sub(1, 4) ~= "http" then return nil end
    local authority = (url .. "/"):match("://(.-)/")
    if not authority then return nil end
    local host = authority:match("@(.*)$") or authority   -- drop user:pass@
    host = host:match("^([^:]*)") or ""                   -- drop :port
    if host == "" or host:find("[^%w%-_%.]") then return nil end
    -- Equality/suffix, not `find`: a substring test also rejected the perfectly
    -- ordinary `notlocalhost.com`.
    if host == "localhost" or host:find("%.localhost$") then return nil end
    return host
end

return urls
