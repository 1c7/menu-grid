import AppKit
import SwiftUI
import ApplicationServices

func value(_ element: AXUIElement, _ key: String) -> CFTypeRef? {
    var result: CFTypeRef?
    AXUIElementCopyAttributeValue(element, key as CFString, &result)
    return result
}
func textValue(_ element: AXUIElement, _ key: String) -> String {
    (value(element, key) as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
}
struct MenuEntry: Identifiable {
    let id: String
    let name: String
    let image: NSImage
    let element: AXUIElement
    let sourceElement: AXUIElement
    let app: NSRunningApplication
}
final class MenuStore: ObservableObject {
    @Published var entries: [MenuEntry] = []
    @Published var trusted = AXIsProcessTrusted()
    @Published var refreshing = false
    @Published var message = ""
    @Published var search = ""
    var filtered: [MenuEntry] { search.isEmpty ? entries : entries.filter { $0.name.localizedCaseInsensitiveContains(search) } }
    func refresh() {
        trusted = AXIsProcessTrusted()
        guard trusted, !refreshing else { return }
        refreshing = true
        DispatchQueue.global(qos: .userInitiated).async {
            var found: [MenuEntry] = []
            // macOS 27 hosts third-party status buttons in MenuBarAgent.
            // Prefer its live proxy where a unique accessible label identifies it.
            var proxies: [(AXUIElement, [String])] = []
            if let agent = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == "com.apple.MenuBarAgent" }) {
                let root = AXUIElementCreateApplication(agent.processIdentifier)
                AXUIElementSetMessagingTimeout(root, 0.18)
                func gather(_ element: AXUIElement, _ depth: Int) {
                    guard depth < 6 else { return }
                    let role = textValue(element, kAXRoleAttribute)
                    if role == kAXButtonRole || role == kAXMenuBarItemRole {
                        let labels = [kAXDescriptionAttribute, kAXTitleAttribute, kAXHelpAttribute].map { textValue(element, $0) }.filter { !$0.isEmpty }
                        proxies.append((element, labels))
                        return
                    }
                    for child in value(element, kAXChildrenAttribute) as? [AXUIElement] ?? [] { gather(child, depth + 1) }
                }
                gather(root, 0)
            }
            for app in NSWorkspace.shared.runningApplications where app.processIdentifier != ProcessInfo.processInfo.processIdentifier {
                let root = AXUIElementCreateApplication(app.processIdentifier)
                AXUIElementSetMessagingTimeout(root, 0.18)
                guard let raw = value(root, kAXExtrasMenuBarAttribute) else { continue }
                let bar = raw as! AXUIElement
                var elements: [AXUIElement] = []
                func walk(_ element: AXUIElement, depth: Int) {
                    guard depth < 4 else { return }
                    if textValue(element, kAXRoleAttribute) == kAXMenuBarItemRole { elements.append(element); return }
                    for child in value(element, kAXChildrenAttribute) as? [AXUIElement] ?? [] { walk(child, depth: depth + 1) }
                }
                walk(bar, depth: 0)
                for (index, element) in elements.enumerated() {
                    let desc = textValue(element, kAXDescriptionAttribute)
                    let title = textValue(element, kAXTitleAttribute)
                    let identifier = textValue(element, kAXIdentifierAttribute)
                    let appName = app.localizedName ?? "菜单项"
                    let name: String
                    if !desc.isEmpty { name = desc }
                    else if elements.count > 1 { name = "\(appName) \(index + 1)" + (title.isEmpty ? "" : " · \(title)") }
                    else { name = appName }
                    let symbols: [(String,String)] = [("wifi","wifi"),("sound","speaker.wave.2"),("battery","battery.100"),("clock","clock"),("controlcenter","switch.2"),("spotlight","magnifyingglass")]
                    let symbol = symbols.first { identifier.lowercased().contains($0.0) }?.1
                    let image = symbol.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: name) } ?? app.icon ?? NSImage(systemSymbolName: "app.dashed", accessibilityDescription: name)!
                    let candidates = proxies.filter { proxy in proxy.1.contains { label in
                        label == name || (!desc.isEmpty && label == desc) || (elements.count == 1 && (label == appName || label.hasPrefix(appName + "\n") || label.hasPrefix(appName + " ")))
                    } }
                    let liveElement = candidates.count == 1 ? candidates[0].0 : element
                    found.append(MenuEntry(id: "\(app.processIdentifier)-\(index)", name: name, image: image, element: liveElement, sourceElement: element, app: app))
                }
            }
            let result = found.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            DispatchQueue.main.async { self.entries = result; self.refreshing = false; if AppDelegate.shared.panel?.isVisible == true { AppDelegate.shared.resizeToContent() } }
        }
    }
    func open(_ entry: MenuEntry) {
        message = ""
        AppDelegate.shared.hide()
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.15) {
            func visibleMenu(_ element: AXUIElement, depth: Int = 0) -> Bool {
                guard depth < 3 else { return false }
                if textValue(element, kAXRoleAttribute) == kAXMenuRole,
                   let raw = value(element, kAXSizeAttribute), CFGetTypeID(raw) == AXValueGetTypeID() {
                    var size = CGSize.zero
                    AXValueGetValue(raw as! AXValue, .cgSize, &size)
                    if size.width > 0 && size.height > 0 { return true }
                }
                return (value(element, kAXChildrenAttribute) as? [AXUIElement] ?? []).contains { visibleMenu($0, depth: depth + 1) }
            }
            func windows() -> Set<Int> {
                let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
                return Set(list.filter { ($0[kCGWindowOwnerPID as String] as? Int32) == entry.app.processIdentifier }.compactMap { $0[kCGWindowNumber as String] as? Int })
            }
            let before = windows()
            // Menu-tracking callbacks can block AXPress until timeout even after the
            // menu opens. A timeout must NEVER trigger a second press or steal focus.
            AXUIElementSetMessagingTimeout(entry.element, 0.25)
            AXUIElementSetMessagingTimeout(entry.sourceElement, 0.15)
            let result = AXUIElementPerformAction(entry.element, kAXPressAction as CFString)
            var observed = false
            for _ in 0..<12 {
                if visibleMenu(entry.sourceElement) || !windows().subtracting(before).isEmpty { observed = true; break }
                Thread.sleep(forTimeInterval: 0.04)
            }
            if ProcessInfo.processInfo.environment["MENU_GRID_DIAGNOSTICS"] == "1" {
                FileHandle.standardError.write(Data("MenuGrid action result=\(result.rawValue) observed=\(observed)\n".utf8))
            }
            if observed || result == .success { return }
            // Only an explicit unsupported-action response permits another action.
            // CannotComplete is ambiguous: leave the target's menu undisturbed.
            if result == .actionUnsupported {
                let fallback = AXUIElementPerformAction(entry.element, kAXShowMenuAction as CFString)
                if fallback == .success || fallback == .cannotComplete { return }
            }
            DispatchQueue.main.async {
                self.message = result == .cannotComplete
                    ? "未能确认 \(entry.name) 的菜单是否打开，请重试。"
                    : "\(entry.name) 打开失败，请刷新后重试（\(result.rawValue)）"
                // Display this only on the next user-initiated opening. Bringing
                // our panel forward here would dismiss a slow native menu.
            }
        }
    }
}
struct Tile: View {
    let entry: MenuEntry
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            VStack(spacing: 7) {
                Image(nsImage: entry.image).resizable().scaledToFit().frame(width: 27, height: 27)
                Text(entry.name).font(.system(size: 10)).lineLimit(1).truncationMode(.tail).foregroundStyle(.primary)
            }
            .frame(width: 61, height: 66)
            .background(hover ? Color.primary.opacity(0.09) : Color.clear, in: RoundedRectangle(cornerRadius: 10))
            .contentShape(Rectangle())
        }.buttonStyle(.plain).help(entry.name).onHover { hover = $0 }
        .accessibilityLabel(entry.name)
    }
}
struct Panel: View {
    @ObservedObject var store: MenuStore
    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Text("菜单栏").font(.system(size: 15, weight: .semibold))
                Text("\(store.entries.count)").font(.system(size: 12)).foregroundStyle(.secondary)
                Spacer()
                if store.refreshing { ProgressView().controlSize(.small) }
                Button { store.refresh() } label: { Image(systemName: "arrow.clockwise") }.buttonStyle(.plain).help("刷新")
                Menu {
                    Button("辅助功能权限") { AppDelegate.shared.permissions() }
                    Divider()
                    Button("退出菜单栏面板") { NSApp.terminate(nil) }
                } label: { Image(systemName: "ellipsis.circle") }.menuStyle(.borderlessButton).frame(width: 22)
            }
            if !store.trusted {
                VStack(spacing: 12) {
                    Text("允许辅助功能访问后，才能读取和打开菜单栏图标。")
                    Button("打开辅助功能设置") { AppDelegate.shared.permissions() }
                    Button("已允许，重新读取") { store.refresh() }
                }.frame(maxWidth: .infinity, minHeight: 130)
            } else {
                TextField("搜索图标", text: $store.search).textFieldStyle(.roundedBorder)
                if store.filtered.isEmpty && !store.refreshing {
                    Text(store.search.isEmpty ? "没有读取到菜单栏图标，点刷新重试。" : "没有匹配的图标").foregroundStyle(.secondary).frame(height: 90)
                } else {
                    ScrollView {
                        LazyVGrid(columns: Array(repeating: GridItem(.fixed(61), spacing: 6), count: 10), alignment: .leading, spacing: 5) {
                            ForEach(store.filtered) { entry in Tile(entry: entry) { store.open(entry) } }
                        }.padding(.vertical, 2)
                    }.frame(height: min(440, CGFloat(max(1, (store.filtered.count + 9) / 10)) * 71 + 4))
                }
                if !store.message.isEmpty { Text(store.message).font(.caption).foregroundStyle(.secondary) }
            }
        }.padding(16).frame(width: 696)
    }
}
final class AppDelegate: NSObject, NSApplicationDelegate {
    static let shared = AppDelegate()
    let store = MenuStore()
    var panel: NSPanel!
    var outsideMonitor: Any?
    var item: NSStatusItem!
    var permissionTimer: Timer?
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "square.grid.3x3.fill", accessibilityDescription: "菜单栏面板")
        item.button?.toolTip = "菜单栏面板 · 点击向下展开"
        item.button?.target = self
        item.button?.action = #selector(toggle)
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 696, height: 260), styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = "菜单栏面板"
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.isFloatingPanel = true
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        let background = NSVisualEffectView()
        background.material = .popover
        background.state = .active
        background.blendingMode = .behindWindow
        panel.contentView = background
        let host = NSHostingView(rootView: Panel(store: store))
        host.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(host)
        NSLayoutConstraint.activate([host.leadingAnchor.constraint(equalTo: background.leadingAnchor), host.trailingAnchor.constraint(equalTo: background.trailingAnchor), host.topAnchor.constraint(equalTo: background.topAnchor), host.bottomAnchor.constraint(equalTo: background.bottomAnchor)])
        outsideMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 { self?.hide(); return nil }
            return event
        }
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            guard let self else { return }
            if self.store.trusted != AXIsProcessTrusted() { self.store.refresh() }
        }
        store.refresh()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.show() }
    }
    @objc func toggle() { if panel.isVisible { hide() } else { show() } }
    func hide() { panel.orderOut(nil) }
    func show() {
        store.refresh()
        guard let screen = item.button?.window?.screen ?? NSScreen.main else { return }
        let width: CGFloat = min(696, screen.visibleFrame.width - 24)
        let height: CGFloat = store.trusted ? min(570, CGFloat(max(1, (store.entries.count + 9) / 10)) * 71 + 112) : 240
        var x = screen.visibleFrame.maxX - width - 12
        var top = screen.visibleFrame.maxY - 7
        if let button = item.button, let window = button.window, window.isVisible {
            let anchor = window.convertToScreen(button.convert(button.bounds, to: nil))
            if screen.frame.contains(anchor.centerPoint) {
                x = min(screen.visibleFrame.maxX - width - 12, max(screen.visibleFrame.minX + 12, anchor.midX - width / 2))
                top = anchor.minY - 7
            }
        }
        panel.setFrame(NSRect(x: x, y: top - height, width: width, height: height), display: true)
        panel.orderFrontRegardless()
        panel.makeKey()
    }
    func resizeToContent() {
        guard let screen = panel.screen else { return }
        let height = min(screen.visibleFrame.height - 30, min(570, CGFloat(max(1, (store.filtered.count + 9) / 10)) * 71 + 112))
        var frame = panel.frame
        let top = frame.maxY
        frame.size.height = height
        frame.origin.y = top - height
        panel.setFrame(frame, display: true)
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { show(); return true }
    func permissions() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }
}
extension NSRect { var centerPoint: NSPoint { NSPoint(x: midX, y: midY) } }
let app = NSApplication.shared
app.delegate = AppDelegate.shared
app.run()
