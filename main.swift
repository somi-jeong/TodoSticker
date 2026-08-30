import SwiftUI
import AppKit

// MARK: - Model

struct Todo: Identifiable, Codable, Equatable {
    var id = UUID()
    var text: String
    var done: Bool = false
}

final class TodoStore: ObservableObject {
    @Published var todos: [Todo] = [] {
        didSet { save() }
    }

    private let fileURL: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TodoSticker", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("todos.json")
    }()

    init() {
        if let data = try? Data(contentsOf: fileURL),
           let list = try? JSONDecoder().decode([Todo].self, from: data) {
            todos = list
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(todos) {
            try? data.write(to: fileURL, options: .atomic)
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
            } label: {
                Image(systemName: todo.done ? "checkmark.square.fill" : "square")
                    .font(.system(size: 15))
                    .foregroundColor(todo.done ? .secondary : .primary)
            }
            .buttonStyle(.plain)

            TextField("", text: $todo.text)
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

    var body: some View {
        VStack(spacing: 0) {
            // Title bar (drag area)
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
                            store.todos.removeAll { $0.id == todo.id }
                        }
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets(top: 1, leading: 10, bottom: 1, trailing: 8))
                    }
                    .onMove { indices, dest in
                        store.todos.move(fromOffsets: indices, toOffset: dest)
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
    let store = TodoStore()

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "checklist", accessibilityDescription: "Todo")
            button.action = #selector(statusClicked)
            button.target = self
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        makePanel()
        panel.orderFrontRegardless()
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

        panel.contentView = NSHostingView(rootView: StickyView(store: store))
    }

    @objc func statusClicked() {
        if let event = NSApp.currentEvent, event.type == .rightMouseUp {
            let menu = NSMenu()
            menu.addItem(withTitle: panel.isVisible ? "위젯 숨기기" : "위젯 보이기",
                         action: #selector(togglePanel), keyEquivalent: "")
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
