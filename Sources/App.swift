import SwiftUI
import AppKit
import Combine
import ServiceManagement

// MARK: - App (solo barra dei menu, niente icona nel Dock)

@main
struct CalcolettiApp: App {
    @StateObject private var model: CalcModel

    init() {
        if let i = CommandLine.arguments.firstIndex(of: "--lang"), i + 1 < CommandLine.arguments.count {
            CalcEngine.english = CommandLine.arguments[i + 1] == "en"
        }
        if CommandLine.arguments.contains("--demo") { SelfTest.demo() }
        if CommandLine.arguments.contains("--selftest") { SelfTest.run() }   // collaudo automatico, poi esce
        _model = StateObject(wrappedValue: CalcModel())
    }

    var body: some Scene {
        MenuBarExtra {
            RootView()
                .environmentObject(model)
        } label: {
            Image(nsImage: MenuIcon.image)
        }
        .menuBarExtraStyle(.window)
    }
}

// MARK: - Icona della barra dei menu: una farfalla di pasta (si adatta a barra chiara/scura)

enum MenuIcon {
    static let image: NSImage = {
        let img = NSImage(size: NSSize(width: 20, height: 16), flipped: false) { _ in
            NSColor.black.setFill()
            NSColor.black.setStroke()
            // ala sinistra e destra con il bordo esterno "dentellato" come le farfalle vere
            for side: CGFloat in [-1, 1] {
                let cx: CGFloat = 10
                let p = NSBezierPath()
                p.move(to: NSPoint(x: cx + side * 1.5, y: 9.2))
                p.curve(to: NSPoint(x: cx + side * 8.5, y: 14.5),
                        controlPoint1: NSPoint(x: cx + side * 4, y: 11.5),
                        controlPoint2: NSPoint(x: cx + side * 6.5, y: 14.5))
                // bordo dentellato verticale
                let teeth = 5
                for i in 0..<teeth {
                    let y0: CGFloat = 14.5 - 13.0 * CGFloat(i) / CGFloat(teeth)
                    let y1: CGFloat = 14.5 - 13.0 * CGFloat(i + 1) / CGFloat(teeth)
                    let ym: CGFloat = (y0 + y1) / 2
                    p.line(to: NSPoint(x: cx + side * 9.6, y: ym))
                    p.line(to: NSPoint(x: cx + side * 8.5, y: y1))
                }
                p.curve(to: NSPoint(x: cx + side * 1.5, y: 6.8),
                        controlPoint1: NSPoint(x: cx + side * 6.5, y: 1.5),
                        controlPoint2: NSPoint(x: cx + side * 4, y: 4.5))
                p.close()
                p.fill()
            }
            // nodo centrale
            let knot = NSBezierPath(roundedRect: NSRect(x: 7.6, y: 5.2, width: 4.8, height: 5.6), xRadius: 1.8, yRadius: 1.8)
            knot.fill()
            return true
        }
        img.isTemplate = true
        return img
    }()
}

// MARK: - Tema giorno / sera

enum ThemeMode: String, CaseIterable, Identifiable {
    case auto, light, dark
    var id: String { rawValue }
    var title: String {
        switch self {
        case .auto: return L("Automatico (giorno/sera)", "Automatic (day/night)")
        case .light: return L("Sempre chiaro", "Always light")
        case .dark: return L("Sempre scuro", "Always dark")
        }
    }
}

struct Palette {
    let bg: Color
    let paper: Color
    let paperLine: Color
    let ink: Color
    let inkSoft: Color
    let red: Color
    let key: Color
    let keyText: Color
    let fnKey: Color
    let fnKeyText: Color
    let clearKey: Color

    static let day = Palette(
        bg: Color(white: 1.0),
        paper: Color(white: 0.972),
        paperLine: Color(white: 0.80),
        ink: Color(white: 0.06),
        inkSoft: Color(white: 0.52),
        red: Color(red: 0.80, green: 0.10, blue: 0.10),
        key: Color(white: 0.07),
        keyText: .white,
        fnKey: Color(white: 0.30),
        fnKeyText: .white,
        clearKey: Color(red: 0.80, green: 0.12, blue: 0.10)
    )

    static let night = Palette(
        bg: Color(white: 0.0),
        paper: Color(white: 0.085),
        paperLine: Color(white: 0.28),
        ink: Color(white: 0.96),
        inkSoft: Color(white: 0.50),
        red: Color(red: 1.0, green: 0.45, blue: 0.42),
        key: Color(white: 0.15),
        keyText: .white,
        fnKey: Color(white: 0.25),
        fnKeyText: .white,
        clearKey: Color(red: 0.72, green: 0.14, blue: 0.12)
    )
}

// MARK: - Modello

struct HistoryGroup: Identifiable {
    let title: String
    var items: [Receipt]
    var id: String { title }
}

final class CalcModel: ObservableObject {
    @Published var engine: CalcEngine { didSet { scheduleSave() } }
    @Published var showHistory = false
    @Published var flashKey: CalcKey?
    @Published var toast: String?
    @Published var now = Date()                       // per il cambio tema giorno/sera
    @Published var expandedReceipts: Set<UUID> = []   // conti aperti in cronologia
    @Published var confirmClear = false
    @Published var decimals: Int {
        didSet { engine.decimals = decimals; UserDefaults.standard.set(decimals, forKey: "decimals") }
    }
    @Published var themeMode: ThemeMode {
        didSet { UserDefaults.standard.set(themeMode.rawValue, forKey: "theme") }
    }
    @Published var nightHour: Int {
        didSet { UserDefaults.standard.set(nightHour, forKey: "nightHour") }
    }
    @Published var dayHour: Int {
        didSet { UserDefaults.standard.set(dayHour, forKey: "dayHour") }
    }

    private var monitor: Any?
    private var saveWork: DispatchWorkItem?
    private var clockTimer: Timer?
    private let fileURL: URL

    /// true durante il collaudo automatico: niente ScrollView/Menu (non disegnabili fuori schermo)
    static var isSnapshot = false

    init(storageDir: URL? = nil, testing: Bool = false) {
        let d = UserDefaults.standard
        let dir = storageDir ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Calcoletti", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("scontrino.json")
        fileURL = url

        var loaded = CalcEngine()
        if let data = try? Data(contentsOf: url),
           let e = try? JSONDecoder().decode(CalcEngine.self, from: data) {
            loaded = e
        }
        let dec = d.object(forKey: "decimals") as? Int ?? 2
        loaded.decimals = dec
        engine = loaded
        decimals = dec
        themeMode = ThemeMode(rawValue: d.string(forKey: "theme") ?? "") ?? .auto
        nightHour = d.object(forKey: "nightHour") as? Int ?? 19
        dayHour = d.object(forKey: "dayHour") as? Int ?? 7

        if !testing { installKeyMonitor() }
        let t = Timer(timeInterval: 30, repeats: true) { [weak self] _ in self?.now = Date() }
        RunLoop.main.add(t, forMode: .common)
        clockTimer = t
        _ = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            self?.saveNow()
        }

        // Al primo avvio si registra tra gli elementi di login, così l'icona c'è sempre.
        if !testing && !d.bool(forKey: "loginConfigured") {
            d.set(true, forKey: "loginConfigured")
            try? SMAppService.mainApp.register()
        }
    }

    // MARK: Tema

    func isNight(at date: Date) -> Bool {
        switch themeMode {
        case .light: return false
        case .dark: return true
        case .auto:
            let h = Calendar.current.component(.hour, from: date)
            return h >= nightHour || h < dayHour
        }
    }

    // MARK: Tasti

    func press(_ k: CalcKey) {
        if showHistory { showHistory = false }
        engine.input(k)
        flashKey = k
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            if self?.flashKey == k { self?.flashKey = nil }
        }
    }

    private func installKeyMonitor() {
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self else { return event }
            return self.handle(event) ? nil : event
        }
    }

    /// Tastiera fisica → tasti della calcolatrice. Restituisce true se l'evento è stato usato.
    func handle(_ e: NSEvent) -> Bool {
        let mods = e.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let plain = (e.charactersIgnoringModifiers ?? "").lowercased()

        if mods.contains(.command) {
            switch plain {
            case "c": copyCurrent(); return true
            case "v": pasteNumber(); return true
            case "y": showHistory.toggle(); return true
            case "q": NSApp.terminate(nil); return true
            default: return false
            }
        }
        if mods.contains(.control) || mods.contains(.option) { return false }

        switch e.keyCode {
        case 36, 76: press(.equals); return true                  // Invio / Invio tastierino
        case 51: press(.backspace); return true                   // ⌫
        case 53:                                                   // Esc
            if showHistory { showHistory = false } else { press(.clear) }
            return true
        case 71, 117: press(.clear); return true                  // Clear tastierino / Canc
        default: break
        }

        guard let ch = e.characters?.first else { return false }
        var key: CalcKey?
        switch ch {
        case "0"..."9": key = .digit(Int(String(ch)) ?? 0)
        case ",", ".": key = .decimal
        case "+": key = .add
        case "-": key = .sub
        case "*", "x", "X": key = .mul
        case "/", ":": key = .div
        case "%": key = .percent
        case "=": key = .equals
        case "s", "S": key = .subtotal
        case "t", "T": key = .total
        case "d", "D": key = .delta
        case "g", "G": key = .grandTotal
        case "n", "N", "_": key = .sign
        case "c", "C": key = .clear
        case "h", "H": showHistory.toggle(); return true
        default: key = nil
        }
        guard let k = key else { return false }
        press(k)
        return true
    }

    // MARK: Azioni

    var displayText: String {
        if !engine.entry.isEmpty { return CalcEngine.formatEntry(engine.entry) }
        return CalcEngine.format(engine.display, decimals: engine.decimals)
    }

    var displayNegative: Bool {
        engine.entry.hasPrefix("-") || (engine.entry.isEmpty && engine.display < 0)
    }

    func recall(_ line: TapeLine) {
        guard let v = line.value else { return }
        engine.recall(v)
        showHistory = false
    }

    func useTotal(_ r: Receipt) {
        guard let t = r.total else { return }
        engine.recall(t)
        showHistory = false
    }

    func copyCurrent() {
        let lines: [TapeLine]
        if engine.receiptInProgress {
            lines = Array(engine.tape[engine.receiptStart...])
        } else if let last = engine.history.last {
            lines = last.lines
        } else {
            return
        }
        copy(lines)
    }

    func copy(_ lines: [TapeLine]) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(CalcEngine.text(for: lines, decimals: engine.decimals), forType: .string)
        flash(L("Copiato negli appunti", "Copied to clipboard"))
    }

    func pasteNumber() {
        guard var s = NSPasteboard.general.string(forType: .string) else { return }
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "€", with: "")
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "\u{00A0}", with: "")
        if s.contains(",") {
            s = s.replacingOccurrences(of: ".", with: "").replacingOccurrences(of: ",", with: ".")
        } else if s.filter({ $0 == "." }).count > 1 {
            s = s.replacingOccurrences(of: ".", with: "")
        }
        guard let v = Decimal(string: s, locale: Locale(identifier: "en_US_POSIX")) else {
            flash(L("Negli appunti non c'è un numero", "No number on the clipboard"))
            return
        }
        engine.recall(v)
        showHistory = false
    }

    func tearTape() { engine.clearTape() }
    func resetGT() { engine.resetGT(); flash(L("GT azzerato", "GT cleared")) }
    func delete(_ r: Receipt) { engine.history.removeAll { $0.id == r.id } }
    func clearHistory() { engine.history.removeAll() }

    func toggleReceipt(_ id: UUID) {
        if expandedReceipts.contains(id) { expandedReceipts.remove(id) } else { expandedReceipts.insert(id) }
    }

    func flash(_ text: String) {
        toast = text
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { [weak self] in
            if self?.toast == text { self?.toast = nil }
        }
    }

    var launchAtLogin: Bool { SMAppService.mainApp.status == .enabled }

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            flash(L("Impostazione non riuscita", "Setting failed"))
        }
        objectWillChange.send()
    }

    var historyGroups: [HistoryGroup] {
        var groups: [HistoryGroup] = []
        for r in engine.history.reversed() {
            let t = CalcModel.dayTitle(r.date)
            if groups.last?.title == t {
                groups[groups.count - 1].items.append(r)
            } else {
                groups.append(HistoryGroup(title: t, items: [r]))
            }
        }
        return groups
    }

    static var dayFormatter: DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: CalcEngine.english ? "en_US" : "it_IT")
        f.dateFormat = CalcEngine.english ? "EEEE, MMMM d, yyyy" : "EEEE d MMMM yyyy"
        return f
    }

    static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "it_IT")
        f.dateFormat = "HH:mm"
        return f
    }()

    static func dayTitle(_ d: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(d) { return L("Oggi", "Today") }
        if cal.isDateInYesterday(d) { return L("Ieri", "Yesterday") }
        let s = dayFormatter.string(from: d)
        return s.prefix(1).uppercased() + s.dropFirst()
    }

    // MARK: Salvataggio

    private func scheduleSave() {
        saveWork?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.saveNow() }
        saveWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: w)
    }

    func saveNow() {
        if let data = try? JSONEncoder().encode(engine) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }
}

// MARK: - Vista principale

struct RootView: View {
    @EnvironmentObject var model: CalcModel
    var body: some View {
        let night = model.isNight(at: model.now)
        let p = night ? Palette.night : Palette.day
        VStack(spacing: 0) {
            HeaderView(p: p)
            if model.showHistory {
                HistoryView(p: p)
            } else {
                TapeView(p: p)
                DisplayView(p: p)
                KeypadView(p: p)
            }
        }
        .frame(width: 312, height: 620)
        .background(p.bg)
        .preferredColorScheme(night ? .dark : .light)
        .onAppear {
            model.now = Date()
            NSApp.activate(ignoringOtherApps: true)   // così la tastiera fisica arriva subito alla calcolatrice
        }
    }
}

// MARK: - Intestazione

struct HeaderView: View {
    @EnvironmentObject var model: CalcModel
    let p: Palette

    var body: some View {
        HStack(spacing: 14) {
            if let t = model.toast {
                Text(t)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(p.inkSoft)
            } else {
                Text(model.showHistory ? L("Cronologia", "History") : "Calcoletti")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(p.ink)
                    .lineLimit(1)
                    .fixedSize()
            }
            Spacer()
            HeaderButton(symbol: model.showHistory ? "xmark" : "clock.arrow.circlepath",
                         help: model.showHistory ? L("Torna alla calcolatrice (Esc)", "Back to calculator (Esc)") : L("Cronologia dei conti (H)", "History (H)"),
                         p: p) { model.showHistory.toggle() }
            if !model.showHistory {
                HeaderButton(symbol: "doc.on.doc", help: L("Copia lo scontrino (⌘C)", "Copy the tape (⌘C)"), p: p) { model.copyCurrent() }
                HeaderButton(symbol: "scissors", help: L("Strappa la carta (i conti restano in cronologia)", "Tear off the paper (history is kept)"), p: p) { model.tearTape() }
            }
            SettingsMenu(p: p)
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 8)
    }
}

struct HeaderButton: View {
    let symbol: String
    let help: String
    let p: Palette
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(p.ink)
                .frame(width: 18, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

struct SettingsMenu: View {
    @EnvironmentObject var model: CalcModel
    let p: Palette

    var body: some View {
        if CalcModel.isSnapshot {
            Image(systemName: "gearshape").font(.system(size: 13)).foregroundStyle(p.ink)
        } else {
            menu
        }
    }

    private var menu: some View {
        Menu {
            Picker(L("Decimali", "Decimals"), selection: $model.decimals) {
                Text(L("F – virgola mobile", "F – floating")).tag(-1)
                Text("0").tag(0)
                Text("2").tag(2)
                Text("3").tag(3)
                Text("4").tag(4)
            }
            Picker(L("Tema", "Theme"), selection: $model.themeMode) {
                ForEach(ThemeMode.allCases) { m in Text(m.title).tag(m) }
            }
            Picker(L("Sera dalle ore", "Night from"), selection: $model.nightHour) {
                ForEach(15..<24, id: \.self) { h in Text("\(h):00").tag(h) }
            }
            Picker(L("Giorno dalle ore", "Day from"), selection: $model.dayHour) {
                ForEach(4..<12, id: \.self) { h in Text("\(h):00").tag(h) }
            }
            Divider()
            Menu(L("Scorciatoie da tastiera", "Keyboard shortcuts")) {
                Text(L("Invio  →  =  oppure totale", "Return  →  =  or total"))
                Text(L("+  −  →  somma / sottrai", "+  −  →  add / subtract"))
                Text(L("*  x  →  moltiplica      /  →  dividi", "*  x  →  multiply      /  →  divide"))
                Text(L("S  →  subtotale ◇      T  →  totale *", "S  →  subtotal ◇      T  →  total *"))
                Text(L("D  →  delta %      G  →  gran totale", "D  →  delta %      G  →  grand total"))
                Text(L("N  →  cambia segno      %  →  percentuale", "N  →  change sign      %  →  percent"))
                Text(L("Esc  →  C/CE      ⌫  →  cancella cifra", "Esc  →  C/CE      ⌫  →  delete digit"))
                Text(L("H  →  cronologia      ⌘C / ⌘V  →  copia / incolla", "H  →  history      ⌘C / ⌘V  →  copy / paste"))
            }
            Divider()
            Toggle(L("Apri all'avvio del Mac", "Open at login"), isOn: Binding(
                get: { model.launchAtLogin },
                set: { model.setLaunchAtLogin($0) }
            ))
            Button(L("Azzera gran totale (GT)", "Clear grand total (GT)")) { model.resetGT() }
            Divider()
            Button(L("Esci da Calcoletti", "Quit Calcoletti")) { NSApp.terminate(nil) }
        } label: {
            Image(systemName: "gearshape")
                .font(.system(size: 13))
                .foregroundStyle(p.ink)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(L("Impostazioni", "Settings"))
    }
}

// MARK: - Carta dello scontrino

struct TapeView: View {
    @EnvironmentObject var model: CalcModel
    let p: Palette

    var body: some View {
        if CalcModel.isSnapshot {
            VStack(spacing: 0) {
                Spacer(minLength: 0)
                VStack(spacing: 3) {
                    ForEach(Array(model.engine.tape.suffix(13))) { line in
                        TapeRow(line: line, decimals: model.engine.decimals, p: p)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
                Color.clear.frame(height: 6)
            }
            .padding(.horizontal, 14)
            .padding(.top, 10)
            .frame(maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: .bottom)
            .clipped()
            .background(ZStack(alignment: .top) { p.paper; ZigZag().fill(p.bg).frame(height: 5) })
            .padding(.horizontal, 14)
        } else {
            scrolling
        }
    }

    private var scrolling: some View {
        GeometryReader { geo in
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 0) {
                        Spacer(minLength: 0)
                        if model.engine.tape.isEmpty {
                            Text(L("Carta pronta", "Paper ready"))
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundStyle(p.inkSoft)
                                .frame(maxWidth: .infinity)
                                .padding(.bottom, 24)
                        }
                        LazyVStack(spacing: 3) {
                            ForEach(model.engine.tape) { line in
                                TapeRow(line: line, decimals: model.engine.decimals, p: p)
                                    .id(line.id)
                                    .onTapGesture { model.recall(line) }
                            }
                        }
                        Color.clear.frame(height: 6).id("bottom")
                    }
                    .padding(.horizontal, 14)
                    .padding(.top, 10)
                    .frame(minHeight: geo.size.height, alignment: .bottom)
                    .background(
                        ZStack(alignment: .top) {
                            p.paper
                            ZigZag().fill(p.bg).frame(height: 5)
                        }
                    )
                    .padding(.horizontal, 14)
                }
                .onAppear { proxy.scrollTo("bottom", anchor: .bottom) }
                .onChange(of: model.engine.tape.last?.id) { _ in
                    withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo("bottom", anchor: .bottom) }
                }
            }
        }
        .frame(maxHeight: .infinity)
    }
}

struct ZigZag: Shape {
    func path(in r: CGRect) -> Path {
        var path = Path()
        let teeth = max(1, Int(r.width / 8))
        let step = r.width / CGFloat(teeth)
        path.move(to: CGPoint(x: r.minX, y: r.minY))
        path.addLine(to: CGPoint(x: r.minX, y: r.maxY))
        for i in 0..<teeth {
            let x = r.minX + step * CGFloat(i)
            path.addLine(to: CGPoint(x: x + step / 2, y: r.minY))
            path.addLine(to: CGPoint(x: x + step, y: r.maxY))
        }
        path.addLine(to: CGPoint(x: r.maxX, y: r.minY))
        path.closeSubpath()
        return path
    }
}

struct HLine: Shape {
    func path(in r: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: r.minX, y: r.midY))
        path.addLine(to: CGPoint(x: r.maxX, y: r.midY))
        return path
    }
}

struct TapeRow: View {
    let line: TapeLine
    let decimals: Int
    let p: Palette

    var body: some View {
        if line.kind == .cut {
            HStack(spacing: 5) {
                Image(systemName: "scissors")
                    .font(.system(size: 8))
                    .foregroundStyle(p.inkSoft)
                HLine()
                    .stroke(style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    .foregroundStyle(p.paperLine)
                    .frame(height: 1)
            }
            .padding(.vertical, 7)
        } else {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(line.label)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(p.inkSoft)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text(CalcEngine.formatLine(line, decimals: decimals))
                    .font(.system(size: 15, weight: weight, design: .monospaced))
                    .foregroundStyle(color)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                Text(line.symbol)
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .foregroundStyle(color)
                    .frame(width: 22, alignment: .leading)
            }
            .padding(.top, line.kind == .total ? 4 : 0)
            .overlay(alignment: .top) {
                if line.kind == .total {
                    HLine()
                        .stroke(p.ink.opacity(0.5), lineWidth: 1)
                        .frame(height: 1)
                        .padding(.leading, 110)
                }
            }
            .contentShape(Rectangle())
        }
    }

    private var color: Color {
        if line.kind == .error || line.symbol == "−" { return p.red }
        if let v = line.value, v < 0 { return p.red }
        if line.kind == .note { return p.inkSoft }
        return p.ink
    }

    private var weight: Font.Weight {
        switch line.kind {
        case .total, .grandTotal: return .bold
        case .subtotal, .result: return .semibold
        default: return .regular
        }
    }
}

// MARK: - Display

struct DisplayView: View {
    @EnvironmentObject var model: CalcModel
    let p: Palette

    var body: some View {
        let e = model.engine
        VStack(alignment: .trailing, spacing: 2) {
            HStack(spacing: 10) {
                if let op = e.pendingOp {
                    Text(CalcEngine.format(e.pendingValue, decimals: e.decimals) + " " + CalcEngine.symbol(op))
                }
                if e.count > 0 {
                    Text("Σ " + CalcEngine.format(e.acc, decimals: e.decimals))
                    Text(L("n. ", "no. ") + "\(e.count)")
                }
                Spacer()
                if e.gt != 0 {
                    Text("GT " + CalcEngine.format(e.gt, decimals: e.decimals))
                        .help(L("Gran totale accumulato (premi GT due volte per azzerarlo)", "Grand total (press GT twice to clear)"))
                }
                Text(verbatim: e.decimals < 0 ? "F" : "\(e.decimals) dec")
            }
            .font(.system(size: 10, weight: .medium, design: .monospaced))
            .foregroundStyle(p.inkSoft)
            .lineLimit(1)

            Text(model.displayText)
                .font(.system(size: 34, weight: .light, design: .monospaced))
                .foregroundStyle(model.displayNegative ? p.red : p.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.4)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .textSelection(.enabled)
        }
        .padding(.horizontal, 18)
        .padding(.top, 8)
        .padding(.bottom, 10)
    }
}

// MARK: - Tastiera

enum KeyRole { case digit, op, fn, clear }

struct KeyDef: Identifiable {
    let key: CalcKey
    let label: String
    let role: KeyRole
    let help: String
    var id: String { label }
}

struct KeypadView: View {
    @EnvironmentObject var model: CalcModel
    let p: Palette

    static var rows: [[KeyDef]] { [
        [KeyDef(key: .clear, label: "C/CE", role: .clear, help: L("Cancella numero / annulla conto (Esc)", "Clear entry / void (Esc)")),
         KeyDef(key: .backspace, label: "⌫", role: .fn, help: L("Cancella ultima cifra", "Delete last digit")),
         KeyDef(key: .sign, label: "±", role: .fn, help: L("Cambia segno (N)", "Change sign (N)")),
         KeyDef(key: .delta, label: "Δ%", role: .fn, help: L("Variazione %: valore iniziale Δ valore finale = (D)", "% change: start Δ end = (D)")),
         KeyDef(key: .grandTotal, label: "GT", role: .fn, help: L("Gran totale (G) – due volte per azzerare", "Grand total (G) – twice to clear"))],
        [KeyDef(key: .digit(7), label: "7", role: .digit, help: ""),
         KeyDef(key: .digit(8), label: "8", role: .digit, help: ""),
         KeyDef(key: .digit(9), label: "9", role: .digit, help: ""),
         KeyDef(key: .div, label: "÷", role: .op, help: L("Dividi (/)", "Divide (/)")),
         KeyDef(key: .percent, label: "%", role: .fn, help: L("Percentuale: 1000 + 22 % → 220, poi + per sommarlo", "Percent: 1000 + 22 % → 220, then + to add it"))],
        [KeyDef(key: .digit(4), label: "4", role: .digit, help: ""),
         KeyDef(key: .digit(5), label: "5", role: .digit, help: ""),
         KeyDef(key: .digit(6), label: "6", role: .digit, help: ""),
         KeyDef(key: .mul, label: "×", role: .op, help: L("Moltiplica (* o X)", "Multiply (* or X)")),
         KeyDef(key: .subtotal, label: "◇", role: .fn, help: L("Subtotale (S)", "Subtotal (S)"))],
        [KeyDef(key: .digit(1), label: "1", role: .digit, help: ""),
         KeyDef(key: .digit(2), label: "2", role: .digit, help: ""),
         KeyDef(key: .digit(3), label: "3", role: .digit, help: ""),
         KeyDef(key: .sub, label: "−", role: .op, help: L("Sottrai (−)", "Subtract (−)")),
         KeyDef(key: .equals, label: "=", role: .op, help: L("Risultato di × ÷ Δ, altrimenti totale (Invio)", "Result of × ÷ Δ, otherwise total (Return)"))],
        [KeyDef(key: .digit(0), label: "0", role: .digit, help: ""),
         KeyDef(key: .doubleZero, label: "00", role: .digit, help: ""),
         KeyDef(key: .decimal, label: CalcEngine.decimalSep, role: .digit, help: L("Virgola (, o .)", "Decimal point (. or ,)")),
         KeyDef(key: .add, label: "+", role: .op, help: L("Somma (+)", "Add (+)")),
         KeyDef(key: .total, label: "*", role: .op, help: L("Totale: chiude lo scontrino e lo salva in cronologia (T)", "Total: closes the tape and saves it to history (T)"))]
    ] }

    var body: some View {
        VStack(spacing: 7) {
            ForEach(0..<KeypadView.rows.count, id: \.self) { r in
                HStack(spacing: 7) {
                    ForEach(KeypadView.rows[r]) { def in
                        Button { model.press(def.key) } label: {
                            Text(def.label)
                                .font(keyFont(def))
                        }
                        .buttonStyle(KeyButtonStyle(bg: bg(for: def), fg: fg(for: def),
                                                    flash: model.flashKey == def.key))
                        .help(def.help)
                    }
                }
                .frame(height: 46)
            }
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 14)
    }

    private func keyFont(_ d: KeyDef) -> Font {
        switch d.role {
        case .digit: return .system(size: 20, weight: .medium, design: .rounded)
        case .op: return .system(size: 22, weight: .regular, design: .rounded)
        case .fn: return .system(size: 15, weight: .medium, design: .rounded)
        case .clear: return .system(size: 13, weight: .semibold, design: .rounded)
        }
    }

    private func bg(for d: KeyDef) -> Color {
        switch d.role {
        case .digit, .op: return p.key
        case .fn: return p.fnKey
        case .clear: return p.clearKey
        }
    }

    private func fg(for d: KeyDef) -> Color {
        d.role == .fn ? p.fnKeyText : p.keyText
    }
}

struct KeyButtonStyle: ButtonStyle {
    let bg: Color
    let fg: Color
    let flash: Bool

    func makeBody(configuration: Configuration) -> some View {
        let down = configuration.isPressed || flash
        return configuration.label
            .foregroundStyle(fg)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(bg))
            .opacity(down ? 0.62 : 1)
            .scaleEffect(down ? 0.95 : 1)
            .animation(.easeOut(duration: 0.08), value: down)
            .contentShape(Rectangle())
    }
}

// MARK: - Cronologia

struct HistoryView: View {
    @EnvironmentObject var model: CalcModel
    let p: Palette

    var body: some View {
        VStack(spacing: 0) {
            if model.engine.history.isEmpty {
                Spacer()
                Image(systemName: "scroll")
                    .font(.system(size: 28, weight: .light))
                    .foregroundStyle(p.inkSoft)
                Text(L("Nessun conto ancora.\nOgni totale (*) finisce qui.", "No sums yet.\nEvery total (*) lands here."))
                    .multilineTextAlignment(.center)
                    .font(.system(size: 12))
                    .foregroundStyle(p.inkSoft)
                    .padding(.top, 8)
                Spacer()
            } else {
                if CalcModel.isSnapshot {
                    VStack(spacing: 0) { list; Spacer(minLength: 0) }.clipped()
                } else {
                    ScrollView(.vertical, showsIndicators: true) { list }
                }
                footer
            }
        }
        .frame(maxHeight: .infinity)
    }

    private var list: some View {
                    LazyVStack(alignment: .leading, spacing: 8, pinnedViews: [.sectionHeaders]) {
                        ForEach(model.historyGroups) { g in
                            Section(header: sectionHeader(g.title)) {
                                ForEach(g.items) { r in
                                    ReceiptCard(receipt: r, p: p, expanded: model.expandedReceipts.contains(r.id)) {
                                        model.toggleReceipt(r.id)
                                    }
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.bottom, 10)
    }

    private var footer: some View {
                HStack {
                    Text("\(model.engine.history.count) " + L("conti salvati", "saved"))
                        .font(.system(size: 11))
                        .foregroundStyle(p.inkSoft)
                    Spacer()
                    if model.confirmClear {
                        Button(L("Annulla", "Cancel")) { model.confirmClear = false }
                            .buttonStyle(.plain)
                            .font(.system(size: 11))
                            .foregroundStyle(p.inkSoft)
                        Button(L("Conferma: svuota tutto", "Confirm: clear all")) {
                            model.clearHistory()
                            model.confirmClear = false
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(p.red)
                    } else {
                        Button(L("Svuota cronologia", "Clear history")) { model.confirmClear = true }
                            .buttonStyle(.plain)
                            .font(.system(size: 11))
                            .foregroundStyle(p.inkSoft)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(p.inkSoft)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
            .background(p.bg)
    }
}

struct ReceiptCard: View {
    @EnvironmentObject var model: CalcModel
    let receipt: Receipt
    let p: Palette
    let expanded: Bool
    let toggle: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button(action: toggle) {
                HStack(spacing: 8) {
                    Text(CalcModel.timeFormatter.string(from: receipt.date))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(p.inkSoft)
                    Text(summary)
                        .font(.system(size: 11))
                        .foregroundStyle(p.inkSoft)
                        .lineLimit(1)
                    Spacer()
                    Text(receipt.total.map { CalcEngine.format($0, decimals: model.engine.decimals) } ?? L("annullato", "void"))
                        .font(.system(size: 14, weight: .bold, design: .monospaced))
                        .foregroundStyle(totalColor)
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(p.inkSoft)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded {
                VStack(spacing: 3) {
                    ForEach(receipt.lines) { line in
                        TapeRow(line: line, decimals: model.engine.decimals, p: p)
                            .onTapGesture { model.recall(line) }
                    }
                }
                .padding(.top, 2)
                HStack(spacing: 16) {
                    smallButton(L("Copia", "Copy"), "doc.on.doc") { model.copy(receipt.lines) }
                    if receipt.total != nil {
                        smallButton(L("Usa il totale", "Use total"), "arrow.uturn.left") { model.useTotal(receipt) }
                    }
                    Spacer()
                    smallButton(L("Elimina", "Delete"), "trash", color: p.red) { model.delete(receipt) }
                }
                .padding(.top, 2)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(p.paper))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(p.paperLine.opacity(0.6), lineWidth: 0.5))
    }

    private var summary: String {
        let n = receipt.lines.filter { $0.kind == .entry }.count
        return n == 1 ? L("1 voce", "1 item") : "\(n) " + L("voci", "items")
    }

    private var totalColor: Color {
        if let t = receipt.total, t < 0 { return p.red }
        return receipt.total == nil ? p.inkSoft : p.ink
    }

    private func smallButton(_ title: String, _ symbol: String, color: Color? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.system(size: 11))
                .foregroundStyle(color ?? p.ink)
        }
        .buttonStyle(.plain)
    }
}
