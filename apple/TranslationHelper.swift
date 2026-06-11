// TranslationHelper.swift
// Headless bridge to the macOS 15+ Translation framework (system on-device translation).
//
// The Translation API is Swift-only and must be driven from a SwiftUI view via
// .translationTask. To use it from a non-GUI service we host an NSHostingView in
// an invisible off-screen window of an .accessory NSApplication and run the
// request loop inside the translationTask closure, where the session is valid.
//
// Modes:
//   (default)       long-lived server. One JSON request per stdin line:
//                       {"id":"...","text":"..."}
//                   one JSON response per stdout line:
//                       {"id":"...","result":"...","error":null}
//                   An empty "text" is a liveness ping answered without
//                   translating. Emits {"id":"__ready__",...} once the
//                   translation session is usable. Exits when stdin closes.
//   --status        print the en -> zh-Hans language-pack status and exit:
//                   installed | supported | unsupported
//   --once <text>   translate one string, print the translation, exit.
//   --prepare       show a small window and ask the system to download the
//                   en -> zh-Hans language pack (user confirmation dialog).
//
// Build: swiftc -O -o bin/apple-translation-helper apple/TranslationHelper.swift

import AppKit
import Foundation
import SwiftUI
import Translation

// MARK: - Language pair (mirrors config.py SRC_LANG/TGT_LANG; zh maps to zh-Hans)

let sourceLanguage = Locale.Language(identifier: "en")
let targetLanguage = Locale.Language(identifier: "zh-Hans")

// MARK: - JSON line protocol

struct LineRequest: Decodable {
    let id: String
    let text: String
}

struct LineResponse: Encodable {
    let id: String
    let result: String?
    let error: String?
}

let stdoutLock = NSLock()

func emit(_ response: LineResponse) {
    guard let data = try? JSONEncoder().encode(response),
          let line = String(data: data, encoding: .utf8) else { return }
    stdoutLock.lock()
    FileHandle.standardOutput.write(Data((line + "\n").utf8))
    stdoutLock.unlock()
}

func logErr(_ message: String) {
    FileHandle.standardError.write(Data(("apple-translation-helper: " + message + "\n").utf8))
}

func statusString(_ status: LanguageAvailability.Status) -> String {
    switch status {
    case .installed: return "installed"
    case .supported: return "supported"
    case .unsupported: return "unsupported"
    @unknown default: return "unsupported"
    }
}

// MARK: - Modes

enum Mode {
    case serve
    case status
    case once(String)
    case prepare
}

func parseMode() -> Mode {
    let args = Array(CommandLine.arguments.dropFirst())
    guard let first = args.first else { return .serve }
    switch first {
    case "--status":
        return .status
    case "--prepare":
        return .prepare
    case "--once":
        guard args.count >= 2 else {
            logErr("--once requires a text argument")
            exit(2)
        }
        return .once(args[1])
    default:
        logErr("unknown argument: \(first)")
        exit(2)
    }
}

// MARK: - stdin reader (serve mode): feeds an AsyncStream consumed in the session

let requestPipe = AsyncStream.makeStream(of: LineRequest.self)

func startStdinReader() {
    let thread = Thread {
        while let line = readLine(strippingNewline: true) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            guard let request = try? JSONDecoder().decode(LineRequest.self, from: Data(trimmed.utf8)) else {
                emit(LineResponse(id: "", result: nil, error: "bad_request_json"))
                continue
            }
            requestPipe.continuation.yield(request)
        }
        // stdin closed: the parent process is gone. Shut down.
        requestPipe.continuation.finish()
        DispatchQueue.main.async { NSApplication.shared.terminate(nil) }
    }
    thread.name = "stdin-reader"
    thread.start()
}

// MARK: - SwiftUI bridge view: owns the TranslationSession

struct BridgeView: View {
    let mode: Mode
    @State private var configuration: TranslationSession.Configuration?

    var body: some View {
        Color.clear
            .frame(width: 1, height: 1)
            .translationTask(configuration) { session in
                await run(session)
            }
            .onAppear {
                configuration = TranslationSession.Configuration(
                    source: sourceLanguage,
                    target: targetLanguage
                )
            }
    }

    private func run(_ session: TranslationSession) async {
        switch mode {
        case .serve:
            emit(LineResponse(id: "__ready__", result: "ready", error: nil))
            for await request in requestPipe.stream {
                if request.text.isEmpty {
                    // Liveness ping: round-trip without touching the engine.
                    emit(LineResponse(id: request.id, result: "", error: nil))
                    continue
                }
                do {
                    let response = try await session.translate(request.text)
                    emit(LineResponse(id: request.id, result: response.targetText, error: nil))
                } catch {
                    emit(LineResponse(id: request.id, result: nil, error: String(describing: error)))
                }
            }
        case .once(let text):
            do {
                let response = try await session.translate(text)
                print(response.targetText)
                exit(0)
            } catch {
                logErr("translate failed: \(error)")
                exit(1)
            }
        case .prepare:
            do {
                // Triggers the system download-confirmation dialog if the pack
                // is supported but not installed; returns once it is usable.
                try await session.prepareTranslation()
                let status = await LanguageAvailability().status(from: sourceLanguage, to: targetLanguage)
                print(statusString(status))
                exit(statusString(status) == "installed" ? 0 : 1)
            } catch {
                logErr("prepareTranslation failed: \(error)")
                exit(1)
            }
        case .status:
            exit(0) // unreachable: --status never starts the app
        }
    }
}

// MARK: - App shell: invisible window hosting the bridge view

final class AppDelegate: NSObject, NSApplicationDelegate {
    let mode: Mode
    var window: NSWindow?

    init(mode: Mode) {
        self.mode = mode
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        var visible = false
        if case .prepare = mode { visible = true }

        let rect = visible
            ? NSRect(x: 0, y: 0, width: 380, height: 100)
            : NSRect(x: -10_000, y: -10_000, width: 1, height: 1)
        let style: NSWindow.StyleMask = visible ? [.titled, .closable] : [.borderless]
        let win = NSWindow(contentRect: rect, styleMask: style, backing: .buffered, defer: false)
        win.contentView = NSHostingView(rootView: BridgeView(mode: mode))
        win.isReleasedWhenClosed = false
        if visible {
            // The system attaches its download-confirmation UI near our window;
            // it must be visible and frontmost for the user to click it.
            win.title = "juyi - download translation language pack"
            win.center()
            win.makeKeyAndOrderFront(nil)
            NSApplication.shared.activate(ignoringOtherApps: true)
        } else {
            win.alphaValue = 0
            win.isOpaque = false
            win.backgroundColor = .clear
            win.ignoresMouseEvents = true
            win.orderFrontRegardless()
        }
        window = win
    }
}

// MARK: - Entry point

let mode = parseMode()

if case .status = mode {
    // No UI needed: query availability and exit.
    Task {
        let status = await LanguageAvailability().status(from: sourceLanguage, to: targetLanguage)
        print(statusString(status))
        exit(0)
    }
    dispatchMain()
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate(mode: mode)
app.delegate = delegate

if case .serve = mode {
    startStdinReader()
}

app.run()
