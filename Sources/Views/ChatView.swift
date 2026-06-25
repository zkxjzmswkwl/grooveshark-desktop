import SwiftUI

struct ChatMessage: Identifiable, Equatable {
    let id = UUID()
    let timestamp: Date
    let nickname: String
    let text: String
    let isSystem: Bool
}

@MainActor
final class ChatViewModel: ObservableObject {
    @Published var messages: [ChatMessage] = []
    @Published var connectionStatus = "Disconnected"
    @Published var draftMessage = ""

    private var client: IRCClient?
    private var nick = ""

    func connect() {
        guard client == nil else { return }

        nick = Self.defaultNick()
        let client = IRCClient(nick: nick)
        self.client = client

        Task {
            await client.setOnLine { [weak self] line in
                Task { @MainActor in
                    self?.handleLine(line)
                }
            }
        }

        Task {
            connectionStatus = "Connecting to \(IRCConfiguration.server)..."
            appendSystemMessage("Connecting as \(nick)...")
            do {
                try await client.connect()
                connectionStatus = "Connected — \(IRCConfiguration.channel)"
            } catch {
                connectionStatus = "Connection failed"
                appendSystemMessage("Failed to connect: \(error.localizedDescription)")
                self.client = nil
            }
        }
    }

    func disconnect() {
        guard let client else { return }
        Task {
            await client.disconnect()
        }
        self.client = nil
        connectionStatus = "Disconnected"
    }

    func sendDraftMessage() {
        let text = draftMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let client else { return }

        draftMessage = ""
        Task {
            do {
                try await client.sendMessage(text)
            } catch {
                appendSystemMessage("Failed to send message: \(error.localizedDescription)")
            }
        }
    }

    private func handleLine(_ line: String) {
        if line.hasPrefix("ERROR") {
            appendSystemMessage(line)
            connectionStatus = "Disconnected"
            client = nil
            return
        }

        guard let message = Self.parseIRCLine(line, ownNick: nick) else { return }
        messages.append(message)
    }

    private func appendSystemMessage(_ text: String) {
        messages.append(
            ChatMessage(
                timestamp: Date(),
                nickname: "•",
                text: text,
                isSystem: true
            )
        )
    }

    private static func defaultNick() -> String {
        let host = Host.current().localizedName ?? "User"
        let sanitized = host.filter { $0.isLetter || $0.isNumber }.prefix(10)
        let suffix = String(format: "%04d", Int.random(in: 0...9999))
        return "GS-\(sanitized)-\(suffix)"
    }

    static func parseIRCLine(_ line: String, ownNick: String) -> ChatMessage? {
        if line.first != ":" {
            let parts = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard let code = Int(parts.first ?? ""), parts.count >= 2 else { return nil }

            switch code {
            case 001:
                let welcome = parts.count > 2 ? String(parts[2]) : "Welcome"
                return systemMessage(welcome.trimmingPrefix(":"))
            case 366:
                return systemMessage("End of names list")
            case 332:
                if parts.count >= 4 {
                    let topic = String(parts[3...].joined(separator: " ")).trimmingPrefix(":")
                    return systemMessage("Topic: \(topic)")
                }
                return nil
            case 333:
                return nil
            case 353:
                if parts.count >= 4 {
                    let names = String(parts[3...].joined(separator: " ")).trimmingPrefix(":")
                    return systemMessage("Users: \(names)")
                }
                return nil
            default:
                guard (400...599).contains(code) else { return nil }
                let detail = parts.count > 2 ? String(parts[2...].joined(separator: " ")).trimmingPrefix(":") : line
                return systemMessage(detail)
            }
        }

        let withoutPrefix = line.dropFirst()
        guard let spaceIndex = withoutPrefix.firstIndex(of: " ") else { return nil }

        let prefix = String(withoutPrefix[..<spaceIndex])
        let rest = String(withoutPrefix[withoutPrefix.index(after: spaceIndex)...])
        let nickname = prefix.split(separator: "!").first.map(String.init) ?? prefix

        if rest.hasPrefix("PRIVMSG ") {
            guard let colonIndex = rest.firstIndex(of: ":") else { return nil }
            let message = String(rest[rest.index(after: colonIndex)...])
            return ChatMessage(timestamp: Date(), nickname: nickname, text: message, isSystem: false)
        }

        if rest.hasPrefix("JOIN ") {
            let channel = rest.dropFirst(5).trimmingCharacters(in: .whitespaces)
            let text = nickname == ownNick ? "You joined \(channel)" : "\(nickname) joined \(channel)"
            return systemMessage(text)
        }

        if rest.hasPrefix("PART ") {
            let text = nickname == ownNick ? "You left the channel" : "\(nickname) left the channel"
            return systemMessage(text)
        }

        if rest.hasPrefix("QUIT ") {
            let reason: String
            if let colonIndex = rest.firstIndex(of: ":") {
                reason = String(rest[rest.index(after: colonIndex)...])
            } else {
                reason = ""
            }
            let detail = reason.isEmpty ? "\(nickname) quit" : "\(nickname) quit: \(reason)"
            return systemMessage(detail)
        }

        if rest.hasPrefix("NICK ") {
            let newNick = rest.dropFirst(5).trimmingCharacters(in: .whitespaces)
            let text = nickname == ownNick ? "You changed nick to \(newNick)" : "\(nickname) is now \(newNick)"
            return systemMessage(text)
        }

        return nil
    }

    private static func systemMessage(_ text: String) -> ChatMessage {
        ChatMessage(timestamp: Date(), nickname: "•", text: text, isSystem: true)
    }
}

private extension String {
    func trimmingPrefix(_ prefix: String) -> String {
        hasPrefix(prefix) ? String(dropFirst(prefix.count)) : self
    }
}

struct ChatView: View {
    @EnvironmentObject private var player: PlayerViewModel
    @StateObject private var chat = ChatViewModel()

    var body: some View {
        VStack(spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Chat")
                        .appFont(size: 14, weight: .bold)
                    Text("\(IRCConfiguration.server) · \(IRCConfiguration.channel)")
                        .appFont(size: 11)
                        .foregroundStyle(Color.grooveTextSecondary)
                }
                Spacer()
                Text(chat.connectionStatus)
                    .appFont(size: 11)
                    .foregroundStyle(Color.grooveTextSecondary)
            }

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        ForEach(chat.messages) { message in
                            ChatMessageRow(message: message)
                                .id(message.id)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                }
                .background(Color.grooveSurfaceRaised)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.grooveBorder, lineWidth: 1))
                .onChange(of: chat.messages.count) { _, _ in
                    guard let last = chat.messages.last else { return }
                    withAnimation(.easeOut(duration: 0.15)) {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }

            HStack(spacing: 8) {
                TextField("Message #grooveshark", text: $chat.draftMessage)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit {
                        chat.sendDraftMessage()
                    }
                Button("Send") {
                    chat.sendDraftMessage()
                }
                .buttonStyle(.borderedProminent)
                .disabled(chat.draftMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(14)
        .background(Color.grooveSurface)
        .preferredColorScheme(player.darkModeEnabled ? .dark : .light)
        .onAppear {
            chat.connect()
        }
        .onDisappear {
            chat.disconnect()
        }
    }
}

private struct ChatMessageRow: View {
    let message: ChatMessage

    var body: some View {
        if message.isSystem {
            Text(message.text)
                .appFont(size: 11)
                .foregroundStyle(Color.grooveTextSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(message.nickname)
                    .appFont(size: 12, weight: .bold)
                    .foregroundStyle(Color.grooveOrange)
                Text(message.text)
                    .appFont(size: 12)
                    .foregroundStyle(Color.grooveTextPrimary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}
