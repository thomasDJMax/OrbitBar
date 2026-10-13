import Foundation

/// Canonical text addresses. Registry byte blobs have no assumed byte order.
public enum BluetoothAddress {
    public static func normalize(_ text: String) -> String? {
        let bytes = Array(text.trimmingCharacters(in: .whitespacesAndNewlines).utf8)
        let digits: [UInt8]
        if bytes.count == 12 {
            digits = bytes
        } else if bytes.count == 17 {
            let separator = bytes[2]
            guard separator == 58 || separator == 45,
                  [2, 5, 8, 11, 14].allSatisfy({ bytes[$0] == separator }) else { return nil }
            digits = bytes.enumerated().compactMap { index, byte in index % 3 == 2 ? nil : byte }
        } else { return nil }
        guard digits.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }) else { return nil }
        let upper = digits.map { (97...102).contains($0) ? $0 - 32 : $0 }
        guard !upper.allSatisfy({ $0 == 48 }), !upper.allSatisfy({ $0 == 70 }) else { return nil }
        return stride(from: 0, to: 12, by: 2).map {
            String(decoding: upper[$0..<($0 + 2)], as: UTF8.self)
        }.joined(separator: ":")
    }
}
