import BudgetAPI
import Foundation
import UIKit
import Vision
import PDFKit

struct ReceiptSuggestion: Identifiable, Equatable {
    let id = UUID()
    let payee: String?
    let amountMinor: Int64?
    let occurredOn: Date?
    let categoryID: String?
    let recognizedText: String

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.payee == rhs.payee && lhs.amountMinor == rhs.amountMinor && lhs.occurredOn == rhs.occurredOn
            && lhs.categoryID == rhs.categoryID && lhs.recognizedText == rhs.recognizedText
    }
}

enum ReceiptOCR {
    static func recognize(_ data: Data, currencyCode: String, categories: [APICategory]) async throws -> ReceiptSuggestion {
        guard let image = UIImage(data: data)?.cgImage else { throw ReceiptOCRError.invalidImage }
        let lines = try await Task.detached(priority: .userInitiated) {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            try VNImageRequestHandler(cgImage: image).perform([request])
            return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
        }.value
        guard !lines.isEmpty else { throw ReceiptOCRError.noText }
        return parse(lines: lines, currencyCode: currencyCode, categories: categories)
    }

    static func parse(lines: [String], currencyCode: String, categories: [APICategory], now: Date = Date()) -> ReceiptSuggestion {
        let cleaned = lines.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        let text = cleaned.joined(separator: "\n")
        let lowered = text.lowercased()
        let categoryID = categories.first { lowered.contains($0.name.lowercased()) }?.id
        return .init(
            payee: cleaned.first(where: plausiblePayee),
            amountMinor: bestAmount(in: cleaned, currencyCode: currencyCode),
            occurredOn: firstDate(in: cleaned, now: now),
            categoryID: categoryID,
            recognizedText: text
        )
    }

    private static func plausiblePayee(_ line: String) -> Bool {
        let lower = line.lowercased()
        guard line.count <= 100, line.rangeOfCharacter(from: .letters) != nil,
              !["receipt", "invoice", "thank you", "subtotal", "total", "tax", "change", "cash", "credit"].contains(where: lower.contains) else { return false }
        return line.filter(\.isNumber).count < max(4, line.count / 2)
    }

    private static func bestAmount(in lines: [String], currencyCode: String) -> Int64? {
        let pattern = #"[-+]?[$€£¥]?\s*\d{1,3}(?:[ ,]\d{3})*(?:[.,]\d{2})|[-+]?[$€£¥]?\s*\d+(?:[.,]\d{2})"#
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return nil }
        var candidates: [(score: Int, value: Int64)] = []
        for line in lines {
            let lower = line.lowercased()
            let range = NSRange(line.startIndex..., in: line)
            for match in expression.matches(in: line, range: range) {
                guard let swiftRange = Range(match.range, in: line) else { continue }
                var raw = String(line[swiftRange]).replacingOccurrences(of: "$", with: "")
                    .replacingOccurrences(of: "€", with: "").replacingOccurrences(of: "£", with: "")
                    .replacingOccurrences(of: "¥", with: "").replacingOccurrences(of: " ", with: "")
                if raw.filter({ $0 == "," }).count == 1, !raw.contains("."), raw.split(separator: ",").last?.count == 2 {
                    raw = raw.replacingOccurrences(of: ",", with: ".")
                } else { raw = raw.replacingOccurrences(of: ",", with: "") }
                guard let value = CurrencyText.parseMinorUnits(raw, currencyCode: currencyCode), value > 0 else { continue }
                let isTotal = lower.contains("total") && !lower.contains("subtotal")
                let score = isTotal ? 1_000 : (lower.contains("amount") || lower.contains("balance") ? 500 : 0)
                candidates.append((score, value))
            }
        }
        return candidates.max { lhs, rhs in lhs.score == rhs.score ? lhs.value < rhs.value : lhs.score < rhs.score }?.value
    }

    private static func firstDate(in lines: [String], now: Date) -> Date? {
        let patterns = ["MM/dd/yyyy", "M/d/yyyy", "MM-dd-yyyy", "M-d-yyyy", "yyyy-MM-dd", "MMM d, yyyy", "MMMM d, yyyy"]
        let calendar = Calendar.current
        for line in lines {
            for pattern in patterns {
                let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = pattern
                if let date = formatter.date(from: line.trimmingCharacters(in: .whitespacesAndNewlines)), date <= now,
                   calendar.dateComponents([.year], from: date, to: now).year ?? 100 < 20 { return date }
            }
        }
        return nil
    }
}

enum ReceiptOCRError: LocalizedError {
    case invalidImage, noText
    var errorDescription: String? {
        switch self {
        case .invalidImage: "The selected receipt image could not be read."
        case .noText: "No readable receipt text was found. Try a clearer, well-lit photo."
        }
    }
}

enum StatementPDFOCR {
    static func recognizeLines(_ data: Data) async throws -> [String] {
        guard data.count <= 10 * 1024 * 1024, data.starts(with: Data("%PDF-".utf8)),
              let document = PDFDocument(data: data), !document.isEncrypted,
              (1...50).contains(document.pageCount) else {
            throw StatementPDFOCRError.unsupportedDocument
        }
        var lines: [String] = []
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index) else { throw StatementPDFOCRError.unreadablePage }
            let bounds = page.bounds(for: .mediaBox)
            let width: CGFloat = 2_000
            let height = max(1, width * bounds.height / max(bounds.width, 1))
            guard let image = page.thumbnail(of: CGSize(width: width, height: height), for: .mediaBox).cgImage else {
                throw StatementPDFOCRError.unreadablePage
            }
            let pageLines = try await Task.detached(priority: .userInitiated) {
                let request = VNRecognizeTextRequest()
                request.recognitionLevel = .accurate
                request.usesLanguageCorrection = true
                try VNImageRequestHandler(cgImage: image).perform([request])
                return (request.results ?? []).sorted {
                    let verticalDifference = abs($0.boundingBox.midY - $1.boundingBox.midY)
                    return verticalDifference > 0.01
                        ? $0.boundingBox.midY > $1.boundingBox.midY
                        : $0.boundingBox.minX < $1.boundingBox.minX
                }.compactMap { $0.topCandidates(1).first?.string }
            }.value
            lines.append(contentsOf: pageLines)
            guard lines.count <= 50_000 else { throw StatementPDFOCRError.tooMuchText }
        }
        guard !lines.isEmpty else { throw StatementPDFOCRError.noText }
        return lines
    }
}

enum StatementPDFOCRError: LocalizedError {
    case unsupportedDocument, unreadablePage, tooMuchText, noText

    var errorDescription: String? {
        switch self {
        case .unsupportedDocument:
            "Scanned PDF recognition supports unencrypted statements up to 10 MB and 50 pages."
        case .unreadablePage:
            "A page in this scanned statement could not be read."
        case .tooMuchText:
            "The scanned statement contains more text than can be reviewed safely."
        case .noText:
            "No readable statement text was found. Try a clearer scan or download CSV, OFX, or QFX from your bank."
        }
    }
}
