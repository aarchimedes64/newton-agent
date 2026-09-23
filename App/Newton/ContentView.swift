import SwiftUI
import NewtonCore
import MessageUI

struct ContentView: View {
    @Bindable var model: AppModel
    @State private var draft = ""
    @State private var settingsPresented = false
    @State private var notesPresented = false
    @State private var statsPresented = false
    @State private var renameID: UUID?
    @State private var renameText = ""
    @State private var speech = SpeechTranscriber()
    @State private var dictationPrefix = ""
    @State private var composerFieldHeight: CGFloat = 0
    @State private var composerSingleLineHeight: CGFloat = 0
    /// The field reports its smallest ever height (an empty/short draft) as the one-line
    /// baseline. Buttons center on that; a taller (wrapped) field keeps them bottom-pinned.
    private var composerIsSingleLine: Bool {
        composerFieldHeight > 0 && composerFieldHeight <= composerSingleLineHeight + 1
    }
    @Environment(\.scenePhase) private var phase
    var body: some View {
        NavigationSplitView {
            List(selection: $model.selection) {
                Section {
                    ForEach(model.conversations.sorted { $0.updatedAt > $1.updatedAt }) { chat in
                        VStack(alignment: .leading, spacing: 5) {
                            Text(chat.title).lineLimit(1).font(.headline)
                            Text(chat.updatedAt, style: .date).font(.caption).foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 4).tag(chat.id)
                        .contextMenu {
                            Button("Rename", systemImage: "pencil") { renameID = chat.id; renameText = chat.title }
                            Button("Delete chat", systemImage: "trash", role: .destructive) { model.deleteChat(chat.id) }
                        }
                        .swipeActions { Button("Delete", role: .destructive) { model.deleteChat(chat.id) } }
                    }
                } header: { Text("Your conversations") }
            }
            .disabled(model.isRunning || !model.storageReady)
            .navigationTitle("Newton")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("New chat", systemImage: "square.and.pencil") { model.newChat() }.disabled(model.isRunning || !model.storageReady)
                }
                ToolbarItemGroup(placement: .bottomBar) {
                    Button("Notes", systemImage: "note.text") { notesPresented = true }
                    Spacer()
                    Button("Settings", systemImage: "gearshape") { settingsPresented = true }
                }
            }
        } detail: {
            VStack(spacing: 0) {
                HStack(spacing: 6) {
                    Image(systemName: model.settings.provider == .local ? "iphone" : "network")
                    Text(model.settings.provider == .local ? "On-device model" : "API · \(URL(string: model.settings.baseURL)?.host ?? "Not configured")")
                        .lineLimit(1)
                    Spacer()
                    Button("Configure", systemImage: "slider.horizontal.3") { settingsPresented = true }.labelStyle(.iconOnly)
                }
                .font(.caption).foregroundStyle(.secondary).padding(.horizontal).padding(.vertical, 10)
                Divider()
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 20) {
                            if model.selectedChat?.messages.isEmpty != false { welcome }
                            ForEach(model.selectedChat?.messages ?? []) { message in MessageRow(message: message) }
                            if model.isRunning {
                                if let streamed = model.streamedText, !streamed.isEmpty {
                                    Text(streamed + "▍").textSelection(.enabled)
                                        .padding(16).frame(maxWidth: .infinity, alignment: .leading)
                                        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18))
                                } else {
                                    HStack { ProgressView(); Text(model.approval == nil ? "Working…" : "Waiting for your approval") }
                                        .font(.footnote).foregroundStyle(.secondary)
                                }
                            }
                            Color.clear.frame(height: 1).id("bottom")
                        }.padding(20)
                    }
                    .onChange(of: model.selectedChat?.messages.count) { _, _ in withAnimation { proxy.scrollTo("bottom", anchor: .bottom) } }
                    .onChange(of: model.streamedText?.count) { _, _ in proxy.scrollTo("bottom", anchor: .bottom) }
                    .overlay(alignment: .bottomTrailing) {
                        // Floats on the transcript canvas just above the composer, inline with the submit column.
                        // Tapping opens the per-generation performance modal.
                        if let rate = rateBadgeValue {
                            Button { statsPresented = true } label: { rateBadge(rate) }
                                .padding(.trailing, 20).padding(.bottom, 10)
                        }
                    }
                }
                composer
            }
            .navigationTitle(model.selectedChat?.title ?? "Newton")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("New chat", systemImage: "square.and.pencil") { model.newChat() }.disabled(model.isRunning || !model.storageReady)
                }
            }
        }
        .sheet(isPresented: $settingsPresented) { SettingsView(model: model) }
        .sheet(isPresented: $notesPresented) { NotesView(model: model) }
        .sheet(isPresented: $statsPresented) { GenerationStatsView(model: model) }
        .sheet(item: $model.approval) { request in
            ApprovalView(model: model, request: request).interactiveDismissDisabled()
                .onDisappear { model.approvalDidDismiss(request.id) }
        }
        .sheet(item: $model.messageDraft) { draft in
            MessageComposer(draft: draft, completion: { model.finishMessage($0, id: draft.id) }).ignoresSafeArea().interactiveDismissDisabled()
                .onDisappear { model.messageDidDismiss(draft.id) }
        }
        .alert("Newton", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("OK") { model.error = nil }
        } message: { Text(model.error ?? "") }
        .alert("Dictation", isPresented: Binding(get: { speech.error != nil }, set: { if !$0 { speech.error = nil } })) {
            Button("OK") { speech.error = nil }
        } message: { Text(speech.error ?? "") }
        .alert("Rename chat", isPresented: Binding(get: { renameID != nil }, set: { if !$0 { renameID = nil } })) {
            TextField("Title", text: $renameText)
            Button("Cancel", role: .cancel) { renameID = nil }
            Button("Save") { if let id = renameID { model.renameChat(id, title: renameText) }; renameID = nil }
        }
        .onChange(of: speech.transcript) { _, text in draft = dictationPrefix + text }
        .onChange(of: model.selection) { _, _ in speech.stop(); draft = ""; model.tokensPerSecond = nil }
        .onChange(of: phase) { _, value in
            if value != .active { speech.stop() }
            if value == .background, model.messageDraft == nil { model.cancel() }
        }
        .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.interruptionNotification)) { _ in speech.stop() }
    }
    private var welcome: some View {
        VStack(alignment: .leading, spacing: 18) {
            Image(systemName: "sparkle").font(.system(size: 40)).foregroundStyle(.indigo)
            Text("A little more capable.").font(.largeTitle.bold())
            Text("Think, write, and get things done with an assistant that lives on your iPhone.")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 14) {
                Label("Chat with a local model or your own API", systemImage: "cpu")
                Label("Plan your day and keep useful notes", systemImage: "calendar")
                Label("Review every tool action before it runs", systemImage: "hand.raised")
            }.font(.subheadline)
            Button("Set up inference") { settingsPresented = true }.buttonStyle(.borderedProminent)
        }.padding(.vertical, 35).frame(maxWidth: .infinity, alignment: .leading)
    }
    /// The badge shows the live rate while a run streams; otherwise it falls back to the
    /// newest measured rate in this conversation's persisted history, keeping the modal
    /// reachable after a relaunch.
    private var rateBadgeValue: Double? {
        if let live = model.tokensPerSecond { return live }
        guard let records = model.selectedChat?.generations, !records.isEmpty else { return nil }
        return records.last { $0.averageTokensPerSecond > 0 }?.averageTokensPerSecond ?? 0
    }
    /// Same 38pt circle geometry as the floating token/sec badge, so the composer controls
    /// and the badge read as one family. Disabled state fills gray (system symbols dimmed
    /// themselves; this custom fill needs the environment to know).
    struct IconButtonLabel: View {
        let symbol: String
        @Environment(\.isEnabled) private var isEnabled
        var body: some View {
            ZStack {
                Circle()
                    .fill(isEnabled ? Color.indigo : Color(.secondarySystemFill))
                    .shadow(color: .black.opacity(0.15), radius: 2, y: 1)
                Image(systemName: symbol).font(.system(size: 16, weight: .bold)).foregroundStyle(.white)
            }
            .frame(width: 38, height: 38)
        }
    }
    private func rateBadge(_ rate: Double) -> some View {
        // Slightly larger than the submit glyph (title-sized circle arrow). Two compact lines:
        // a small bolt over the rate, sized to sit legibly inside the circle.
        ZStack {
            Circle()
                .fill(.indigo)
                .shadow(color: .black.opacity(0.22), radius: 3, y: 2)
            VStack(spacing: 1) {
                Image(systemName: "bolt.fill").font(.system(size: 8, weight: .bold))
                Text(String(format: "%.1f", rate)).font(.system(size: 10, weight: .bold))
            }
            .foregroundStyle(.white)
        }
        .frame(width: 38, height: 38)
        .accessibilityLabel(String(format: "Streaming at %.1f tokens per second", rate))
    }
    private var composer: some View {
        VStack(spacing: 8) {
            if model.settings.provider == .compatible {
                Text("Chat and approved tool results go to your configured API.").font(.caption2).foregroundStyle(.secondary)
            }
            HStack(alignment: composerIsSingleLine ? .center : .bottom, spacing: 12) {
                TextField("Ask Newton…", text: $draft, axis: .vertical).lineLimit(1...6)
                    .padding(12).background(.quaternary, in: RoundedRectangle(cornerRadius: 16))
                    .onGeometryChange(for: CGSize.self, of: { $0.size }) { size in
                        composerFieldHeight = size.height
                        if composerSingleLineHeight == 0 || size.height < composerSingleLineHeight {
                            composerSingleLineHeight = size.height
                        }
                    }
                    .disabled(model.isRunning || speech.isRecording)
                Button {
                    if speech.isRecording { speech.stop() }
                    else { dictationPrefix = draft.isEmpty ? "" : draft + " "; Task { await speech.start() } }
                } label: {
                    Image(systemName: speech.isRecording ? "mic.fill" : "mic")
                        .font(.system(size: 30))
                        .foregroundStyle(speech.isRecording ? .red : .indigo)
                        .frame(width: 38, height: 38)
                }
                .accessibilityLabel(speech.isRecording ? "Stop dictation" : "Start on-device dictation")
                .disabled(model.isRunning || speech.isStarting)
                if model.isRunning {
                    Button { model.cancel() } label: { IconButtonLabel(symbol: "stop.fill") }
                    .accessibilityLabel("Stop generating")
                } else {
                    Button {
                        speech.stop(); if model.send(draft) { draft = "" }
                    } label: { IconButtonLabel(symbol: "arrow.up") }
                    .accessibilityLabel("Send message")
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !model.storageReady || model.isManagingModel || speech.isStarting)
                }
            }
        }.padding().background(.bar)
    }
}

import AVFoundation

struct MessageRow: View {
    let message: Message
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if message.role == "tool" {
                DisclosureGroup {
                    Text(message.content ?? "").font(.caption.monospaced()).textSelection(.enabled)
                } label: { Label("Tool result", systemImage: "checklist").font(.caption).foregroundStyle(.secondary) }
            } else {
                Text(message.role == "user" ? "YOU" : "NEWTON").font(.caption2.weight(.bold)).tracking(1.5).foregroundStyle(.secondary)
                if let content = message.content, !content.isEmpty { Text(content).textSelection(.enabled) }
                ForEach(message.toolCalls ?? []) { call in
                    DisclosureGroup {
                        Text(call.function.arguments).font(.caption.monospaced()).textSelection(.enabled)
                    } label: { Label(call.function.name, systemImage: "wrench.and.screwdriver").font(.footnote) }
                }
            }
        }
        .padding(16).frame(maxWidth: .infinity, alignment: .leading)
        .background(message.role == "user" ? Color.indigo.opacity(0.08) : Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18))
    }
}

struct ApprovalView: View {
    let model: AppModel
    let request: ApprovalRequest
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Label("Review tool request", systemImage: "hand.raised.fill").font(.title2.bold())
                    Text(request.call.function.name).font(.headline.monospaced())
                    Text(model.makeTools().first { $0.definition.name == request.call.function.name }?.definition.description ?? "")
                    Text(prettyArguments).font(.body.monospaced()).textSelection(.enabled).padding().frame(maxWidth: .infinity, alignment: .leading).background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
                    Text(model.settings.provider == .local ? "The result will be available to your on-device model." : "The result will be sent to \(URL(string: model.settings.baseURL)?.host ?? "your API") as part of this chat.")
                        .font(.footnote).foregroundStyle(.secondary)
                    HStack {
                        Button("Decline", role: .cancel) { model.resolveApproval(false) }.buttonStyle(.bordered)
                        Spacer()
                        Button("Allow once") { model.resolveApproval(true) }.buttonStyle(.borderedProminent)
                    }
                }.padding(24)
            }.navigationTitle("Permission").navigationBarTitleDisplayMode(.inline)
        }
    }
    private var prettyArguments: String {
        guard let object = try? JSONSerialization.jsonObject(with: Data(request.call.function.arguments.utf8)),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]) else { return request.call.function.arguments }
        return String(decoding: data, as: UTF8.self)
    }
}

struct MessageComposer: UIViewControllerRepresentable {
    let draft: MessageDraft
    let completion: (String) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(completion) }
    func makeUIViewController(context: Context) -> MFMessageComposeViewController {
        let controller = MFMessageComposeViewController()
        controller.recipients = [draft.recipient]; controller.body = draft.body
        controller.messageComposeDelegate = context.coordinator
        return controller
    }
    func updateUIViewController(_ controller: MFMessageComposeViewController, context: Context) {}
    final class Coordinator: NSObject, MFMessageComposeViewControllerDelegate {
        let completion: (String) -> Void
        init(_ completion: @escaping (String) -> Void) { self.completion = completion }
        func messageComposeViewController(_ controller: MFMessageComposeViewController, didFinishWith result: MessageComposeResult) {
            switch result {
            case .sent: completion("The user sent the message through Messages. Delivery is not confirmed.")
            case .cancelled: completion("The user cancelled. No message was sent by this composer.")
            case .failed: completion("Messages reported failure. Do not automatically retry.")
            @unknown default: completion("Message outcome unknown. Do not automatically retry.")
            }
        }
    }
}
