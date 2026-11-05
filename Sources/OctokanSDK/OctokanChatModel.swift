import Foundation
import SwiftUI

public struct OctokanMessage: Identifiable, Equatable {
    public let id: String
    public let serverId: Int?
    public let fromVisitor: Bool
    public let body: String
    public var pending: Bool
    public var at: Date = Date()
    public var kind: String = "text" // text, image, audio or file
    public var attachmentName: String?
    public var attachmentSize: Int?
    public var attachmentURL: URL?
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
    @Published public private(set) var logo: URL?
    @Published public private(set) var welcome = "Hey, something not working? Tell us."
    @Published public private(set) var ready = false
    @Published public private(set) var error: String?
    @Published public private(set) var typing = false // the owner is typing a reply
    @Published public private(set) var seenAt: Date? // when the owner last opened the conversation

    private var client: OctokanClient?
    private var polling: Task<Void, Never>?
    private var queue: [QueuedMessage] = []
    private var lastServerId = 0
    private var typingSentAt = Date.distantPast

    public init() {}

    public func start() async {
        Octokan.chatOpened()
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
            typing = res.typing ?? false
            seenAt = res.seenAt.flatMap(parseISO)
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
        Octokan.chatClosed()
        polling?.cancel()
        polling = nil
    }

    /// Call while the person types. Tells the owner "typing...", at most every three seconds.
    public func notifyTyping() {
        guard let client, client.token != nil, Date().timeIntervalSince(typingSentAt) >= 3 else { return }
        typingSentAt = Date()
        Task { try? await client.typing() }
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
    private var flushing = false

    /// One sender at a time: a send and the poll loop must not post the same message twice at once.
    private func flush() async {
        guard let client, !flushing else { return }
        flushing = true
        defer { flushing = false }
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
                try? await Task.sleep(nanoseconds: 3_000_000_000)
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
            typing = res.typing ?? false
            seenAt = res.seenAt.flatMap(parseISO) ?? seenAt
        }
    }

    private func merge(_ incoming: [WireMessage]) {
        for m in incoming {
            lastServerId = max(lastServerId, m.id)
            var item = OctokanMessage(id: m.clientId ?? "s\(m.id)", serverId: m.id, fromVisitor: m.sender == "visitor", body: m.body, pending: false, at: parseISO(m.at) ?? Date())
            item.kind = m.kind ?? "text"
            item.attachmentName = m.attachment?.name
            item.attachmentSize = m.attachment?.size
            item.attachmentURL = m.attachment?.url.flatMap(URL.init(string:))
            if let i = messages.firstIndex(where: { $0.id == item.id || ($0.serverId != nil && $0.serverId == m.id) }) {
                messages[i] = item
            } else {
                messages.append(item)
            }
        }
        Octokan.markRead(lastServerId)
    }

    private func apply(_ config: WireConfig?) {
        guard let config else { return }
        if let t = config.title, !t.isEmpty { title = t }
        if let w = config.welcome, !w.isEmpty { welcome = w }
        if let l = config.logo, l.hasPrefix("https://"), let url = URL(string: l) { logo = url }
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

/// The server sends ISO times like 2026-11-05T10:00:00.123456+00:00; this reads them with or without fractions.
func parseISO(_ iso: String) -> Date? {
    let withFraction = ISO8601DateFormatter()
    withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let d = withFraction.date(from: iso) { return d }
    let plain = ISO8601DateFormatter()
    plain.formatOptions = [.withInternetDateTime]
    if let d = plain.date(from: iso) { return d }
    // fractions longer than milliseconds: drop them and read the rest
    if let dot = iso.firstIndex(of: "."), let tz = iso[dot...].firstIndex(where: { $0 == "+" || $0 == "-" || $0 == "Z" }) {
        return plain.date(from: String(iso[..<dot]) + String(iso[tz...]))
    }
    return nil
}
