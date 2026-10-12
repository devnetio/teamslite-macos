import Foundation
import os
import Security

let log = Logger(subsystem: "com.devnetio.TeamsLite", category: "app")

enum Config {
    /// Public client "Microsoft Graph Command Line Tools"; override in Settings with your own app registration.
    static let defaultClientID = "14d82eec-204b-4c2f-b7e8-296a70dab67e"
    static let defaultTenant = "organizations"
    /// Base URL of your deployed relay Worker (see relay/), set in Settings. Empty or "off" disables live updates.
    static let defaultRelay = ""
    static let relayPlaceholder = "https://teamslite-relay.<your-subdomain>.workers.dev"
    static let scopes = "openid profile offline_access User.Read User.ReadBasic.All Chat.ReadWrite"
    static let presenceScope = "https://graph.microsoft.com/Presence.ReadWrite offline_access"

    /// Keep the user's Teams status at Available while TeamsLite runs (on unless turned off in Settings).
    static var alwaysAvailable: Bool { UserDefaults.standard.object(forKey: "alwaysAvailable") as? Bool ?? true }

    static var clientID: String { value("clientID") ?? defaultClientID }
    static var tenant: String { value("tenant") ?? defaultTenant }

    static var relayURL: URL? {
        let raw = value("relayURL") ?? defaultRelay
        if raw.lowercased() == "off" { return nil }
        return URL(string: raw)
    }

    static func value(_ key: String) -> String? {
        let v = UserDefaults.standard.string(forKey: key)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (v?.isEmpty ?? true) ? nil : v
    }
}

/// Generic-password items in the login keychain.
enum Keychain {
    private static let service = "com.devnetio.TeamsLite"

    private static func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    static func read(_ account: String) -> Data? {
        var q = query(account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess else { return nil }
        return out as? Data
    }

    @discardableResult
    static func write(_ data: Data, account: String) -> Bool {
        let q = query(account)
        var status = SecItemUpdate(q as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var add = q
            add[kSecValueData as String] = data
            status = SecItemAdd(add as CFDictionary, nil)
        }
        if status != errSecSuccess { log.error("Keychain write failed: \(status)") }
        return status == errSecSuccess
    }

    static func delete(_ account: String) {
        SecItemDelete(query(account) as CFDictionary)
    }
}

/// Graph timestamps ("2024-09-26T15:58:19.993Z", variable fraction digits, optional offset).
enum GraphDate {
    private static let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    static func string(_ date: Date) -> String { formatter.string(from: date) }

    static func parse(_ s: String?) -> Date? {
        guard let s else { return nil }
        let u = Array(s.utf8)
        guard u.count >= 19 else { return nil }
        func num(_ at: Int, _ len: Int) -> Int? {
            var v = 0
            for k in at..<(at + len) {
                guard k < u.count, u[k] >= 48, u[k] <= 57 else { return nil }
                v = v * 10 + Int(u[k] - 48)
            }
            return v
        }
        guard let y = num(0, 4), let mo = num(5, 2), let d = num(8, 2),
              let h = num(11, 2), let mi = num(14, 2), let se = num(17, 2) else { return nil }
        var i = 19
        var frac = 0.0
        if i < u.count, u[i] == UInt8(ascii: ".") {
            i += 1
            var scale = 0.1
            while i < u.count, u[i] >= 48, u[i] <= 57 {
                frac += Double(u[i] - 48) * scale
                scale /= 10
                i += 1
            }
        }
        var offset = 0
        if i < u.count, u[i] == UInt8(ascii: "+") || u[i] == UInt8(ascii: "-"),
           let oh = num(i + 1, 2), let om = num(i + 4, 2) {
            offset = (oh * 3600 + om * 60) * (u[i] == UInt8(ascii: "-") ? -1 : 1)
        }
        // Days from civil (Howard Hinnant's algorithm).
        let yy = mo <= 2 ? y - 1 : y
        let era = (yy >= 0 ? yy : yy - 399) / 400
        let yoe = yy - era * 400
        let doy = (153 * ((mo + 9) % 12) + 2) / 5 + d - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        let days = era * 146097 + doe - 719468
        let seconds = Double(days * 86400 + h * 3600 + mi * 60 + se - offset) + frac
        return Date(timeIntervalSince1970: seconds)
    }
}

/// Shared, lazily created formatters (DateFormatter is expensive to build).
enum Fmt {
    static let time: DateFormatter = make { $0.timeStyle = .short; $0.dateStyle = .none }
    static let weekday: DateFormatter = make { $0.setLocalizedDateFormatFromTemplate("EEE") }
    static let shortDate: DateFormatter = make { $0.dateStyle = .short; $0.timeStyle = .none }
    static let dayTitle: DateFormatter = make { $0.setLocalizedDateFormatFromTemplate("EEEEdMMMM") }
    static let dayTitleYear: DateFormatter = make { $0.setLocalizedDateFormatFromTemplate("EEEEdMMMMyyyy") }

    private static func make(_ configure: (DateFormatter) -> Void) -> DateFormatter {
        let f = DateFormatter()
        configure(f)
        return f
    }

    /// Compact timestamp for the chat list.
    static func listTime(_ date: Date?) -> String {
        guard let date else { return "" }
        let cal = Calendar.current
        if cal.isDateInToday(date) { return time.string(from: date) }
        if cal.isDateInYesterday(date) { return "Yesterday" }
        if let days = cal.dateComponents([.day], from: cal.startOfDay(for: date), to: cal.startOfDay(for: Date())).day,
           days < 7 { return weekday.string(from: date) }
        return shortDate.string(from: date)
    }

    static func day(_ date: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(date) { return "Today" }
        if cal.isDateInYesterday(date) { return "Yesterday" }
        let sameYear = cal.component(.year, from: date) == cal.component(.year, from: Date())
        return (sameYear ? dayTitle : dayTitleYear).string(from: date)
    }
}
