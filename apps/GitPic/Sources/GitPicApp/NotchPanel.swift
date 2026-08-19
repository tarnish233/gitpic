import AppKit
import SwiftUI
import GitPicCore

/// What the notch is currently showing.
@Observable
@MainActor
final class NotchModel {
    enum Phase: Equatable {
        case idle
        case hovering(count: Int)
        case uploading(count: Int)
        case done(summary: String)
        case failed(summary: String)
    }
    var phase: Phase = .idle
}

/// The interactive region of the notch overlay.
///
/// Two measured facts shape this view, and both are easy to get wrong:
///
/// 1. **The top `safeAreaInsets.top` points deliver no mouse or drag events to
///    any window, at any level.** Panels were placed over the menu-bar strip at
///    shielding, statusBar+1, mainMenu+1, popUpMenu, and floating levels; a
///    synthesised click reached none of them — `acceptsFirstMouse` was not even
///    queried. The same panel extended below the strip received the click
///    immediately. So the droppable area *must* hang below the menu bar; the
///    part visually hugging the notch is decoration.
///
/// 2. **`acceptsFirstMouse` must return true.** A `.accessory` app is never the
///    active app, and AppKit swallows the first click into an inactive window to
///    activate it. In the successful probe `acceptsFirstMouse` was queried
///    immediately before `mouseDown` arrived.
///
/// This is also where the design deliberately departs from the `macos-notch-ui`
/// skill reference, which sets `ignoresMouseEvents = true` (see
/// `references/NotchWindow.swift:42`). Click-through is right for a status
/// indicator and fatal for a drop target.
final class NotchDropView: NSView {
    var onDrop: (([URL]) -> Void)?
    var onHoverChange: ((Int?) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL])
    }
    required init?(coder: NSCoder) { fatalError("not loaded from a nib") }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// Keep every event on this view. The SwiftUI layer above is decoration and
    /// must not intercept the drag.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = superview.map { convert(point, from: $0) } ?? point
        return bounds.contains(local) ? self : nil
    }

    private func imageURLs(_ info: NSDraggingInfo) -> [URL] {
        let objs = info.draggingPasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        // Not filtered by extension on purpose: the CLI does no content
        // validation either (`src/commands/upload.rs:257-276` uploads any bytes),
        // so rejecting here would make the GUI stricter than the tool it drives.
        return objs
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        let urls = imageURLs(sender)
        guard !urls.isEmpty else { return [] }
        onHoverChange?(urls.count)
        return .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        imageURLs(sender).isEmpty ? [] : .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        onHoverChange?(nil)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = imageURLs(sender)
        onHoverChange?(nil)
        guard !urls.isEmpty else { return false }
        onDrop?(urls)
        return true
    }
}

/// The always-present overlay pinned to the top-centre of the notched screen.
@MainActor
final class NotchPanel: NSPanel {
    /// Height of the transparent, permanently-armed strip immediately below the
    /// menu bar. Small so it barely intrudes; a drag crossing it is what opens
    /// the real drop area. NSView hit-testing is by bounds, not alpha, so a fully
    /// transparent ledge still receives drags.
    static let ledgeHeight: CGFloat = 16
    /// Height of the drop area once a drag has opened it.
    static let openHeight: CGFloat = 130

    let model = NotchModel()
    private let dropView = NotchDropView(frame: .zero)
    private var hosting: NSHostingView<NotchContent>!
    private var isOpen = false

    var onDrop: (([URL]) -> Void)?

    init() {
        super.init(contentRect: .zero,
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered,
                   defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isMovableByWindowBackground = false
        ignoresMouseEvents = false          // see NotchDropView's note
        hidesOnDeactivate = false
        level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
        collectionBehavior = [.stationary, .canJoinAllSpaces,
                              .fullScreenAuxiliary, .ignoresCycle]

        hosting = NSHostingView(rootView: NotchContent(model: model))
        hosting.translatesAutoresizingMaskIntoConstraints = false
        dropView.addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: dropView.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: dropView.trailingAnchor),
            hosting.topAnchor.constraint(equalTo: dropView.topAnchor),
            hosting.bottomAnchor.constraint(equalTo: dropView.bottomAnchor),
        ])
        contentView = dropView

        dropView.onDrop = { [weak self] urls in
            guard let self else { return }
            self.model.phase = .uploading(count: urls.count)
            self.setOpen(true)
            self.onDrop?(urls)
        }
        dropView.onHoverChange = { [weak self] count in
            guard let self else { return }
            if let count {
                self.model.phase = .hovering(count: count)
                self.setOpen(true)
            } else if case .uploading = self.model.phase {
                // A drop already started work; keep it open.
            } else {
                self.model.phase = .idle
                self.setOpen(false)
            }
        }
    }

    /// The screen carrying the hardware notch, falling back to the main screen so
    /// non-notched Macs still get a usable pill at the top centre.
    static var hostScreen: NSScreen? {
        NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) ?? NSScreen.main
    }

    static var screenHasNotch: Bool { (hostScreen?.safeAreaInsets.top ?? 0) > 0 }

    private var menuBarInset: CGFloat {
        // On a notchless screen there is no safe-area inset, but the menu bar is
        // still a reserved strip, so fall back to its measured height.
        let inset = Self.hostScreen?.safeAreaInsets.top ?? 0
        return inset > 0 ? inset : NSStatusBar.system.thickness
    }

    private var panelWidth: CGFloat { 260 }

    func place() {
        guard let screen = Self.hostScreen else { return }
        let h = menuBarInset + (isOpen ? Self.openHeight : Self.ledgeHeight)
        let f = CGRect(x: screen.frame.midX - panelWidth / 2,
                       y: screen.frame.maxY - h,
                       width: panelWidth,
                       height: h)
        setFrame(f, display: true)
    }

    func show() {
        place()
        orderFront(nil)
    }

    private func setOpen(_ open: Bool) {
        guard open != isOpen else { return }
        isOpen = open
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.22
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            place()
        }
    }

    /// Show a terminal state briefly, then fall back to idle.
    func flash(_ phase: NotchModel.Phase, seconds: TimeInterval = 2.6) {
        model.phase = phase
        setOpen(true)
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard let self else { return }
            if self.model.phase == phase {
                self.model.phase = .idle
                self.setOpen(false)
            }
        }
    }
}

/// Decoration only — it must not install any drop handler of its own, or it would
/// compete with `NotchDropView` for the drag.
struct NotchContent: View {
    var model: NotchModel

    var body: some View {
        VStack(spacing: 6) {
            Spacer(minLength: 0)
            switch model.phase {
            case .idle:
                // A small handle hanging just under the notch. It sits in the
                // ledge — the strip below the menu bar — which is exactly the
                // region that can receive a drag, so what the user aims at and
                // what actually accepts the drop are the same pixels.
                Capsule()
                    .fill(.white.opacity(0.28))
                    .frame(width: 64, height: 4)
                    .padding(.bottom, 5)
            case .hovering(let n):
                label("arrow.down.circle.fill",
                      n == 1 ? "松手上传" : "松手上传 \(n) 张", .white)
            case .uploading(let n):
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small).tint(.white)
                    Text(n == 1 ? "上传中…" : "上传 \(n) 张…")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white)
                }
            case .done(let s):
                label("checkmark.circle.fill", s, .green)
            case .failed(let s):
                label("exclamationmark.triangle.fill", s, .orange)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(alignment: .top) {
            NotchShape()
                .fill(.black)
                .animation(.easeOut(duration: 0.18), value: model.phase)
        }
        .clipShape(NotchShape())
        .allowsHitTesting(false)
    }

    private func label(_ icon: String, _ text: String, _ tint: Color) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon).foregroundStyle(tint)
            Text(text)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white)
                .lineLimit(2)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 10)
    }
}
