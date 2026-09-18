// Copyright (c) 2026 Patrick Tudor. SPDX-License-Identifier: MIT
import Foundation

/// Every user-facing string in the app. A key is its English wording and has an
/// entry, with a translator comment, in packaging/Localization/<table>.xcstrings.
/// scripts/package.py compiles those catalogs into the app bundle, and
/// scripts/check-localization.py keeps this source and the catalogs in step.
///
/// There is deliberately no default "Localizable" table. A bare SwiftUI literal
/// such as Text("Done") would look there, find nothing, and show English in
/// every language, so views take an already-localized String from here instead.
public enum Strings {
    /// The main window: choosing archives, the queue, results, and their errors.
    public static func extraction(_ key: String, _ arguments: CVarArg...) -> String {
        lookup(key, table: "Extraction", arguments: arguments)
    }

    /// The menu bar.
    public static func menus(_ key: String, _ arguments: CVarArg...) -> String {
        lookup(key, table: "Menus", arguments: arguments)
    }

    /// The update sheet, its progress messages, and update errors.
    public static func updates(_ key: String, _ arguments: CVarArg...) -> String {
        lookup(key, table: "Updates", arguments: arguments)
    }

    static func lookup(_ key: String, table: String, arguments: [CVarArg], bundle: Bundle = .main) -> String {
        let format = bundle.localizedString(forKey: key, value: key, table: table)
        // Text without arguments is never a format string, so a "%" in a
        // translation is shown as written.
        guard !arguments.isEmpty else { return format }
        // Plural rules travel with the looked-up string; formatting it directly
        // selects the form for the count and localizes the digits.
        return String(format: format, locale: .current, arguments: arguments)
    }
}
