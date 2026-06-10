enum ClaudePermissionModes {
    static let bypassPermissions = "bypassPermissions"
    static let dontAsk = "dontAsk"
    static let plan = "plan"

    static func canonicalHostMode(_ mode: String) -> String {
        mode == dontAsk ? bypassPermissions : mode
    }

    static func requiresDangerousModeUnlock(_ mode: String?) -> Bool {
        mode == bypassPermissions
    }
}
