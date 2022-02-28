--
-- Created by IntelliJ IDEA.
-- User: libin
-- Date: 2020/6/9
-- Time: 16:07
-- To change this template use File | Settings | File Templates.
-- 可以实现自动将访问频次过高的IP地址加入黑名单封禁一段时间

--连接池超时回收毫秒
local pool_max_idle_time = 10000
--连接池大小
local pool_size = 100
--redis 连接超时时间
local redis_connection_timeout = 100
--redis host
local redis_host = "127.0.0.1"
--redis port
local redis_port = "6379"
--redis auth
local redis_auth = "123456789";
--封禁IP时间（秒）
local ip_block_time= 120
--指定ip访问频率时间段（秒）
local ip_time_out = 1
--指定ip访问频率计数最大值（次）
local ip_max_count = 3


--  错误日志记录
local function errlog(msg, ex)
    ngx.log(ngx.ERR, msg, ex)
end

-- 释放连接池
local function close_redis(red)
    if not red then
        return
    end
    local ok, err = red:set_keepalive(pool_max_idle_time, pool_size)
    if not ok then
        ngx.say("redis connct err:",err)
        return red:close()
    end
end


--连接redis
local redis = require "resty.redis"
local client = redis:new()
local ok, err = client:connect(redis_host, redis_port)
-- 连接失败返回服务器错误
if not ok then
    close_redis(client)
    ngx.exit(ngx.HTTP_INTERNAL_SERVER_ERROR)
end
--设置超时时间
client:set_timeout(redis_connection_timeout)

-- 优化验证密码操作 代表连接在连接池使用的次数，如果为0代表未使用，不为0代表复用 在只有为0时才进行密码校验
local connCount, err = client:get_reused_times()
-- 新建连接，需要认证密码
if  0 == connCount then
    local ok, err = client:auth(redis_auth)
    if not ok then
        errlog("failed to auth: ", err)
        return
    end
    --从连接池中获取连接，无需再次认证密码
elseif err then
    errlog("failed to get reused times: ", err)
    return
end

-- 获取请求ip
local function getIp()
    local clientIP = ngx.req.get_headers()["X-Real-IP"]
    if clientIP == nil then
        clientIP = ngx.req.get_headers()["x_forwarded_for"]
    end
    if clientIP == nil then
        clientIP = ngx.var.remote_addr
    end
    return clientIP
end

local cliendIp = getIp();

local incrKey = "limit:count:"..cliendIp
local blockKey = "limit:block:"..cliendIp

--查询ip是否被禁止访问，如果存在则返回403错误代码
local is_block,err = client:get(blockKey)
if tonumber(is_block) == 1 then
    ngx.exit(ngx.HTTP_FORBIDDEN)
    close_redis(client)
end

local ip_count, err = client:incr(incrKey)
if tonumber(ip_count) == 1 then
    client:expire(incrKey,ip_time_out)
end
--如果超过单位时间限制的访问次数，则添加限制访问标识，限制时间为ip_block_time
if tonumber(ip_count) > tonumber(ip_max_count) then
    client:set(blockKey,1)
    client:expire(blockKey,ip_block_time)
end

close_redis(client)
