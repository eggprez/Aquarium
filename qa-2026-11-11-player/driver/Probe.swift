import XCTest

let base = "/private/tmp/claude-501/-Users-scottbindelglass--claude-spares-spare-DbO4PZ/7b379cbb-fbdb-45cd-b9e6-11fa86355f9e/scratchpad/io"

final class Probe: XCTestCase {
    var app: XCUIApplication!
    var out = ""
    var dir = ""

    func walk(_ s: XCUIElementSnapshot, _ f: (XCUIElementSnapshot) -> Void) {
        f(s); for c in s.children { walk(c, f) }
    }
    func name(_ t: XCUIElement.ElementType) -> String {
        switch t {
        case .button: return "btn"; case .staticText: return "txt"; case .slider: return "sld"
        case .image: return "img"; case .switch: return "sw"; case .cell: return "cell"
        case .other: return "oth"; case .toggle: return "tog"; case .textField: return "fld"
        case .scrollView: return "scr"; case .progressIndicator: return "prog"; case .activityIndicator: return "spin"
        case .picker: return "pick"; case .segmentedControl: return "seg"; case .link: return "link"
        case .alert: return "alert"; case .sheet: return "sheet"; case .popover: return "pop"; case .menuItem: return "mi"; case .menu: return "menu"
        default: return "t\(t.rawValue)" }
    }
    func snap() -> XCUIElementSnapshot? { try? app.snapshot() }
    func labels(_ filter: String?) {
        guard let s = snap() else { out += "no snapshot\n"; return }
        walk(s) { e in
            let l = e.label; let v = (e.value as? String) ?? (e.value.map { "\($0)" } ?? "")
            if l.isEmpty && v.isEmpty { return }
            if e.elementType == .other && e.children.count > 0 && v.isEmpty { return }
            if let f = filter, !l.localizedCaseInsensitiveContains(f), !v.localizedCaseInsensitiveContains(f) { return }
            let r = e.frame
            out += "\(name(e.elementType)) [\(l)]\(v.isEmpty ? "" : " =\(v)")\(e.isSelected ? " SEL" : "")\(e.isEnabled ? "" : " DIS") @\(Int(r.midX)),\(Int(r.midY)) \(Int(r.width))x\(Int(r.height))\n"
        }
    }
    func find(_ label: String, nth: Int = 0) -> CGRect? {
        guard let s = snap() else { return nil }
        var exact: [XCUIElementSnapshot] = [], part: [XCUIElementSnapshot] = []
        walk(s) { e in
            if e.frame.width < 1 || e.frame.height < 1 { return }
            if e.label.caseInsensitiveCompare(label) == .orderedSame { exact.append(e) }
            else if e.label.localizedCaseInsensitiveContains(label) { part.append(e) }
        }
        func rank(_ a: [XCUIElementSnapshot]) -> [XCUIElementSnapshot] {
            a.filter { $0.elementType == .button } + a.filter { $0.elementType != .button && $0.children.isEmpty } + a.filter { $0.elementType != .button && !$0.children.isEmpty }
        }
        let all = rank(exact) + rank(part)
        return all.count > nth ? all[nth].frame : nil
    }
    func pt(_ x: CGFloat, _ y: CGFloat) -> XCUICoordinate {
        app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: x, dy: y))
    }
    func npt(_ a: [String], _ i: Int) -> XCUICoordinate {
        let x = Double(a[i]) ?? 0, y = Double(a[i+1]) ?? 0
        if x <= 1.0 && y <= 1.0 { return app.coordinate(withNormalizedOffset: CGVector(dx: x, dy: y)) }
        return pt(x, y)
    }
    func run(_ line: String) {
        let a = line.split(separator: " ", maxSplits: 1).map(String.init)
        guard let c = a.first else { return }
        let rest = a.count > 1 ? a[1] : ""
        let w = rest.split(separator: " ").map(String.init)
        switch c {
        case "labels": labels(rest.isEmpty ? nil : rest)
        case "show":
            if find("Timeline") == nil && find("Channel info") == nil { app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3)).tap(); Thread.sleep(forTimeInterval: 0.7) }
        case "pos":
            if find("Timeline") == nil { app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3)).tap(); Thread.sleep(forTimeInterval: 0.7) }
            if let s = snap() { walk(s) { e in
                if e.label == "Timeline" { out += "POS \((e.value as? String) ?? "?")" }
                if e.label == "Play" || e.label == "Pause" || e.label == "Loading" { out += " [\(e.label)]" }
                if e.label.hasPrefix("Quality,") { out += " {\(e.label)}" }
            }; out += "\n" }
        case "tap", "tap2":
            if let r = find(rest, nth: c == "tap2" ? 1 : 0) { pt(r.midX, r.midY).tap(); out += "tapped [\(rest)] @\(Int(r.midX)),\(Int(r.midY))\n" } else { out += "NOTFOUND [\(rest)]\n" }
        case "has": out += (find(rest) != nil ? "YES" : "NO") + " [\(rest)]\n"
        case "tapxy": npt(w, 0).tap()
        case "dtap": npt(w, 0).doubleTap()
        case "press": npt(w, 0).press(forDuration: Double(w[2]) ?? 1)
        case "drag":
            let hold = w.count > 4 ? (Double(w[4]) ?? 0.1) : 0.1
            npt(w, 0).press(forDuration: hold, thenDragTo: npt(w, 2), withVelocity: .slow, thenHoldForDuration: w.count > 5 ? (Double(w[5]) ?? 0) : 0)
        case "swipe":
            npt(w, 0).press(forDuration: 0.05, thenDragTo: npt(w, 2), withVelocity: .fast, thenHoldForDuration: 0)
        case "pinchv":
            let s = CGFloat(Double(w[0]) ?? 2)
            let v = app.images["Video"].firstMatch
            if v.exists { v.pinch(withScale: s, velocity: s > 1 ? 1.5 : -1.5); out += "pinched video\n" } else { out += "NOVIDEO\n" }
        case "pinch": app.pinch(withScale: CGFloat(Double(w[0]) ?? 2), velocity: (Double(w[0]) ?? 2) > 1 ? 2 : -2)
        case "rotate":
            let m: [String: UIDeviceOrientation] = ["portrait": .portrait, "left": .landscapeLeft, "right": .landscapeRight, "down": .portraitUpsideDown]
            XCUIDevice.shared.orientation = m[rest] ?? .portrait
        case "home": XCUIDevice.shared.press(.home)
        case "activate": app.activate()
        case "wait": Thread.sleep(forTimeInterval: Double(rest) ?? 1)
        case "shot":
            let d = XCUIScreen.main.screenshot().pngRepresentation
            try? d.write(to: URL(fileURLWithPath: "\(dir)/\(rest).png"))
        case "type": app.typeText(rest)
        case "state": out += "state \(app.state.rawValue)\n"
        default: out += "unknown \(c)\n"
        }
    }
    func testLoop() {
        continueAfterFailure = true
        let udid = ProcessInfo.processInfo.environment["SIMULATOR_UDID"] ?? "x"
        dir = "\(base)/\(udid)"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        app = XCUIApplication(bundleIdentifier: "scottai.FellyJin")
        let cmd = "\(dir)/cmd.txt", res = "\(dir)/out.txt"
        try? "ready\n".write(toFile: "\(dir)/ready.txt", atomically: true, encoding: .utf8)
        let end = Date().addingTimeInterval(8 * 3600)
        while Date() < end {
            if let t = try? String(contentsOfFile: cmd, encoding: .utf8) {
                try? FileManager.default.removeItem(atPath: cmd)
                out = ""
                var quit = false
                for l in t.split(separator: "\n").map(String.init) {
                    if l == "quit" { quit = true; break }
                    run(l)
                }
                try? (out + "done\n").write(toFile: res, atomically: true, encoding: .utf8)
                if quit { return }
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
    }
}
