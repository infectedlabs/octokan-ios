import Foundation

/// A message as the server returns it.
struct WireMessage: Decodable {
    let id: Int
    let sender: String
    let body: String
    let at: String
    let clientId: String?
}

struct WireConfig: Decodable {
    let title: String?
    let accent: String?
    let welcome: String?
}

struct InitResponse: Decodable {
    let token: String?
    let config: WireConfig?
    let messages: [WireMessage]?
    let typing: Bool? // the owner is typing a reply
    let seenAt: String? // when the owner last opened the conversation
}

struct MessagesResponse: Decodable {
    let messages: [WireMessage]?
    let status: String?
    let typing: Bool?
    let seenAt: String?
}

struct SendResponse: Decodable {
    let message: WireMessage?
}

struct ErrorResponse: Decodable {
    let error: String?
}

public enum OctokanError: Error, LocalizedError {
    case server(String)
    case network
    case notConfigured

    public var errorDescription: String? {
        switch self {
        case .server(let message): return message
        case .network: return "No connection. Your message will send when you're back online."
        case .notConfigured: return "Call Octokan.configure(appId:baseURL:) first."
        }
    }
}

/// Talks to the octokan backend. The visitor token travels in the Authorization header, never in a URL.
final class OctokanClient {
    let appId: String
    let baseURL: URL
    var token: String?
    private let session: URLSession

    init(appId: String, baseURL: URL, token: String?, session: URLSession = .shared) {
        self.appId = appId
        self.baseURL = baseURL
        self.token = token
        self.session = session
    }

    private func request(_ path: String, method: String, query: [URLQueryItem] = [], body: [String: Any]? = nil) throws -> URLRequest {
        var comps = URLComponents(url: baseURL.appendingPathComponent("api/v1/\(path)"), resolvingAgainstBaseURL: false)!
        comps.queryItems = [URLQueryItem(name: "appId", value: appId)] + query
        var req = URLRequest(url: comps.url!)
        req.httpMethod = method
        req.timeoutInterval = 20
        // Native apps send no Origin; this header tells the backend which SDK is calling.
        req.setValue("ios", forHTTPHeaderField: "X-Octokan-Platform")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if var body {
            body["appId"] = appId
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        return req
    }

    private func run<T: Decodable>(_ req: URLRequest, as type: T.Type) async throws -> T {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: req)
        } catch {
            throw OctokanError.network
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        // 5xx is the server having a bad moment, not a refusal: the caller keeps the message queued and retries
        if status >= 500 { throw OctokanError.network }
        guard (200..<300).contains(status) else {
            let message = (try? JSONDecoder().decode(ErrorResponse.self, from: data))?.error
            throw OctokanError.server(message ?? "Something went wrong (\(status)).")
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    func start(user: OctokanUser?) async throws -> InitResponse {
        var body: [String: Any] = [
            "locale": Locale.current.identifier,
            "page": "app",
        ]
        if let user {
            var u: [String: Any] = [:]
            if let id = user.id { u["id"] = id }
            if let email = user.email { u["email"] = email }
            if let name = user.name { u["name"] = name }
            body["user"] = u
        }
        return try await run(try request("init", method: "POST", body: body), as: InitResponse.self)
    }

    func messages(after id: Int) async throws -> MessagesResponse {
        try await run(try request("messages", method: "GET", query: [URLQueryItem(name: "after", value: String(id))]), as: MessagesResponse.self)
    }

    /// Tells the owner the person is typing. Fire and forget.
    func typing() async throws {
        struct Done: Decodable { let ok: Bool? }
        _ = try await run(try request("typing", method: "POST", body: [:]), as: Done.self)
    }

    func send(_ text: String, clientId: String) async throws -> WireMessage? {
        let res = try await run(try request("messages", method: "POST", body: ["body": text, "clientId": clientId]), as: SendResponse.self)
        return res.message
    }

    func forget() async throws {
        struct Done: Decodable { let deleted: Bool? }
        _ = try await run(try request("forget", method: "POST", body: [:]), as: Done.self)
    }
}
