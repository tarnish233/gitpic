import Foundation

extension CommandLineTool {
    /// A refresh may change which shells are available, but must not reset an explicit choice
    /// (notably fish on a machine whose login shell is zsh). Only fall back when it disappeared.
    public static func preferredShell(current: Shell?, available: [Shell], loginShell: URL?) -> Shell? {
        if let current, available.contains(current) { return current }
        if let measured = loginShell.flatMap(Shell.named), available.contains(measured) { return measured }
        return available.first
    }
}
