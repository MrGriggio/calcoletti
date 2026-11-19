import Foundation

/// Testo nella lingua dell'app: italiano se il Mac è in italiano, altrimenti inglese.
func L(_ it: String, _ en: String) -> String { CalcEngine.english ? en : it }

// MARK: - Modello dati dello scontrino

enum LineKind: String, Codable {
    case entry      // numero battuto (+, −, ×, ÷, Δ …)
    case result     // risultato di × ÷ % Δ
    case subtotal   // ◇
    case total      // *
    case grandTotal // GT
    case note       // righe informative (annullato, GT azzerato)
    case error      // E
    case cut        // linea di taglio tra uno scontrino e l'altro
}

struct TapeLine: Codable, Identifiable, Equatable {
    var id = UUID()
    var value: Decimal?
    var symbol: String
    var label: String = ""
    var kind: LineKind
}

struct Receipt: Codable, Identifiable, Equatable {
    var id = UUID()
    var date: Date
    var lines: [TapeLine]
    var total: Decimal?
}

enum CalcKey: Hashable {
    case digit(Int), doubleZero, decimal, backspace, sign, clear
    case add, sub, mul, div, delta, percent
    case equals      // tasto "=": conclude × ÷ Δ, altrimenti fa il totale
    case subtotal, total, grandTotal
}

enum PendingOp: String, Codable { case mul, div, delta }

// MARK: - Motore (logica da calcolatrice scrivente, come la Olivetti Logos)

struct CalcEngine: Codable {
    var tape: [TapeLine] = []
    var history: [Receipt] = []
    var receiptStart: Int = 0

    var entry: String = ""          // numero in battitura, formato grezzo "1234.5"
    var acc: Decimal = 0            // accumulatore delle somme
    var count: Int = 0              // numero di voci sommate (CNT)
    var gt: Decimal = 0             // gran totale
    var pendingOp: PendingOp? = nil
    var pendingValue: Decimal = 0
    var display: Decimal = 0        // valore mostrato quando non si sta battendo
    var displayIsResult = false     // il display contiene un risultato riutilizzabile con + / −
    var lastWasGT = false
    var decimals: Int = 2           // -1 = virgola mobile (F)

    static var english: Bool = !(Locale.preferredLanguages.first ?? "it").hasPrefix("it")
    static var decimalSep: String { english ? "." : "," }
    static var groupSep: String { english ? "," : "." }

    static let maxTapeLines = 1500
    static let maxHistory = 2000
    static let maxDigits = 15

    // MARK: Stato utile alla UI

    var entryValue: Decimal? {
        guard !entry.isEmpty, entry != "-" else { return entry == "-" ? 0 : nil }
        return Decimal(string: entry, locale: Locale(identifier: "en_US_POSIX"))
    }

    var currentValue: Decimal { entryValue ?? display }

    var receiptInProgress: Bool { tape.count > receiptStart }

    // MARK: Ingresso tasti

    mutating func input(_ key: CalcKey) {
        let wasGT = lastWasGT
        if key != .grandTotal { lastWasGT = false }

        switch key {
        case .digit(let d): typeDigits(String(d))
        case .doubleZero: typeDigits("00")
        case .decimal: typeDecimal()
        case .backspace: backspace()
        case .sign: toggleSign()
        case .clear: clear()
        case .add: addOrSubtract(positive: true)
        case .sub: addOrSubtract(positive: false)
        case .mul: startOp(.mul)
        case .div: startOp(.div)
        case .delta: startOp(.delta)
        case .percent: percent()
        case .equals:
            if pendingOp != nil { equals() } else { total() }
        case .subtotal: subtotal()
        case .total: total()
        case .grandTotal: grandTotal(second: wasGT)
        }
        trimTape()
    }

    /// Mette un valore (es. toccato sullo scontrino o dalla cronologia) nel display come se fosse battuto.
    mutating func recall(_ value: Decimal) {
        entry = CalcEngine.raw(value)
        lastWasGT = false
    }

    mutating func clearTape() {
        // Strappa la carta: se c'è uno scontrino in corso lo archivia prima.
        if receiptInProgress { archive(total: nil) }
        tape.removeAll()
        receiptStart = 0
    }

    mutating func resetGT() { gt = 0 }

    // MARK: Battitura

    private mutating func typeDigits(_ d: String) {
        let digits = entry.filter(\.isNumber).count
        if digits + d.count > CalcEngine.maxDigits { return }
        if entry == "0" { entry = "" }
        if entry == "-0" { entry = "-" }
        if entry.isEmpty && d == "00" { entry = "0"; return }
        entry += d
    }

    private mutating func typeDecimal() {
        if entry.contains(".") { return }
        if entry.isEmpty { entry = "0." }
        else if entry == "-" { entry = "-0." }
        else { entry += "." }
    }

    private mutating func backspace() {
        guard !entry.isEmpty else { return }
        entry.removeLast()
        if entry == "-" { entry = "" }
    }

    private mutating func toggleSign() {
        if entry.isEmpty {
            if display != 0 { entry = CalcEngine.raw(-display) } else { entry = "-" }
        } else if entry.hasPrefix("-") {
            entry.removeFirst()
        } else {
            entry = "-" + entry
        }
    }

    private mutating func clear() {
        if !entry.isEmpty { entry = ""; return }   // CE
        // C: annulla il conto in corso
        let hadWork = pendingOp != nil || count > 0 || receiptInProgress
        if hadWork {
            append(TapeLine(value: nil, symbol: "C", label: L("annullato", "void"), kind: .note))
            archive(total: nil)
        }
        acc = 0; count = 0; pendingOp = nil; pendingValue = 0
        display = 0; displayIsResult = false
    }

    private mutating func takeEntry() -> Decimal? {
        guard let v = entryValue else { return nil }
        entry = ""
        return v
    }

    // MARK: Somme

    private mutating func addOrSubtract(positive: Bool) {
        var v: Decimal
        if pendingOp != nil {
            guard let r = equals() else { return }
            v = r
        } else if let e = takeEntry() {
            v = e
        } else if displayIsResult {
            v = display
        } else {
            return
        }
        v = round(v)
        acc += positive ? v : -v
        count += 1
        append(TapeLine(value: v, symbol: positive ? "+" : "−", kind: .entry))
        display = acc
        displayIsResult = false
    }

    private mutating func subtotal() {
        if pendingOp != nil || entryValue != nil { addOrSubtract(positive: true) }
        guard count > 0 else { return }
        append(TapeLine(value: acc, symbol: "◇", label: L("n. ", "no. ") + "\(count)", kind: .subtotal))
        display = acc
        displayIsResult = false
    }

    private mutating func total() {
        if pendingOp != nil && count == 0 {
            equals()                          // es. 12 × 3 * → conclude la moltiplicazione
        } else if pendingOp != nil || entryValue != nil {
            addOrSubtract(positive: true)     // l'ultimo numero battuto va sommato
        }
        if count > 0 {
            let t = acc
            append(TapeLine(value: t, symbol: "*", label: L("n. ", "no. ") + "\(count)", kind: .total))
            gt += t
            acc = 0; count = 0
            display = t
            displayIsResult = true
            archive(total: t)
        } else if receiptInProgress {
            archive(total: display)
            displayIsResult = true
        }
    }

    private mutating func grandTotal(second: Bool) {
        let standalone = !receiptInProgress && pendingOp == nil && count == 0
        if second {
            gt = 0
            append(TapeLine(value: 0, symbol: "GT", label: L("azzerato", "cleared"), kind: .note))
            lastWasGT = false
            display = 0
            displayIsResult = false
        } else {
            append(TapeLine(value: gt, symbol: "GT", label: L("gran totale", "grand total"), kind: .grandTotal))
            display = gt
            displayIsResult = true
            lastWasGT = true
        }
        if standalone { receiptStart = tape.count }
    }

    // MARK: Moltiplicazioni, divisioni, delta

    private mutating func startOp(_ op: PendingOp) {
        var first: Decimal
        if pendingOp != nil {
            if entryValue == nil {
                // cambio di operazione: sostituisce il simbolo dell'ultima riga
                pendingOp = op
                if let i = tape.indices.last { tape[i].symbol = CalcEngine.symbol(op); tape[i].label = op == .delta ? L("da", "from") : "" }
                return
            }
            guard let r = equals() else { return }
            first = r
        } else if let e = takeEntry() {
            first = e
        } else {
            first = display
        }
        pendingOp = op
        pendingValue = first
        append(TapeLine(value: first, symbol: CalcEngine.symbol(op), label: op == .delta ? L("da", "from") : "", kind: .entry))
        display = first
        displayIsResult = false
    }

    @discardableResult
    private mutating func equals() -> Decimal? {
        guard let op = pendingOp else { return nil }
        let a = pendingValue
        let b = takeEntry() ?? display
        pendingOp = nil
        switch op {
        case .mul:
            append(TapeLine(value: b, symbol: "", kind: .entry))
            return finish(round(a * b), symbol: "=")
        case .div:
            append(TapeLine(value: b, symbol: "", kind: .entry))
            guard b != 0 else { return fail() }
            return finish(round(a / b), symbol: "=")
        case .delta:
            append(TapeLine(value: b, symbol: "", label: L("a", "to"), kind: .entry))
            guard a != 0 else { return fail() }
            let diff = b - a
            append(TapeLine(value: diff, symbol: "Δ", label: L("differenza", "difference"), kind: .entry))
            let pct = CalcEngine.round(diff / abs(a) * 100, scale: decimals < 0 ? 4 : max(decimals, 2))
            return finish(pct, symbol: "%", label: L("variazione", "change"))
        }
    }

    private mutating func percent() {
        if let op = pendingOp {
            let a = pendingValue
            let b = takeEntry() ?? display
            pendingOp = nil
            switch op {
            case .mul:
                append(TapeLine(value: b, symbol: "%", kind: .entry))
                finish(round(a * b / 100), symbol: "=")
            case .div:
                append(TapeLine(value: b, symbol: "%", kind: .entry))
                guard b != 0 else { fail(); return }
                finish(round(a / b * 100), symbol: "%")
            case .delta:
                pendingOp = .delta
                if entry.isEmpty && b != display { entry = CalcEngine.raw(b) }
                equals()
            }
            return
        }
        // Senza operazione in sospeso: percentuale sul totale parziale (es. 1000 + 22 % → 220)
        guard let v = takeEntry() else { return }
        if count > 0 {
            append(TapeLine(value: v, symbol: "%", label: L("su ", "of ") + CalcEngine.format(acc, decimals: decimals), kind: .entry))
            finish(round(acc * v / 100), symbol: "=")
        } else {
            append(TapeLine(value: v, symbol: "%", kind: .entry))
            finish(round(v / 100), symbol: "=")
        }
    }

    @discardableResult
    private mutating func finish(_ r: Decimal, symbol: String, label: String = "") -> Decimal {
        append(TapeLine(value: r, symbol: symbol, label: label, kind: .result))
        display = r
        displayIsResult = true
        return r
    }

    @discardableResult
    private mutating func fail() -> Decimal? {
        append(TapeLine(value: nil, symbol: "E", label: L("errore", "error"), kind: .error))
        pendingOp = nil
        entry = ""
        display = 0
        displayIsResult = false
        return nil
    }

    // MARK: Carta e cronologia

    private mutating func append(_ line: TapeLine) { tape.append(line) }

    private mutating func archive(total: Decimal?) {
        if receiptInProgress {
            let lines = Array(tape[receiptStart...])
            history.append(Receipt(date: Date(), lines: lines, total: total))
            if history.count > CalcEngine.maxHistory { history.removeFirst(history.count - CalcEngine.maxHistory) }
        }
        tape.append(TapeLine(value: nil, symbol: "", kind: .cut))
        receiptStart = tape.count
    }

    private mutating func trimTape() {
        let extra = tape.count - CalcEngine.maxTapeLines
        guard extra > 0 else { return }
        tape.removeFirst(extra)
        receiptStart = max(0, receiptStart - extra)
    }

    private func round(_ v: Decimal) -> Decimal {
        decimals < 0 ? CalcEngine.round(v, scale: 10) : CalcEngine.round(v, scale: decimals)
    }

    // MARK: Utilità numeriche e formattazione italiana

    static func symbol(_ op: PendingOp) -> String {
        switch op { case .mul: return "×"; case .div: return "÷"; case .delta: return "Δ" }
    }

    static func round(_ v: Decimal, scale: Int) -> Decimal {
        var input = v
        var out = Decimal()
        NSDecimalRound(&out, &input, scale, .plain)
        return out
    }

    /// Valore → stringa grezza per la battitura ("1234.5")
    static func raw(_ v: Decimal) -> String {
        var s = "\(round(v, scale: 10))"
        if s.contains(".") {
            while s.hasSuffix("0") { s.removeLast() }
            if s.hasSuffix(".") { s.removeLast() }
        }
        return s == "-0" ? "0" : s
    }

    /// 1234567.5 → "1.234.567,50" (decimals = -1 → virgola mobile)
    static func format(_ v: Decimal, decimals: Int, signed: Bool = false) -> String {
        let scale = decimals < 0 ? 8 : decimals
        var r = round(v, scale: scale)
        let negative = r < 0
        if negative { r = -r }
        let s = "\(r)"
        var intPart = s
        var frac = ""
        if let dot = s.firstIndex(of: ".") {
            intPart = String(s[..<dot])
            frac = String(s[s.index(after: dot)...])
        }
        if decimals >= 0 {
            if frac.count < decimals { frac += String(repeating: "0", count: decimals - frac.count) }
            if frac.count > decimals { frac = String(frac.prefix(decimals)) }
        } else {
            while frac.hasSuffix("0") { frac.removeLast() }
        }
        let out = group(intPart) + (frac.isEmpty ? "" : decimalSep + frac)
        let isZero = r == 0
        if negative && !isZero { return "-" + out }
        if signed && !isZero { return "+" + out }
        return out
    }

    /// Stringa in battitura → visualizzazione ("1234.5" → "1.234,5", mantiene la virgola finale)
    static func formatEntry(_ e: String) -> String {
        var s = e
        var sign = ""
        if s.hasPrefix("-") { sign = "-"; s.removeFirst() }
        if s.isEmpty { return sign + "0" }
        let parts = s.split(separator: ".", omittingEmptySubsequences: false)
        let intPart = parts.first.map(String.init) ?? "0"
        var out = group(intPart.isEmpty ? "0" : intPart)
        if parts.count > 1 { out += decimalSep + parts[1] }
        return sign + out
    }

    private static func group(_ digits: String) -> String {
        var chars = Array(digits)
        var out = ""
        while chars.count > 3 {
            out = groupSep + String(chars.suffix(3)) + out
            chars.removeLast(3)
        }
        return String(chars) + out
    }

    static func decimals(for line: TapeLine, base: Int) -> Int {
        (line.kind == .result && line.symbol == "%") ? (base < 0 ? base : max(base, 2)) : base
    }

    static func isSigned(_ line: TapeLine) -> Bool {
        ["differenza", "variazione", "difference", "change"].contains(line.label)
    }

    static func formatLine(_ line: TapeLine, decimals: Int) -> String {
        guard let v = line.value else { return "" }
        return format(v, decimals: self.decimals(for: line, base: decimals), signed: isSigned(line))
    }

    /// Testo dello scontrino per appunti / condivisione
    static func text(for lines: [TapeLine], decimals: Int) -> String {
        lines.map { line -> String in
            if line.kind == .cut { return String(repeating: "-", count: 32) }
            let v = formatLine(line, decimals: decimals)
            let left = line.label.padding(toLength: 11, withPad: " ", startingAt: 0)
            let right = String(repeating: " ", count: max(0, 17 - v.count)) + v
            return left + right + " " + line.symbol
        }.joined(separator: "\n")
    }
}
