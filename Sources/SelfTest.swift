import SwiftUI
import AppKit
import Metal

/// Collaudo automatico: `Calcoletti --selftest <cartella>`
/// Simula la tastiera fisica, controlla i risultati, salva le schermate e scrive report.md.
@MainActor
enum SelfTest {
    static func run() -> Never {
        if !CommandLine.arguments.contains("--lang") { CalcEngine.english = false }   // i controlli sono in formato italiano
        let args = CommandLine.arguments.filter { !$0.hasPrefix("--") && $0 != "en" && $0 != "it" }
        let out = URL(fileURLWithPath: args.count > 1 ? args.last! : FileManager.default.currentDirectoryPath)
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        _ = NSApplication.shared
        CalcModel.isSnapshot = true

        var report: [String] = ["# Collaudo Calcoletti", ""]
        var failures = 0
        func check(_ ok: Bool, _ what: String) {
            report.append((ok ? "- ✅ " : "- ❌ ") + what)
            if !ok { failures += 1 }
        }

        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("calcoletti-\(UUID().uuidString)")
        let model = CalcModel(storageDir: tmp, testing: true)
        model.decimals = 2

        // Tastiera fisica simulata (stessi eventi che manda la tastiera del Mac)
        func key(_ chars: String, code: UInt16 = 0, mods: NSEvent.ModifierFlags = []) -> Bool {
            guard let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: mods,
                                           timestamp: 0, windowNumber: 0, context: nil,
                                           characters: chars, charactersIgnoringModifiers: chars,
                                           isARepeat: false, keyCode: code) else { return false }
            return model.handle(e)
        }
        func type(_ s: String) {
            for ch in s {
                switch ch {
                case "⏎": _ = key("\r", code: 36)
                case "⎋": _ = key("\u{1b}", code: 53)
                case "⌫": _ = key("\u{7f}", code: 51)
                default: _ = key(String(ch))
                }
            }
        }
        func dec(_ s: String) -> Decimal { Decimal(string: s, locale: Locale(identifier: "en_US_POSIX"))! }

        report.append("## Calcoli con la tastiera del Mac")
        type("12,5+7,25+3-s100+t")
        check(model.engine.history.last?.total == dec("116.75"), "12,50 + 7,25 + 3 − ◇ + 100 + T → 116,75")
        type("1000+22%+⏎")
        check(model.engine.history.last?.total == 1220, "1000 + 22 % + Invio → 1.220 (IVA)")
        type("100d112⏎")
        check(model.engine.display == 12, "100 D 112 Invio → +12,00 % (Δ%)")
        check(model.displayText == "12,00", "display mostra 12,00 (letto: \(model.displayText))")
        type("t")
        type("80d60=")
        check(model.engine.display == -25, "80 Δ 60 = → −25 %")
        type("t")
        type("12*3⏎")
        check(model.engine.display == 36, "12 * 3 Invio → 36")
        type("t")
        type("1234⌫⌫")
        check(model.engine.entry == "12", "⌫ cancella le cifre (resta 12)")
        type("⎋")
        check(model.engine.entry.isEmpty, "Esc cancella il numero")
        type("10/0⏎")
        check(model.engine.tape.last?.kind == .error, "10 / 0 → E (errore)")
        type("⎋")
        type("g")
        check(model.engine.display == model.engine.gt, "G richiama il gran totale")
        let handledCmdQ = key("x", mods: [.command])
        check(handledCmdQ == false, "⌘X non viene intercettato (resta al sistema)")
        type("h")
        check(model.showHistory, "H apre la cronologia")
        type("⎋")
        check(!model.showHistory, "Esc chiude la cronologia")

        // Salvataggio su disco
        model.saveNow()
        let saved = (try? Data(contentsOf: tmp.appendingPathComponent("scontrino.json"))).flatMap {
            try? JSONDecoder().decode(CalcEngine.self, from: $0)
        }
        check(saved?.history.count == model.engine.history.count, "cronologia salvata su disco (\(saved?.history.count ?? 0) conti)")

        // Uno scontrino in corso per le schermate
        type("45,90+12,10+8,50-")

        // report scritto subito, così i risultati arrivano anche se le schermate falliscono
        func writeReport() {
            var r = report
            r.append("")
            r.append(failures == 0 ? "**Tutti i controlli superati.**" : "**\(failures) controlli FALLITI.**")
            try? r.joined(separator: "\n").write(to: out.appendingPathComponent("report.md"), atomically: true, encoding: .utf8)
        }
        writeReport()

        if CommandLine.arguments.contains("--no-shots") { exit(failures == 0 ? 0 : 1) }

        report.append("")
        report.append("## Schermate")
        let hasGPU = MTLCreateSystemDefaultDevice() != nil && !CommandLine.arguments.contains("--cpu")
        report.append("- disegno: " + (hasGPU ? "GPU (ImageRenderer)" : "senza GPU (AppKit)"))
        func shot(_ name: String, night: Bool) {
            model.themeMode = night ? .dark : .light
            model.flashKey = nil
            var png: Data?
            if hasGPU {
                let r = ImageRenderer(content: RootView().environmentObject(model))
                r.scale = 2
                if let cg = r.cgImage {
                    png = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])
                }
            } else {
                let host = NSHostingView(rootView: RootView().environmentObject(model))
                let frame = NSRect(x: 0, y: 0, width: 312, height: 620)
                host.frame = frame
                let win = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
                win.appearance = NSAppearance(named: night ? .darkAqua : .aqua)
                win.contentView = host
                host.layoutSubtreeIfNeeded()
                RunLoop.current.run(until: Date().addingTimeInterval(0.4))
                host.layoutSubtreeIfNeeded()
                if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                    host.cacheDisplay(in: host.bounds, to: rep)
                    png = rep.representation(using: .png, properties: [:])
                }
                win.contentView = nil
            }
            var ok = false
            if let png = png { ok = (try? png.write(to: out.appendingPathComponent(name))) != nil }
            check(ok, "schermata \(name)")
        }
        shot("1-giorno.png", night: false)
        shot("2-sera.png", night: true)
        model.showHistory = true
        if let first = model.engine.history.last { model.expandedReceipts.insert(first.id) }
        shot("3-cronologia-giorno.png", night: false)
        shot("4-cronologia-sera.png", night: true)

        report.append("")
        report.append(failures == 0 ? "**Tutti i controlli superati.**" : "**\(failures) controlli FALLITI.**")
        try? report.joined(separator: "\n").write(to: out.appendingPathComponent("report.md"), atomically: true, encoding: .utf8)
        print(report.joined(separator: "\n"))
        exit(failures == 0 ? 0 : 1)
    }

    /// Fotogrammi per il video: `Calcoletti --demo <cartella>` salva una schermata dopo ogni tasto.
    static func demo() -> Never {
        let args = CommandLine.arguments.filter { !$0.hasPrefix("--") && $0 != "en" && $0 != "it" }
        let out = URL(fileURLWithPath: args.count > 1 ? args.last! : FileManager.default.currentDirectoryPath)
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        _ = NSApplication.shared
        CalcModel.isSnapshot = true
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("calcoletti-demo-\(UUID().uuidString)")
        let model = CalcModel(storageDir: tmp, testing: true)
        model.decimals = 2
        model.themeMode = .light
        var manifest: [String] = []
        var n = 0

        let cpu = CommandLine.arguments.contains("--cpu")
        func render(_ name: String) {
            var png: Data?
            if cpu {
                let night = model.isNight(at: Date())
                let host = NSHostingView(rootView: RootView().environmentObject(model))
                let frame = NSRect(x: 0, y: 0, width: 312, height: 620)
                host.frame = frame
                let win = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
                win.appearance = NSAppearance(named: night ? .darkAqua : .aqua)
                win.contentView = host
                host.layoutSubtreeIfNeeded()
                RunLoop.current.run(until: Date().addingTimeInterval(0.25))
                if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                    host.cacheDisplay(in: host.bounds, to: rep)
                    png = rep.representation(using: .png, properties: [:])
                }
                win.contentView = nil
            } else {
                let r = ImageRenderer(content: RootView().environmentObject(model))
                r.scale = 3
                if let cg = r.cgImage { png = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) }
            }
            if let png = png { try? png.write(to: out.appendingPathComponent(name)) }
        }
        func frame(_ label: String) {
            let name = String(format: "k%03d.png", n)
            render(name)
            manifest.append("\(name)\t\(label)")
            n += 1
        }
        func press(_ ch: Character) {
            let chars = ch == "⏎" ? "\r" : String(ch)
            let code: UInt16 = ch == "⏎" ? 36 : 0
            if let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                        windowNumber: 0, context: nil, characters: chars,
                                        charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code) {
                _ = model.handle(e)
            }
        }
        let stills = CommandLine.arguments.contains("--stills")
        if !stills { frame("start") }
        let scenes = CalcEngine.english ? ["12.50+7.25+3-s100+t", "1000+22%+t", "100d112⏎"]
                                        : ["12,50+7,25+3-s100+t", "1000+22%+t", "100d112⏎"]
        for scene in scenes {
            manifest.append("# scena")
            for ch in scene {
                press(ch)
                if stills { manifest.append("x\t\(ch)") } else { frame(String(ch)) }
            }
        }
        if stills {
            model.flashKey = nil
            print("stills: giorno"); render("giorno.png")
            model.themeMode = .dark
            print("stills: sera"); render("sera.png")
            model.showHistory = true
            if let last = model.engine.history.last { model.expandedReceipts.insert(last.id) }
            print("stills: cronologia"); render("cronologia-sera.png")
            model.themeMode = .light
            render("cronologia-giorno.png")
            print("stills: fatto")
            exit(0)
        }
        try? manifest.joined(separator: "\n").write(to: out.appendingPathComponent("manifest.txt"), atomically: true, encoding: .utf8)
        exit(0)
    }
}
