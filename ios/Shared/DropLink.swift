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

    func url(path: String, filename: String? = nil, directory: String? = nil,
             offset: Int? = nil) -> URL {
        var url = URLComponents()
        url.scheme = "http"
        url.host = host
        url.port = port
        url.path = path
        var items = [URLQueryItem(name: "t", value: token)]
        if let filename { items.append(URLQueryItem(name: "name", value: filename)) }
        if let directory { items.append(URLQueryItem(name: "dir", value: directory)) }
        if let offset { items.append(URLQueryItem(name: "offset", value: String(offset))) }
        url.queryItems = items
        return url.url!
    }
}

enum PairingStore {
    static let groupID = "group.com.gavin02031.switchdrop"
    private static let key = "pairedSwitch"
    private static let folderKey = "selectedSwitchFolder"

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
        UserDefaults.standard.removeObject(forKey: folderKey)
        UserDefaults(suiteName: groupID)?.removeObject(forKey: folderKey)
    }

    static func saveDestination(_ path: String) {
        UserDefaults.standard.set(path, forKey: folderKey)
        UserDefaults(suiteName: groupID)?.set(path, forKey: folderKey)
    }

    static func loadDestination(sharedOnly: Bool = false) -> String {
        let stored = UserDefaults(suiteName: groupID)?.string(forKey: folderKey)
            ?? (sharedOnly ? nil : UserDefaults.standard.string(forKey: folderKey))
        guard let stored, stored.hasPrefix("/"), !stored.contains("..") else { return "/" }
        return stored
    }
}

struct SwitchHealth: Decodable {
    let name: String
    let `protocol`: Int
}

struct SwitchEntry: Decodable, Identifiable {
    let name: String
    let type: String
    let size: UInt64
    var id: String { name }
    var isFolder: Bool { type == "folder" }
}

struct SwitchDirectory: Decodable {
    let path: String
    let items: [SwitchEntry]
    let nextOffset: Int?
}

enum DropTransport {
    static func verify(_ link: DropLink) async throws {
        var request = URLRequest(url: link.url(path: "/health"))
        request.timeoutInterval = 8
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let status = response as? HTTPURLResponse, status.statusCode == 200,
              let health = try? JSONDecoder().decode(SwitchHealth.self, from: data),
              health.name == "SwitchDrop", health.`protocol` == 2
        else { throw DropLinkError.incompatibleSwitch }
    }

    static func browse(_ directory: String, on link: DropLink,
                       offset: Int = 0) async throws -> SwitchDirectory {
        var request = URLRequest(url: link.url(path: "/browse", directory: directory,
                                               offset: offset))
        request.timeoutInterval = 15
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let message = String(data: data, encoding: .utf8) ?? "Folder unavailable"
            throw NSError(domain: "SwitchDrop", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: message])
        }
        let listing = try JSONDecoder().decode(SwitchDirectory.self, from: data)
        guard listing.path == directory else { throw DropLinkError.invalidResponse }
        return listing
    }

    static func send(_ file: URL, filename: String, to link: DropLink,
                     directory: String = "/",
                     delegate: URLSessionTaskDelegate? = nil) async throws {
        var request = URLRequest(url: link.url(path: "/upload", filename: filename,
                                              directory: directory))
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
