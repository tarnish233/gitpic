import SwiftUI
import GitPicCore

struct UploadPane: View {
    @Bindable var model: AppModel

    var body: some View {
        Form {
            ConfigGate(model: model, repairs: false) { draft in
                Section("路径") {
                    ConfigField(label: "模板", prompt: "images/{year}/{month}/{hash8}-{name}.{ext}",
                                text: draft.upload.pathTemplate)
                    Text("可用占位符：{year} {month} {day} {hash} {hash8} {name} {ext}")
                        .font(.caption).foregroundStyle(.secondary)
                }

                // Everything about "what link do I get" in one section. The two
                // live-together axes were in the history pane until now, one pane away
                // from the only other row naming the same idea.
                //
                // Two independent dimensions, because that is what they are: any syntax
                // can address either host. The flat four-case picker these replaced
                // listed Markdown / HTML / CDN URL / Raw URL as if they were
                // alternatives, which left two of the six combinations unreachable.
                //
                // One picker per row, and no `.fixedSize()`: two segmented controls in
                // one Form row plus the row's label column pushed the content to 920pt
                // inside a 680pt window — measured — squeezing the sidebar to a sliver.
                //
                // Two config rows, not app-local state: these bind to
                // `upload.format` and `upload.link_kind` through the draft, so they are
                // written by the toolbar's 保存 and reverted by 放弃 like every other
                // setting on this pane. There used to be a third row here — a separate
                // "CLI 默认地址" for `upload.link_kind` — with a caption admitting it had
                // no effect on the app. Two controls for the same idea, one of which
                // disclaimed itself, is what got collapsed: the app now copies what the
                // config says, so there is one address and one place to set it.
                //
                // Tagged by `rawValue` rather than by the enum, because the draft holds
                // the config's strings and those strings are the CLI's own spellings
                // (`md`/`html`/`url`, `cdn`/`raw` — see `LinkSyntax`).
                Section("链接") {
                    Picker("格式", selection: draft.upload.format) {
                        ForEach(LinkSyntax.allCases) { Text($0.label).tag($0.rawValue) }
                    }
                    .pickerStyle(.segmented)
                    Picker("地址", selection: draft.upload.linkKind) {
                        ForEach(LinkTarget.allCases) { Text($0.label).tag($0.rawValue) }
                    }
                    .pickerStyle(.segmented)
                    Text("配置文件里的 `upload.format` 与 `upload.link_kind`，改完按右上角"
                         + "「保存」才生效。")
                        .font(.caption).foregroundStyle(.secondary)
                }

                Section("行为") {
                    CaptionedToggle(label: "内容去重",
                                    caption: "相同内容不再重复提交，直接返回已有链接。",
                                    isOn: draft.upload.dedup)
                    // Label only, no caption: the switch says what it does. The app
                    // performs the copy itself (`--json` never writes the clipboard)
                    // and reads this same key, so one switch covers app and CLI alike
                    // — which is why it is no longer labelled 仅 CLI.
                    CaptionedToggle(label: "自动复制到剪贴板", isOn: draft.upload.autoCopy)
                }

                Section("压缩") {
                    CaptionedToggle(label: "上传前压缩", isOn: draft.upload.compress)
                    // Only the parameters are gated on the toggle. Disabling the
                    // whole section would disable the toggle too, leaving no way
                    // to switch compression back on.
                    Group {
                    LabeledContent("最大宽度") {
                        HStack(spacing: 12) {
                            Slider(value: intBinding(draft.upload.maxWidth), in: 0...4096, step: 64)
                                .frame(width: 180)
                            Text(draft.upload.maxWidth.wrappedValue == 0
                                 ? "不限制" : "\(draft.upload.maxWidth.wrappedValue) px")
                                .monospacedDigit().foregroundStyle(.secondary)
                                .frame(width: 70, alignment: .trailing)
                        }
                    }
                    LabeledContent("质量") {
                        HStack(spacing: 12) {
                            Slider(value: intBinding(draft.upload.quality), in: 1...100, step: 1)
                                .frame(width: 180)
                            Text("\(draft.upload.quality.wrappedValue)")
                                .monospacedDigit().foregroundStyle(.secondary)
                                .frame(width: 70, alignment: .trailing)
                        }
                    }
                    }
                    .disabled(!draft.upload.compress.wrappedValue)
                }
            }
        }
        .formChrome()
    }

    /// Slider works in Double; the config stores Int.
    private func intBinding(_ b: Binding<Int>) -> Binding<Double> {
        Binding(get: { Double(b.wrappedValue) },
                set: { b.wrappedValue = Int($0.rounded()) })
    }
}
