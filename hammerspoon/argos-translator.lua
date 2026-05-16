-- argos-translator.lua
-- ⌥+T to translate the current selection via the local argos-translator service.
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
local HOTKEY_MODS = { "alt" }
local HOTKEY_KEY = "t"
local FONT_NAME = ".AppleSystemUIFont"
local FONT_SIZE = 14
local MAX_WIDTH = 460
local PADDING = 12
local LOG_PATH = os.getenv("HOME") .. "/Library/Logs/argos-translator-hs.log"
local CLIPBOARD_TIMEOUT_S = 1.2
local CLIPBOARD_KEY_DELAY_US = 100 * 1000

local activeCanvas = nil
local activeWatcher = nil
local hotkey = nil

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
end

local function buildCanvas(mouseX, mouseY, body, subtitle)
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

    -- Re-measure body with the chosen width to compute wrapped height.
    local inner = width - PADDING * 2
    local bodySize = hs.drawing.getTextDrawingSize(body, mainStyle) or { w = inner, h = 24 }
    local bodyLines = math.max(1, math.ceil(bodySize.w / math.max(1, inner)))
    local bodyHeight = math.ceil(bodySize.h * bodyLines)
    local subSize = { w = 0, h = 0 }
    local subHeight = 0
    if subtitle and #subtitle > 0 then
        subSize = hs.drawing.getTextDrawingSize(subtitle, subStyle) or { w = inner, h = 14 }
        local subLines = math.max(1, math.ceil(subSize.w / math.max(1, inner)))
        subHeight = math.ceil(subSize.h * subLines)
    end
    local height = bodyHeight + subHeight + PADDING * 2 + (subtitle and 6 or 0)

    -- Edge clipping: keep inside current screen bounds.
    local screen = hs.mouse.getCurrentScreen() or hs.screen.mainScreen()
    local sf = screen:frame()
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
        text = body,
        textFont = FONT_NAME,
        textSize = FONT_SIZE,
        textColor = { white = 1 },
        textLineBreak = "wordWrap",
        frame = { x = PADDING, y = PADDING, w = inner, h = bodyHeight },
    })
    if subtitle and #subtitle > 0 then
        c:appendElements({
            id = "sub",
            type = "text",
            text = subtitle,
            textFont = FONT_NAME,
            textSize = FONT_SIZE - 3,
            textColor = { white = 0.7 },
            frame = {
                x = PADDING,
                y = PADDING + bodyHeight + 6,
                w = inner,
                h = subHeight,
            },
        })
    end
    return c
end

local function show(mouseX, mouseY, body, subtitle)
    dismiss()
    activeCanvas = buildCanvas(mouseX, mouseY, body, subtitle)
    activeCanvas:show()

    -- Click outside the canvas dismisses it. Don't consume the event so the
    -- click still hits whatever is under the cursor.
    activeWatcher = hs.eventtap.new(
        { hs.eventtap.event.types.leftMouseDown },
        function(event)
            if not activeCanvas then return false end
            local p = event:location()
            local f = activeCanvas:frame()
            if p.x < f.x or p.x > f.x + f.w or p.y < f.y or p.y > f.y + f.h then
                dismiss()
            end
            return false
        end
    )
    activeWatcher:start()
end

local function update(body, subtitle)
    if not activeCanvas then return end
    -- Rebuild in-place rather than mutate fields (height may change).
    local f = activeCanvas:frame()
    local mx, my = f.x - 10, f.y - 10
    show(mx, my, body, subtitle)
end

-- ---------- translation call with progressive timeouts ---------- --

local function callTranslate(text, source)
    local mp = hs.mouse.absolutePosition()
    local frontApp = hs.application.frontmostApplication()
    local appName = frontApp and frontApp:name() or "unknown"
    show(mp.x, mp.y, "翻译中…", nil)
    appendLog({ event = "trigger", app = appName, source = source or "unknown", input_len = #text })

    local body = hs.json.encode({ text = text })

    local t08, t15, t30
    t08 = hs.timer.doAfter(0.8, function()
        update("翻译中…(已 0.8s)", nil)
    end)
    t15 = hs.timer.doAfter(1.5, function()
        update("服务无响应,检查中…", nil)
        hs.http.asyncGet(URL .. "/health", function(code, _, _)
            if not activeCanvas then return end
            if code ~= 200 then
                update(string.format("服务异常 (HTTP %s)", tostring(code)), nil)
            end
        end)
    end)
    t30 = hs.timer.doAfter(3.0, function()
        update(
            "失败:超时",
            "运行 ~/.local/share/argos-translator/scripts/test.sh 诊断"
        )
    end)

    hs.http.asyncPost(
        URL .. "/translate",
        body,
        { ["Content-Type"] = "application/json" },
        function(status, response, _)
            if t08 then t08:stop() end
            if t15 then t15:stop() end
            if t30 then t30:stop() end
            if not activeCanvas then return end -- user dismissed
            if status == nil or status == 0 then
                appendLog({ event = "translate_done", app = appName, source = source or "unknown", status = status or 0, error = "connect_failed" })
                update("失败:无法连接 127.0.0.1:54321", "确认 launchd 服务在运行")
                return
            end
            local ok, parsed = pcall(hs.json.decode, response or "")
            if not ok or type(parsed) ~= "table" then
                appendLog({ event = "translate_done", app = appName, source = source or "unknown", status = status, error = "json_decode" })
                update(string.format("响应解析失败 (HTTP %d)", status), nil)
                return
            end
            appendLog({
                event = "translate_done",
                app = appName,
                source = source or "unknown",
                status = status,
                elapsed_ms = parsed.elapsed_ms or 0,
                cached = parsed.cached or false,
                error = parsed.error or "",
            })
            if parsed.error == "empty_input" then
                update("(空输入)", nil)
                return
            end
            if parsed.error == "src_lang_mismatch" then
                update(parsed.result or "", "源语言看起来不是英文")
                return
            end
            local result = parsed.result or "(空结果)"
            local subParts = { string.format("%d ms", parsed.elapsed_ms or 0) }
            if parsed.cached then table.insert(subParts, "cached") end
            if parsed.truncated then table.insert(subParts, "已截断") end
            if parsed.skipped then table.insert(subParts, "未翻译") end
            update(result, table.concat(subParts, " · "))
        end
    )
end

-- ---------- hotkey entry ---------- --

local function onHotkey()
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
    callTranslate(text, src)
end

function M.start()
    if hotkey then hotkey:delete() end
    hotkey = hs.hotkey.bind(HOTKEY_MODS, HOTKEY_KEY, onHotkey)
end

function M.stop()
    if hotkey then
        hotkey:delete()
        hotkey = nil
    end
    dismiss()
end

M.start()
return M
