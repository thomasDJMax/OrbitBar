import Foundation

/// UID strings are opaque. Recognize complete address tokens only, rather than
/// collecting hex letters across arbitrary text and accidentally joining them.
public enum BluetoothAudioUIDAddress {
    public static func extract(from uid: String?) -> Set<String> {
        guard let uid, !uid.isEmpty else { return [] }
        let text = uid as NSString
        let fullRange = NSRange(location: 0, length: text.length)
        let uuidRanges = uuid.matches(in: uid, range: fullRange).map(\.range)
        var addresses = Set<String>()

        for match in separated.matches(in: uid, range: fullRange) {
            let range = match.range(at: 1)
            let candidate = text.substring(with: range)
            let before = text.substring(to: range.location)
            let after = text.substring(from: NSMaxRange(range))
            // Do not take six bytes out of a longer byte sequence.
            guard precedingByte.firstMatch(in: before, range: NSRange(location: 0, length: (before as NSString).length)) == nil,
                  followingByte.firstMatch(in: after, range: NSRange(location: 0, length: (after as NSString).length)) == nil,
                  let address = BluetoothAddress.normalize(candidate) else { continue }
            addresses.insert(address)
        }
        for match in compact.matches(in: uid, range: fullRange) {
            let range = match.range(at: 1)
            // The final 12 hex characters of a UUID are not MAC evidence.
            guard !uuidRanges.contains(where: { NSIntersectionRange($0, range).length > 0 }),
                  let address = BluetoothAddress.normalize(text.substring(with: range)) else { continue }
            addresses.insert(address)
        }
        return addresses
    }

    private static let separated = try! NSRegularExpression(pattern: #"(?<![A-Za-z0-9])([0-9A-Fa-f]{2}([:-])(?:[0-9A-Fa-f]{2}\2){4}[0-9A-Fa-f]{2})(?![A-Za-z0-9])"#)
    private static let compact = try! NSRegularExpression(pattern: #"(?<![A-Za-z0-9])(?:0[xX])?([0-9A-Fa-f]{12})(?![A-Za-z0-9])"#)
    private static let uuid = try! NSRegularExpression(pattern: #"(?<![A-Za-z0-9])[0-9A-Fa-f]{8}-(?:[0-9A-Fa-f]{4}-){3}[0-9A-Fa-f]{12}(?![A-Za-z0-9])"#)
    private static let precedingByte = try! NSRegularExpression(pattern: #"(?:^|[^A-Za-z0-9])[0-9A-Fa-f]{2}[:-]$"#)
    private static let followingByte = try! NSRegularExpression(pattern: #"^[:-][0-9A-Fa-f]{2}(?:$|[^A-Za-z0-9])"#)
}
