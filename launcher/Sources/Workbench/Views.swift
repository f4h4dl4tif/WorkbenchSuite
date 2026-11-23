import SwiftUI

enum SidebarItem: Hashable {
    case all, installed, updates
    case category(String)
}

struct ContentView: View {
    @EnvironmentObject var store: SuiteStore
    @State private var selection: SidebarItem? = .all
    @State private var search = ""
    @State private var detail: SuiteApp?
    @Environment(\.glassOn) private var glassOn

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    if let update = store.launcherUpdate { LauncherUpdateBanner(release: update) }
                    if let until = store.rateLimitedUntil { RateLimitNote(until: until) }
                    if selection == .all && search.isEmpty { Hero() }
                    lineup
                }
                .padding(32)
                .frame(maxWidth: 1240, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .background(SuiteBackground(glass: glassOn))
            .searchable(text: $search, placement: .toolbar, prompt: "Search tools")
            .toolbar {
                ToolbarItem {
                    Button { Task { await store.refresh() } } label: {
                        if store.isRefreshing { ProgressView().controlSize(.small) }
                        else { Label("Check for Updates", systemImage: "arrow.clockwise") }
                    }
                    .help(store.lastChecked.map { "Check GitHub for new releases (last checked \($0.formatted(.relative(presentation: .named))))" } ?? "Check GitHub for new releases")
                }
            }
        }
        .navigationSplitViewStyle(.balanced)
        .sheet(item: $detail) { app in AppDetailView(app: app).environmentObject(store) }
        #if DEBUG
        .onReceive(NotificationCenter.default.publisher(for: .glassSnapshotDetail)) { n in
            detail = n.object == nil ? nil : store.apps.first
        }
        #endif
        .alert("Workbench", isPresented: Binding(get: { store.alert != nil }, set: { if !$0 { store.alert = nil; store.needsAppManagement = false } })) {
            if store.needsAppManagement {
                Button("Open App Management Settings") {
                    NSWorkspace.shared.open(Permission.appManagementSettings)
                    store.alert = nil; store.needsAppManagement = false
                }
            }
            Button("OK") { store.alert = nil; store.needsAppManagement = false }
        } message: { Text(store.alert ?? "") }
    }

    private var sidebar: some View {
        List(selection: $selection) {
            Section("Library") {
                Label("All Tools", systemImage: "square.grid.2x2").tag(SidebarItem.all)
                Label("Installed", systemImage: "checkmark.circle")
                    .badge(store.installed.count)
                    .tag(SidebarItem.installed)
                Label("Updates", systemImage: "arrow.down.circle")
                    .badge(store.updatesAvailable.count)
                    .tag(SidebarItem.updates)
            }
            Section("Categories") {
                ForEach(store.catalog.categories, id: \.self) { c in
                    Label(c, systemImage: Theme.categoryIcon(c)).tag(SidebarItem.category(c))
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            VStack(alignment: .leading, spacing: 4) {
                Text(store.catalog.suite).font(.system(size: 11, weight: .semibold))
                Link("Open source on GitHub", destination: store.suiteRepoURL)
                    .font(.system(size: 11)).foregroundStyle(Theme.amber)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
        }
        .navigationSplitViewColumnWidth(min: 190, ideal: 210)
    }

    private var filtered: [SuiteApp] {
        var list = store.apps
        switch selection ?? .all {
        case .all: break
        case .installed: list = list.filter { store.installed[$0.id] != nil }
        case .updates: list = store.updatesAvailable
        case .category(let c): list = list.filter { $0.category == c }
        }
        if !search.isEmpty {
            list = list.filter {
                $0.name.localizedCaseInsensitiveContains(search) || $0.tagline.localizedCaseInsensitiveContains(search)
                    || $0.category.localizedCaseInsensitiveContains(search)
            }
        }
        return list
    }

    private var title: String {
        switch selection ?? .all {
        case .all: return "The lineup"
        case .installed: return "Installed"
        case .updates: return "Updates"
        case .category(let c): return c
        }
    }

    private var lineup: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                SectionLabel(number: String(format: "%02d", filtered.count), title: title)
                Spacer()
                if selection == .updates {
                    if let run = store.queueRun {
                        QueueStatus(done: run.done, total: run.total)
                    } else if !store.updatesAvailable.isEmpty {
                        Button("Update All") { Task { await store.updateAll() } }.buttonStyle(PrimaryButtonStyle())
                    }
                }
            }
            if filtered.isEmpty {
                Text(emptyMessage).foregroundStyle(Theme.secondary).padding(.vertical, 40).frame(maxWidth: .infinity)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 270, maximum: 420), spacing: 16)], spacing: 16) {
                    ForEach(filtered) { app in
                        AppCard(app: app).onTapGesture { detail = app }
                    }
                }
            }
        }
    }

    private var emptyMessage: String {
        switch selection ?? .all {
        case .installed: return "None of the tools are installed yet."
        case .updates: return "Everything is up to date."
        default: return "No tools match “\(search)”."
        }
    }
}

struct Hero: View {
    @EnvironmentObject var store: SuiteStore
    @Environment(\.glassOn) private var glassOn

    var body: some View {
        HStack(alignment: .center, spacing: 24) {
            VStack(alignment: .leading, spacing: 12) {
                SectionLabel(number: "\(store.apps.count)", title: "native Mac tools")
                Text("Capable, open-source\ntools for your Mac.")
                    .font(.system(size: 34, weight: .bold))
                    .foregroundStyle(.white)
                Text("Free and MIT-licensed. Native SwiftUI, local-first, no accounts or subscriptions.\nInstall any tool in one click and keep them all up to date from here.")
                    .font(.system(size: 13.5))
                    .foregroundStyle(Theme.secondary)
                    .lineSpacing(3)
                HStack(spacing: 10) {
                    let updates = store.updatesAvailable.count
                    if let run = store.queueRun {
                        QueueStatus(done: run.done, total: run.total)
                    } else if updates > 0 {
                        Button("Update \(updates) Tool\(updates == 1 ? "" : "s")") { Task { await store.updateAll() } }
                            .buttonStyle(PrimaryButtonStyle())
                    }
                    Link(destination: store.suiteRepoURL) { Text("View on GitHub") }
                        .buttonStyle(AdaptiveSecondaryButtonStyle())
                }
                .padding(.top, 6)
            }
            .layoutPriority(1)
            Spacer(minLength: 0)
            ViewThatFits(in: .horizontal) { iconCloud; EmptyView() }
        }
        .padding(28)
        .frame(minHeight: 250)
        .background(glassOn ? AnyShapeStyle(Color.clear) : AnyShapeStyle(LinearGradient(colors: [Theme.card, Theme.background], startPoint: .top, endPoint: .bottom)),
                    in: RoundedRectangle(cornerRadius: 22))
        .glassPanel(glassOn, in: RoundedRectangle(cornerRadius: 22))
        .overlay(RoundedRectangle(cornerRadius: 22).stroke(glassOn ? Color.clear : Theme.border))
    }

    /// A loose cluster of tool icons in the hero's corner.
    private var iconCloud: some View {
        let icons = Array(store.apps.prefix(12))
        return LazyVGrid(columns: Array(repeating: GridItem(.fixed(40), spacing: 10), count: 4), spacing: 10) {
            ForEach(icons) { app in
                Image(nsImage: store.icon(for: app)).resizable().frame(width: 40, height: 40)
            }
        }
        .opacity(0.9)
        .mask(LinearGradient(colors: [.black, .black.opacity(0.15)], startPoint: .topTrailing, endPoint: .bottomLeading))
    }
}

struct AppCard: View {
    @EnvironmentObject var store: SuiteStore
    let app: SuiteApp
    @State private var hovering = false
    @Environment(\.glassOn) private var glassOn

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                Image(nsImage: store.icon(for: app)).resizable().frame(width: 52, height: 52)
                VStack(alignment: .leading, spacing: 5) {
                    Text(app.name).font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
                    Pill(text: app.category, color: Theme.categoryColor(app.category))
                }
                Spacer(minLength: 0)
            }
            Text(app.tagline)
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.secondary)
                .lineLimit(2, reservesSpace: true)
            Spacer(minLength: 0)
            ActionRow(app: app)
        }
        .padding(16)
        .frame(minHeight: 168)
        .background(glassOn ? Color.clear : (hovering ? Theme.cardHover : Theme.card), in: RoundedRectangle(cornerRadius: 16))
        .glassPanel(glassOn, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(hovering ? Theme.amber.opacity(0.35) : (glassOn ? Color.clear : Theme.border)))
        .offset(y: hovering ? -2 : 0)
        .animation(.easeOut(duration: 0.15), value: hovering)
        .onHover { hovering = $0 }
        .contentShape(Rectangle())
    }
}

/// Status text plus the main button for a tool: Install, Update, Open, or progress.
struct ActionRow: View {
    @EnvironmentObject var store: SuiteStore
    let app: SuiteApp

    var body: some View {
        HStack(spacing: 10) {
            switch store.state(of: app) {
            case .checking:
                ProgressView().controlSize(.small)
                Text("Checking…").statusStyle()
                Spacer()
            case .unavailable(let why):
                Text(why).statusStyle().lineLimit(1).help(why)
                Spacer()
            case .notInstalled:
                Text(store.releases[app.id].map { "v\($0.version)" } ?? "").statusStyle()
                Spacer()
                Button("Install") { Task { await store.install(app) } }.buttonStyle(PrimaryButtonStyle())
            case .installed(let v):
                Label("v\(v)", systemImage: "checkmark.circle.fill").labelStyle(.titleAndIcon)
                    .font(.system(size: 11.5, weight: .medium)).foregroundStyle(Theme.mint)
                Spacer()
                Button("Open") { store.open(app) }.buttonStyle(AdaptiveSecondaryButtonStyle())
            case .updateAvailable(let from, let to):
                Text("v\(from) → v\(to)").statusStyle()
                Spacer()
                Button("Open") { store.open(app) }.buttonStyle(AdaptiveSecondaryButtonStyle())
                Button("Update") { Task { await store.install(app) } }.buttonStyle(PrimaryButtonStyle())
            case .working(let label, let progress):
                VStack(alignment: .leading, spacing: 5) {
                    Text(label).statusStyle()
                    if let progress { ProgressView(value: progress).tint(Theme.amber) }
                    else { ProgressView().progressViewStyle(.linear).tint(Theme.amber) }
                }
            case .queued(let position):
                HStack(spacing: 5) {
                    Image(systemName: "clock").font(.system(size: 11)).foregroundStyle(Theme.amber)
                    Text(position == 1 ? "Up next" : "Queued · #\(position)").statusStyle()
                }
                Spacer()
                Button("Remove") { store.dequeue(app) }.buttonStyle(AdaptiveSecondaryButtonStyle())
                    .help("Take \(app.name) out of the update queue")
            }
        }
        .frame(height: 28)
    }
}

private extension Text {
    func statusStyle() -> some View {
        font(.system(size: 11.5, weight: .medium)).foregroundStyle(Theme.tertiary)
    }
}

struct LauncherUpdateBanner: View {
    let release: Release
    @Environment(\.glassOn) private var glassOn
    var body: some View {
        HStack {
            Image(systemName: "sparkles").foregroundStyle(Theme.amber)
            Text("Workbench \(release.version) is available.").font(.system(size: 12.5, weight: .medium))
            Spacer()
            Link("Download", destination: release.htmlURL).buttonStyle(PrimaryButtonStyle())
        }
        .padding(12)
        .background(Theme.amber.opacity(glassOn ? 0 : 0.08), in: RoundedRectangle(cornerRadius: 12))
        .glassPanel(glassOn, in: RoundedRectangle(cornerRadius: 12), tint: Theme.amber.opacity(0.18))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.amber.opacity(0.25)))
    }
}

// MARK: - Detail sheet

struct AppDetailView: View {
    @EnvironmentObject var store: SuiteStore
    @Environment(\.dismiss) private var dismiss
    let app: SuiteApp
    @State private var confirmUninstall = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 18) {
                Image(nsImage: store.icon(for: app)).resizable().frame(width: 88, height: 88)
                VStack(alignment: .leading, spacing: 6) {
                    Text(app.name).font(.system(size: 26, weight: .bold))
                    Text(app.tagline).font(.system(size: 14)).foregroundStyle(Theme.secondary)
                    HStack(spacing: 6) {
                        Pill(text: app.category, color: Theme.categoryColor(app.category))
                        Pill(text: "macOS \(app.minOS)+")
                        Pill(text: "MIT")
                    }.padding(.top, 2)
                }
                Spacer()
                Button { dismiss() } label: { Image(systemName: "xmark").font(.system(size: 12, weight: .bold)) }
                    .buttonStyle(.plain).foregroundStyle(Theme.secondary).keyboardShortcut(.cancelAction)
            }
            .padding(24)

            Divider().overlay(Theme.border)

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text(app.description).font(.system(size: 13.5)).lineSpacing(3)
                    info
                    if let notes = store.releases[app.id]?.body, !notes.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            SectionLabel(number: "v\(store.releases[app.id]!.version)", title: "Release notes")
                            Text((try? AttributedString(markdown: notes, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(notes))
                                .font(.system(size: 12.5)).foregroundStyle(Theme.secondary).textSelection(.enabled)
                        }
                    }
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Divider().overlay(Theme.border)

            HStack(spacing: 10) {
                Link(destination: store.repoURL(app)) { Label("Source Code", systemImage: "chevron.left.forwardslash.chevron.right") }
                    .buttonStyle(AdaptiveSecondaryButtonStyle())
                if store.installed[app.id] != nil {
                    Button("Show in Finder") { store.reveal(app) }.buttonStyle(AdaptiveSecondaryButtonStyle())
                    Button("Uninstall…") { confirmUninstall = true }.buttonStyle(AdaptiveSecondaryButtonStyle())
                }
                Spacer()
                ActionRow(app: app).frame(maxWidth: 300)
            }
            .padding(18)
        }
        .frame(width: 620, height: 560)
        .background(Theme.background)
        .confirmationDialog("Move \(app.name) to the Bin?", isPresented: $confirmUninstall) {
            Button("Move to Bin", role: .destructive) { store.uninstall(app) }
        } message: {
            Text("The app is moved to the Bin. Its settings and data stay on your Mac.")
        }
    }

    private var info: some View {
        let release = store.releases[app.id]
        let rows: [(String, String)] = [
            ("Installed", store.installed[app.id].map { "v\($0.version) · \($0.url.deletingLastPathComponent().path)" } ?? "Not installed"),
            ("Latest release", release.map { "v\($0.version)" + ($0.publishedAt.map { " · " + $0.formatted(date: .abbreviated, time: .omitted) } ?? "") }
                ?? (store.releaseErrors[app.id] ?? "Unknown")),
            ("Download", release?.installAsset.map { "\($0.name) · \(ByteCountFormatter.string(fromByteCount: Int64($0.size), countStyle: .file))" } ?? "—"),
            ("Repository", "github.com/\(store.catalog.owner)/\(app.repo)"),
        ]
        return Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 8) {
            ForEach(rows, id: \.0) { row in
                GridRow {
                    Text(row.0).foregroundStyle(Theme.tertiary)
                    Text(row.1).foregroundStyle(.white.opacity(0.85)).textSelection(.enabled)
                }
            }
        }
        .font(.system(size: 12.5))
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.border))
    }
}

// MARK: - Settings

struct SettingsView: View {
    @EnvironmentObject var store: SuiteStore
    @AppStorage("installLocation") private var installLocation = SuiteStore.InstallLocation.applications.rawValue
    @AppStorage("checkOnLaunch") private var checkOnLaunch = true
    @AppStorage(GlassTheme.key) private var glassTheme = false
    @State private var token = TokenStore.load() ?? ""

    var body: some View {
        Form {
            Picker("Install tools in", selection: $installLocation) {
                ForEach(SuiteStore.InstallLocation.allCases) { Text($0.title).tag($0.rawValue) }
            }
            Toggle("Check for updates when Workbench opens", isOn: $checkOnLaunch)
            Section {
                Toggle(isOn: $glassTheme) {
                    Text("Liquid Glass theme")
                    Text(GlassTheme.supported ? "Tool cards, the welcome panel and buttons use Apple's Liquid Glass."
                                              : "Requires macOS 26.")
                }
                .disabled(!GlassTheme.supported)
            } header: { Text("Appearance") }
            Section {
                SecureField("Personal access token (optional)", text: $token)
                    .onSubmit { TokenStore.save(token) }
                HStack {
                    Text("Only needed for private repos or to avoid GitHub's hourly limit. Stored in your keychain.")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Save") { TokenStore.save(token); Task { await store.refresh() } }
                }
            } header: { Text("GitHub") }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .padding(.vertical, 8)
    }
}


/// Shown in place of the Update All button while the queue runs: "Updating 2 of 3…".
struct QueueStatus: View {
    let done: Int
    let total: Int
    var body: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text("Updating \(min(done + 1, total)) of \(total)…")
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(Theme.amber)
                .monospacedDigit()
        }
        .padding(.horizontal, 12).frame(height: 30)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Updating \(min(done + 1, total)) of \(total)")
    }
}


/// Shown while GitHub's API limit is used up: results are the saved ones, updates still work.
struct RateLimitNote: View {
    let until: Date
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "clock.arrow.circlepath").foregroundStyle(Theme.amber)
            Text("Showing saved results. GitHub's hourly check limit resets at \(until.formatted(date: .omitted, time: .shortened)); new versions are still detected from the website. Add a token in Settings to raise the limit.")
                .font(.system(size: 12)).foregroundStyle(Theme.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.04)))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.white.opacity(0.08)))
    }
}
