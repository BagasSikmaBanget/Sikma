--[[
    Animedimensions - improved executor-safe loader
    ------------------------------------------------------------
    What this does:
      * Loads the original Animedimensions payload from a list of mirrors.
      * Adds executor compatibility shims (only for globals that are missing).
      * Adds auto-reconnect, including re-joining the same private server.
      * Optionally re-queues the loader after a teleport (executor feature).
      * Patches the payload UI at runtime: red accents become black, and a
        "Private Server" tab is added inside the script's own menu.

    NOTE ON THE UI PATCH:
      The payload's GUI is compiled by a VM, so it cannot be edited directly.
      The patch works by inspecting PlayerGui after the payload loads: it walks
      the GUI tree, converts red colors to black, finds the tab bar, clones one
      tab button, and injects a Private Server panel next to the existing tabs.
      It is heuristic: if the menu layout is very unusual the tab is skipped
      (the rest of the loader still works). Set CONFIG.PATCH_UI = false to
      disable it entirely.

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

    -- Post-load UI patch (the payload's GUI is obfuscated, so it is patched at runtime).
    PATCH_UI = true,
    RECOLOR_RED_TO_BLACK = true,
    -- Text that was red on a dark surface becomes this color instead of black,
    -- otherwise it would be invisible on the new black background.
    TEXT_ON_DARK = "white",
    -- How long to keep looking for the payload GUI before giving up (seconds).
    UI_PATCH_TIMEOUT = 60,

    -- Mirrors are tried in order.
    SCRIPT_URLS = {
        "https://raw.githubusercontent.com/Yanwanlnwza/SmellLikeHacker/main/Animedimensions.lua",
        "https://cdn.jsdelivr.net/gh/Yanwanlnwza/SmellLikeHacker@main/Animedimensions.lua",
        "https://raw.githack.com/Yanwanlnwza/SmellLikeHacker/main/Animedimensions.lua",
    },

    VERBOSE = true,
}

local genv = (getgenv and getgenv()) or _G

local uiStatus

local function log(...)
    if not CONFIG.VERBOSE then
        return
    end
    local warnFn = genv.warn or warn
    if type(warnFn) ~= "function" then
        warnFn = print
    end
    local ok = pcall(warnFn, "[Animedimensions]", ...)
    if not ok then
        print("[Animedimensions]", ...)
    end
    if uiStatus then
        local parts = {}
        for i = 1, select("#", ...) do
            parts[i] = tostring((select(i, ...)))
        end
        pcall(uiStatus, table.concat(parts, " "))
    end
end

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
    local shim = {
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
        countlz = countlz,
        countrz = countrz,
    }
    if bit.extract then
        shim.extract = bit.extract
    end
    if bit.replace then
        shim.replace = bit.replace
    end
    ensure("bit32", shim)
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
    teleporting = false,
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
    if ok then
        reconnect.attempts = 0
        reconnect.teleporting = true
        taskLib.delay(30, function()
            reconnect.teleporting = false
        end)
    else
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
            reconnect.attempts = 0
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
            if reconnect.teleporting then
                return
            end
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

    local quoted = {}
    for _, url in ipairs(CONFIG.SCRIPT_URLS) do
        quoted[#quoted + 1] = string.format("%q", url)
    end

    local source = string.format([[
local urls = {%s}
local lastError
for _, url in ipairs(urls) do
    local ok, src = pcall(function()
        return game:HttpGet(url)
    end)
    if ok and type(src) == "string" and #src > 0 then
        local ran, runError = pcall(function()
            return loadstring(src)()
        end)
        if ran then
            return
        end
        lastError = runError
    else
        lastError = src
    end
end
warn("[Animedimensions] queued run failed: " .. tostring(lastError))
]], table.concat(quoted, ", "))

    local ok, err = pcall(queueOnTeleport, source)
    if not ok then
        log("queue_on_teleport failed: " .. tostring(err))
    end
end

-- ---------------------------------------------------------------------------
-- Runtime UI patch (recolor + private server menu)
-- ---------------------------------------------------------------------------

local BLACK = Color3.new(0, 0, 0)
local WHITE = Color3.new(1, 1, 1)
local TEXT_TARGET

local function textTarget()
    if TEXT_TARGET == nil then
        TEXT_TARGET = (CONFIG.TEXT_ON_DARK == "white") and WHITE or BLACK
    end
    return TEXT_TARGET
end

local function asColor(value)
    if value == nil then
        return nil
    end
    local ok, r, g, b = pcall(function()
        return value.R, value.G, value.B
    end)
    if ok and type(r) == "number" and type(g) == "number" and type(b) == "number" then
        return r, g, b
    end
    return nil
end

local function isRed(r, g, b)
    if r < 0.35 then
        return false
    end
    local other = math.max(g, b)
    return other < 0.6 and (r - other) > 0.18
end

local function luminance(r, g, b)
    return 0.299 * r + 0.587 * g + 0.114 * b
end

local function readColor(obj, prop)
    local ok, value = pcall(function()
        return obj[prop]
    end)
    if not ok then
        return nil
    end
    return asColor(value)
end

local function effectiveBackground(obj)
    local current = obj
    for _ = 1, 6 do
        current = current.Parent
        if not current or not current:IsA("GuiObject") then
            break
        end
        local ok, transparency = pcall(function()
            return current.BackgroundTransparency
        end)
        local r, g, b = readColor(current, "BackgroundColor3")
        if r and (not ok or transparency < 0.5) then
            return r, g, b
        end
        local ir, ig, ib = readColor(current, "ImageColor3")
        if ir then
            return ir, ig, ib
        end
    end
    return 0, 0, 0
end

local function setRedToBlack(obj, prop, isText)
    local r, g, b = readColor(obj, prop)
    if not r or not isRed(r, g, b) then
        return false
    end
    local target = BLACK
    if isText then
        local br, bg, bb = effectiveBackground(obj)
        if luminance(br, bg, bb) < 0.4 then
            target = textTarget()
        end
    end
    pcall(function()
        obj[prop] = target
    end)
    return true
end

local SURFACE_PROPS = { "BackgroundColor3", "BorderColor3", "ImageColor3", "ScrollBarImageColor3" }
local TEXT_PROPS = { "TextColor3", "PlaceholderColor3", "TextStrokeColor3" }

local function recolorGradient(gradient)
    local ok, sequence = pcall(function()
        return gradient.Color
    end)
    if not ok or sequence == nil then
        return false
    end
    local okPoints, points = pcall(function()
        return sequence.Keypoints
    end)
    if not okPoints or points == nil then
        return false
    end

    local changed = false
    local keypoints = {}
    for _, keypoint in ipairs(points) do
        local r, g, b = asColor(keypoint.Value)
        if r and isRed(r, g, b) then
            keypoints[#keypoints + 1] = ColorSequenceKeypoint.new(keypoint.Time, BLACK)
            changed = true
        else
            keypoints[#keypoints + 1] = keypoint
        end
    end

    if changed and #keypoints >= 2 then
        pcall(function()
            gradient.Color = ColorSequence.new(keypoints)
        end)
    end
    return changed
end

local function recolor(root)
    local changed = 0
    if root:IsA("GuiObject") then
        for _, prop in ipairs(SURFACE_PROPS) do
            if setRedToBlack(root, prop, false) then
                changed = changed + 1
            end
        end
        for _, prop in ipairs(TEXT_PROPS) do
            if setRedToBlack(root, prop, true) then
                changed = changed + 1
            end
        end
    elseif root:IsA("UIStroke") then
        if setRedToBlack(root, "Color", false) then
            changed = changed + 1
        end
    elseif root:IsA("UIGradient") then
        if recolorGradient(root) then
            changed = changed + 1
        end
    end
    return changed
end

local function areaOf(gui)
    local ok, size = pcall(function()
        return gui.AbsoluteSize
    end)
    if not ok or not size then
        return 0
    end
    return size.X * size.Y
end

local function isWithin(obj, ancestor)
    local current = obj
    while current do
        if current == ancestor then
            return true
        end
        current = current.Parent
    end
    return false
end

local function findTabBar(playerGui)
    local best, bestCount
    for _, obj in ipairs(playerGui:GetDescendants()) do
        if obj:IsA("GuiObject") and obj.Visible then
            local sizes, count = {}, 0
            for _, child in ipairs(obj:GetChildren()) do
                if child:IsA("TextButton") and child.Visible then
                    count = count + 1
                    sizes[#sizes + 1] = areaOf(child)
                end
            end
            if count >= 2 then
                local minSize, maxSize = math.huge, 0
                for _, size in ipairs(sizes) do
                    if size < minSize then
                        minSize = size
                    end
                    if size > maxSize then
                        maxSize = size
                    end
                end
                if maxSize > 0 and (minSize / maxSize) > 0.5 and (not bestCount or count > bestCount) then
                    best, bestCount = obj, count
                end
            end
        end
    end
    return best
end

local function findPanelContainer(mainFrame, tabBar)
    local best, bestArea = nil, 0
    local mainArea = areaOf(mainFrame)
    for _, obj in ipairs(mainFrame:GetDescendants()) do
        if obj:IsA("Frame") and obj.Visible and not isWithin(obj, tabBar) then
            local parent = obj.Parent
            if parent and parent ~= mainFrame and parent:IsA("GuiObject") then
                local siblings = 0
                for _, other in ipairs(parent:GetChildren()) do
                    if other:IsA("GuiObject") then
                        siblings = siblings + 1
                    end
                end
                local area = areaOf(obj)
                if siblings >= 2 and area > bestArea and area > mainArea * 0.12 then
                    best, bestArea = obj, area
                end
            end
        end
    end
    if best then
        return best.Parent, best
    end
    return mainFrame, nil
end

local function addCorner(obj, radius)
    local ok, corner = pcall(Instance.new, "UICorner")
    if ok and corner then
        corner.CornerRadius = UDim.new(0, radius or 6)
        corner.Parent = obj
    end
end

local function addStroke(obj, color)
    local ok, stroke = pcall(Instance.new, "UIStroke")
    if ok and stroke then
        stroke.Color = color or Color3.fromRGB(70, 70, 70)
        stroke.Thickness = 1
        stroke.Parent = obj
    end
end

local function newButton(parent, text, order)
    local button = Instance.new("TextButton")
    button.Name = "Action"
    button.Size = UDim2.new(1, 0, 0, 32)
    button.LayoutOrder = order
    button.BackgroundColor3 = BLACK
    button.BackgroundTransparency = 0.15
    button.BorderSizePixel = 0
    button.AutoButtonColor = true
    button.Font = Enum.Font.GothamMedium
    button.TextSize = 13
    button.TextColor3 = WHITE
    button.Text = text
    addCorner(button, 6)
    addStroke(button)
    button.Parent = parent
    return button
end

local function newInput(parent, placeholder, text, order)
    local box = Instance.new("TextBox")
    box.Name = "Input"
    box.Size = UDim2.new(1, 0, 0, 30)
    box.LayoutOrder = order
    box.BackgroundColor3 = BLACK
    box.BackgroundTransparency = 0.1
    box.BorderSizePixel = 0
    box.ClearTextOnFocus = false
    box.Font = Enum.Font.Gotham
    box.TextSize = 12
    box.TextColor3 = WHITE
    box.PlaceholderColor3 = Color3.fromRGB(140, 140, 140)
    box.TextXAlignment = Enum.TextXAlignment.Left
    box.PlaceholderText = placeholder
    box.Text = text or ""
    local ok, padding = pcall(Instance.new, "UIPadding")
    if ok and padding then
        padding.PaddingLeft = UDim.new(0, 8)
        padding.PaddingRight = UDim.new(0, 8)
        padding.Parent = box
    end
    addCorner(box, 6)
    addStroke(box)
    box.Parent = parent
    return box
end

local function newLabel(parent, text, order, bold)
    local label = Instance.new("TextLabel")
    label.Name = "Label"
    label.Size = UDim2.new(1, 0, 0, 18)
    label.LayoutOrder = order
    label.BackgroundTransparency = 1
    label.Font = bold and Enum.Font.GothamBold or Enum.Font.Gotham
    label.TextSize = bold and 15 or 12
    label.TextColor3 = WHITE
    label.TextXAlignment = Enum.TextXAlignment.Left
    label.TextWrapped = true
    label.Text = text
    label.Parent = parent
    return label
end

local function manualRejoin()
    reconnect.stopped = false
    reconnect.scheduled = false
    reconnect.attempts = 0
    rejoin()
end

local function buildPanel(container, templatePanel)
    local panel = Instance.new("ScrollingFrame")
    panel.Name = "PrivateServerPanel"
    panel.BackgroundTransparency = 1
    panel.BorderSizePixel = 0
    panel.ScrollBarThickness = 4
    panel.ScrollBarImageColor3 = Color3.fromRGB(90, 90, 90)
    panel.CanvasSize = UDim2.new(0, 0, 0, 0)
    local okAuto = pcall(function()
        panel.AutomaticCanvasSize = Enum.AutomaticSize.Y
    end)
    if not okAuto then
        panel.CanvasSize = UDim2.new(0, 0, 0, 320)
    end
    if templatePanel then
        pcall(function()
            panel.Size = templatePanel.Size
            panel.Position = templatePanel.Position
            panel.AnchorPoint = templatePanel.AnchorPoint
            panel.ZIndex = templatePanel.ZIndex
        end)
    else
        panel.Size = UDim2.new(1, 0, 1, 0)
    end
    panel.Visible = false

    local list = Instance.new("UIListLayout")
    list.Padding = UDim.new(0, 6)
    list.SortOrder = Enum.SortOrder.LayoutOrder
    list.Parent = panel

    local okPadding, padding = pcall(Instance.new, "UIPadding")
    if okPadding and padding then
        padding.PaddingTop = UDim.new(0, 10)
        padding.PaddingLeft = UDim.new(0, 12)
        padding.PaddingRight = UDim.new(0, 12)
        padding.PaddingBottom = UDim.new(0, 10)
        padding.Parent = panel
    end

    newLabel(panel, "Private Server", 1, true)

    newLabel(panel, "Private server link", 2, false)
    local linkBox = newInput(panel, "https://www.roblox.com/games/...?privateServerLinkCode=...", CONFIG.PRIVATE_SERVER_LINK, 3)

    newLabel(panel, "Instance id (optional)", 4, false)
    local instanceBox = newInput(panel, "gameInstanceId", CONFIG.PRIVATE_SERVER_INSTANCE_ID, 5)

    local apply = newButton(panel, "Save and rejoin", 6)
    apply.MouseButton1Click:Connect(function()
        local link = linkBox.Text
        local instanceId = instanceBox.Text
        CONFIG.PRIVATE_SERVER_LINK = link or ""
        CONFIG.PRIVATE_SERVER_INSTANCE_ID = instanceId or ""
        local parsed = parsePrivateServerLink(CONFIG.PRIVATE_SERVER_LINK)
        if parsed and parsed.placeId then
            CONFIG.PLACE_ID = parsed.placeId
        end
        log("Private server settings saved")
        manualRejoin()
    end)

    local current = newButton(panel, "Rejoin current server", 7)
    current.MouseButton1Click:Connect(function()
        CONFIG.REJOIN_CURRENT_SERVER = true
        manualRejoin()
    end)

    local toggle = newButton(panel, "", 8)
    local function refreshToggle()
        toggle.Text = (CONFIG.AUTO_RECONNECT and "[x] " or "[ ] ") .. "Auto-reconnect"
    end
    refreshToggle()
    toggle.MouseButton1Click:Connect(function()
        CONFIG.AUTO_RECONNECT = not CONFIG.AUTO_RECONNECT
        refreshToggle()
        log("Auto-reconnect " .. (CONFIG.AUTO_RECONNECT and "enabled" or "disabled"))
    end)

    local status = newLabel(panel, "Ready", 9, false)
    status.TextColor3 = Color3.fromRGB(170, 170, 170)
    pcall(function()
        status.AutomaticSize = Enum.AutomaticSize.Y
    end)
    status.Size = UDim2.new(1, 0, 0, 18)
    uiStatus = function(message)
        status.Text = message
    end

    panel.Parent = container
    return panel, status
end

local function tryAttachUi(playerGui)
    local tabBar = findTabBar(playerGui)
    if not tabBar or not tabBar.Parent then
        return false
    end

    local mainFrame = tabBar.Parent
    local container, templatePanel = findPanelContainer(mainFrame, tabBar)
    if not container then
        return false
    end

    local panel = buildPanel(container, templatePanel)

    local templateButton
    for _, child in ipairs(tabBar:GetChildren()) do
        if child:IsA("TextButton") and child.Visible then
            templateButton = child
            break
        end
    end

    local tab
    if templateButton then
        local ok, clone = pcall(function()
            return templateButton:Clone()
        end)
        if ok and clone then
            tab = clone
        end
    end
    if not tab then
        tab = Instance.new("TextButton")
        tab.BackgroundColor3 = BLACK
        tab.BorderSizePixel = 0
        tab.Font = Enum.Font.GothamMedium
        tab.TextSize = 13
        tab.TextColor3 = WHITE
        tab.Size = UDim2.new(1, 0, 0, 32)
        addCorner(tab, 6)
    end

    tab.Name = "PrivateServerTab"
    tab.Text = "Private Server"
    pcall(function()
        tab.LayoutOrder = 999
    end)
    tab.Parent = tabBar

    local tabs = {}
    for _, child in ipairs(tabBar:GetChildren()) do
        if child:IsA("TextButton") and child ~= tab then
            tabs[#tabs + 1] = child
        end
    end

    local siblings = {}
    for _, child in ipairs(container:GetChildren()) do
        if child ~= panel and child:IsA("GuiObject") and not isWithin(child, tabBar) then
            siblings[#siblings + 1] = child
        end
    end

    tab.MouseButton1Click:Connect(function()
        for _, other in ipairs(siblings) do
            pcall(function()
                other.Visible = false
            end)
        end
        panel.Visible = true
    end)

    for _, other in ipairs(tabs) do
        other.MouseButton1Click:Connect(function()
            panel.Visible = false
        end)
    end

    if CONFIG.RECOLOR_RED_TO_BLACK then
        recolor(tab)
        for _, descendant in ipairs(tab:GetDescendants()) do
            recolor(descendant)
        end
    end

    log("Private Server menu added to the script menu")
    return true
end

local function startUiPatch()
    local Players = getService("Players")
    if not Players then
        return
    end
    local player = Players.LocalPlayer
    if not player then
        return
    end

    taskLib.spawn(function()
        local playerGui
        for _ = 1, 120 do
            playerGui = player:FindFirstChildOfClass("PlayerGui")
            if playerGui then
                break
            end
            taskLib.wait(0.5)
        end
        if not playerGui then
            playerGui = getService("CoreGui")
        end
        if not playerGui then
            log("UI patch: PlayerGui not found")
            return
        end

        if playerGui.DescendantAdded then
            playerGui.DescendantAdded:Connect(function(descendant)
                if CONFIG.RECOLOR_RED_TO_BLACK then
                    recolor(descendant)
                    for _, child in ipairs(descendant:GetDescendants()) do
                        recolor(child)
                    end
                end
            end)
        end

        local attached = false
        local recolored = 0
        local attempts = math.max(1, math.floor(CONFIG.UI_PATCH_TIMEOUT * 2))

        for attempt = 1, attempts do
            if CONFIG.RECOLOR_RED_TO_BLACK and (attempt == 1 or attempt % 6 == 0) then
                for _, descendant in ipairs(playerGui:GetDescendants()) do
                    recolored = recolored + recolor(descendant)
                end
            end
            if not attached then
                local okAttach, result = pcall(tryAttachUi, playerGui)
                if okAttach and result then
                    attached = true
                end
            end
            if attached then
                break
            end
            taskLib.wait(0.5)
        end

        if recolored > 0 then
            log("UI patch: " .. tostring(recolored) .. " red element(s) changed to black")
        end
        if not attached then
            log("UI patch: script menu not found, private server menu skipped")
        end
    end)
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
            local compiled, fn = pcall(compile, source, "=Animedimensions")
            if compiled then
                local ran, result = pcall(fn)
                if ran then
                    return result
                end
                lastError = result
                log("Payload runtime error from " .. url .. ": " .. tostring(result))
            else
                lastError = fn
                log("Payload compile error from " .. url .. ": " .. tostring(fn))
            end
        else
            lastError = source
            log("Download failed for " .. url .. ": " .. tostring(source))
        end
    end
    error("Unable to run the Animedimensions payload: " .. tostring(lastError))
end

local ok, err = pcall(function()
    startAutoReconnect()
    setupQueueOnTeleport()
    if CONFIG.PATCH_UI then
        local patched, patchError = pcall(startUiPatch)
        if not patched then
            log("UI patch failed to start: " .. tostring(patchError))
        end
    end
    return loadPayload()
end)

if not ok then
    log("Payload error: " .. tostring(err))
end
