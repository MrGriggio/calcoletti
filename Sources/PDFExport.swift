import AppKit

/// Crea un PDF A4 con i conti della cronologia, impaginati come scontrini.
enum PDFExport {
    static let page = CGRect(x: 0, y: 0, width: 595, height: 842)   // A4 in punti
    static let margin: CGFloat = 50

    static let inkColor = NSColor(calibratedWhite: 0.08, alpha: 1)
    static let softColor = NSColor(calibratedWhite: 0.48, alpha: 1)
    static let lineColor = NSColor(calibratedWhite: 0.78, alpha: 1)
    static let redColor = NSColor(calibratedRed: 0.80, green: 0.10, blue: 0.10, alpha: 1)

    static func data(for receipts: [Receipt], decimals: Int, title: String? = nil) -> Data {
        let out = NSMutableData()
        var box = page
        guard let consumer = CGDataConsumer(data: out as CFMutableData),
              let ctx = CGContext(consumer: consumer, mediaBox: &box, nil) else { return Data() }

        let sorted = receipts.sorted { $0.date < $1.date }
        let mono = NSFont.monospacedSystemFont(ofSize: 10.5, weight: .regular)
        let monoBold = NSFont.monospacedSystemFont(ofSize: 10.5, weight: .bold)
        let monoSemi = NSFont.monospacedSystemFont(ofSize: 10.5, weight: .semibold)
        let small = NSFont.monospacedSystemFont(ofSize: 8.5, weight: .regular)
        let lineH: CGFloat = 15
        let right = page.width - margin
        let valueRight = right - 26
        let symbolX = right - 20

        var y: CGFloat = 0
        var pageNo = 0
        var open = false

        func draw(_ s: String, x: CGFloat, y: CGFloat, font: NSFont, color: NSColor, alignRight: Bool = false) {
            let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
            let str = s as NSString
            let w = alignRight ? str.size(withAttributes: attrs).width : 0
            str.draw(at: CGPoint(x: x - w, y: y), withAttributes: attrs)
        }
        func hline(_ y: CGFloat, from x0: CGFloat, to x1: CGFloat, color: NSColor, dash: Bool = false, width: CGFloat = 0.6) {
            ctx.saveGState()
            ctx.setStrokeColor(color.cgColor)
            ctx.setLineWidth(width)
            if dash { ctx.setLineDash(phase: 0, lengths: [3, 3]) }
            ctx.move(to: CGPoint(x: x0, y: y)); ctx.addLine(to: CGPoint(x: x1, y: y)); ctx.strokePath()
            ctx.restoreGState()
        }
        func endPage() {
            guard open else { return }
            draw("Calcoletti · \(pageNo)", x: right, y: page.height - margin + 18, font: small, color: softColor, alignRight: true)
            NSGraphicsContext.restoreGraphicsState()
            ctx.restoreGState()
            ctx.endPDFPage()
            open = false
        }
        func newPage() {
            endPage()
            ctx.beginPDFPage(nil)
            ctx.saveGState()
            ctx.translateBy(x: 0, y: page.height)
            ctx.scaleBy(x: 1, y: -1)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
            pageNo += 1
            open = true
            y = margin
        }
        func ensure(_ h: CGFloat) { if y + h > page.height - margin { newPage() } }

        // Intestazione
        newPage()
        draw(title ?? L("Cronologia dei conti", "Calculation history"), x: margin, y: y,
             font: NSFont.systemFont(ofSize: 20, weight: .bold), color: inkColor)
        y += 30
        let f = DateFormatter()
        f.locale = Locale(identifier: CalcEngine.english ? "en_US" : "it_IT")
        f.dateStyle = .long; f.timeStyle = .short
        let n = sorted.count
        let countText = n == 1 ? L("1 conto", "1 calculation") : "\(n) " + L("conti", "calculations")
        draw("Calcoletti · " + L("esportato il ", "exported on ") + f.string(from: Date()) + " · " + countText,
             x: margin, y: y, font: NSFont.systemFont(ofSize: 10), color: softColor)
        y += 26
        hline(y, from: margin, to: right, color: inkColor, width: 1)
        y += 18

        if sorted.isEmpty {
            draw(L("Nessun conto in cronologia.", "No calculations in history."), x: margin, y: y,
                 font: NSFont.systemFont(ofSize: 11), color: softColor)
        }

        let df = DateFormatter()
        df.locale = Locale(identifier: CalcEngine.english ? "en_US" : "it_IT")
        df.dateFormat = CalcEngine.english ? "EEEE, MMMM d, yyyy · HH:mm" : "EEEE d MMMM yyyy · HH:mm"

        for r in sorted {
            // un conto che sta in una pagina non viene spezzato
            let visible = r.lines.filter { $0.kind != .cut }
            let needed = 22 + lineH * CGFloat(visible.count) + CGFloat(visible.filter { $0.kind == .total }.count) * 4 + 28
            ensure(min(needed, page.height - 2 * margin - 40))
            // titolo del conto: data e totale
            var head = df.string(from: r.date)
            head = head.prefix(1).uppercased() + head.dropFirst()
            draw(head, x: margin, y: y, font: NSFont.systemFont(ofSize: 11, weight: .semibold), color: inkColor)
            let totalText = r.total.map { CalcEngine.format($0, decimals: decimals) } ?? L("annullato", "void")
            draw(totalText, x: right, y: y, font: NSFont.monospacedSystemFont(ofSize: 11, weight: .bold),
                 color: (r.total ?? 0) < 0 ? redColor : (r.total == nil ? softColor : inkColor), alignRight: true)
            y += 22

            for line in r.lines {
                if line.kind == .cut { continue }
                ensure(lineH + (line.kind == .total ? 6 : 0))
                if line.kind == .total {
                    hline(y + 1, from: valueRight - 130, to: right, color: inkColor)
                    y += 4
                }
                let isRed = line.kind == .error || line.symbol == "−" || (line.value ?? 0) < 0
                let color = isRed ? redColor : (line.kind == .note ? softColor : inkColor)
                let font: NSFont
                switch line.kind {
                case .total, .grandTotal: font = monoBold
                case .subtotal, .result: font = monoSemi
                default: font = mono
                }
                if !line.label.isEmpty {
                    draw(line.label, x: margin + 12, y: y, font: small, color: softColor)
                }
                draw(CalcEngine.formatLine(line, decimals: decimals), x: valueRight, y: y, font: font, color: color, alignRight: true)
                draw(line.symbol, x: symbolX, y: y, font: font, color: color)
                y += lineH
            }
            y += 10
            ensure(12)
            hline(y, from: margin, to: right, color: lineColor, dash: true)
            y += 18
        }
        endPage()
        ctx.closePDF()
        return out as Data
    }
}
