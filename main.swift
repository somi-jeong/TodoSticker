import SwiftUI
import AppKit

// MARK: - Model

struct Todo: Identifiable, Equatable {
    var id = UUID()
    var text: String
    var done: Bool = false
    var blockId: String? = nil   // 노션 블록 ID (nil = 아직 노션에 없음)
    var dirty: Bool = false      // 노션에 밀어야 할 변경 있음
    var lastEditAt: Date? = nil  // 타이핑 중 원격 덮어쓰기 방지용
}

extension Todo: Codable {
    enum CodingKeys: String, CodingKey { case id, text, done, blockId, dirty }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        text = try c.decode(String.self, forKey: .text)
        done = try c.decodeIfPresent(Bool.self, forKey: .done) ?? false
        blockId = try c.decodeIfPresent(String.self, forKey: .blockId)
        dirty = try c.decodeIfPresent(Bool.self, forKey: .dirty) ?? false
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(text, forKey: .text)
        try c.encode(done, forKey: .done)
        try c.encodeIfPresent(blockId, forKey: .blockId)
        try c.encode(dirty, forKey: .dirty)
    }
}

struct StoreFile: Codable {
    var todos: [Todo] = []
    var deletedBlockIds: [String] = []
    var orderDirty: Bool = false
    var pageId: String? = nil
    var pageDateKey: String? = nil
}

final class TodoStore: ObservableObject {
    @Published var todos: [Todo] = [] { didSet { save() } }
    var deletedBlockIds: [String] = [] { didSet { save() } }
    var orderDirty: Bool = false { didSet { save() } }
    var pageId: String? = nil { didSet { save() } }
    var pageDateKey: String? = nil { didSet { save() } }

    private var loading = true

    private let fileURL: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TodoSticker", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("todos.json")
    }()

    init() {
        if let data = try? Data(contentsOf: fileURL) {
            if let f = try? JSONDecoder().decode(StoreFile.self, from: data) {
                todos = f.todos
                deletedBlockIds = f.deletedBlockIds
                orderDirty = f.orderDirty
                pageId = f.pageId
                pageDateKey = f.pageDateKey
            } else if let legacy = try? JSONDecoder().decode([Todo].self, from: data) {
                todos = legacy
            }
        }
        loading = false
    }

    private func save() {
        guard !loading else { return }
        let f = StoreFile(todos: todos, deletedBlockIds: deletedBlockIds,
                          orderDirty: orderDirty, pageId: pageId, pageDateKey: pageDateKey)
        if let data = try? JSONEncoder().encode(f) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }
}

// MARK: - Notion API

struct NotionConfig: Codable {
    var token: String
    var databaseId: String

    static func load() -> NotionConfig? {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TodoSticker/notion.json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(NotionConfig.self, from: data)
    }
}

struct RemoteTodo {
    var blockId: String
    var text: String
    var checked: Bool
}

struct NotionError: Error {
    var status: Int
    var message: String
}

final class NotionAPI {
    let token: String
    let dbId: String

    init(config: NotionConfig) {
        token = config.token
        dbId = config.databaseId
    }

    @discardableResult
    func request(_ method: String, _ path: String, body: [String: Any]? = nil) async throws -> [String: Any] {
        var req = URLRequest(url: URL(string: "https://api.notion.com/v1/" + path)!)
        req.httpMethod = method
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("2022-06-28", forHTTPHeaderField: "Notion-Version")
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, resp) = try await URLSession.shared.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? -1
        guard (200..<300).contains(status) else {
            throw NotionError(status: status, message: String(data: data, encoding: .utf8) ?? "")
        }
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    static func richText(_ s: String) -> [[String: Any]] {
        [["type": "text", "text": ["content": s]]]
    }

    static func todoBlock(_ text: String, checked: Bool) -> [String: Any] {
        ["object": "block", "type": "to_do",
         "to_do": ["rich_text": richText(text), "checked": checked]]
    }

    private static func pageTitle(_ page: [String: Any]) -> String {
        for p in (page["properties"] as? [String: [String: Any]] ?? [:]).values {
            if p["type"] as? String == "title" {
                return ((p["title"] as? [[String: Any]]) ?? [])
                    .compactMap { $0["plain_text"] as? String }.joined()
            }
        }
        return ""
    }

    // 같은 날짜에 페이지가 여러 개면 "해야할일" 제목이 붙은 쪽을 우선
    private static func pickTodoPage(_ results: [[String: Any]]) -> String? {
        if let match = results.first(where: { pageTitle($0).contains("해야할일") }) {
            return match["id"] as? String
        }
        return results.first?["id"] as? String
    }

    func findPage(dateKey: String) async throws -> String? {
        let res = try await request("POST", "databases/\(dbId)/query", body: [
            "filter": ["property": "날짜", "date": ["equals": dateKey]],
            "page_size": 10
        ])
        return Self.pickTodoPage(res["results"] as? [[String: Any]] ?? [])
    }

    func findLatestPageBefore(dateKey: String) async throws -> String? {
        let res = try await request("POST", "databases/\(dbId)/query", body: [
            "filter": ["property": "날짜", "date": ["before": dateKey]],
            "sorts": [["property": "날짜", "direction": "descending"]],
            "page_size": 10
        ])
        return Self.pickTodoPage(res["results"] as? [[String: Any]] ?? [])
    }

    func createPage(dateKey: String) async throws -> String {
        let compact = dateKey.replacingOccurrences(of: "-", with: "")
        let res = try await request("POST", "pages", body: [
            "parent": ["database_id": dbId],
            "properties": [
                "제목": ["title": Self.richText("\(compact) 해야할일")],
                "날짜": ["date": ["start": dateKey]]
            ]
        ])
        guard let id = res["id"] as? String else {
            throw NotionError(status: -1, message: "page create failed")
        }
        return id
    }

    func fetchTodos(pageId: String) async throws -> [RemoteTodo] {
        var out: [RemoteTodo] = []
        var cursor: String? = nil
        repeat {
            var path = "blocks/\(pageId)/children?page_size=100"
            if let cursor { path += "&start_cursor=\(cursor)" }
            let res = try await request("GET", path)
            for b in res["results"] as? [[String: Any]] ?? [] {
                guard b["type"] as? String == "to_do",
                      let td = b["to_do"] as? [String: Any],
                      let id = b["id"] as? String else { continue }
                let text = ((td["rich_text"] as? [[String: Any]]) ?? [])
                    .compactMap { $0["plain_text"] as? String }.joined()
                out.append(RemoteTodo(blockId: id, text: text, checked: td["checked"] as? Bool ?? false))
            }
            cursor = (res["has_more"] as? Bool == true) ? res["next_cursor"] as? String : nil
        } while cursor != nil
        return out
    }

    // returns created block ids in order
    func appendTodos(pageId: String, items: [(text: String, checked: Bool)]) async throws -> [String] {
        guard !items.isEmpty else { return [] }
        var ids: [String] = []
        // Notion caps children at 100 per call
        for chunk in stride(from: 0, to: items.count, by: 100).map({ Array(items[$0..<min($0+100, items.count)]) }) {
            let res = try await request("PATCH", "blocks/\(pageId)/children", body: [
                "children": chunk.map { Self.todoBlock($0.text, checked: $0.checked) }
            ])
            ids += (res["results"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String }
        }
        return ids
    }

    func updateTodo(blockId: String, text: String, checked: Bool) async throws {
        try await request("PATCH", "blocks/\(blockId)", body: [
            "to_do": ["rich_text": Self.richText(text), "checked": checked]
        ])
    }

    func deleteBlock(blockId: String) async throws {
        try await request("DELETE", "blocks/\(blockId)")
    }
}

// MARK: - Sync Engine

@MainActor
final class SyncEngine: ObservableObject {
    enum State: Equatable {
        case off, ok, error(String)
    }
    @Published var state: State = .off
    @Published var lastSyncAt: Date? = nil

    private let store: TodoStore
    private let api: NotionAPI?
    private var syncing = false
    private var lastPullAt = Date.distantPast

    init(store: TodoStore) {
        self.store = store
        if let config = NotionConfig.load() {
            api = NotionAPI(config: config)
        } else {
            api = nil
        }
    }

    private static func dayKey(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }

    func tick(forcePull: Bool = false) async {
        guard let api, !syncing else { return }
        syncing = true
        defer { syncing = false }

        do {
            // 1. 날짜 넘어감 처리: 어제 항목은 로컬에서 비우고 오늘 페이지로 전환
            let todayKey = Self.dayKey(Date())
            if store.pageDateKey != todayKey {
                store.pageDateKey = todayKey
                store.pageId = nil
                store.todos.removeAll { $0.blockId != nil }
                store.orderDirty = false
                lastPullAt = .distantPast
            }

            // 2. 오늘 페이지 확보 (없으면 생성 + 직전 날짜에서 미완료 이월)
            if store.pageId == nil {
                if let found = try await api.findPage(dateKey: todayKey) {
                    store.pageId = found
                } else {
                    var carried: [(text: String, checked: Bool)] = []
                    if let prev = try await api.findLatestPageBefore(dateKey: todayKey) {
                        carried = try await api.fetchTodos(pageId: prev)
                            .filter { !$0.checked }
                            .map { ($0.text, false) }
                    }
                    let newPage = try await api.createPage(dateKey: todayKey)
                    _ = try await api.appendTodos(pageId: newPage, items: carried)
                    store.pageId = newPage
                }
            }
            guard let pageId = store.pageId else { return }

            // 3. 삭제 밀기
            for blockId in store.deletedBlockIds {
                do { try await api.deleteBlock(blockId: blockId) }
                catch let e as NotionError where e.status == 404 { /* 이미 없음 */ }
                store.deletedBlockIds.removeAll { $0 == blockId }
            }

            // 4. 순서 변경 밀기: 새 순서로 전부 다시 만들고 옛 블록 삭제
            if store.orderDirty {
                let items = store.todos
                let newIds = try await api.appendTodos(pageId: pageId,
                                                       items: items.map { ($0.text, $0.done) })
                if newIds.count == items.count {
                    let oldIds = items.compactMap { $0.blockId }
                    var updated = items
                    for i in updated.indices {
                        updated[i].blockId = newIds[i]
                        updated[i].dirty = false
                    }
                    store.todos = updated
                    store.orderDirty = false
                    store.deletedBlockIds += oldIds
                    for blockId in store.deletedBlockIds {
                        do { try await api.deleteBlock(blockId: blockId) }
                        catch let e as NotionError where e.status == 404 {}
                        store.deletedBlockIds.removeAll { $0 == blockId }
                    }
                }
            } else {
                // 5. 수정(텍스트/체크) 밀기
                for todo in store.todos where todo.dirty && todo.blockId != nil {
                    do {
                        try await api.updateTodo(blockId: todo.blockId!, text: todo.text, checked: todo.done)
                        if let i = store.todos.firstIndex(where: { $0.id == todo.id }) {
                            store.todos[i].dirty = false
                        }
                    } catch let e as NotionError where e.status == 404 {
                        store.todos.removeAll { $0.id == todo.id }
                    }
                }
                // 6. 새 항목 밀기
                let pending = store.todos.filter { $0.blockId == nil }
                if !pending.isEmpty {
                    let newIds = try await api.appendTodos(pageId: pageId,
                                                          items: pending.map { ($0.text, $0.done) })
                    if newIds.count == pending.count {
                        for (offset, todo) in pending.enumerated() {
                            if let i = store.todos.firstIndex(where: { $0.id == todo.id }) {
                                store.todos[i].blockId = newIds[offset]
                                store.todos[i].dirty = false
                            }
                        }
                    }
                }
            }

            // 7. 노션 → 위젯 당겨오기 (30초 간격, 타이핑 중엔 건너뜀)
            let typing = store.todos.contains {
                Date().timeIntervalSince($0.lastEditAt ?? .distantPast) < 3
            }
            if (forcePull || Date().timeIntervalSince(lastPullAt) > 28) && !typing && !store.orderDirty {
                let remote = try await api.fetchTodos(pageId: pageId)
                lastPullAt = Date()
                var merged: [Todo] = []
                let deletedSet = Set(store.deletedBlockIds)
                for r in remote {
                    if deletedSet.contains(r.blockId) { continue }
                    if var local = store.todos.first(where: { $0.blockId == r.blockId }) {
                        if !local.dirty {
                            local.text = r.text
                            local.done = r.checked
                        }
                        merged.append(local)
                    } else {
                        merged.append(Todo(text: r.text, done: r.checked, blockId: r.blockId))
                    }
                }
                merged += store.todos.filter { $0.blockId == nil }
                if merged != store.todos {
                    store.todos = merged
                }
            }

            state = .ok
            lastSyncAt = Date()
        } catch {
            state = .error("\(error)")
        }
    }
}

// MARK: - Views

struct TodoRow: View {
    @Binding var todo: Todo
    var onDelete: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            Button {
                todo.done.toggle()
                todo.dirty = true
            } label: {
                Image(systemName: todo.done ? "checkmark.square.fill" : "square")
                    .font(.system(size: 15))
                    .foregroundColor(todo.done ? .secondary : .primary)
            }
            .buttonStyle(.plain)

            TextField("", text: Binding(
                get: { todo.text },
                set: {
                    todo.text = $0
                    todo.dirty = true
                    todo.lastEditAt = Date()
                }
            ))
            .textFieldStyle(.plain)
            .font(.system(size: 13))
            .strikethrough(todo.done)
            .foregroundColor(todo.done ? .secondary : .primary)

            if hovering {
                Button(action: onDelete) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }

            Image(systemName: "line.3.horizontal")
                .font(.system(size: 10))
                .foregroundColor(.secondary.opacity(hovering ? 0.7 : 0.25))
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }
}

struct StickyView: View {
    @ObservedObject var store: TodoStore
    @ObservedObject var sync: SyncEngine
    @State private var newText = ""
    @State private var today = Date()
    @FocusState private var inputFocused: Bool

    private static let titleFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ko_KR")
        f.dateFormat = "yyyy.MM.dd (E) 할 일"
        return f
    }()

    private let minuteTimer = Timer.publish(every: 60, on: .main, in: .common).autoconnect()

    private let paper = Color(red: 1.0, green: 0.96, blue: 0.72)
    private let paperDark = Color(red: 0.98, green: 0.90, blue: 0.45)

    @ViewBuilder
    private var syncBadge: some View {
        switch sync.state {
        case .off:
            EmptyView()
        case .ok:
            Image(systemName: "checkmark.icloud")
                .font(.system(size: 10))
                .foregroundColor(.black.opacity(0.35))
                .help(sync.lastSyncAt.map { "노션 동기화됨 \(Self.timeString($0))" } ?? "노션 동기화됨")
        case .error(let msg):
            Image(systemName: "exclamationmark.icloud")
                .font(.system(size: 10))
                .foregroundColor(.orange)
                .help("노션 동기화 오류: \(msg)")
        }
    }

    private static func timeString(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f.string(from: d)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "pin.fill")
                    .font(.system(size: 10))
                    .foregroundColor(.orange.opacity(0.7))
                Text(Self.titleFormatter.string(from: today))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.black.opacity(0.6))
                    .onReceive(minuteTimer) { now in
                        if !Calendar.current.isDate(now, inSameDayAs: today) {
                            today = now
                        }
                    }
                Spacer()
                syncBadge
                if !store.todos.isEmpty {
                    Text("\(store.todos.filter { !$0.done }.count)/\(store.todos.count)")
                        .font(.system(size: 10))
                        .foregroundColor(.black.opacity(0.4))
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 6)

            if store.todos.isEmpty {
                Spacer()
                Text("아래에 할 일을 입력하세요")
                    .font(.system(size: 11))
                    .foregroundColor(.black.opacity(0.35))
                Spacer()
            } else {
                List {
                    ForEach($store.todos) { $todo in
                        TodoRow(todo: $todo) {
                            if let blockId = todo.blockId {
                                store.deletedBlockIds.append(blockId)
                            }
                            store.todos.removeAll { $0.id == todo.id }
                        }
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets(top: 1, leading: 10, bottom: 1, trailing: 8))
                    }
                    .onMove { indices, dest in
                        store.todos.move(fromOffsets: indices, toOffset: dest)
                        store.orderDirty = true
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }

            Divider().opacity(0.3)

            HStack(spacing: 6) {
                Image(systemName: "plus")
                    .font(.system(size: 11))
                    .foregroundColor(.black.opacity(0.4))
                TextField("추가하고 Enter", text: $newText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .focused($inputFocused)
                    .onSubmit {
                        let text = newText.trimmingCharacters(in: .whitespaces)
                        guard !text.isEmpty else { return }
                        store.todos.append(Todo(text: text))
                        newText = ""
                        inputFocused = true
                    }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
        }
        .frame(minWidth: 200, minHeight: 160)
        .background(
            LinearGradient(colors: [paper, paperDark],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
        )
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.black.opacity(0.1), lineWidth: 0.5)
        )
        .preferredColorScheme(.light)
    }
}

// MARK: - Panel

final class StickyPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

// MARK: - App Delegate

final class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    var panel: StickyPanel!
    var syncTimer: Timer?
    let store = TodoStore()
    var engine: SyncEngine!

    func applicationDidFinishLaunching(_ notification: Notification) {
        engine = SyncEngine(store: store)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "checklist", accessibilityDescription: "Todo")
            button.action = #selector(statusClicked)
            button.target = self
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        makePanel()
        panel.orderFrontRegardless()

        syncTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in await self.engine.tick() }
        }
        Task { @MainActor in await self.engine.tick(forcePull: true) }
    }

    private func makePanel() {
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let size = NSSize(width: 240, height: 320)
        let origin = NSPoint(x: screen.maxX - size.width - 24,
                             y: screen.maxY - size.height - 24)

        panel = StickyPanel(
            contentRect: NSRect(origin: origin, size: size),
            styleMask: [.borderless, .nonactivatingPanel, .resizable],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.minSize = NSSize(width: 200, height: 160)
        panel.setFrameAutosaveName("TodoStickerPanel")

        panel.contentView = NSHostingView(rootView: StickyView(store: store, sync: engine))
    }

    @objc func statusClicked() {
        if let event = NSApp.currentEvent, event.type == .rightMouseUp {
            let menu = NSMenu()
            menu.addItem(withTitle: panel.isVisible ? "위젯 숨기기" : "위젯 보이기",
                         action: #selector(togglePanel), keyEquivalent: "")
            menu.addItem(withTitle: "지금 동기화", action: #selector(syncNow), keyEquivalent: "")
            menu.addItem(.separator())
            menu.addItem(withTitle: "종료", action: #selector(quit), keyEquivalent: "q")
            for item in menu.items { item.target = self }
            statusItem.menu = menu
            statusItem.button?.performClick(nil)
            statusItem.menu = nil
        } else {
            togglePanel()
        }
    }

    @objc func togglePanel() {
        if panel.isVisible {
            panel.orderOut(nil)
        } else {
            panel.orderFrontRegardless()
        }
    }

    @objc func syncNow() {
        Task { @MainActor in await self.engine.tick(forcePull: true) }
    }

    @objc func quit() {
        NSApp.terminate(nil)
    }
}

// MARK: - Entry point

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
