import Foundation
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// The number of unread replies from support, for a badge on your chat icon.
public final class OctokanUnread: ObservableObject {
    public static let shared = OctokanUnread()
    @Published public internal(set) var count = 0
}

public struct OctokanUser: Equatable {
    public var id: String?
    public var email: String?
    public var name: String?

    public init(id: String? = nil, email: String? = nil, name: String? = nil) {
        self.id = id
        self.email = email
        self.name = name
    }
}

/// The one-stop entry point.
///
///     Octokan.configure(appId: "app_xxxxxxxxxxxx", baseURL: URL(string: "https://YOUR-BACKEND")!)
///     Octokan.identify(id: user.id, email: user.email, name: user.name)   // optional
///     Octokan.presentChat()                                               // or embed OctokanChatView()
public enum Octokan {
    static var appId: String?
    static var baseURL: URL?
    static var user: OctokanUser?
    static let defaults = UserDefaults.standard
    static var lastRead = 0
    static var chatsOpen = 0
    static var badgeTask: Task<Void, Never>?

    /// How many replies from support the person hasn't read. Use `OctokanChatButton`, which already shows it, or
    /// observe this to put your own badge on your own chat icon: `@ObservedObject var unread = OctokanUnread.shared`.
    @MainActor
    public static func watchUnread() {
        guard badgeTask == nil, let appId, let baseURL, let token = defaults.string(forKey: tokenKey(appId)) else { return }
        lastRead = defaults.integer(forKey: readKey(appId))
        badgeTask = Task {
            while !Task.isCancelled {
                if chatsOpen == 0 {
                    let client = OctokanClient(appId: appId, baseURL: baseURL, token: token)
                    if let res = try? await client.messages(after: lastRead, peek: true) {
                        let n = (res.messages ?? []).filter { $0.sender == "owner" && $0.id > lastRead }.count
                        OctokanUnread.shared.count = n
                    }
                }
                try? await Task.sleep(nanoseconds: 20_000_000_000)
            }
        }
    }

    @MainActor
    public static func stopWatchingUnread() {
        badgeTask?.cancel()
        badgeTask = nil
    }

    @MainActor static func chatOpened() {
        chatsOpen += 1
        OctokanUnread.shared.count = 0
    }

    @MainActor static func chatClosed() {
        chatsOpen = max(0, chatsOpen - 1)
    }

    /// Remembers how far the person has read, so the badge counts only replies they haven't seen.
    @MainActor static func markRead(_ serverId: Int) {
        guard let appId else { return }
        if serverId > lastRead {
            lastRead = serverId
            defaults.set(serverId, forKey: readKey(appId))
        }
        if OctokanUnread.shared.count != 0 { OctokanUnread.shared.count = 0 }
    }

    static func readKey(_ appId: String) -> String { "octokan.read.\(appId)" }

    /// Call once at launch. Nothing is sent and nothing is stored until the person opens the chat.
    public static func configure(appId: String, baseURL: URL) {
        self.appId = appId
        self.baseURL = baseURL
        user = nil
    }

    /// Tell octokan who is signed in, so you see their name and email in the inbox. Optional.
    public static func identify(id: String? = nil, email: String? = nil, name: String? = nil) {
        user = OctokanUser(id: id, email: email, name: name)
    }

    /// Call on sign-out so the next person on this device starts a fresh conversation.
    public static func reset() {
        user = nil
        if let appId {
            defaults.removeObject(forKey: tokenKey(appId))
            defaults.removeObject(forKey: pendingKey(appId))
            defaults.removeObject(forKey: readKey(appId))
            lastRead = 0
            DispatchQueue.main.async { OctokanUnread.shared.count = 0 }
        }
    }

    /// Lets a person erase their own chat from octokan's servers and from this device.
    public static func deleteMyData() async throws {
        guard let appId, let baseURL else { throw OctokanError.notConfigured }
        let client = OctokanClient(appId: appId, baseURL: baseURL, token: defaults.string(forKey: tokenKey(appId)))
        try await client.forget()
        reset()
    }

    static func tokenKey(_ appId: String) -> String { "octokan.token.\(appId)" }
    static func pendingKey(_ appId: String) -> String { "octokan.pending.\(appId)" }

    #if canImport(UIKit)
    /// Presents the chat as a sheet over the top-most screen.
    @MainActor
    public static func presentChat() {
        guard let top = topViewController() else { return }
        let host = UIHostingController(rootView: OctokanChatView(onClose: { top.presentedViewController?.dismiss(animated: true) }))
        host.modalPresentationStyle = .pageSheet
        top.present(host, animated: true)
    }

    @MainActor
    private static func topViewController() -> UIViewController? {
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first { $0.activationState == .foregroundActive }
        var top = scene?.windows.first { $0.isKeyWindow }?.rootViewController
        while let next = top?.presentedViewController { top = next }
        return top
    }
    #endif
}
