-- platform/urls.lua
--
-- Tiny shared URL helpers (used by tabs_jumper and usage_stats).

local urls = {}

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
