import AppKit
import NotchCore
import PluginCore
import PluginStore
import SwiftUI

/// 设置 › 插件里装、卸、新建外部插件：选文件夹或拖进来，先给人看登记了什么再装；卸掉的挪进备份。
/// 文件操作和校验归 `PluginStore`，放到后台做：插件文件夹大、或者在慢盘上时界面不卡。不靠 config.json，配置文件解不开也能用
struct InstalledPluginsSection: View {
    let state: AppState
    /// 拖到整页上的文件夹（`PluginsPane` 接）：来了就校验
    @Binding var dropped: URL?
    @State private var pending: Pending?
    @State private var uninstalling: Manifest?
    @State private var creating = false
    @State private var choosing = false
    @State private var working = false
    @State private var error: String?

    /// 校验过、等用户点「安装」的文件夹
    struct Pending: Identifiable {
        var source: URL
        var manifest: Manifest
        var replacing: Bool
        var id: URL { source }
    }

    var body: some View {
        let installed = state.manifests.values.sorted { $0.id < $1.id }
        Section {
            ForEach(installed, id: \.id) { m in
                LabeledContent {
                    HStack(spacing: 4) {
                        Button { NSWorkspace.shared.activateFileViewerSelecting([PluginPaths.plugins.appendingPathComponent(m.id)]) } label: {
                            Image(systemName: "folder")
                        }
                        .help("在 Finder 中显示")
                        Button("卸载…") { uninstalling = m }
                    }
                    .buttonStyle(.borderless)
                    .disabled(working)
                } label: {
                    PluginLabel(plugin: m.id, state: state, detail: m.id)
                }
            }
            HStack {
                Button("安装插件…") { choosing = true }
                Button("新建插件…") { creating = true }
                Spacer()
                if working { ProgressView().controlSize(.small) }
            }
            .disabled(working)
        } header: {
            Text("已安装")
        } footer: {
            if let error {
                Text(error).foregroundStyle(.red)
            } else {
                Text("插件是一个含 manifest.json 的文件夹，也可以直接拖到这一页上安装。Pip 不运行插件里的任何文件；卸掉的插件挪进 ~/Library/Application Support/Notchkeeper/backup/plugins/，不会删除（自带的终端插件除外）。")
            }
        }
        .fileImporter(isPresented: $choosing, allowedContentTypes: [.folder]) { result in
            switch result {
            case .success(let url): inspect(url)
            case .failure(let e): error = String(localized: "打不开这个文件夹：\(e.localizedDescription)")
            }
        }
        .sheet(item: $pending) { p in
            InstallPluginSheet(pending: p) { install(p.source) }
        }
        .sheet(isPresented: $creating) {
            NewPluginSheet { state.reloadManifests() }
        }
        .confirmationDialog(uninstalling.map { String(localized: "卸载「\($0.name)」？") } ?? "", isPresented: Binding(
            get: { uninstalling != nil }, set: { if !$0 { uninstalling = nil } }), presenting: uninstalling) { m in
            Button("卸载", role: .destructive) { uninstall(m) }
        } message: { m in
            // 终端插件的目录归 App、每次启动都换新，里面没有用户写的东西：直接删
            Text(m.id == PluginID.terminal ? String(localized: "删掉终端插件的脚本，~/.zshrc 里那一行留着也不报错。之后终端发来的卡片都会丢掉。")
                                           : String(localized: "插件文件夹挪进备份，不会删除。之后它发来的卡片和活动都会丢掉。"))
        }
        .onChange(of: dropped) {
            guard let url = dropped else { return }
            dropped = nil
            inspect(url)
        }
    }

    private func inspect(_ url: URL) {
        error = nil
        run { store in
            let m = try store.inspect(url, symbolExists: InboxWatcher.symbolExists)
            let replacing = FileManager.default.fileExists(atPath: store.plugins.appendingPathComponent(m.id).path)
            return Pending(source: url, manifest: m, replacing: replacing)
        } then: { pending = $0 }
    }

    private func install(_ url: URL) {
        run { store in
            try store.install(url, symbolExists: InboxWatcher.symbolExists, now: Date())
        } then: { result in
            Log.write("插件：已安装 \(result.manifest.id)\(result.replaced == nil ? "" : "，旧版挪进备份")")
        }
    }

    private func uninstall(_ m: Manifest) {
        run { store in
            if m.id == PluginID.terminal { try TerminalPlugin.uninstall() } else { _ = try store.uninstall(m.id, now: Date()) }
        } then: { _ in
            Log.write("插件：已卸载 \(m.id)")
        }
    }

    /// 后台做文件操作，回主线程更新界面、重读登记。错误只显示在本页，不往外抛
    private func run<T: Sendable>(_ work: @escaping @Sendable (PluginStore) throws -> T, then: @escaping @MainActor (T) -> Void) {
        working = true
        error = nil
        Task {
            let result = await Task.detached { Result { try work(PluginStore()) } }.value
            switch result {
            case .success(let value): then(value)
            case .failure(let e): error = e.localizedDescription
            }
            state.reloadManifests()
            working = false
        }
    }
}

/// 设置页上显示的原因。和 `pipctl plugin` 的说法一致（`PluginCommand.describe`）；改一边，两边一起改
extension PluginStore.Problem: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .noManifest: return String(localized: "文件夹里没有 manifest.json")
        case .manifest(.malformed): return String(localized: "manifest.json 不是 JSON，或缺 id、name、symbol")
        case .manifest(.badID): return String(localized: "id 只能用小写字母、数字和连字符，至多 32 个字符")
        case .manifest(.reservedID): return String(localized: "id 是内置插件的（guard、claude），换一个")
        case .manifest(.missingField): return String(localized: "名字（name）和图标（symbol）不能是空的")
        case .manifest(.tooLong): return String(localized: "名字至多 \(Card.maxValue) 个字，图标名至多 \(Manifest.maxSymbol) 个字符")
        case .unknownSymbol(let s): return String(localized: "系统里没有叫 \(s) 的 SF Symbol（名字可以在「SF Symbols」App 里查）")
        case .bundled: return String(localized: "terminal 是自带的终端插件，在设置 › 终端里装卸")
        case .alreadyInstalled: return String(localized: "这个文件夹就是已经装着的那份")
        case .notInstalled: return String(localized: "没装这个插件")
        case .exists: return String(localized: "同 id 的插件已经装着")
        }
    }
}

/// 装之前给人看：登记了什么名字、图标、id，会不会替换已装的
struct InstallPluginSheet: View {
    let pending: InstalledPluginsSection.Pending
    let onInstall: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let m = pending.manifest
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                PluginIcon(symbol: m.symbol, size: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text("安装「\(m.name)」？").font(.headline)
                    Text(m.id).font(.caption).monospaced().foregroundStyle(.secondary)
                }
            }
            Text(pending.source.path(percentEncoded: false)).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            if pending.replacing {
                Label("已经装着同 id 的插件：旧版挪进备份，不会删除。", systemImage: "arrow.triangle.2.circlepath")
            }
            Text("Pip 只读它的 manifest.json，不运行里面的任何文件。装上后它发来的卡片会标明来源。")
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("取消", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(pending.replacing ? "替换" : "安装") {
                    dismiss()
                    onInstall()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}

/// 新建一个只有 manifest.json 的插件，建好后给出一条能直接跑的 pipctl 命令
struct NewPluginSheet: View {
    let onCreated: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var id = ""
    @State private var symbol = ""
    @State private var created: Manifest?
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let created { done(created) } else { form }
        }
        .frame(width: 440)
    }

    private var form: some View {
        VStack(spacing: 0) {
            Form {
                TextField("名字", text: $name, prompt: Text("卡上标明来源用，例如「备份」"))
                VStack(alignment: .leading, spacing: 4) {
                    TextField("id", text: $id, prompt: Text("例如 backup"))
                    if let idProblem { Text(idProblem).font(.caption).foregroundStyle(.red) }
                }
                VStack(alignment: .leading, spacing: 4) {
                    LabeledContent {
                        HStack {
                            TextField("图标", text: $symbol, prompt: Text("SF Symbol 名，例如 externaldrive")).labelsHidden()
                            PluginIcon(symbol: symbolValid ? symbol : "questionmark", size: 22)
                        }
                    } label: {
                        Text("图标")
                    }
                    if !symbol.isEmpty, !symbolValid { Text("系统里没有这个图标，名字可以在「SF Symbols」App 里查").font(.caption).foregroundStyle(.red) }
                }
                if let error { Text(error).foregroundStyle(.red) }
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("取消", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("新建", action: create)
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.allSatisfy(\.isWhitespace) || id.isEmpty || idProblem != nil || !symbolValid)
            }
            .padding([.horizontal, .bottom], 20)
        }
    }

    private func done(_ m: Manifest) -> some View {
        let command = "pipctl notify --plugin \(m.id) --title \"你好\""
        return VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                PluginIcon(symbol: m.symbol, size: 40)
                Text("已新建「\(m.name)」").font(.headline)
            }
            Text("在终端里跑下面这行，刘海会弹一张卡：")
            HStack {
                Text(command).monospaced().textSelection(.enabled)
                Spacer()
                Button("拷贝") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(command, forType: .string)
                }
            }
            HStack {
                Button("在 Finder 中显示") { NSWorkspace.shared.activateFileViewerSelecting([PluginPaths.plugins.appendingPathComponent(m.id)]) }
                Spacer()
                Button("完成") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
    }

    private var symbolValid: Bool { !symbol.isEmpty && InboxWatcher.symbolExists(symbol) }

    /// 边输边查：格式、保留的 id、已经装着的
    private var idProblem: String? {
        guard !id.isEmpty else { return nil }
        guard Message.isPluginID(id) else { return String(localized: "只能用小写字母、数字和连字符，至多 32 个字符") }
        guard !PluginID.builtIn.contains(id), id != PluginID.terminal else { return String(localized: "这个 id 留给内置插件，换一个") }
        guard !FileManager.default.fileExists(atPath: PluginPaths.plugins.appendingPathComponent(id).path) else { return String(localized: "同 id 的插件已经装着") }
        return nil
    }

    private func create() {
        error = nil
        do {
            created = try PluginStore().create(id: id, name: name, symbol: symbol, symbolExists: InboxWatcher.symbolExists)
            Log.write("插件：已新建 \(id)")
            onCreated()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// 外部插件的图标：和设置页侧栏一样的圆角底，大小可调
struct PluginIcon: View {
    let symbol: String
    let size: CGFloat

    var body: some View {
        RoundedRectangle(cornerRadius: size / 4, style: .continuous)
            .fill(Color.indigo.gradient)
            .frame(width: size, height: size)
            .overlay(Image(systemName: symbol).font(.system(size: size * 0.6, weight: .semibold)).foregroundStyle(.white))
            .accessibilityHidden(true)
    }
}
