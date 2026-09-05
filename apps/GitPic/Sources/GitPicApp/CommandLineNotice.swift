import SwiftUI

/// Warnings are never disclosure-only or color-only, and long paths must wrap rather than clip.
struct CommandLineNotice: View {
    let message: String

    var body: some View {
        Label(message, systemImage: "exclamationmark.triangle.fill")
            .font(.caption)
            .foregroundStyle(.orange)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
    }
}
