// qwd: streams every on-screen macOS window and replays pointer input. Spawned by server.py.
// stdout: [u8 type][u32 id][u32 length][payload], big-endian. 1 = JPEG of window `id`,
//         2 = JSON list of windows (front to back), 3 = JSON cursor {id, x, y}.
// stdin:  JSON lines {t: down|up|move|scroll, id, x, y (0...1 inside the window), b (1 = right), dx, dy}.
import AppKit
import ScreenCaptureKit

let maxSide = 1920.0   // ponytail: one JPEG per changed frame; VideoToolbox H.264 + WebCodecs if Wi-Fi can't keep up
let hiddenApps: Set<String> = ["com.apple.dock", "com.apple.WindowManager", "com.apple.controlcenter",
                               "com.apple.notificationcenterui", "com.apple.systemuiserver"]
let ci = CIContext()
let outLock = NSLock()

func emit(_ type: UInt8, _ id: UInt32, _ payload: Data) {
    var d = Data([type])
    withUnsafeBytes(of: id.bigEndian) { d.append(contentsOf: $0) }
    withUnsafeBytes(of: UInt32(payload.count).bigEndian) { d.append(contentsOf: $0) }
    d.append(payload)
    outLock.lock(); FileHandle.standardOutput.write(d); outLock.unlock()
}

func log(_ s: String) { FileHandle.standardError.write(Data("qwd: \(s)\n".utf8)) }

struct Win { let id: CGWindowID, pid: pid_t, layer: Int, frame: CGRect, app: String, title: String }
var bundleIDs: [pid_t: String] = [:]

func windows() -> [Win] {   // on-screen windows, front to back
    let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
    return list.compactMap { d in
        guard let id = d[kCGWindowNumber as String] as? Int, let pid = (d[kCGWindowOwnerPID as String] as? Int).map(pid_t.init),
              let layer = d[kCGWindowLayer as String] as? Int, layer < 1000, layer != 24, layer != 25,
              (d[kCGWindowAlpha as String] as? Double ?? 1) > 0,
              let b = d[kCGWindowBounds as String] as? NSDictionary, let f = CGRect(dictionaryRepresentation: b as CFDictionary),
              f.width >= 24, f.height >= 24 else { return nil }
        let app = d[kCGWindowOwnerName as String] as? String ?? ""
        let bid = bundleIDs[pid] ?? NSRunningApplication(processIdentifier: pid)?.bundleIdentifier ?? ""
        bundleIDs[pid] = bid
        if app == "Window Server" || hiddenApps.contains(bid) { return nil }
        return Win(id: CGWindowID(id), pid: pid, layer: layer, frame: f, app: app, title: d[kCGWindowName as String] as? String ?? "")
    }
}

// MARK: capture

final class Capture: NSObject, SCStreamOutput {
    let id: CGWindowID
    var size: CGSize
    var stream: SCStream?
    var last = Data()
    init(_ id: CGWindowID, _ size: CGSize) { self.id = id; self.size = size }

    func stream(_ s: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard let info = (CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]])?.first,
              info[.status] as? Int == SCFrameStatus.complete.rawValue,   // idle frames carry nothing new
              let px = sb.imageBuffer,
              let jpg = ci.jpegRepresentation(of: CIImage(cvPixelBuffer: px), colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                                              options: [CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String): 0.7])
              jpg != last   // ScreenCaptureKit also marks unchanged windows complete whenever anything else redraws
        else { return }
        last = jpg
        emit(1, id, jpg)
    }
}

func config(_ f: CGRect) -> SCStreamConfiguration {
    let c = SCStreamConfiguration(), scale = min(2, maxSide / max(f.width, f.height))
    c.width = Int(f.width * scale)
    c.height = Int(f.height * scale)
    c.minimumFrameInterval = CMTime(value: 1, timescale: 30)
    c.showsCursor = false
    c.queueDepth = 3
    return c
}

var caps: [CGWindowID: Capture] = [:]
var failed = Set<CGWindowID>()
var syncing = false

func sync(_ wins: [Win]) {   // one capture stream per window, kept in step with the window list
    guard !syncing else { return }   // the next tick retries
    syncing = true
    Task { @MainActor in
        defer { syncing = false }
        let want = Dictionary(wins.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for (id, cap) in caps where want[id] == nil { caps[id] = nil; try? await cap.stream?.stopCapture() }
        for w in wins {
            if let cap = caps[w.id], cap.size != w.frame.size {
                cap.size = w.frame.size
                try? await cap.stream?.updateConfiguration(config(w.frame))
            }
        }
        let new = wins.filter { caps[$0.id] == nil && !failed.contains($0.id) }
        guard !new.isEmpty, let content = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true) else { return }
        for w in new {
            guard let sw = content.windows.first(where: { $0.windowID == w.id }) else { continue }
            let cap = Capture(w.id, w.frame.size)
            let s = SCStream(filter: SCContentFilter(desktopIndependentWindow: sw), configuration: config(w.frame), delegate: nil)
            do {
                try s.addStreamOutput(cap, type: .screen, sampleHandlerQueue: DispatchQueue(label: "w\(w.id)"))
                cap.stream = s
                caps[w.id] = cap
                try await s.startCapture()
            } catch {
                caps[w.id] = nil
                failed.insert(w.id)
                log("window \(w.id) (\(w.app)): \(error.localizedDescription)")
            }
        }
    }
}

var lastList = Data(), lastCursor = Data(), ticks = 0

func tick() {
    ticks += 1
    let wins = windows()
    let list = wins.map { ["id": $0.id, "pid": $0.pid, "layer": $0.layer, "app": $0.app, "title": $0.title,
                           "x": $0.frame.minX, "y": $0.frame.minY, "w": $0.frame.width, "h": $0.frame.height] as [String: Any] }
    let data = (try? JSONSerialization.data(withJSONObject: list, options: .sortedKeys)) ?? Data()
    let changed = data != lastList
    if changed { lastList = data; emit(2, 0, data) }
    if changed || ticks % 30 == 0 { sync(wins) }

    let p = CGEvent(source: nil)?.location ?? .zero
    var cursor: [String: Any] = ["id": 0]
    if let w = wins.first(where: { $0.frame.contains(p) }) {
        cursor = ["id": w.id, "x": (p.x - w.frame.minX) / w.frame.width, "y": (p.y - w.frame.minY) / w.frame.height]
    }
    let c = (try? JSONSerialization.data(withJSONObject: cursor, options: .sortedKeys)) ?? Data()
    if c != lastCursor { lastCursor = c; emit(3, 0, c) }
}

// MARK: input

@_silgen_name("_AXUIElementGetWindow")
func _AXUIElementGetWindow(_ element: AXUIElement, _ id: UnsafeMutablePointer<CGWindowID>) -> AXError

func raise(_ w: Win) {   // bring the window to the front so the synthetic click lands on it
    let app = AXUIElementCreateApplication(w.pid)
    AXUIElementSetAttributeValue(app, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
    var value: CFTypeRef?
    AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value)
    for el in value as? [AXUIElement] ?? [] {
        var id: CGWindowID = 0
        if _AXUIElementGetWindow(el, &id) == .success, id == w.id {
            AXUIElementPerformAction(el, kAXRaiseAction as CFString)
            AXUIElementSetAttributeValue(el, kAXMainAttribute as CFString, kCFBooleanTrue)
        }
    }
}

var held: CGMouseButton?
var clicks = 1, lastClick = (time: 0.0, at: CGPoint.zero)

func post(_ type: CGEventType, _ p: CGPoint, _ b: CGMouseButton, clickState: Int) {
    let e = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: p, mouseButton: b)
    e?.setIntegerValueField(.mouseEventClickState, value: Int64(clickState))
    e?.post(tap: .cghidEventTap)
}

func wheel(_ v: Any?) -> Int32 { Int32(max(-3000, min(3000, v as? Double ?? 0))) }

func handle(_ e: [String: Any]) {
    let wins = windows()
    let w = wins.first { Int($0.id) == e["id"] as? Int }
    let p = w.map { CGPoint(x: $0.frame.minX + (e["x"] as? Double ?? 0) * $0.frame.width,
                            y: $0.frame.minY + (e["y"] as? Double ?? 0) * $0.frame.height) }
        ?? CGEvent(source: nil)?.location ?? .zero
    let t = e["t"] as? String
    if let w, t == "down" || t == "scroll", wins.first(where: { $0.frame.contains(p) })?.id != w.id {
        raise(w)
        usleep(80_000)
    }
    switch t {
    case "down":
        let b: CGMouseButton = e["b"] as? Int == 1 ? .right : .left
        let now = ProcessInfo.processInfo.systemUptime
        clicks = now - lastClick.time < 0.4 && hypot(p.x - lastClick.at.x, p.y - lastClick.at.y) < 8 ? clicks + 1 : 1
        lastClick = (now, p)
        held = b
        post(b == .left ? .leftMouseDown : .rightMouseDown, p, b, clickState: clicks)
    case "up":
        guard let b = held else { return }
        held = nil
        post(b == .left ? .leftMouseUp : .rightMouseUp, p, b, clickState: clicks)
    case "move":
        post(held == .left ? .leftMouseDragged : held == .right ? .rightMouseDragged : .mouseMoved,
             p, held ?? .left, clickState: held == nil ? 0 : clicks)
    case "scroll":
        post(.mouseMoved, p, .left, clickState: 0)
        CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
                wheel1: wheel(e["dy"]), wheel2: wheel(e["dx"]), wheel3: 0)?.post(tap: .cghidEventTap)
    default: break
    }
}

// MARK: main

if !AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary) {
    log("no Accessibility yet, view-only: System Settings > Privacy & Security > Accessibility > QuestWindows")
}
if !CGPreflightScreenCaptureAccess() {
    CGRequestScreenCaptureAccess()
    log("needs Screen Recording: System Settings > Privacy & Security > Screen & System Audio Recording > QuestWindows")
    sleep(20)   // the viewer reconnects and respawns us; don't re-prompt in a tight loop
    exit(1)
}
Thread {
    while let line = readLine() {
        if let e = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] {
            DispatchQueue.main.async { handle(e) }
        }
    }
    exit(0)   // server went away
}.start()
Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { _ in tick() }
RunLoop.main.run()
