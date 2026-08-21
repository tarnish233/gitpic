import Foundation

/// What the menu-bar drop target accepts.
///
/// Lives here rather than beside the `NSView` that calls it because the rule is a
/// product decision worth a test, and `GitPicApp` is an executable target that no
/// test can import (see `Package.swift`).
public enum ImageDrop {

    /// The one image a drag should upload, or `nil` to refuse the drag outright.
    ///
    /// **Exactly one.** A drag of several images is refused rather than partially
    /// uploaded: `draggingEntered` returns no operation, the icon does not
    /// highlight, and the system plays its own snap-back. Silence is the right
    /// answer there — the drag never started as far as the user's eye is concerned.
    ///
    /// This takes URLs that have **already been filtered to images** by the caller,
    /// via `NSPasteboard.readObjects(forClasses:options:)` with
    /// `.urlReadingContentsConformToTypes: [UTType.image.identifier]`. That check is
    /// left to AppKit on purpose: it uses the file's real type, so a folder
    /// (`public.folder`) is excluded without this code keeping an extension
    /// allow-list of its own. Measured on the fixtures: `one.png` → `public.png`,
    /// `notes.txt` → `public.plain-text`, `archive.zip` → `public.zip-archive`,
    /// `a-folder` → `public.folder`.
    ///
    /// **This reverses a decision the deleted notch drop view had written down.**
    /// That view accepted any file type, arguing the GUI should not be stricter than
    /// the CLI, which validates no content either. Two things outweigh it: the two
    /// surviving upload entry points already restrict to images (the open panel via
    /// `allowedContentTypes`, the clipboard via `urlReadingContentsConformToTypes`),
    /// so an unfiltered drop was the odd one out; and a drag has no undo — by the
    /// time a wrong file is uploaded it is a commit in the image-host repository.
    public static func accepted(imageURLs: [URL]) -> URL? {
        imageURLs.count == 1 ? imageURLs.first : nil
    }
}
