import Foundation

/// Servern som har tidtabellen och Västtrafiks positioner (server/server.py).
/// Adressen kommer från Info.plist, som får den från Konfig/Lokal.xcconfig, så
/// att den inte står i git.
enum Server {
    static let bas: URL = {
        let info = Bundle.main.infoDictionary ?? [:]
        let schema = (info["ServerSchema"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "https"
        let vard = (info["ServerAdress"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "localhost:8125"
        return URL(string: "\(schema)://\(vard)/")!
    }()

    private static let session: URLSession = {
        let c = URLSessionConfiguration.default
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        c.timeoutIntervalForRequest = 30
        return URLSession(configuration: c)
    }()

    static func hamta<T: Decodable>(_ typ: T.Type, _ vag: String, omrade: String) async throws -> T {
        var u = URLComponents(url: bas.appendingPathComponent(vag), resolvingAgainstBaseURL: false)!
        u.queryItems = [URLQueryItem(name: "omrade", value: omrade)]
        let (data, svar) = try await session.data(from: u.url!)
        let kod = (svar as? HTTPURLResponse)?.statusCode ?? 0
        guard kod == 200 else { throw ServerFel.status(kod) }
        return try JSONDecoder().decode(T.self, from: data)
    }
}

enum ServerFel: LocalizedError {
    case status(Int)

    var errorDescription: String? {
        switch self {
        case .status(503): return "Servern bygger dagens tidtabell."
        case .status(let kod): return "Servern svarade \(kod)."
        }
    }
}
