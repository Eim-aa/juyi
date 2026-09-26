-- Behavioral contracts for hammerspoon/argos-translator.lua.
--
-- This file provides a small mock of the Hammerspoon APIs used by Juyi and is
-- intentionally runnable by stock Lua 5.4 in CI:
--
--   lua5.4 tests/hammerspoon_runtime_test.lua hammerspoon/argos-translator.lua

local sourcePath = (type(arg) == "table" and arg[1])
    or "hammerspoon/argos-translator.lua"

local VALID_TOKEN = string.rep("0123456789abcdef", 4)
local state = {
    now = 10,
    timers = {},
    watchers = {},
    posts = {},
    gets = {},
    responses = {},
    selections = {},
    alerts = {},
    authToken = VALID_TOKEN,
    cloudRemovalMarker = "absent",
    ownerRequest = "absent",
    paused = false,
    persistedEngine = nil,
    canvasCount = 0,
    selectionReads = 0,
    copyKeystrokes = 0,
    statusWrites = {},
}

local OWNER_EPOCH = "11111111-2222-3333-4444-555555555555"
local NATIVE_INSTANCE = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
local LEGACY_INSTANCE = "99999999-8888-7777-6666-555555555555"

local function expect(condition, message)
    if not condition then error(message, 2) end
end

local function expectEqual(actual, expected, message)
    if actual ~= expected then
        error(string.format(
            "%s (expected %s, got %s)",
            message,
            tostring(expected),
            tostring(actual)
        ), 2)
    end
end

-- Keep all product filesystem access in memory. The source file is still read
-- normally by dofile; only paths rooted at this synthetic HOME are intercepted.
local fakeHome = "__juyi_hammerspoon_test_home__"
local realOpen = io.open
io.open = function(path, mode)
    if path == fakeHome .. "/.config/argos-translator/owner-request.json"
        and mode == "r" then
        if state.ownerRequest == "absent" then
            return nil, "No such file or directory", 2
        end
        if state.ownerRequest == "unavailable" then
            return nil, "Permission denied", 13
        end
        return {
            read = function() return state.ownerRequest end,
            close = function() end,
        }
    end
    if path == fakeHome .. "/.config/argos-translator/hs-paused"
        and mode == "r" then
        if not state.paused then return nil, "No such file or directory", 2 end
        return {
            read = function() return "1" end,
            close = function() end,
        }
    end
    if path == fakeHome .. "/.config/argos-translator/auth-token" and mode == "r" then
        if state.authToken == nil then return nil, "No such file or directory", 2 end
        return {
            read = function() return state.authToken end,
            close = function() end,
        }
    end
    if path == fakeHome .. "/.config/argos-translator/cloud-removal-pending"
        and mode == "r" then
        if state.cloudRemovalMarker == "absent" then
            return nil, "No such file or directory", 2
        end
        if state.cloudRemovalMarker == "unavailable" then
            return nil, "Permission denied", 13
        end
        return {
            read = function() return "1\n" end,
            close = function() end,
        }
    end
    if path == fakeHome .. "/.config/argos-translator/hs-engine" then
        if mode == "r" then
            if state.persistedEngine == nil then
                return nil, "No such file or directory", 2
            end
            return {
                read = function() return state.persistedEngine end,
                close = function() end,
            }
        end
        if mode == "w" then
            return {
                write = function(_, value)
                    state.persistedEngine = value:gsub("%s+", "")
                end,
                close = function() end,
            }
        end
    end
    if path:sub(1, #fakeHome) == fakeHome then
        if mode == "r" then return nil, "No such file or directory", 2 end
        return {
            write = function() end,
            close = function() end,
        }
    end
    return realOpen(path, mode)
end

local realGetenv = os.getenv
os.getenv = function(name)
    if name == "HOME" then return fakeHome end
    return realGetenv(name)
end

local function newTimer(delay, callback, repeating)
    local timer = {
        delay = delay,
        callback = callback,
        enabled = true,
        repeating = repeating,
    }
    function timer:stop() self.enabled = false end
    function timer:start() self.enabled = true end
    function timer:isEnabled() return self.enabled end
    function timer:fire()
        expect(self.enabled, "attempted to fire a stopped timer")
        if not self.repeating then self.enabled = false end
        self.callback()
    end
    table.insert(state.timers, timer)
    return timer
end

local eventTypes = {
    leftMouseDown = 1,
    rightMouseDown = 3,
    keyDown = 10,
    flagsChanged = 12,
    otherMouseDown = 25,
}

local screen = { _frame = { x = 0, y = 0, w = 600, h = 220 } }
function screen:frame() return self._frame end

hs = {
    accessibilityState = function() return true end,
    application = {
        frontmostApplication = function()
            return { name = function() return "Runtime Test" end }
        end,
    },
    json = {
        encode = function(value)
            if type(value) == "table" and value.module_loaded ~= nil then
                state.lastStatus = value
                table.insert(state.statusWrites, value)
                return "encoded-status"
            end
            if type(value) == "table" and value.text ~= nil then
                return "encoded-request:" .. tostring(value.engine) .. ":" .. tostring(value.text)
            end
            return "encoded-request"
        end,
        decode = function(value)
            if value == "valid-native-owner-request" then
                return {
                    version = 1,
                    requested_owner = "native",
                    epoch = OWNER_EPOCH,
                    native_instance_id = NATIVE_INSTANCE,
                }
            end
            if value == "native-owner-request-with-extra-key" then
                return {
                    version = 1,
                    requested_owner = "native",
                    epoch = OWNER_EPOCH,
                    native_instance_id = NATIVE_INSTANCE,
                    extra = true,
                }
            end
            if value == "health-response" then
                return {
                    engines = { apple = true, volc = true },
                    default_engine = "apple",
                }
            end
            local response = state.responses[value]
            if response == nil then
                error("unknown mocked JSON response: " .. tostring(value))
            end
            return response
        end,
    },
    timer = {
        secondsSinceEpoch = function() return state.now end,
        usleep = function() end,
        doAfter = function(delay, callback)
            return newTimer(delay, callback, false)
        end,
        doEvery = function(delay, callback)
            return newTimer(delay, callback, true)
        end,
    },
    uielement = {
        focusedElement = function()
            state.selectionReads = state.selectionReads + 1
            return {
                selectedText = function()
                    return table.remove(state.selections, 1)
                end,
            }
        end,
    },
    pasteboard = {
        readAllData = function() return {} end,
        writeAllData = function() return true end,
        changeCount = function() return 0 end,
        getContents = function() return nil end,
        setContents = function(value)
            state.pasteboard = value
            return true
        end,
    },
    mouse = {
        absolutePosition = function() return { x = 100, y = 70 } end,
        getCurrentScreen = function() return screen end,
    },
    screen = { mainScreen = function() return screen end },
    drawing = {
        getTextDrawingSize = function(text, style)
            local size = style and style.size or 14
            return { w = math.max(1, #text * (size / 2)), h = 18 }
        end,
    },
    canvas = {},
    eventtap = { event = { types = eventTypes } },
    keycodes = { map = { escape = 53 } },
    alert = {
        show = function(message) table.insert(state.alerts, message) end,
    },
    http = {},
    host = { uuid = function() return LEGACY_INSTANCE end },
}

hs.canvas.new = function(frame)
    state.canvasCount = state.canvasCount + 1
    state.lastBody = nil
    state.lastSubtitle = nil
    local canvas = { _frame = frame, deleted = false }
    function canvas:appendElements(element)
        if element.id == "body" then state.lastBody = element.text end
        if element.id == "sub" then state.lastSubtitle = element.text end
    end
    function canvas:show() state.currentCanvas = self end
    function canvas:delete()
        self.deleted = true
        if state.currentCanvas == self then state.currentCanvas = nil end
    end
    function canvas:frame() return self._frame end
    return canvas
end

hs.eventtap.new = function(types, callback)
    local watcher = { types = types, callback = callback, enabled = false }
    function watcher:start() self.enabled = true end
    function watcher:stop() self.enabled = false end
    function watcher:isEnabled() return self.enabled end

    local isTapWatcher = false
    for _, eventType in ipairs(types) do
        if eventType == eventTypes.flagsChanged then isTapWatcher = true end
    end
    if isTapWatcher then
        state.tapWatcher = watcher
    else
        state.popupWatcher = watcher
    end
    table.insert(state.watchers, watcher)
    return watcher
end

hs.eventtap.keyStroke = function()
    state.copyKeystrokes = state.copyKeystrokes + 1
end

hs.http.asyncGet = function(url, headers, callback)
    table.insert(state.gets, { url = url, headers = headers, callback = callback })
    callback(200, "health-response", {})
end

hs.http.asyncPost = function(url, body, headers, callback)
    table.insert(state.posts, {
        url = url,
        body = body,
        headers = headers,
        callback = callback,
    })
end

local function flagsEvent(flags)
    return {
        getType = function() return eventTypes.flagsChanged end,
        getFlags = function() return flags end,
    }
end

local function keyEvent(keyCode)
    return {
        getType = function() return eventTypes.keyDown end,
        getKeyCode = function() return keyCode end,
    }
end

local function clickEvent(x, y)
    return {
        getType = function() return eventTypes.leftMouseDown end,
        location = function() return { x = x, y = y } end,
    }
end

local function insideClick()
    local frame = state.currentCanvas._frame
    return clickEvent(frame.x + 2, frame.y + 2)
end

local function fireLatestTriggerTimer()
    for index = #state.timers, 1, -1 do
        local timer = state.timers[index]
        if timer.delay == 0.01 and timer.enabled then
            timer:fire()
            return
        end
    end
    error("double-tap did not schedule a hotkey trigger")
end

local function fireLatestOwnerPoll()
    for index = #state.timers, 1, -1 do
        local timer = state.timers[index]
        if timer.delay == 1.0 and timer.repeating and timer.enabled then
            timer:fire()
            return
        end
    end
    error("owner reconciliation timer not found")
end

local function requestTimers()
    local found = {}
    for index = #state.timers, 1, -1 do
        local timer = state.timers[index]
        if timer.delay == 0.8 and found.t08 == nil then found.t08 = timer end
        if timer.delay == 1.5 and found.t15 == nil then found.t15 = timer end
        if timer.delay == 3.0 and found.t30 == nil then found.t30 = timer end
        if found.t08 and found.t15 and found.t30 then return found end
    end
    error("translation request did not create every progressive timer")
end

local function queueSelection(text)
    table.insert(state.selections, text)
    local start = state.now + 1
    state.now = start
    state.tapWatcher.callback(flagsEvent({ alt = true }))
    state.now = start + 0.03
    state.tapWatcher.callback(flagsEvent({}))
    state.now = start + 0.15
    state.tapWatcher.callback(flagsEvent({ alt = true }))
    state.now = start + 0.18
    state.tapWatcher.callback(flagsEvent({}))
end

local function triggerSelection(text)
    local postCount = #state.posts
    queueSelection(text)
    fireLatestTriggerTimer()
    expectEqual(#state.posts, postCount + 1, "hotkey should issue one translation POST")
    return state.posts[#state.posts]
end

local function assertAuthorization(headers, expected, context)
    expectEqual(headers.Authorization, expected, context)
end

-- Load the real module after the mock is complete. M.start() runs as it does in
-- Hammerspoon, giving the test access through the actual event callbacks.
local module = dofile(sourcePath)
expectEqual(#state.gets, 1, "module startup should issue one health request")
expectEqual(state.tapWatcher:isEnabled(), true, "legacy watcher should start without a request")
expectEqual(state.lastStatus.owner_protocol_version, 1, "owner protocol version missing")
expectEqual(state.lastStatus.legacy_instance_id, LEGACY_INSTANCE, "legacy instance mismatch")
expectEqual(state.lastStatus.owner_state, "legacy_active", "legacy owner state mismatch")
expectEqual(state.lastStatus.active_request, false, "startup reported an active request")
expectEqual(state.lastStatus.popup_visible, false, "startup reported a popup")
assertAuthorization(
    state.gets[1].headers,
    "Bearer " .. VALID_TOKEN,
    "valid token should authenticate health request"
)

-- A new generation must stop old timers. Even a callback already dequeued by
-- the event loop must see the stale generation and leave the current UI alone.
local firstPost = triggerSelection("first")
assertAuthorization(
    firstPost.headers,
    "Bearer " .. VALID_TOKEN,
    "valid token should authenticate translation request"
)
local firstTimers = requestTimers()

local secondPost = triggerSelection("second")
local secondTimers = requestTimers()
for name, timer in pairs(firstTimers) do
    expect(not timer.enabled, "superseded " .. name .. " timer remained active")
end
local healthCount = #state.gets
firstTimers.t08.callback()
firstTimers.t15.callback()
firstTimers.t30.callback()
expectEqual(#state.gets, healthCount, "stale health timer issued a request")
expectEqual(state.lastBody, "翻译中…", "stale timer overwrote current transition")

state.responses.first = {
    result = "旧译文",
    engine = "apple",
    elapsed_ms = 10,
    warnings = {},
}
firstPost.callback(200, "first", {})
expectEqual(state.lastBody, "翻译中…", "stale response overwrote the new request")
for name, timer in pairs(secondTimers) do
    expect(timer.enabled, "stale response stopped current " .. name .. " timer")
end


-- A durable native owner request is a full legacy data-plane barrier. The
-- watcher, pending request, timers, popup and gesture state must be tombstoned
-- before an epoch-bound yielded acknowledgement is published.
state.ownerRequest = "valid-native-owner-request"
fireLatestOwnerPoll()
expectEqual(state.tapWatcher:isEnabled(), false, "native request left watcher active")
expectEqual(state.currentCanvas, nil, "native request left popup visible")
expectEqual(state.lastStatus.owner_state, "yielded", "native request was not acknowledged")
expectEqual(state.lastStatus.owner_request_epoch, OWNER_EPOCH, "owner epoch mismatch")
expectEqual(
    state.lastStatus.owner_request_native_instance_id,
    NATIVE_INSTANCE,
    "native instance acknowledgement mismatch"
)
expectEqual(state.lastStatus.watcher_active, false, "yielded status reported watcher")
expectEqual(state.lastStatus.active_request, false, "yielded status reported request")
expectEqual(state.lastStatus.popup_visible, false, "yielded status reported popup")
local yieldedCanvasCount = state.canvasCount
state.responses.yieldedLate = {
    result = "不得重现",
    engine = "apple",
    elapsed_ms = 8,
    warnings = {},
}
secondPost.callback(200, "yieldedLate", {})
expectEqual(state.canvasCount, yieldedCanvasCount, "yielded request reopened a popup")

-- Removing the request is an explicit return to the legacy owner. Hammerspoon
-- may resume only after it observes confirmed absence.
state.ownerRequest = "absent"
fireLatestOwnerPoll()
expectEqual(state.tapWatcher:isEnabled(), true, "legacy watcher did not resume")
expectEqual(state.lastStatus.owner_state, "legacy_active", "legacy owner did not resume")
expectEqual(state.lastStatus.owner_request_epoch, nil, "stale owner epoch survived resume")

-- Pause is the same full kill barrier, not just a watcher toggle.
local pausedPost = triggerSelection("pause barrier")
state.paused = true
fireLatestOwnerPoll()
expectEqual(state.tapWatcher:isEnabled(), false, "pause left watcher active")
expectEqual(state.currentCanvas, nil, "pause left popup visible")
expectEqual(state.lastStatus.owner_state, "paused", "pause state mismatch")
expectEqual(state.lastStatus.active_request, false, "pause left request active")
local pausedCanvasCount = state.canvasCount
state.responses.pausedLate = {
    result = "暂停后迟到",
    engine = "apple",
    elapsed_ms = 9,
    warnings = {},
}
pausedPost.callback(200, "pausedLate", {})
expectEqual(state.canvasCount, pausedCanvasCount, "pause allowed late popup")
state.paused = false
fireLatestOwnerPoll()
expectEqual(state.tapWatcher:isEnabled(), true, "unpause did not resume legacy watcher")

-- A hotkey already queued by the event tap must observe a newly written pause
-- or owner request itself, without waiting for the one-second owner poll.
for _, boundary in ipairs({ "pause", "native owner", "invalid owner", "unavailable owner" }) do
    local selectionReads = state.selectionReads
    local copyKeystrokes = state.copyKeystrokes
    local postCount = #state.posts
    local getCount = #state.gets
    queueSelection("must remain unread after " .. boundary)
    if boundary == "pause" then
        state.paused = true
    elseif boundary == "native owner" then
        state.ownerRequest = "valid-native-owner-request"
    elseif boundary == "invalid owner" then
        state.ownerRequest = "native-owner-request-with-extra-key"
    else
        state.ownerRequest = "unavailable"
    end
    fireLatestTriggerTimer()
    expectEqual(state.selectionReads, selectionReads, boundary .. " allowed queued AX read")
    expectEqual(state.copyKeystrokes, copyKeystrokes, boundary .. " allowed queued copy")
    expectEqual(#state.posts, postCount, boundary .. " allowed queued translation POST")
    expectEqual(#state.gets, getCount, boundary .. " allowed queued HTTP GET")
    expectEqual(state.tapWatcher:isEnabled(), false, boundary .. " left watcher active")
    expectEqual(table.remove(state.selections, 1), "must remain unread after " .. boundary,
        boundary .. " consumed the queued selection")
    state.paused = false
    state.ownerRequest = "absent"
    fireLatestOwnerPoll()
end

-- A long successful response is clipped to the usable screen, visibly marked,
-- and still copies the complete unmodified translation.
secondPost = triggerSelection("second after owner barrier")
local fullTranslation = string.rep("完整译文", 200)
state.responses.second = {
    result = fullTranslation,
    engine = "apple",
    elapsed_ms = 12,
    warnings = {},
}
secondPost.callback(200, "second", {})
expect(
    state.currentCanvas._frame.h <= screen._frame.h,
    "long popup exceeded usable screen height"
)
expect(state.lastBody ~= fullTranslation, "long translation was not clipped for display")
expect(state.lastBody:find("…", 1, true), "clipped translation lacks ellipsis")
expect(
    state.lastSubtitle:find("内容过长，点击复制完整译文", 1, true),
    "long translation lacks copy-full hint"
)
expectEqual(state.popupWatcher.callback(insideClick()), true, "popup click should be consumed")
expectEqual(
    state.pasteboard,
    fullTranslation,
    "success click did not copy the complete translation"
)

-- Error warnings may contain credentials, authorization headers, account
-- paths, or email addresses. None may reach the subtitle or copied details.
local warningSecret = "secret-123456789"
local warningBearer = string.rep("f", 64)
local errorPost = triggerSelection("third")
state.responses.error = {
    result = "",
    engine = "volc",
    elapsed_ms = 20,
    error = "volc_error",
    warnings = {
        "VOLC_SECRET_KEY=" .. warningSecret
            .. " Authorization: Bearer " .. warningBearer
            .. " reader@example.com /Users/private-user/file",
    },
}
errorPost.callback(200, "error", {})
expect(state.lastSubtitle:find("[已脱敏]", 1, true), "warning was not redacted")
for _, sensitive in ipairs({
    warningSecret,
    warningBearer,
    "reader@example.com",
    "private-user",
}) do
    expect(
        not state.lastSubtitle:find(sensitive, 1, true),
        "sensitive warning value reached subtitle: " .. sensitive
    )
end
state.popupWatcher.callback(insideClick())
expect(
    state.pasteboard:find("检查云端设置", 1, true),
    "error click did not copy actionable details"
)
expect(not state.pasteboard:find(warningSecret, 1, true), "copied error leaked secret")
expect(not state.pasteboard:find(warningBearer, 1, true), "copied error leaked bearer")

-- Transition clicks close without copying, and a later response must not
-- resurrect the dismissed popup.
local transitionPost = triggerSelection("fourth")
local pasteboardBeforeTransitionClick = state.pasteboard
state.popupWatcher.callback(insideClick())
expectEqual(
    state.pasteboard,
    pasteboardBeforeTransitionClick,
    "transition click unexpectedly copied text"
)
expectEqual(state.currentCanvas, nil, "transition click did not dismiss popup")
local canvasCount = state.canvasCount
state.responses.transition = {
    result = "迟到但已关闭",
    engine = "apple",
    elapsed_ms = 4,
    warnings = {},
}
transitionPost.callback(200, "transition", {})
expectEqual(state.canvasCount, canvasCount, "dismissed transition reopened on response")

-- Escape consumes the key and dismisses. An external click dismisses without
-- consuming the event so the underlying app still receives it.
triggerSelection("fifth")
expectEqual(state.popupWatcher.callback(keyEvent(53)), true, "Escape was not consumed")
expectEqual(state.currentCanvas, nil, "Escape did not dismiss popup")

triggerSelection("sixth")
local outsideFrame = state.currentCanvas._frame
expectEqual(
    state.popupWatcher.callback(clickEvent(outsideFrame.x - 20, outsideFrame.y - 20)),
    false,
    "outside click should continue to underlying app"
)
expectEqual(state.currentCanvas, nil, "outside click did not dismiss popup")

-- Server validation can return empty_input with HTTP 400. That specific error
-- must remain reachable instead of being flattened into a generic HTTP error.
local emptyPost = triggerSelection("seventh")
state.responses.empty = {
    result = "",
    engine = "apple",
    elapsed_ms = 1,
    error = "empty_input",
    warnings = {},
}
emptyPost.callback(400, "empty", {})
expectEqual(state.lastBody, "(空输入)", "HTTP 400 empty_input was not classified")
expect(
    state.lastSubtitle:find("请重新选择英文文本", 1, true),
    "empty_input lacks actionable guidance"
)
state.popupWatcher.callback(insideClick())
expect(
    state.pasteboard:find("请重新选择英文文本", 1, true),
    "empty_input click did not copy actionable details"
)

local stoppedSelectionReads = state.selectionReads
local stoppedCopyKeystrokes = state.copyKeystrokes
local stoppedPostCount = #state.posts
local stoppedGetCount = #state.gets
queueSelection("must remain unread after stop")
module.stop()
fireLatestTriggerTimer()
expectEqual(state.selectionReads, stoppedSelectionReads, "stop allowed queued AX read")
expectEqual(state.copyKeystrokes, stoppedCopyKeystrokes, "stop allowed queued copy")
expectEqual(#state.posts, stoppedPostCount, "stop allowed queued translation POST")
expectEqual(#state.gets, stoppedGetCount, "stop allowed queued HTTP GET")
expectEqual(state.tapWatcher:isEnabled(), false, "queued callback restarted a stopped watcher")
expectEqual(table.remove(state.selections, 1), "must remain unread after stop",
    "stopped callback consumed the queued selection")

-- Reload must reconcile before ever starting the new watcher. A durable
-- request therefore survives both Juyi and Hammerspoon crashes without a
-- transient dual-owner window.
state.ownerRequest = "valid-native-owner-request"
local yieldedStartupModule = dofile(sourcePath)
expectEqual(state.tapWatcher:isEnabled(), false, "startup briefly enabled yielded watcher")
expectEqual(state.lastStatus.owner_state, "yielded", "startup did not preserve yield")
expectEqual(state.lastStatus.owner_request_epoch, OWNER_EPOCH, "startup yield epoch mismatch")
yieldedStartupModule.stop()

-- Invalid, oversized or unavailable control state is fail-closed. It cannot
-- mint a yielded acknowledgement and cannot fall back to a legacy watcher.
state.ownerRequest = "native-owner-request-with-extra-key"
local invalidOwnerModule = dofile(sourcePath)
expectEqual(state.tapWatcher:isEnabled(), false, "invalid owner request enabled watcher")
expectEqual(state.lastStatus.owner_state, "blocked", "invalid owner request was not blocked")
expectEqual(state.lastStatus.owner_request_epoch, nil, "invalid request acknowledged an epoch")
invalidOwnerModule.stop()

state.ownerRequest = "unavailable"
local unavailableOwnerModule = dofile(sourcePath)
expectEqual(state.tapWatcher:isEnabled(), false, "unavailable owner request enabled watcher")
expectEqual(
    state.lastStatus.owner_state,
    "blocked",
    "unavailable owner request was not blocked"
)
unavailableOwnerModule.stop()
state.ownerRequest = "absent"

-- A removal marker is a per-request data-plane kill switch. Even if the app
-- entered removal after this module loaded with a persisted cloud choice, the
-- next gesture must be forced to Apple and must persist that safe choice.
state.persistedEngine = "volc"
state.cloudRemovalMarker = "absent"
local removalModule = dofile(sourcePath)
state.cloudRemovalMarker = "present"
local markerPost = triggerSelection("marker appeared after startup")
expect(
    markerPost.body:find("encoded-request:apple:", 1, true) == 1,
    "present removal marker did not block the cloud request"
)
expectEqual(state.persistedEngine, "apple", "removal marker did not persist Apple")
removalModule.stop()

-- Unreadable or otherwise unverifiable marker state is also fail-closed.
state.persistedEngine = "volc"
state.cloudRemovalMarker = "unavailable"
local unavailableMarkerModule = dofile(sourcePath)
local unavailableMarkerPost = triggerSelection("marker cannot be verified")
expect(
    unavailableMarkerPost.body:find("encoded-request:apple:", 1, true) == 1,
    "unverifiable removal marker did not block the cloud request"
)
expectEqual(state.persistedEngine, "apple", "unverifiable marker did not persist Apple")
unavailableMarkerModule.stop()

state.persistedEngine = nil
state.cloudRemovalMarker = "absent"

-- The client accepts exactly 64 lowercase hexadecimal characters. Missing or
-- malformed files preserve development compatibility by omitting Authorization.
local function assertTokenPolicy(token, expectedAuthorization, label)
    state.authToken = token
    local getCountBefore = #state.gets
    local loaded = dofile(sourcePath)
    expectEqual(#state.gets, getCountBefore + 1, label .. " startup health count")
    assertAuthorization(
        state.gets[#state.gets].headers,
        expectedAuthorization,
        label .. " health Authorization"
    )
    local post = triggerSelection("token policy " .. label)
    assertAuthorization(post.headers, expectedAuthorization, label .. " POST Authorization")
    expectEqual(post.headers["Content-Type"], "application/json", label .. " content type")
    loaded.stop()
end

assertTokenPolicy(nil, nil, "missing token")
assertTokenPolicy(string.rep("a", 63), nil, "63-character token")
assertTokenPolicy(string.rep("A", 64), nil, "uppercase token")
assertTokenPolicy(string.rep("a", 63) .. "g", nil, "non-hex token")
assertTokenPolicy(VALID_TOKEN, "Bearer " .. VALID_TOKEN, "valid 64-hex token")

print("PASS hammerspoon runtime behavior contracts")
