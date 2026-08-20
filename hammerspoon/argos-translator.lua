-- argos-translator.lua
-- Double-tap ⌥ (Option) to translate the current selection via the local argos-translator service.
--
-- Capture path (primary): hs.uielement.focusedElement():selectedText() — works
-- in AX-aware apps (Safari, Pages, Notes, Mail, native Cocoa text views).
--
-- Capture path (fallback): briefly hijack ⌘+C with a full pasteboard
-- snapshot/restore so the user's clipboard (incl. rich text, files, images)
-- ends up byte-identical to what it was before the keystroke. Pasteboard
-- changeCount is used to detect "Cmd+C actually fired" — robust against
-- "selected text equals existing clipboard" edge cases.

local M = {}

local URL = "http://127.0.0.1:54321"
-- Trigger: double-tap the Option (⌥) key — two clean taps within the window.
local DOUBLE_TAP_WINDOW_S = 0.35 -- max gap between the two taps
local TAP_MAX_HOLD_S = 0.35      -- each tap must be a quick press→release
local FONT_NAME = ".AppleSystemUIFont"
local FONT_SIZE = 14
local MAX_WIDTH = 460
local PADDING = 12
local LOG_PATH = os.getenv("HOME") .. "/Library/Logs/argos-translator-hs.log"
local CLIPBOARD_TIMEOUT_S = 1.2
local CLIPBOARD_KEY_DELAY_US = 100 * 1000

local activeCanvas = nil
local activeWatcher = nil
local activePopup = nil
local tapWatcher = nil
local optDown = false
local optPressTime = 0
local lastTapTime = 0
local sawOtherKey = false
local requestGeneration = 0
local activeRequest = nil

-- Engine selection: switched live via the menu bar, sent with each request.
local ENGINE_STATE_PATH = os.getenv("HOME") .. "/.config/argos-translator/hs-engine"
local STATUS_PATH = os.getenv("HOME") .. "/.config/argos-translator/hs-status.json"
local PAUSE_PATH = os.getenv("HOME") .. "/.config/argos-translator/hs-paused"
local AUTH_TOKEN_PATH = os.getenv("HOME") .. "/.config/argos-translator/auth-token"
local CLOUD_REMOVAL_MARKER_PATH = os.getenv("HOME") .. "/.config/argos-translator/cloud-removal-pending"
local ENGINE_SHORT = { volc = "云端", apple = "苹果" }
local ENGINE_SOURCE = { volc = "火山云端", apple = "苹果端上翻译" }
-- Engine failures come back as error codes with the source text echoed in
-- `result`; they must render as errors, never as a translation.
local ERROR_TITLE = {
    apple_error = "苹果端上翻译出错",
    volc_error = "云端翻译出错",
    no_engine_available = "没有可用的翻译引擎",
}
local ERROR_HINT = {
    apple_error = "请打开句译，准备 Apple 离线翻译",
    volc_error = "请打开句译，检查云端设置",
    no_engine_available = "请打开句译，选择可用的翻译方式",
}
local DIAGNOSTIC_HINT = {
    volc_credentials_or_permission = "请检查云端密钥和机器翻译权限",
    volc_timeout = "云端连接超时，请稍后重试",
    volc_network = "无法连接云端，请检查网络",
    volc_http_error = "云端 HTTP 请求失败",
    volc_api_error = "云端服务返回错误",
    volc_service_error = "云端服务暂时不可用",
    apple_timeout_or_language_pack = "Apple 翻译超时，请确认语言包已准备好",
    apple_helper_unavailable = "Apple 离线组件不可用",
    apple_helper_error = "Apple 离线组件异常退出",
    apple_translation_error = "Apple 离线翻译失败",
    engine_setup_required = "请打开句译，准备一种翻译方式",
}
local currentEngine = "apple"
local volcAvailable = false
local appleAvailable = false
local menubar = nil
local externalEngineWatcher = nil
local setEngine, rebuildMenu, persistEngine -- forward declarations (assigned below)

-- A cloud-removal transaction is a data-plane kill switch, not merely UI
-- state. Any existing marker -- including one we cannot read -- must prevent
-- selected text from being sent to the cloud. Only an explicit ENOENT means
-- the marker is absent.
local function cloudRemovalBlocksVolc()
    local f, _, errno = io.open(CLOUD_REMOVAL_MARKER_PATH, "r")
    if f then
        f:close()
        return true
    end
    return errno ~= 2
end

local function appendLog(fields)
    fields.ts = os.date("!%Y-%m-%dT%H:%M:%SZ")
    local ok, line = pcall(hs.json.encode, fields)
    if not ok then return end
    local f = io.open(LOG_PATH, "a")
    if f then
        f:write(line .. "\n")
        f:close()
    end
end

local function isPaused()
    local f = io.open(PAUSE_PATH, "r")
    if not f then return false end
    local value = f:read("*l")
    f:close()
    return value == "1"
end

local function writeStatus(moduleLoaded)
    local status = {
        module_loaded = moduleLoaded and true or false,
        accessibility = hs.accessibilityState(false) and true or false,
        watcher_active = tapWatcher ~= nil and tapWatcher:isEnabled() or false,
        paused = isPaused(),
        updated_at = os.time(),
    }
    local ok, encoded = pcall(hs.json.encode, status)
    if not ok then return end
    local tempPath = STATUS_PATH .. ".tmp"
    local f = io.open(tempPath, "w")
    if f then
        f:write(encoded .. "\n")
        f:close()
        os.rename(tempPath, STATUS_PATH)
    end
end

-- Truncate to at most maxBytes without splitting a UTF-8 sequence.
local function utf8Truncate(s, maxBytes)
    if #s <= maxBytes then return s end
    local i = maxBytes + 1
    while i > 1 do
        local b = s:byte(i)
        if not b or b < 0x80 or b >= 0xC0 then break end
        i = i - 1
    end
    return s:sub(1, i - 1) .. "…"
end

-- Read the token for every request so an installer can add or rotate it
-- without requiring the Hammerspoon config to be reloaded.  An absent token
-- deliberately leaves out Authorization for source-tree development servers.
local function readAuthToken()
    local f = io.open(AUTH_TOKEN_PATH, "r")
    if not f then return nil end
    local token = f:read("*l")
    f:close()
    if not token then return nil end
    token = token:match("^%s*(.-)%s*$") or ""
    if #token ~= 64 or not token:match("^[0-9a-f]+$") then return nil end
    return token
end

local function requestHeaders(extra)
    local headers = {}
    if extra then
        for key, value in pairs(extra) do headers[key] = value end
    end
    local token = readAuthToken()
    if token then headers["Authorization"] = "Bearer " .. token end
    return headers
end

-- Server warnings can contain an upstream exception string.  Keep the useful
-- diagnosis while removing common credential forms and local account names.
local function sanitizeWarning(value)
    if type(value) ~= "string" then return nil end
    local warning = value:gsub("[%c]+", " "):gsub("%s+", " ")
    warning = warning:gsub("([Bb][Ee][Aa][Rr][Ee][Rr]%s+)[^%s,;]+", "%1[已脱敏]")
    warning = warning:gsub("([Aa][Uu][Tt][Hh][Oo][Rr][Ii][Zz][Aa][Tt][Ii][Oo][Nn]%s*[:=]%s*)[^%s,;]+", "%1[已脱敏]")
    warning = warning:gsub("([Vv][Oo][Ll][Cc]_[Aa][Cc][Cc][Ee][Ss][Ss]_[Kk][Ee][Yy]%s*[:=]%s*)[^%s,;]+", "%1[已脱敏]")
    warning = warning:gsub("([Vv][Oo][Ll][Cc]_[Ss][Ee][Cc][Rr][Ee][Tt]_[Kk][Ee][Yy]%s*[:=]%s*)[^%s,;]+", "%1[已脱敏]")
    warning = warning:gsub("([Aa][Cc][Cc][Ee][Ss][Ss]_[Kk][Ee][Yy]%s*[:=]%s*)[^%s,;]+", "%1[已脱敏]")
    warning = warning:gsub("([Ss][Ee][Cc][Rr][Ee][Tt]_[Kk][Ee][Yy]%s*[:=]%s*)[^%s,;]+", "%1[已脱敏]")
    warning = warning:gsub("([Aa][Cc][Cc][Ee][Ss][Ss][Kk][Ee][Yy]%s*[:=]%s*)[^%s,;]+", "%1[已脱敏]")
    warning = warning:gsub("([Ss][Ee][Cc][Rr][Ee][Tt][Kk][Ee][Yy]%s*[:=]%s*)[^%s,;]+", "%1[已脱敏]")
    warning = warning:gsub("([Aa][Kk]%s*[:=]%s*)[^%s,;]+", "%1[已脱敏]")
    warning = warning:gsub("([Ss][Kk]%s*[:=]%s*)[^%s,;]+", "%1[已脱敏]")
    warning = warning:gsub("([Tt][Oo][Kk][Ee][Nn]%s*[:=]%s*)[^%s,;]+", "%1[已脱敏]")
    warning = warning:gsub("[%w%._%+%-]+@[%w%.%-]+", "[邮箱已脱敏]")
    warning = warning:gsub("/Users/[^/%s]+", "~")
    warning = warning:gsub("[%w%+/%-_=%.]+", function(word)
        if #word >= 24 and word:match("%a") and word:match("%d") then
            return "[已脱敏]"
        end
        return word
    end)
    warning = warning:match("^%s*(.-)%s*$") or ""
    if warning == "" then return nil end
    return utf8Truncate(warning, 160)
end

local function warningDetail(warnings)
    if type(warnings) ~= "table" then return nil end
    for _, warning in ipairs(warnings) do
        if type(warning) == "string" and DIAGNOSTIC_HINT[warning] then
            return DIAGNOSTIC_HINT[warning]
        end
        local detail = sanitizeWarning(warning)
        if detail then return detail end
    end
    return nil
end

-- ---------- text capture ---------- --

local function getSelectionViaAX()
    local diag = { ax_ok = false, ax_text_len = 0 }
    local ok, el = pcall(hs.uielement.focusedElement)
    if not ok or not el then
        diag.ax_error = "no_focused_element"
        return nil, diag
    end
    local ok2, sel = pcall(function() return el:selectedText() end)
    if not ok2 then
        diag.ax_error = "selected_text_failed"
        return nil, diag
    end
    diag.ax_ok = true
    diag.ax_text_len = sel and #sel or 0
    if sel and #sel > 0 then return sel, diag end
    return nil, diag
end

local function getSelectionViaClipboard()
    local diag = {
        clipboard_changed = false,
        clipboard_elapsed_ms = 0,
        clipboard_text_len = 0,
        clipboard_timeout_ms = math.floor(CLIPBOARD_TIMEOUT_S * 1000),
    }
    local snapshot = hs.pasteboard.readAllData()
    local oldCount = hs.pasteboard.changeCount()
    local oldText = hs.pasteboard.getContents()
    local started = hs.timer.secondsSinceEpoch()
    hs.eventtap.keyStroke({ "cmd" }, "c", CLIPBOARD_KEY_DELAY_US)
    local deadline = started + CLIPBOARD_TIMEOUT_S
    local text = nil
    while hs.timer.secondsSinceEpoch() < deadline do
        hs.timer.usleep(20 * 1000) -- 20ms
        local countDelta = hs.pasteboard.changeCount() - oldCount
        local current = hs.pasteboard.getContents()
        if countDelta > 0 or (current and oldText and current ~= oldText) then
            text = current
            diag.clipboard_changed = countDelta > 0
            diag.clipboard_elapsed_ms = math.floor((hs.timer.secondsSinceEpoch() - started) * 1000)
            diag.clipboard_count_delta = countDelta
            diag.clipboard_text_len = text and #text or 0
            if text and #text > 0 then
                break
            end
        end
    end
    if not text or #text == 0 then
        local countDelta = hs.pasteboard.changeCount() - oldCount
        local current = hs.pasteboard.getContents()
        diag.clipboard_changed = countDelta > 0
        diag.clipboard_count_delta = countDelta
        diag.clipboard_elapsed_ms = math.floor((hs.timer.secondsSinceEpoch() - started) * 1000)
        diag.clipboard_text_len = current and #current or 0
        if countDelta > 0 then
            text = hs.pasteboard.getContents()
        end
    end
    -- Restore pasteboard byte-for-byte (rich text, files, images, …).
    if snapshot then
        hs.pasteboard.writeAllData(snapshot)
    end
    return text, diag
end

local function getSelectedText()
    local diag = {}
    local t, axDiag = getSelectionViaAX()
    diag.ax = axDiag
    if t then return t, "ax", diag end
    local clipDiag
    t, clipDiag = getSelectionViaClipboard()
    diag.clipboard = clipDiag
    if t and #t > 0 then return t, "clipboard", diag end
    return nil, nil, diag
end

-- ---------- canvas (singleton; new hotkey press deletes the previous) ---------- --

local function dismiss()
    if activeWatcher then
        activeWatcher:stop()
        activeWatcher = nil
    end
    if activeCanvas then
        activeCanvas:delete()
        activeCanvas = nil
    end
    activePopup = nil
end

-- Estimate the wrapped height of `text` laid out in a column `inner` wide.
-- Each hard line is measured on its own: multiplying the WHOLE text's natural
-- height by a wrap factor double-counts explicit newlines and oversizes the
-- popup for multiline translations.
local function measureWrapped(text, style, inner)
    local total = 0
    for line in (text .. "\n"):gmatch("(.-)\n") do
        local seg = (line == "") and " " or line
        local sz = hs.drawing.getTextDrawingSize(seg, style) or { w = inner, h = 18 }
        local wrapped = math.max(1, math.ceil(sz.w / math.max(1, inner)))
        total = total + math.ceil(sz.h * wrapped)
    end
    return total
end

local function fitTextToHeight(text, style, inner, maxHeight)
    if maxHeight <= 0 then return "", 0, true end
    local fullHeight = measureWrapped(text, style, inner)
    if fullHeight <= maxHeight then return text, fullHeight, false end

    -- Search on bytes and always pass candidates through utf8Truncate so a
    -- multibyte Chinese character is never split.
    local best = "…"
    local bestHeight = measureWrapped(best, style, inner)
    if bestHeight > maxHeight then return best, maxHeight, true end
    local low, high = 0, math.max(0, #text - 1)
    while low <= high do
        local mid = math.floor((low + high) / 2)
        local candidate = utf8Truncate(text, mid)
        local candidateHeight = measureWrapped(candidate, style, inner)
        if candidateHeight <= maxHeight then
            best, bestHeight = candidate, candidateHeight
            low = mid + 1
        else
            high = mid - 1
        end
    end
    return best, bestHeight, true
end

local function buildCanvas(mouseX, mouseY, body, subtitle, options)
    -- Measure: first an unconstrained pass to get the natural width.
    local mainStyle = {
        font = FONT_NAME,
        size = FONT_SIZE,
        color = { white = 1 },
        lineBreak = "wordWrap",
    }
    local subStyle = {
        font = FONT_NAME,
        size = FONT_SIZE - 3,
        color = { white = 0.7 },
        lineBreak = "wordWrap",
    }

    local natural = hs.drawing.getTextDrawingSize(body, mainStyle) or { w = MAX_WIDTH, h = 24 }
    local width = math.min(math.ceil(natural.w) + PADDING * 2, MAX_WIDTH)
    if width < 120 then width = 120 end

    local inner = width - PADDING * 2
    local displayBody = body
    local displaySubtitle = subtitle
    local bodyHeight = measureWrapped(displayBody, mainStyle, inner)
    local subHeight = 0
    if displaySubtitle and #displaySubtitle > 0 then
        subHeight = measureWrapped(displaySubtitle, subStyle, inner)
    end

    -- `screen:frame()` is the usable area (menu bar and Dock excluded).  Keep
    -- the popup strictly within it, clipping only the rendered copy: the full
    -- translation remains in activePopup.copyText for click-to-copy.
    local screen = hs.mouse.getCurrentScreen() or hs.screen.mainScreen()
    local sf = screen:frame()
    local maxHeight = math.max(1, math.floor(sf.h - 12))
    local gap = subHeight > 0 and 6 or 0
    local height = bodyHeight + subHeight + PADDING * 2 + gap
    if height > maxHeight then
        local overflowHint = "内容过长"
        if options and options.kind == "success" and options.copyText then
            overflowHint = "内容过长，点击复制完整译文"
        end
        if displaySubtitle and #displaySubtitle > 0 then
            displaySubtitle = overflowHint .. " · " .. displaySubtitle
        else
            displaySubtitle = overflowHint
        end

        local contentBudget = math.max(0, maxHeight - PADDING * 2)
        local minBodyHeight = measureWrapped("…", mainStyle, inner)
        local desiredSubBudget = math.floor(contentBudget * 0.35)
        local subBudget = math.max(0, math.min(desiredSubBudget, contentBudget - math.min(minBodyHeight, contentBudget)))
        displaySubtitle, subHeight = fitTextToHeight(displaySubtitle, subStyle, inner, subBudget)
        gap = subHeight > 0 and 6 or 0
        local bodyBudget = math.max(0, contentBudget - subHeight - gap)
        displayBody, bodyHeight = fitTextToHeight(displayBody, mainStyle, inner, bodyBudget)
        height = math.min(maxHeight, bodyHeight + subHeight + PADDING * 2 + gap)
    end

    -- Edge clipping: keep inside current screen bounds.
    local x = math.max(sf.x + 6, math.min(mouseX + 10, sf.x + sf.w - width - 10))
    local y = math.max(sf.y + 6, math.min(mouseY + 10, sf.y + sf.h - height - 10))

    local c = hs.canvas.new({ x = x, y = y, w = width, h = height })
    c:appendElements({
        type = "rectangle",
        action = "fill",
        fillColor = { white = 0.08, alpha = 0.95 },
        roundedRectRadii = { xRadius = 6, yRadius = 6 },
    })
    c:appendElements({
        id = "body",
        type = "text",
        text = displayBody,
        textFont = FONT_NAME,
        textSize = FONT_SIZE,
        textColor = { white = 1 },
        textLineBreak = "wordWrap",
        frame = { x = PADDING, y = PADDING, w = inner, h = bodyHeight },
    })
    if displaySubtitle and #displaySubtitle > 0 and subHeight > 0 then
        c:appendElements({
            id = "sub",
            type = "text",
            text = displaySubtitle,
            textFont = FONT_NAME,
            textSize = FONT_SIZE - 3,
            textColor = { white = 0.7 },
            frame = {
                x = PADDING,
                y = PADDING + bodyHeight + gap,
                w = inner,
                h = subHeight,
            },
        })
    end
    return c
end

local function pointInFrame(point, frame)
    return point.x >= frame.x and point.x <= frame.x + frame.w
        and point.y >= frame.y and point.y <= frame.y + frame.h
end

local function handlePopupClick()
    local popup = activePopup
    if not popup then return end
    if popup.generation and (not activeRequest or popup.generation ~= activeRequest.generation) then
        dismiss()
        return
    end
    local kind = popup.kind
    local copyText = popup.copyText
    dismiss()
    if (kind == "success" or kind == "error") and copyText and #copyText > 0 then
        local ok, copied = pcall(hs.pasteboard.setContents, copyText)
        if ok and copied ~= false then
            hs.alert.show(kind == "success" and "已复制译文" or "已复制错误详情", 0.8)
        else
            hs.alert.show("复制失败", 1.0)
        end
    end
end

local function show(mouseX, mouseY, body, subtitle, options)
    dismiss()
    options = options or { kind = "transition" }
    activeCanvas = buildCanvas(mouseX, mouseY, body, subtitle, options)
    activePopup = {
        kind = options.kind or "transition",
        copyText = options.copyText,
        generation = options.generation,
    }
    activeCanvas:show()

    -- Popup clicks are consumed so they do not click through into the current
    -- app. Outside clicks only dismiss and continue to their original target.
    activeWatcher = hs.eventtap.new(
        {
            hs.eventtap.event.types.leftMouseDown,
            hs.eventtap.event.types.rightMouseDown,
            hs.eventtap.event.types.otherMouseDown,
            hs.eventtap.event.types.keyDown,
        },
        function(event)
            if not activeCanvas then return false end
            local eventType = event:getType()
            if eventType == hs.eventtap.event.types.keyDown then
                local escapeKey = (hs.keycodes.map and hs.keycodes.map.escape) or 53
                if event:getKeyCode() == escapeKey then
                    dismiss()
                    return true
                end
                return false
            end
            local p = event:location()
            local f = activeCanvas:frame()
            if not pointInFrame(p, f) then
                dismiss()
                return false
            end
            if eventType == hs.eventtap.event.types.leftMouseDown
                and activePopup then
                -- The overflow hint lives in the subtitle, so the entire
                -- popup is clickable even though the primary target is body.
                handlePopupClick()
                return true
            end
            dismiss()
            return true
        end
    )
    activeWatcher:start()
end

local function update(body, subtitle, options)
    if not activeCanvas then return end
    -- Rebuild in-place rather than mutate fields (height may change).
    local f = activeCanvas:frame()
    local mx, my = f.x - 10, f.y - 10
    show(mx, my, body, subtitle, options)
end

-- ---------- translation call with progressive timeouts ---------- --

local function stopRequestTimers(request)
    if not request or not request.timers then return end
    for _, timer in pairs(request.timers) do
        if timer then timer:stop() end
    end
    request.timers = {}
end

local function beginRequest()
    requestGeneration = requestGeneration + 1
    if activeRequest then stopRequestTimers(activeRequest) end
    activeRequest = { generation = requestGeneration, timers = {}, finished = false }
    -- A new gesture owns the UI immediately, even while selection capture is
    -- still in progress. This also prevents an old popup lingering on failure.
    dismiss()
    return activeRequest
end

local function requestIsCurrent(request)
    return request ~= nil
        and activeRequest == request
        and request.generation == requestGeneration
end

local function popupOptions(request, kind, copyText)
    return {
        generation = request.generation,
        kind = kind,
        copyText = copyText,
    }
end

local function showForRequest(request, mouseX, mouseY, body, subtitle, kind, copyText)
    if not requestIsCurrent(request) then return end
    show(mouseX, mouseY, body, subtitle, popupOptions(request, kind, copyText))
end

local function updateForRequest(request, body, subtitle, kind, copyText)
    if not requestIsCurrent(request) or not activeCanvas then return end
    update(body, subtitle, popupOptions(request, kind, copyText))
end

local function joinDetails(detail, hint)
    if detail and hint then return detail .. " · " .. hint end
    return detail or hint
end

local function errorCopyText(title, subtitle)
    if subtitle and #subtitle > 0 then return title .. "\n" .. subtitle end
    return title
end

local function showRequestError(request, title, subtitle)
    updateForRequest(request, title, subtitle, "error", errorCopyText(title, subtitle))
end

local function callTranslate(text, source, request)
    if not requestIsCurrent(request) then return end
    local mp = hs.mouse.absolutePosition()
    local frontApp = hs.application.frontmostApplication()
    local appName = frontApp and frontApp:name() or "unknown"
    showForRequest(request, mp.x, mp.y, "翻译中…", nil, "transition", nil)
    appendLog({ event = "trigger", app = appName, source = source or "unknown", input_len = #text })

    local requestEngine = currentEngine
    if requestEngine == "volc" and cloudRemovalBlocksVolc() then
        -- Persist the safe choice as well as overriding this individual
        -- request, so async health/watcher state cannot re-enable cloud on the
        -- next gesture while removal is unfinished.
        requestEngine = "apple"
        currentEngine = "apple"
        persistEngine("apple")
        rebuildMenu()
        appendLog({ event = "cloud_request_blocked", reason = "removal_pending" })
    end
    local body = hs.json.encode({ text = text, engine = requestEngine })

    request.timers.t08 = hs.timer.doAfter(0.8, function()
        if not requestIsCurrent(request) then return end
        updateForRequest(request, "翻译中…(已 0.8s)", nil, "transition", nil)
    end)
    request.timers.t15 = hs.timer.doAfter(1.5, function()
        if not requestIsCurrent(request) then return end
        updateForRequest(request, "服务无响应,检查中…", nil, "transition", nil)
        hs.http.asyncGet(URL .. "/health", requestHeaders(), function(code, _, _)
            if not requestIsCurrent(request) or request.finished or not activeCanvas then return end
            if code ~= 200 then
                showRequestError(request, "翻译组件没有响应", "请打开句译自动修复")
            end
        end)
    end)
    request.timers.t30 = hs.timer.doAfter(3.0, function()
        if not requestIsCurrent(request) then return end
        showRequestError(
            request,
            "失败:超时",
            "请打开句译，前往“诊断与帮助”"
        )
    end)

    hs.http.asyncPost(
        URL .. "/translate",
        body,
        requestHeaders({ ["Content-Type"] = "application/json" }),
        function(status, response, _)
            stopRequestTimers(request)
            request.finished = true
            if not requestIsCurrent(request) or not activeCanvas then return end
            if status == nil or status == 0 then
                appendLog({ event = "translate_done", app = appName, source = source or "unknown", status = status or 0, error = "connect_failed" })
                showRequestError(request, "翻译组件没有响应", "请打开句译自动修复")
                return
            end
            local ok, parsed = pcall(hs.json.decode, response or "")
            if not ok or type(parsed) ~= "table" then
                appendLog({ event = "translate_done", app = appName, source = source or "unknown", status = status, error = "json_decode" })
                showRequestError(
                    request,
                    string.format("响应解析失败 (HTTP %d)", tonumber(status) or 0),
                    "请打开句译，前往“诊断与帮助”"
                )
                return
            end
            appendLog({
                event = "translate_done",
                app = appName,
                source = source or "unknown",
                status = status,
                engine = parsed.engine or "",
                elapsed_ms = parsed.elapsed_ms or 0,
                cached = parsed.cached or false,
                error = parsed.error or "",
            })
            local detail = warningDetail(parsed.warnings) or sanitizeWarning(parsed.detail)
            local httpStatus = tonumber(status) or 0
            if parsed.error == "empty_input" then
                local hint = joinDetails(detail, "请重新选择英文文本")
                showRequestError(request, "(空输入)", hint)
                return
            end
            if httpStatus < 200 or httpStatus >= 300 then
                local hint = httpStatus == 401
                    and "请打开句译自动修复本地认证"
                    or "请打开句译，前往“诊断与帮助”"
                showRequestError(
                    request,
                    string.format("翻译请求失败 (HTTP %d)", httpStatus),
                    joinDetails(detail, hint)
                )
                return
            end
            if parsed.error == "src_lang_mismatch" then
                local hint = joinDetails(detail, "源语言看起来不是英文，请重新选择英文文本")
                updateForRequest(
                    request,
                    type(parsed.result) == "string" and parsed.result or "未识别到英文文本",
                    hint,
                    "error",
                    errorCopyText("未识别到英文文本", hint)
                )
                return
            end
            if parsed.error and parsed.error ~= "" then
                local title = ERROR_TITLE[parsed.error]
                    or ("翻译出错：" .. tostring(parsed.error))
                local hint = ERROR_HINT[parsed.error]
                    or "请打开句译，前往“诊断与帮助”"
                local subtitle = joinDetails(detail, hint)
                showRequestError(request, "⚠️ " .. title, subtitle)
                return
            end
            local result = type(parsed.result) == "string" and parsed.result or "(空结果)"
            local engUsed = parsed.engine or currentEngine
            local subParts = {
                "来自 " .. (ENGINE_SOURCE[engUsed] or engUsed),
                string.format("%d ms", tonumber(parsed.elapsed_ms) or 0),
            }
            if parsed.cached then table.insert(subParts, "cached") end
            if parsed.truncated then table.insert(subParts, "已截断") end
            if parsed.skipped then table.insert(subParts, "未翻译") end
            updateForRequest(
                request,
                result,
                table.concat(subParts, " · "),
                "success",
                result
            )
        end
    )
end

-- ---------- engine selection (menu bar) ---------- --

local function readPersistedEngine()
    local f = io.open(ENGINE_STATE_PATH, "r")
    if not f then return nil end
    local s = f:read("*l")
    f:close()
    if s then s = s:gsub("%s+", "") end
    if s == "argos" then return "apple" end -- legacy engine, removed
    if s == "volc" or s == "apple" then return s end
    return nil
end

persistEngine = function(eng)
    local f = io.open(ENGINE_STATE_PATH, "w")
    if f then
        f:write(eng .. "\n")
        f:close()
    end
end

rebuildMenu = function()
    if not menubar then return end
    menubar:setTitle("句译·" .. (ENGINE_SHORT[currentEngine] or "?"))
    menubar:setMenu({
        { title = "翻译引擎", disabled = true },
        {
            title = "苹果端上（离线 · 系统翻译）",
            checked = (currentEngine == "apple"),
            disabled = (not appleAvailable),
            fn = function() setEngine("apple") end,
        },
        {
            title = "云端（火山 · 需联网）",
            checked = (currentEngine == "volc"),
            disabled = (not volcAvailable),
            fn = function() setEngine("volc") end,
        },
        { title = "-" },
        { title = "译文下方会标注「来自 …」", disabled = true },
    })
end

setEngine = function(eng)
    if eng == "volc" and cloudRemovalBlocksVolc() then
        currentEngine = "apple"
        persistEngine("apple")
        rebuildMenu()
        hs.alert.show("云端配置正在移除，已保持离线模式", 1.8)
        return
    end
    if eng == "volc" and not volcAvailable then
        hs.alert.show("云端不可用：未配置火山 API Key", 1.5)
        return
    end
    if eng == "apple" and not appleAvailable then
        hs.alert.show("苹果端上翻译不可用（需 macOS 15+ 并构建助手）", 1.8)
        return
    end
    currentEngine = eng
    persistEngine(eng)
    rebuildMenu()
    if eng == "volc" then
        hs.alert.show("已切到 火山云端", 1.0)
    else
        hs.alert.show("已切到 苹果端上翻译", 1.2)
        -- Warm the helper in the background so the first real translation
        -- after switching isn't slow.
        hs.http.asyncPost(
            URL .. "/translate",
            hs.json.encode({ text = "warmup", engine = eng }),
            requestHeaders({ ["Content-Type"] = "application/json" }),
            function() end
        )
    end
    appendLog({ event = "engine_switch", engine = eng })
end

local function initEngineState()
    hs.http.asyncGet(URL .. "/health", requestHeaders(), function(code, bodyStr, _)
        -- Re-read at callback time. A user may switch from cloud back to
        -- offline while this health request is in flight; a stale callback
        -- must never re-enable cloud uploads.
        local persisted = readPersistedEngine()
        if code == 200 then
            local ok, h = pcall(hs.json.decode, bodyStr or "")
            if ok and type(h) == "table" then
                if h.engines ~= nil then
                    if h.engines.volc ~= nil then
                        volcAvailable = h.engines.volc and true or false
                    end
                    if h.engines.apple ~= nil then
                        appleAvailable = h.engines.apple and true or false
                    end
                end
                if not persisted and h.default_engine then
                    currentEngine = h.default_engine
                end
            end
        end
        if persisted then currentEngine = persisted end
        if currentEngine == "argos" then currentEngine = "apple" end
        if currentEngine == "volc" and cloudRemovalBlocksVolc() then
            currentEngine = "apple"
            persistEngine("apple")
        end
        -- Keep the user's explicit choice even when it is temporarily
        -- unavailable. In particular, never turn an offline choice into a
        -- cloud upload without prior consent.
        rebuildMenu()
    end)
end

local function startExternalEngineWatcher()
    if externalEngineWatcher then externalEngineWatcher:stop() end
    externalEngineWatcher = hs.timer.doEvery(1.0, function()
        local paused = isPaused()
        if tapWatcher then
            if paused and tapWatcher:isEnabled() then tapWatcher:stop() end
            if not paused and not tapWatcher:isEnabled() then tapWatcher:start() end
        end
        writeStatus(true)
        local requested = readPersistedEngine()
        if (requested == "volc" or currentEngine == "volc")
            and cloudRemovalBlocksVolc() then
            currentEngine = "apple"
            persistEngine("apple")
            rebuildMenu()
            appendLog({ event = "cloud_request_blocked", reason = "removal_pending" })
            requested = "apple"
        end
        if requested and requested ~= currentEngine then
            if (requested == "apple" and appleAvailable) or (requested == "volc" and volcAvailable) then
                currentEngine = requested
                rebuildMenu()
                appendLog({ event = "engine_switch_external", engine = requested })
            else
                -- Availability can change after the native app saves cloud
                -- credentials and restarts the service. Refresh rather than
                -- requiring a Hammerspoon config reload.
                hs.http.asyncGet(URL .. "/health", requestHeaders(), function(code, bodyStr, _)
                    if code ~= 200 then return end
                    if readPersistedEngine() ~= requested then return end
                    local ok, h = pcall(hs.json.decode, bodyStr or "")
                    if not ok or type(h) ~= "table" or type(h.engines) ~= "table" then return end
                    appleAvailable = h.engines.apple and true or false
                    volcAvailable = h.engines.volc and true or false
                    if (requested == "apple" and appleAvailable) or (requested == "volc" and volcAvailable) then
                        currentEngine = requested
                        rebuildMenu()
                        appendLog({ event = "engine_switch_external", engine = requested })
                    end
                end)
            end
        end
    end)
end

-- ---------- hotkey entry ---------- --

local function onHotkey()
    local request = beginRequest()
    local text, src, diag = getSelectedText()
    if not text or #text == 0 then
        local frontApp = hs.application.frontmostApplication()
        local failure = {
            event = "trigger_failed",
            reason = "no_selection",
            app = frontApp and frontApp:name() or "unknown",
        }
        if diag and diag.ax then
            failure.ax_ok = diag.ax.ax_ok
            failure.ax_text_len = diag.ax.ax_text_len
            failure.ax_error = diag.ax.ax_error or ""
        end
        if diag and diag.clipboard then
            failure.clipboard_changed = diag.clipboard.clipboard_changed
            failure.clipboard_count_delta = diag.clipboard.clipboard_count_delta or 0
            failure.clipboard_elapsed_ms = diag.clipboard.clipboard_elapsed_ms or 0
            failure.clipboard_text_len = diag.clipboard.clipboard_text_len or 0
            failure.clipboard_timeout_ms = diag.clipboard.clipboard_timeout_ms or 0
        end
        appendLog(failure)
        hs.alert.show("未检测到选中文本", 1.2)
        return
    end
    callTranslate(text, src, request)
end

-- ---------- double-tap Option detection ---------- --

local function flagsOnlyOption(flags)
    return flags.alt and not flags.cmd and not flags.ctrl and not flags.shift and not flags.fn
end

local function flagsCleared(flags)
    return not flags.alt and not flags.cmd and not flags.ctrl and not flags.shift and not flags.fn
end

local function onFlagsOrKey(event)
    if event:getType() == hs.eventtap.event.types.keyDown then
        -- A real key was pressed; if Option is held this isn't a lone tap.
        if optDown then sawOtherKey = true end
        return false
    end

    -- flagsChanged
    local flags = event:getFlags()
    local now = hs.timer.secondsSinceEpoch()

    if flagsOnlyOption(flags) and not optDown then
        optDown = true
        optPressTime = now
        sawOtherKey = false
    elseif flagsCleared(flags) and optDown then
        optDown = false
        local clean = (not sawOtherKey) and (now - optPressTime) <= TAP_MAX_HOLD_S
        if clean and (now - lastTapTime) <= DOUBLE_TAP_WINDOW_S then
            lastTapTime = 0
            -- Run capture outside the eventtap callback. The clipboard fallback
            -- posts Cmd+C and waits for pasteboard changes; doing that while
            -- still inside the flagsChanged callback can starve the synthetic
            -- key event until after the wait has already timed out.
            hs.timer.doAfter(0.01, onHotkey)
        elseif clean then
            lastTapTime = now
        else
            lastTapTime = 0
        end
    elseif optDown then
        -- Option still down but another modifier changed → not a lone tap.
        sawOtherKey = true
    end

    return false
end

-- Python's side rotates via RotatingFileHandler; this log needs its own cap.
local function rotateLogIfNeeded()
    local f = io.open(LOG_PATH, "r")
    if not f then return end
    local size = f:seek("end")
    f:close()
    if size and size > 5 * 1024 * 1024 then
        os.remove(LOG_PATH .. ".1")
        os.rename(LOG_PATH, LOG_PATH .. ".1")
    end
end

function M.start()
    rotateLogIfNeeded()
    if tapWatcher then tapWatcher:stop() end
    tapWatcher = hs.eventtap.new(
        { hs.eventtap.event.types.flagsChanged, hs.eventtap.event.types.keyDown },
        onFlagsOrKey
    )
    tapWatcher:start()
    if isPaused() then tapWatcher:stop() end
    startExternalEngineWatcher()
    -- The native app is the single Juyi menu-bar surface. Hammerspoon keeps
    -- only the hotkey, popup and engine watcher.
    if menubar then menubar:delete(); menubar = nil end
    initEngineState()
    writeStatus(true)
    hs.accessibilityStateCallback = function() writeStatus(true) end
end

function M.stop()
    if activeRequest then stopRequestTimers(activeRequest) end
    activeRequest = nil
    requestGeneration = requestGeneration + 1
    if tapWatcher then
        tapWatcher:stop()
        tapWatcher = nil
    end
    if menubar then
        menubar:delete()
        menubar = nil
    end
    if externalEngineWatcher then externalEngineWatcher:stop(); externalEngineWatcher = nil end
    writeStatus(false)
    dismiss()
end

M.start()
return M
