local redis        = require "resty.redis"
local master_cache = ngx.shared.redis_master_cache

local RATE_LIMIT  = tonumber(os.getenv("RATE_LIMIT"))  or 100
local RATE_BURST  = tonumber(os.getenv("RATE_BURST"))  or 20
local WINDOW_MS   = 60 * 1000
local EFFECTIVE   = RATE_LIMIT + RATE_BURST  -- 120

local REDIS_MODE  = os.getenv("REDIS_MODE") or "sentinel"
local MASTER_NAME = os.getenv("SENTINEL_MASTER_NAME") or "mymaster"
local SENTINELS   = {
    { host = os.getenv("SENTINEL_HOST_1") or "sentinel-1", port = 26379 },
    { host = os.getenv("SENTINEL_HOST_2") or "sentinel-2", port = 26379 },
    { host = os.getenv("SENTINEL_HOST_3") or "sentinel-3", port = 26379 },
}
local MASTER_TTL = 30  -- seconds to cache the discovered master address

-- ── Sentinel discovery ────────────────────────────────────────────────────────

local function discover_master()
    local cached_host = master_cache:get("host")
    local cached_port = master_cache:get("port")
    if cached_host and cached_port then
        return cached_host, tonumber(cached_port)
    end

    for _, s in ipairs(SENTINELS) do
        local sentinel = redis:new()
        sentinel:set_timeout(200)
        local ok = sentinel:connect(s.host, s.port)
        if ok then
            local res = sentinel:sentinel("get-master-addr-by-name", MASTER_NAME)
            sentinel:close()
            if res and type(res) == "table" and res[1] and res[2] then
                local host, port = res[1], tonumber(res[2])
                master_cache:set("host", host, MASTER_TTL)
                master_cache:set("port", tostring(port), MASTER_TTL)
                return host, port
            end
        end
    end
    return nil, nil, "no sentinel available"
end

-- ── Redis connection ──────────────────────────────────────────────────────────

local function get_redis()
    local red = redis:new()
    red:set_timeout(200)

    local host, port, err
    if REDIS_MODE == "direct" then
        host = os.getenv("REDIS_PRIMARY_HOST") or "localhost"
        port = 6379
    else
        host, port, err = discover_master()
        if not host then
            return nil, err or "sentinel discovery failed"
        end
    end

    local ok, conn_err = red:connect(host, port)
    if not ok then
        return nil, conn_err
    end
    return red
end

local function release_redis(red)
    local ok, err = red:set_keepalive(60000, 50)
    if not ok then
        red:close()
    end
end

-- ── Sliding-window rate limit ─────────────────────────────────────────────────

local client_ip    = ngx.var.remote_addr
local now_ms       = ngx.now() * 1000
local window_start = now_ms - WINDOW_MS
local key          = "rl:" .. client_ip
local member       = tostring(now_ms) .. ":" .. tostring(math.random(1, 999999))

local red, err = get_redis()
if not red then
    ngx.log(ngx.WARN, "rate_limit: Redis unavailable, failing open: ", err)
    return
end

red:init_pipeline(4)
red:zadd(key, now_ms, member)
red:zremrangebyscore(key, "-inf", window_start)
red:zcard(key)
red:expire(key, 61)

local results, pipe_err = red:commit_pipeline()
if pipe_err then
    master_cache:delete("host")
    master_cache:delete("port")
    red:close()
    ngx.log(ngx.WARN, "rate_limit: pipeline error, failing open: ", pipe_err)
    return
end

release_redis(red)

local count = results[3]
if type(count) ~= "number" then
    ngx.log(ngx.WARN, "rate_limit: unexpected zcard result, failing open")
    return
end

local reset_epoch = math.ceil((now_ms + WINDOW_MS) / 1000)

ngx.header["X-RateLimit-Limit"]     = tostring(RATE_LIMIT)
ngx.header["X-RateLimit-Remaining"] = tostring(math.max(0, EFFECTIVE - count))
ngx.header["X-RateLimit-Reset"]     = tostring(reset_epoch)

if count > EFFECTIVE then
    ngx.header["Retry-After"]  = "60"
    ngx.header["Content-Type"] = "application/json"
    ngx.status = ngx.HTTP_TOO_MANY_REQUESTS
    ngx.say('{"error":"rate limit exceeded","retry_after":60}')
    ngx.exit(ngx.HTTP_TOO_MANY_REQUESTS)
end
