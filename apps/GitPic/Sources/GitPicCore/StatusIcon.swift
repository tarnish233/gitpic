import Foundation

/// Which SF Symbol the menu-bar icon should be showing.
///
/// Three mutually exclusive cases. The mapping lives here so a test can pin it;
/// *when* `.uploading` is shown is a refcount in `AppDelegate`, not this type.
/// In `GitPicCore` because `GitPicApp` is an executable target no test can import.
/// The symbol names are plain strings (no AppKit) so a test can pin the whole rule.
public enum StatusIcon: Equatable, Sendable {
    /// Nothing in flight. The resting glyph.
    case idle
    /// One or more uploads running. Held until the last one finishes.
    case uploading
    /// Discovery finished and `gitpic` was not found. Decided once at launch
    /// and never recovered from.
    case unavailable

    /// The resting glyph: the app's own mark.
    public static let idleSymbol = "photo.on.rectangle.angled"
    /// In flight. An arrow, because the direction is the news.
    public static let uploadingSymbol = "arrow.up.circle"
    /// No `gitpic`; nothing here can upload.
    public static let unavailableSymbol = "exclamationmark.triangle.fill"

    /// The symbol to draw.
    public var symbol: String {
        switch self {
        case .idle: return Self.idleSymbol
        case .uploading: return Self.uploadingSymbol
        case .unavailable: return Self.unavailableSymbol
        }
    }
}
