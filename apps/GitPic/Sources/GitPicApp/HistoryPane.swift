import AppKit
import SwiftUI
import GitPicCore

struct HistoryPane: View {
    @Bindable var model: AppModel

    /// How much thumbnail fetching is outstanding, pushed by ``ThumbnailStore``.
    ///
    /// View state and not something on ``AppModel``, unlike everything else this pane
    /// reads. Two reasons. Its lifetime is exactly this pane's: `.task` below subscribes
    /// when 历史 appears and is cancelled when it goes away, so nothing keeps a
    /// subscription alive for a window that is closed — and the window now survives
    /// being closed (see ``SettingsWindowController``). And no other surface wants it:
    /// the status-item menu has no rows and no thumbnails, so putting it on the model
    /// would be widening the app's shared state for one `Text`.
    @State private var progress: ThumbnailProgress = .idle

    /// A copy that just landed: which row's button is showing its checkmark, and which
    /// click put it there.
    ///
    /// One value for the whole pane rather than state inside each row, because the
    /// states it has to rule out are all *between* rows. Two rows can never be
    /// mid-checkmark at once, and copying several in a row moves the mark instead of
    /// leaving a trail of them: whichever click was last owns the only mark there is,
    /// and the row it left reverts in the same update.
    ///
    /// `seq` is not decoration. `.task(id:)` restarts only when the id actually
    /// *changes*, so keyed on the record alone a second click on the **same** row would
    /// not restart anything — the first click's timer would still be the one running,
    /// and it would clear the second click's checkmark early, after whatever was left
    /// of the first second. Bumping a counter on every copy makes each click a distinct
    /// id, so the timer restarts and the mark always lasts its full stay.
    private struct CopyFlash: Equatable {
        let record: HistoryRecord.ID
        let seq: Int
    }
    @State private var flash: CopyFlash?
    @State private var flashCount = 0

    /// How long the checkmark stays. Long enough to be seen if the eye was elsewhere on
    /// the row when it was clicked, short enough that it is gone before the next copy —
    /// and it does not have to carry information the way a banner did, because the
    /// pointer is already on the thing it is about.
    private static let flashDuration = Duration.seconds(1)

    var body: some View {
        // Same container as every other pane, and that is the whole point.
        //
        // This was a bare `VStack` + `List`, and it did not line up with anything: a
        // grouped `Form` honours the detail column's own margins, a naked `List` does
        // not. Measured on this window — the form panes' content sits at x=847 inside
        // a scroll area starting at 827 (a symmetric 20pt inset); the list's scroll
        // area started at 816 and ran 494 wide, so it bled 11pt *under* the split-view
        // divider on the left and 11pt past the window's right edge. Padding it by
        // hand would have meant hard-coding that 11 and re-deriving it at every window
        // size. Using the container the other panes use costs nothing and cannot drift.
        //
        // The format switcher scrolls with the content now rather than being pinned
        // above it. It is not the only way to reach those two choices — the status-item
        // menu carries the same shared `linkForm` — and a pinned strip was what forced
        // the hand-aligned layout in the first place.
        if let failure = model.configFailure {
            // Not "还没有上传记录", which is a claim this pane is in no position to
            // make: history and config are read by the same `reload()`, config first,
            // so a file that will not parse takes the history down with it and the
            // list is empty for a reason that has nothing to do with uploads.
            ContentUnavailableView {
                Label("读不到历史", systemImage: "exclamationmark.triangle")
            } description: {
                Text("\(failure.headline)。历史和配置是一起读的，所以这里也是空的。")
            } actions: {
                Button("重试") { Task { await model.reload() } }
                    .disabled(model.busy)
                Button("去「图床」处理") { SettingsNavigation.shared.selectedTab = .host }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.history.isEmpty {
            ContentUnavailableView("还没有上传记录", systemImage: "clock",
                                   description: Text("上传一张图片后会出现在这里。"))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            Form {
                // A header view rather than a title string, because it carries two
                // things: how many records, and what the copy buttons will produce.
                //
                // In the header and not the footer, and that is the whole point of the
                // second line. The switcher itself lives in 上传 now, so this pane has a
                // mode set elsewhere — and a footer sits below every row, which with 37
                // of them means below the fold, read by nobody. The copy button's
                // tooltip says the same thing, but only to whoever hovers the right
                // pixel.
                Section {
                    ForEach(model.history) { r in row(r) }
                } header: {
                    HStack(alignment: .firstTextBaseline) {
                        Text("\(model.history.count) 条记录")
                        // One line for the whole pane. On a cold cache the rows sit as
                        // grey boxes for about four seconds (``ThumbnailLimits``), and
                        // with nothing said about it a slow link is indistinguishable
                        // from a broken one.
                        //
                        // Next to the count rather than in place of it, and on the left
                        // rather than the right: the copy hint over there is a standing
                        // fact about this pane, and a line that comes and goes must
                        // neither replace it nor shove it sideways. Growing leftward
                        // into the `Spacer()` moves nothing.
                        //
                        // `.caption`, so the header cannot change height when it
                        // appears — the count beside it is the taller of the two either
                        // way — and `.monospacedDigit()` so a climbing number does not
                        // reflow its own text on every image, the same reason the byte
                        // sizes in the rows are monospaced.
                        //
                        // No `ProgressView` next to it, deliberately. The numbers moving
                        // already say "working"; a spinner is taller than this text and
                        // so is the one thing here that *would* change the header's
                        // height, and it would do it twice per open.
                        if progress.isActive {
                            Text("· 正在取缩略图 \(progress.done)/\(progress.total)")
                                .font(.caption)
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text("复制 \(model.linkForm.label) · 在「上传」页的「链接」改")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .formChrome()
            // Pushed, not polled: the store yields on every change and the current
            // state on subscribe, so this costs one hop onto the actor per image
            // resolved and nothing at all while the pane sits idle. Cancelled with the
            // pane, which is what releases the store's side of it.
            .task {
                // Subscribing is itself a hop onto the store, so it is its own `await`
                // rather than one buried in the `for` — the stream is handed back with
                // the current state already in it.
                let updates = await model.thumbnails.progressUpdates()
                for await update in updates {
                    progress = update
                }
            }
            // The checkmark's only way back. Keyed on the whole `CopyFlash`, so every
            // click — including a second one on the same row — cancels the previous
            // timer and starts a fresh one; see ``CopyFlash``. Clearing sets the id to
            // `nil`, which re-runs this and falls straight out of the guard.
            //
            // The cancellation check is what keeps a mark from being cleared by the
            // *previous* row's timer: when the id changes, this closure is cancelled
            // mid-sleep, and a cancelled run that went on to write `flash = nil` would
            // wipe the mark the new click had just set. Same shape as
            // `AppModel.beginWork`'s debounce, for the same reason.
            .task(id: flash) {
                guard flash != nil else { return }
                try? await Task.sleep(for: Self.flashDuration)
                guard !Task.isCancelled else { return }
                flash = nil
            }
        }
    }

    private func row(_ r: HistoryRecord) -> some View {
        HStack(spacing: 10) {
            // `savedConfig` is what an address is built from, so with no readable
            // config there is no URL to fetch — the row still lists what was uploaded,
            // it just cannot show it. The `configFailure` branch above already covers
            // the case where the read *failed*; this covers the seconds before the
            // first read lands.
            HistoryThumbnail(source: model.savedConfig.map { r.thumbnailSource(config: $0) },
                             store: model.thumbnails,
                             deduped: r.deduped)
            VStack(alignment: .leading, spacing: 2) {
                Text(r.name).lineLimit(1)
                Text(r.path)
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            Text(byteText(r.size))
                .font(.caption).monospacedDigit().foregroundStyle(.secondary)
            Button { copy(r) } label: { copyGlyph(flashed: flash?.record == r.id) }
                .buttonStyle(.borderless)
                // Swapped with the glyph, because this doubles as what a screen reader
                // reads off the button — see the note on ``copy(_:)`` about what the
                // checkmark cannot say out loud.
                .help(flash?.record == r.id ? "已复制" : "复制 \(model.linkForm.label)")
        }
        .padding(.vertical, 2)
    }

    /// The copy button's icon: the clipboard, or the checkmark that says the click
    /// landed.
    ///
    /// **Both glyphs are always laid out, one of them transparent.** A plain
    /// `Image(systemName: flashed ? … : …)` would resize the button as it swapped:
    /// measured at the 13 pt body size these rows inherit, `doc.on.clipboard` renders
    /// 16×18 pt and `checkmark` 14×13, so the mark would pull the byte count beside it
    /// 2 pt to the right and shorten the row's tallest trailing element by 5 on the way
    /// through — a twitch in the layout, to report that nothing went wrong.
    ///
    /// A `.frame(width:height:)` would pin it too, at the price of a hard-coded pair of
    /// numbers to re-measure whenever either symbol is redrawn. Stacking them makes the
    /// frame the union of the two glyphs, which is the same fix and derives itself.
    ///
    /// The swap is instant, deliberately: this is direct feedback for a click on the
    /// control under the pointer, and immediacy is the whole content of the message. The
    /// one animation in this app is for something that arrives late — see ``Motion``.
    private func copyGlyph(flashed: Bool) -> some View {
        ZStack {
            Image(systemName: "doc.on.clipboard").opacity(flashed ? 0 : 1)
            Image(systemName: "checkmark").opacity(flashed ? 1 : 0)
        }
    }

    /// History stores one URL and no record of which kind it is, so both addresses
    /// are rebuilt from the configured target — see `UploadedLink`.
    ///
    /// **Success is reported on the button; failure keeps the notification.** The split
    /// is not a preference, it is ``AppModel/notify(title:body:)``'s own justification
    /// applied where it holds and dropped where it does not. That justification is
    /// "outcomes are events, the window is usually closed when one happens" — true of an
    /// upload, and false of this button, which cannot be clicked without the window
    /// open, this pane in front, and the pointer resting on the control itself. A banner
    /// plus a system sound (`Notifier.post` sets `content.sound = .default`) for a click
    /// whose result is already under the cursor was the loudest available way of saying
    /// nothing.
    ///
    /// The failures below keep their banners because they carry a diagnosis no badge can
    /// hold: ``CDNUnavailable/ambiguousBranch`` is a sentence about a `/` in the branch
    /// name making every jsDelivr address a 404, and the remedy is a config change in
    /// another pane. A checkmark cannot say that, and neither can its absence. `Notifier`
    /// itself is untouched for the same reason — an upload finishing still wants the
    /// banner and the sound, because then the window really may be shut.
    ///
    /// One cost, stated because it is real: a checkmark is silent where the banner was
    /// announced, so a VoiceOver user loses a spoken confirmation and gets a changed
    /// button label instead. The log line below is what still distinguishes "copied, and
    /// you looked away" from "the button did nothing" after the fact — the same reason
    /// ``AppModel/writeLinkForm(_:)`` logs the success it deliberately does not announce.
    private func copy(_ r: HistoryRecord) {
        guard let cfg = model.savedConfig else {
            // Was a bare `return`: the button did nothing at all and said nothing
            // about why.
            model.notify(title: "复制失败", body: "读不到配置，生成不了链接")
            return
        }
        let form = model.linkForm
        // Names the cause, not just the gap: with a slashed branch every row in the pane
        // is CDN-less, and the remedy is a config change. Decided in Core, so the
        // menu-bar copy cannot word it differently — which it already did.
        switch UploadedLink(r, config: cfg).snippetOrReason(form, name: r.name) {
        case let .unavailable(reason):
            model.notify(title: "复制失败", body: reason)
        case let .text(text):
            if Clipboard.write(text) {
                flashCount += 1
                flash = CopyFlash(record: r.id, seq: flashCount)
                Diagnostics.log("copied \(form.label) from history: \(r.name)")
            } else {
                model.notify(title: "写剪贴板失败", body: r.name)
            }
        }
    }

    private func byteText(_ n: Int) -> String {
        n < 1024 ? "\(n) B" : String(format: "%.1f KB", Double(n) / 1024)
    }
}

/// One history row's picture: a fixed box holding the image, or the reason there is
/// none.
///
/// **Fixed box, image fitted inside it.** The width has to be constant or every row's
/// text starts at a different x, which is the one thing a list of 100 rows cannot
/// afford; and fitting rather than filling means a screenshot is shown whole instead
/// of centre-cropped to a shape it never had. The cost is letterboxing, which is why
/// the box is a visible surface rather than nothing.
///
/// The states are kept apart rather than collapsed into "no picture": a 404 on a
/// private image host is permanent and needs a decision from the user, a transport
/// error is worth reopening the pane for, and an original past the size ceiling is
/// working as designed. ``ThumbnailFailure/message`` is what the tooltip says.
struct HistoryThumbnail: View {
    /// `nil` when there is no config to build an address from.
    let source: ThumbnailSource?
    let store: ThumbnailStore
    let deduped: Bool

    /// 44×32 at a 4:3-ish ratio, which is the shape most screenshots arrive in, so
    /// the common case letterboxes least. Retina wants 88×64 of it; the decoder is
    /// asked for 160 px on the long edge (``ThumbnailLimits/maxPixel``).
    private static let width: CGFloat = 44
    private static let height: CGFloat = 32
    private static let corner: CGFloat = 5

    private enum Load {
        case pending
        case loaded(Thumbnail)
        case failed(ThumbnailFailure)
    }
    @State private var load: Load = .pending

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: Self.corner, style: .continuous)
                .fill(.quaternary)
            switch load {
            case .pending:
                // No spinner, deliberately. A hundred of them chasing each other down
                // the pane reports nothing and is the noisiest thing on screen; the
                // placeholder is the same glyph this row carried before.
                Image(systemName: "photo").foregroundStyle(.tertiary)
            case .loaded(let thumb):
                Image(decorative: thumb.image, scale: 1)
                    // The decoded thumbnail is larger than the box on a 1× display,
                    // so this is a downscale and the interpolation is visible.
                    .interpolation(.high)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            case .failed:
                Image(systemName: "photo.badge.exclamationmark").foregroundStyle(.tertiary)
            }
        }
        .frame(width: Self.width, height: Self.height)
        .clipShape(RoundedRectangle(cornerRadius: Self.corner, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Self.corner, style: .continuous)
                .strokeBorder(.separator, lineWidth: 0.5)
        }
        // Outside the clip, so the badge can sit on the corner rather than be cut by
        // it — the same place Finder puts an alias badge.
        .overlay(alignment: .bottomTrailing) { dedupBadge }
        .help(tooltip)
        // Keyed on the source, so a row whose address moved — `github.owner/repo/
        // branch` changed under it — refetches instead of showing the old picture.
        // Cancelled when the row scrolls away; the fetch itself survives that on
        // purpose, so the next row wanting the same image finds it cached.
        //
        // **Timed, so a cache hit and a download are not given the same treatment.**
        // The store cannot be asked which layer answered — and should not be, since
        // the answer that matters is not "was it cached" but "did anyone see the
        // placeholder". Both questions have the same answer, and the elapsed time is
        // the one that measures it directly: below the threshold nothing was on screen
        // long enough to fade *from*, and animating there would put a flutter on every
        // reopen of a warm pane where today there is none. Above it the grey box was
        // read as a grey box, and the picture replacing it is a change worth softening.
        // ``Motion/thumbnailIsLateAfter`` carries the numbers.
        //
        // Only the image. A late *failure* swaps one tertiary glyph for another inside
        // the same box, at the same size — there is no cut there to soften.
        .task(id: source) {
            guard let source else { return }
            let asked = ContinuousClock.now
            let result = await store.thumbnail(for: source)
            let late = ContinuousClock.now - asked >= Motion.thumbnailIsLateAfter
            switch result {
            case .success(let thumb):
                if late {
                    withAnimation(Motion.thumbnailArrival) { load = .loaded(thumb) }
                } else {
                    load = .loaded(thumb)
                }
            case .failure(let why):
                load = .failed(why)
            }
        }
    }

    /// `deduped` used to be the row's leading glyph — `doc.on.doc` instead of
    /// `photo` — and the thumbnail took that slot. It is a badge now rather than
    /// dropped: a deduped upload shows the *same picture* as the row it deduped
    /// against, which is exactly why the distinction has to be stated somewhere.
    ///
    /// **`.caption2` and not `.system(size: 7)`.** 7 pt was below every text style the
    /// platform ships — the macOS scale bottoms out at 10 pt, which `footnote`, `caption`
    /// and `caption2` all resolve to (measured with `NSFont.preferredFont(forTextStyle:)`)
    /// — so it was a number with nothing behind it, and one that could not follow the
    /// system text size anywhere.
    ///
    /// `.imageScale(.small)` is the half that keeps the swap from being a regression, and
    /// it is a relative knob rather than the magic number returning in a second spelling.
    /// Footprints below are the badge's own rendered layout size, measured with
    /// `ImageRenderer` against this same 44×32 box:
    ///
    /// | spelling | badge | of box height |
    /// | --- | --- | --- |
    /// | `.system(size: 7)`, as shipped | 13×16 | 50% |
    /// | `.caption2`, default medium scale | 17×20 | 62% |
    /// | `.caption2` + `.small` | 14×17 | 53% |
    ///
    /// The middle row is why the second modifier is here: at the default scale the token
    /// alone grows the badge to 17×20, which crowds the corner and starts competing with
    /// the picture 0.12.0 put in this slot. `.small` lands 1 pt larger on each axis than
    /// what shipped — still clear of the corner, glyph a shade bigger rather than
    /// smaller, and checked by eye at 1× and 2× as well as measured. `.footnote` +
    /// `.small` renders identically, both being 10 pt; `.caption2` is named because it is
    /// the bottom of the scale and says so.
    @ViewBuilder private var dedupBadge: some View {
        if deduped {
            Image(systemName: "doc.on.doc.fill")
                .font(.caption2.weight(.semibold))
                .imageScale(.small)
                .foregroundStyle(.secondary)
                .padding(2)
                .background(Circle().fill(.background))
                .overlay(Circle().strokeBorder(.separator, lineWidth: 0.5))
                .offset(x: 3, y: 3)
                .help("内容重复：仓库里这个路径已经是同样的内容，这次没有再上传")
        }
    }

    /// Always something, never an empty tooltip: the failure message where there is
    /// one, and otherwise the address the picture came from — which the row's own path
    /// line can only show truncated.
    private var tooltip: String {
        switch load {
        case .failed(let why):
            return why.message
        case .pending:
            return source == nil ? "还没读到配置，取不了缩略图" : "正在取缩略图…"
        case .loaded:
            // The address it was *reached* at is not recorded — a CDN hit and a raw
            // fallback are one cached image afterwards — so this names where the row
            // points, which is what the truncated path line cannot show in full.
            return source?.urls.first ?? ""
        }
    }
}
