import Foundation
import SwiftUI

public struct OctokanMessage: Identifiable, Equatable {
    public let id: String
    public let serverId: Int?
    public let fromVisitor: Bool
    public let body: String
    public var pending: Bool
}

struct QueuedMessage: Codable, Equatable {
    let clientId: String
    let body: String
}

/// Drives the chat screen: starts the conversation, sends with an offline queue and polls for replies.
@MainActor
public final class OctokanChatModel: ObservableObject {
    @Published public private(set) var messages: [OctokanMessage] = []
    @Published public private(set) var title = "Support"
    @Published public private(set) var accent = Color.black
    @Published public private(set) var welcome = "Hey, something not working? Tell us."
    @Published public private(set) var ready = false
    @Published public private(set) var error: String?

    private var client: OctokanClient?
    private var polling: Task<Void, Never>?
    private var queue: [QueuedMessage] = []
    private var lastServerId = 0

    public init() {}

    public func start() async {
        guard let appId = Octokan.appId, let baseURL = Octokan.baseURL else {
            error = OctokanError.notConfigured.errorDescription
            return
        }
        let client = OctokanClient(appId: appId, baseURL: baseURL, token: Octokan.defaults.string(forKey: Octokan.tokenKey(appId)))
        self.client = client
        queue = loadQueue(appId)

        do {
            let res = try await client.start(user: Octokan.user)
            if let token = res.token {
                client.token = token
                Octokan.defaults.set(token, forKey: Octokan.tokenKey(appId))
            }
            apply(res.config)
            merge(res.messages ?? [])
            for q in queue where !messages.contains(where: { $0.id == q.clientId }) {
                messages.append(OctokanMessage(id: q.clientId, serverId: nil, fromVisitor: true, body: q.body, pending: true))
            }
            error = nil
            ready = true
            await flush()
            beginPolling()
        } catch {
            self.error = (error as? OctokanError)?.errorDescription ?? error.localizedDescription
            ready = true
        }
    }

    public func stop() {
        polling?.cancel()
        polling = nil
    }

    public func send(_ raw: String) {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, client != nil else { return }
        let clientId = UUID().uuidString.lowercased()
        messages.append(OctokanMessage(id: clientId, serverId: nil, fromVisitor: true, body: String(text.prefix(2000)), pending: true))
        queue.append(QueuedMessage(clientId: clientId, body: String(text.prefix(2000))))
        saveQueue()
        Task { await flush() }
    }

    // MARK: - internals

    /// Sends queued messages in order. A network failure leaves them queued for the next poll.
    private func flush() async {
        guard let client else { return }
        while let next = queue.first {
            do {
                let sent = try await client.send(next.body, clientId: next.clientId)
                queue.removeFirst()
                saveQueue()
                if let sent { merge([sent]) }
                error = nil
            } catch OctokanError.server(let message) {
                // the server refused it (too fast, too long...): drop it from the queue and tell the person
                queue.removeFirst()
                saveQueue()
                messages.removeAll { $0.id == next.clientId }
                error = message
            } catch {
                return // offline: try again later
            }
        }
    }

    private func beginPolling() {
        polling?.cancel()
        polling = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 4_000_000_000)
                guard let self, !Task.isCancelled else { return }
                await self.poll()
            }
        }
    }

    private func poll() async {
        guard let client else { return }
        if !queue.isEmpty { await flush() }
        if let res = try? await client.messages(after: lastServerId) {
            merge(res.messages ?? [])
        }
    }

    private func merge(_ incoming: [WireMessage]) {
        for m in incoming {
            lastServerId = max(lastServerId, m.id)
            let item = OctokanMessage(id: m.clientId ?? "s\(m.id)", serverId: m.id, fromVisitor: m.sender == "visitor", body: m.body, pending: false)
            if let i = messages.firstIndex(where: { $0.id == item.id || ($0.serverId != nil && $0.serverId == m.id) }) {
                messages[i] = item
            } else {
                messages.append(item)
            }
        }
    }

    private func apply(_ config: WireConfig?) {
        guard let config else { return }
        if let t = config.title, !t.isEmpty { title = t }
        if let w = config.welcome, !w.isEmpty { welcome = w }
        if let hex = config.accent, let c = Color(octokanHex: hex) { accent = c }
    }

    private func loadQueue(_ appId: String) -> [QueuedMessage] {
        guard let data = Octokan.defaults.data(forKey: Octokan.pendingKey(appId)) else { return [] }
        return (try? JSONDecoder().decode([QueuedMessage].self, from: data)) ?? []
    }

    private func saveQueue() {
        guard let appId = Octokan.appId else { return }
        if let data = try? JSONEncoder().encode(queue) { Octokan.defaults.set(data, forKey: Octokan.pendingKey(appId)) }
    }
}

extension Color {
    init?(octokanHex: String) {
        var s = octokanHex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        self.init(red: Double((v >> 16) & 255) / 255, green: Double((v >> 8) & 255) / 255, blue: Double(v & 255) / 255)
    }
}
