--[[
    Animedimensions - improved executor-safe loader
    ------------------------------------------------------------
    What this does:
      * Loads the original Animedimensions payload from a list of mirrors.
      * Adds executor compatibility shims (only for globals that are missing).
      * Adds auto-reconnect, including re-joining the same private server.
      * Optionally re-queues the loader after a teleport (executor feature).

    IMPORTANT:
      The Animedimensions payload is obfuscated (MoonSec V3 + Luraph VM).
      It makes HTTP calls (HttpService GetAsync/PostAsync/RequestAsync) and
      calls identifyexecutor(). Only run this if you trust the source.

    SETUP:
      1. Paste your private server link into CONFIG.PRIVATE_SERVER_LINK.
      2. Run this file with your executor.
]]

local CONFIG = {
    -- Example:
    -- "https://www.roblox.com/games/1234567890/Anime-Dimensions?privateServerLinkCode=ABCDEF..."
    PRIVATE_SERVER_LINK = "",

    -- Optional: paste the server's gameInstanceId here if you know it.
    -- (A normal private-server link only contains a link code, not this id.)
    PRIVATE_SERVER_INSTANCE_ID = "",

    -- Optional: the private server's id used by TeleportToPrivateServer.
    PRIVATE_SERVER_ID = "",

    -- Used only when PRIVATE_SERVER_LINK has no place id.
    PLACE_ID = nil,

    AUTO_RECONNECT = true,
    RECONNECT_DELAY = 5,
    MAX_RECONNECT_ATTEMPTS = 0, -- 0 = unlimited

    -- Prefer re-joining the server we are currently in (best for private servers).
    REJOIN_CURRENT_SERVER = true,

    -- Re-run this loader after a teleport, when the executor supports it.
    QUEUE_ON_TELEPORT = true,

    -- Mirrors are tried in order.
    SCRIPT_URLS = {
        "https://raw.githubusercontent.com/Yanwanlnwza/SmellLikeHacker/main/Animedimensions.lua",
        "https://cdn.jsdelivr.net/gh/Yanwanlnwza/SmellLikeHacker@main/Animedimensions.lua",
        "https://raw.githack.com/Yanwanlnwza/SmellLikeHacker/main/Animedimensions.lua",
    },

    VERBOSE = true,
}

local function log(...)
    if not CONFIG.VERBOSE then
        return
    end
    local ok = pcall(warn, "[Animedimensions]", ...)
    if not ok then
        print("[Animedimensions]", ...)
    end
end

local genv = (getgenv and getgenv()) or _G

local function getService(name)
    local ok, service = pcall(function()
        return game:GetService(name)
    end)
    return ok and service or nil
end

-- ---------------------------------------------------------------------------
-- Compatibility shims (never overwrite an existing global)
-- ---------------------------------------------------------------------------

local function ensure(name, value)
    if genv[name] == nil then
        local ok = pcall(function()
            genv[name] = value
        end)
        if not ok then
            log("Could not install compatibility shim for '" .. name .. "'")
        end
    end
end

if genv.unpack == nil and table.unpack then
    ensure("unpack", table.unpack)
end

local function fallbackSpawn(fn, ...)
    local co = coroutine.create(fn)
    coroutine.resume(co, ...)
end

local function fallbackDelay(seconds, fn, ...)
    local args = table.pack(...)
    local co = coroutine.create(function()
        if wait then
            wait(seconds)
        end
        fn(table.unpack(args, 1, args.n))
    end)
    coroutine.resume(co)
end

if genv.task == nil then
    ensure("task", {
        wait = wait or function() end,
        spawn = spawn or fallbackSpawn,
        delay = delay or fallbackDelay,
        defer = delay or fallbackDelay,
        cancel = function() end,
    })
end

if genv.islclosure == nil then
    ensure("islclosure", function(fn)
        if type(fn) ~= "function" then
            return false
        end
        local ok, dumped = pcall(string.dump, fn)
        return ok and dumped ~= nil
    end)
end

if genv.iscclosure == nil then
    ensure("iscclosure", function(fn)
        if type(fn) ~= "function" then
            return false
        end
        local isl = genv.islclosure
        return not (isl and isl(fn))
    end)
end

if genv.identifyexecutor == nil then
    ensure("identifyexecutor", function()
        return "Unknown"
    end)
end

if genv.getgenv == nil then
    ensure("getgenv", function()
        return genv
    end)
end

if genv.typeof == nil then
    ensure("typeof", function(value)
        return type(value)
    end)
end

if genv.warn == nil then
    ensure("warn", function(...)
        print(...)
    end)
end

if genv.bit32 == nil and genv.bit ~= nil then
    local bit = genv.bit
    local function countlz(value)
        value = value % 4294967296
        if value == 0 then
            return 32
        end
        local count = 0
        for i = 31, 0, -1 do
            if value >= 2 ^ i then
                break
            end
            count = count + 1
        end
        return count
    end
    local function countrz(value)
        value = value % 4294967296
        if value == 0 then
            return 32
        end
        local count = 0
        while value % 2 == 0 do
            value = math.floor(value / 2)
            count = count + 1
        end
        return count
    end
    ensure("bit32", {
        band = bit.band,
        bor = bit.bor,
        bxor = bit.bxor,
        bnot = bit.bnot,
        lshift = bit.lshift,
        rshift = bit.rshift,
        arshift = bit.arshift,
        lrotate = bit.lrotate,
        rrotate = bit.rrotate,
        btest = bit.btest,
        extract = bit.extract,
        replace = bit.replace,
        countlz = countlz,
        countrz = countrz,
    })
end

if genv.buffer == nil then
    log("This executor is missing the Luau 'buffer' library; the payload may fail to run.")
end

if genv.string and genv.string.pack == nil then
    log("This executor is missing string.pack; the payload may fail to run.")
end

local taskLib = genv.task or {
    wait = wait or function() end,
    spawn = spawn or fallbackSpawn,
    delay = delay or fallbackDelay,
    defer = delay or fallbackDelay,
}

-- ---------------------------------------------------------------------------
-- HTTP
-- ---------------------------------------------------------------------------

local function httpGet(url)
    if game and type(game.HttpGet) == "function" then
        local ok, response = pcall(game.HttpGet, game, url)
        if ok and type(response) == "string" then
            return response
        end
    end

    local request = genv.request
        or genv.http_request
        or (genv.syn and genv.syn.request)
        or (genv.http and genv.http.request)

    if type(request) == "function" then
        local ok, response = pcall(request, { Url = url, Method = "GET" })
        if ok and response then
            if type(response) == "string" then
                return response
            end
            if type(response.Body) == "string" then
                return response.Body
            end
            if type(response.body) == "string" then
                return response.body
            end
        end
    end

    local httpget = genv.httpget or (genv.syn and genv.syn.httpget)
    if type(httpget) == "function" then
        local ok, response = pcall(httpget, url)
        if ok and type(response) == "string" then
            return response
        end
    end

    error("No HTTP GET implementation is available in this executor")
end

local function compile(source, chunkName)
    local loader = genv.loadstring or loadstring or genv.load or load
    if type(loader) ~= "function" then
        error("This executor does not expose loadstring/load")
    end
    local fn, err = loader(source, chunkName)
    if type(fn) ~= "function" then
        error("Payload failed to compile: " .. tostring(err))
    end
    return fn
end

-- ---------------------------------------------------------------------------
-- Auto reconnect
-- ---------------------------------------------------------------------------

local reconnect = {
    attempts = 0,
    busy = false,
    scheduled = false,
    stopped = false,
}

local function stillConnected()
    local Players = getService("Players")
    local player = Players and Players.LocalPlayer
    return player ~= nil and player.Parent ~= nil and player:IsDescendantOf(game)
end

local function parsePrivateServerLink(link)
    if type(link) ~= "string" or link == "" then
        return nil
    end
    local placeId = link:match("games/(%d+)") or link:match("placeId=(%d+)")
    local instanceId = link:match("gameInstanceId=([%w%%%-_]+)")
    local linkCode = link:match("privateServerLinkCode=([%w%%%-_]+)")
        or link:match("[?&]code=([%w%%%-_]+)")
    return {
        placeId = placeId and tonumber(placeId) or nil,
        instanceId = instanceId,
        linkCode = linkCode,
    }
end

local function rejoin()
    if reconnect.busy or reconnect.stopped then
        return
    end
    reconnect.busy = true

    local Players = getService("Players")
    local TeleportService = getService("TeleportService")
    local player = Players and Players.LocalPlayer
    if not (player and TeleportService) then
        reconnect.busy = false
        return
    end

    local info = parsePrivateServerLink(CONFIG.PRIVATE_SERVER_LINK)
    local placeId = (info and info.placeId) or CONFIG.PLACE_ID or game.PlaceId

    local function attempt(label, method, ...)
        local ok, err = pcall(method, TeleportService, ...)
        if ok then
            log("Reconnect via " .. label .. " started")
            return true
        end
        log("Reconnect via " .. label .. " failed: " .. tostring(err))
        return false
    end

    local ok = false
    local instanceId = (info and info.instanceId) or CONFIG.PRIVATE_SERVER_INSTANCE_ID

    if not ok and instanceId and instanceId ~= "" then
        ok = attempt("link instance id", TeleportService.TeleportToPlaceInstance, placeId, instanceId, player)
    end

    if not ok and CONFIG.REJOIN_CURRENT_SERVER and game.JobId and game.JobId ~= "" then
        ok = attempt("current server", TeleportService.TeleportToPlaceInstance, placeId, game.JobId, player)
    end

    local privateServerId = CONFIG.PRIVATE_SERVER_ID
    if not ok and privateServerId and privateServerId ~= "" then
        ok = attempt("private server id", TeleportService.TeleportToPrivateServer, placeId, privateServerId, { player })
    end

    if not ok and info and info.linkCode then
        ok = attempt("link code", TeleportService.TeleportToPrivateServer, placeId, info.linkCode, { player })
    end

    if not ok then
        ok = attempt("public server", TeleportService.Teleport, placeId, player)
    end

    reconnect.busy = false
    if not ok then
        reconnect.stopped = true
    end
end

local function scheduleReconnect(reason)
    if not CONFIG.AUTO_RECONNECT or reconnect.stopped or reconnect.busy or reconnect.scheduled then
        return
    end

    reconnect.attempts = reconnect.attempts + 1
    if CONFIG.MAX_RECONNECT_ATTEMPTS > 0 and reconnect.attempts > CONFIG.MAX_RECONNECT_ATTEMPTS then
        reconnect.stopped = true
        log("Maximum reconnect attempts reached")
        return
    end

    reconnect.scheduled = true
    log("Disconnect detected (" .. tostring(reason) .. "); reconnecting in " .. tostring(CONFIG.RECONNECT_DELAY) .. "s")

    taskLib.delay(CONFIG.RECONNECT_DELAY, function()
        reconnect.scheduled = false
        if stillConnected() then
            log("Player is still connected; skipping reconnect")
            return
        end
        rejoin()
    end)
end

local function startAutoReconnect()
    if not CONFIG.AUTO_RECONNECT then
        return
    end

    local Players = getService("Players")
    local RunService = getService("RunService")
    local TeleportService = getService("TeleportService")
    if not Players then
        return
    end

    local player = Players.LocalPlayer
    if not player then
        return
    end

    if player.AncestryChanged then
        player.AncestryChanged:Connect(function()
            if not player:IsDescendantOf(game) then
                scheduleReconnect("AncestryChanged")
            end
        end)
    end

    if Players.PlayerRemoving then
        Players.PlayerRemoving:Connect(function(leaving)
            if leaving == player then
                scheduleReconnect("PlayerRemoving")
            end
        end)
    end

    if RunService then
        taskLib.spawn(function()
            while not reconnect.stopped do
                taskLib.wait(1)
                if not player.Parent or not player:IsDescendantOf(game) then
                    scheduleReconnect("heartbeat")
                    break
                end
            end
        end)
    end

    if TeleportService and TeleportService.TeleportInitFailed then
        TeleportService.TeleportInitFailed:Connect(function(_, result, err)
            log("TeleportInitFailed: " .. tostring(result) .. " " .. tostring(err))
            scheduleReconnect("TeleportInitFailed")
        end)
    end
end

local function setupQueueOnTeleport()
    if not CONFIG.QUEUE_ON_TELEPORT then
        return
    end

    local queueOnTeleport = genv.queue_on_teleport
        or (genv.syn and genv.syn.queue_on_teleport)
        or (genv.fluxus and genv.fluxus.queue_on_teleport)

    if type(queueOnTeleport) ~= "function" then
        return
    end

    local url = CONFIG.SCRIPT_URLS[1]
    local source = string.format("loadstring(game:HttpGet(%q))()", url)
    local ok, err = pcall(queueOnTeleport, source)
    if not ok then
        log("queue_on_teleport failed: " .. tostring(err))
    end
end

-- ---------------------------------------------------------------------------
-- Payload
-- ---------------------------------------------------------------------------

local function loadPayload()
    local lastError
    for _, url in ipairs(CONFIG.SCRIPT_URLS) do
        local ok, source = pcall(httpGet, url)
        if ok and type(source) == "string" and #source > 0 then
            log("Downloaded payload from " .. url .. " (" .. tostring(#source) .. " bytes)")
            local fn = compile(source, "=Animedimensions")
            return fn()
        end
        lastError = source
    end
    error("Unable to download the Animedimensions payload: " .. tostring(lastError))
end

local ok, err = pcall(function()
    startAutoReconnect()
    setupQueueOnTeleport()
    return loadPayload()
end)

if not ok then
    log("Payload error: " .. tostring(err))
end
