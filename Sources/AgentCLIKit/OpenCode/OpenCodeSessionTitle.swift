import Foundation

/// Native timestamp placeholders are session identifiers, not generated task names; keep them from replacing host titles.
enum OpenCodeSessionTitle {
    static func meaningful(_ title: String?) -> String? {
        guard let title else { return nil }
        // Matches v1's Session.isDefaultTitle while preserving genuine titles that merely share its prefix.
        let placeholder = #"\A(?:New session|Child session) - [0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}\.[0-9]{3}Z\z"#
        return title.range(of: placeholder, options: .regularExpression) == nil ? title : nil
    }
}
