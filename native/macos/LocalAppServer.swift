import Foundation
import Network
final class LocalAppServer {
    private let listener: NWListener
    private let root: URL
    private let queue = DispatchQueue(label: "rijian.local-assets")
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    var onReady: (() -> Void)?
    var onFailure: ((String) -> Void)?

    init(root: URL) throws {
        self.root = root
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: 24716)
        listener = try NWListener(using: parameters)
    }
    func start() {
        listener.stateUpdateHandler = { [weak self] state in

            switch state {
            case .ready: DispatchQueue.main.async { self?.onReady?() }
            case .failed(let error): DispatchQueue.main.async { self?.onFailure?(error.localizedDescription) }
            default: break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            let id = ObjectIdentifier(connection)
            self.connections[id] = connection
            connection.stateUpdateHandler = { [weak self] state in
                if case .cancelled = state { self?.connections.removeValue(forKey: id) }
                if case .failed = state { connection.cancel() }
            }
            connection.start(queue: self.queue)
            self.receive(connection, collected: Data())
        }
        listener.start(queue: queue)
    }
    private func receive(_ connection: NWConnection, collected: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, complete, error in
            guard let self else { connection.cancel(); return }
            var request = collected
            request.append(data ?? Data())
            if request.range(of: Data("\r\n\r\n".utf8)) != nil {
                self.respond(connection, request: request)
            } else if error != nil || complete || request.count > 16384 {
                connection.cancel()
            } else { self.receive(connection, collected: request) }
        }
    }
    private func respond(_ connection: NWConnection, request: Data) {

        let line = String(decoding: request, as: UTF8.self).components(separatedBy: "\r\n").first ?? ""
        let parts = line.split(separator: " ")
        guard parts.count >= 2, parts[0] == "GET" else { connection.cancel(); return }
        let path = String(parts[1]).components(separatedBy: "?").first?.removingPercentEncoding ?? "/"
        let file = root.appendingPathComponent(path == "/" ? "index.html" : String(path.dropFirst())).standardizedFileURL
        let allowed = file.path.hasPrefix(root.standardizedFileURL.path + "/")
        let data = allowed ? try? Data(contentsOf: file) : nil
        let body = data ?? Data("Not Found".utf8)
        let mime = ["html":"text/html; charset=utf-8","js":"application/javascript; charset=utf-8","css":"text/css; charset=utf-8","json":"application/json","png":"image/png"][file.pathExtension] ?? "application/octet-stream"
        let header = "HTTP/1.1 \(data == nil ? "404 Not Found" : "200 OK")\r\nContent-Type: \(mime)\r\nContent-Length: \(body.count)\r\nCache-Control: no-cache\r\nConnection: close\r\n\r\n"
        var response = Data(header.utf8)
        response.append(body)
        connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
    }
    deinit { listener.cancel(); connections.values.forEach { $0.cancel() } }
}
