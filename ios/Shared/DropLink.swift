import Foundation

enum DropLinkError: LocalizedError {
    case invalidQR
    case incompatibleSwitch
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .invalidQR: return "This isn't a SwitchDrop pairing code."
        case .incompatibleSwitch: return "The Switch isn't running a compatible SwitchDrop version."
        case .invalidResponse: return "The Switch didn't accept this transfer."
        }
    }
}

struct DropLink: Codable, Equatable {
    let host: String
    let port: Int
    let token: String

    init(qr: String) throws {
        guard let url = URLComponents(string: qr),
              url.scheme == "http", url.path == "/", url.port == 38470,
              let host = url.host, Self.isPrivateIPv4(host),
              let token = url.queryItems?.first(where: { $0.name == "t" })?.value,
              token.count == 32,
              token.allSatisfy({ $0.isASCII && $0.isHexDigit })
        else { throw DropLinkError.invalidQR }
        self.host = host
        self.port = 38470
        self.token = token
    }

    static func isPrivateIPv4(_ address: String) -> Bool {
        let parts = address.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return false }
        var numbers: [Int] = []
        for part in parts {
            guard !part.isEmpty, part.count <= 3,
                  part.allSatisfy({ $0.isNumber && $0.isASCII }),
                  let value = Int(part), value <= 255,
                  String(value) == part else { return false }
            numbers.append(value)
        }
        return numbers[0] == 10 ||
            (numbers[0] == 172 && (16...31).contains(numbers[1])) ||
            (numbers[0] == 192 && numbers[1] == 168) ||
            (numbers[0] == 169 && numbers[1] == 254)
    }

    func url(path: String, filename: String? = nil) -> URL {
        var url = URLComponents()
        url.scheme = "http"
        url.host = host
        url.port = port
        url.path = path
        var items = [URLQueryItem(name: "t", value: token)]
        if let filename { items.append(URLQueryItem(name: "name", value: filename)) }
        url.queryItems = items
        return url.url!
    }
}

enum PairingStore {
    static let groupID = "group.com.gavin02031.switchdrop"
    private static let key = "pairedSwitch"

    static func save(_ link: DropLink) {
        guard let bytes = try? JSONEncoder().encode(link) else { return }
        UserDefaults.standard.set(bytes, forKey: key)
        UserDefaults(suiteName: groupID)?.set(bytes, forKey: key)
    }

    static func load(sharedOnly: Bool = false) -> DropLink? {
        let shared = UserDefaults(suiteName: groupID)?.data(forKey: key)
        let data = shared ?? (sharedOnly ? nil : UserDefaults.standard.data(forKey: key))
        guard let data else { return nil }
        return try? JSONDecoder().decode(DropLink.self, from: data)
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: key)
        UserDefaults(suiteName: groupID)?.removeObject(forKey: key)
    }
}

struct SwitchHealth: Decodable {
    let name: String
    let `protocol`: Int
}

enum DropTransport {
    static func verify(_ link: DropLink) async throws {
        var request = URLRequest(url: link.url(path: "/health"))
        request.timeoutInterval = 8
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let status = response as? HTTPURLResponse, status.statusCode == 200,
              let health = try? JSONDecoder().decode(SwitchHealth.self, from: data),
              health.name == "SwitchDrop", health.`protocol` == 1
        else { throw DropLinkError.incompatibleSwitch }
    }

    static func send(_ file: URL, filename: String, to link: DropLink,
                     delegate: URLSessionTaskDelegate? = nil) async throws {
        var request = URLRequest(url: link.url(path: "/upload", filename: filename))
        request.httpMethod = "POST"
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 60
        let (data, response) = try await URLSession.shared.upload(for: request, fromFile: file,
                                                                  delegate: delegate)
        guard let status = response as? HTTPURLResponse, status.statusCode == 201 else {
            let message = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw NSError(domain: "SwitchDrop", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Switch rejected the file: \(message)"])
        }
    }
}

final class UploadProgress: NSObject, URLSessionTaskDelegate {
    var changed: @Sendable (Double) -> Void

    init(changed: @escaping @Sendable (Double) -> Void) {
        self.changed = changed
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    didSendBodyData bytesSent: Int64, totalBytesSent: Int64,
                    totalBytesExpectedToSend: Int64) {
        guard totalBytesExpectedToSend > 0 else { return }
        changed(Double(totalBytesSent) / Double(totalBytesExpectedToSend))
    }
}
