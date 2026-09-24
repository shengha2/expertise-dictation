import Foundation

protocol STTSocket: AnyObject {
    var onOpen: (() -> Void)? { get set }
    var onText: ((String) -> Void)? { get set }
    var onClose: ((Error?) -> Void)? { get set }
    func connect()
    func send(text: String)
    func send(data: Data)
    func ping()
    func close()
}

enum WebSocketHandshakeError: LocalizedError {
    case rejected(statusCode: Int)
    var errorDescription: String? {
        switch self { case .rejected(let status): return "WebSocket connection rejected (HTTP \(status))" }
    }
}

/// Thin wrapper over URLSessionWebSocketTask with a receive loop and delegate callbacks.
/// Callbacks run on an internal serial queue; callers hop to main as needed.
final class WebSocketClient: NSObject, URLSessionWebSocketDelegate, STTSocket {
    var onOpen: (() -> Void)?
    var onText: ((String) -> Void)?
    var onData: ((Data) -> Void)?
    var onClose: ((Error?) -> Void)?

    private var session: URLSession!
    private var task: URLSessionWebSocketTask?
    private let url: URL
    private let headers: [String: String]
    private let refuseRedirects: Bool
    private var closed = false
    private let stateLock = NSLock()
    private let queue = OperationQueue()

    init(url: URL, headers: [String: String], refuseRedirects: Bool = false) {
        self.url = url
        self.headers = headers
        self.refuseRedirects = refuseRedirects
        super.init()
        queue.maxConcurrentOperationCount = 1
        let cfg = refuseRedirects ? URLSessionConfiguration.ephemeral : URLSessionConfiguration.default
        if refuseRedirects { cfg.httpShouldSetCookies = false }
        cfg.timeoutIntervalForRequest = 30
        cfg.waitsForConnectivity = false
        session = URLSession(configuration: cfg, delegate: self, delegateQueue: queue)
    }

    func connect() {
        var req = URLRequest(url: url)
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        let t = session.webSocketTask(with: req)
        t.maximumMessageSize = 8 * 1024 * 1024
        task = t
        t.resume()
        receiveLoop()
    }

    func send(text: String) {
        task?.send(.string(text)) { [weak self] error in
            if let error { self?.fail(error) }
        }
    }

    func send(data: Data) {
        task?.send(.data(data)) { [weak self] error in
            if let error { self?.fail(error) }
        }
    }

    func ping() {
        task?.sendPing { [weak self] error in
            if let error { self?.fail(error) }
        }
    }

    func close() {
        guard markClosed() else { return }
        task?.cancel(with: .normalClosure, reason: nil)
        session.finishTasksAndInvalidate()
    }

    private func receiveLoop() {
        task?.receive { [weak self] result in
            guard let self, !self.isClosed else { return }
            switch result {
            case .success(let message):
                switch message {
                case .string(let s): self.onText?(s)
                case .data(let d): self.onData?(d)
                @unknown default: break
                }
                self.receiveLoop()
            case .failure(let error):
                self.fail(error)
            }
        }
    }

    private func fail(_ error: Error) {
        guard markClosed() else { return }
        onClose?(Self.reportedError(error, response: task?.response, refuseRedirects: refuseRedirects))
        session.invalidateAndCancel()
    }

    /// Hosted authentication needs the HTTP handshake status; the transport's
    /// generic bad-server-response error cannot distinguish it from a disconnect.
    /// Keep the existing direct-provider error unchanged.
    static func reportedError(_ error: Error, response: URLResponse?, refuseRedirects: Bool) -> Error {
        if refuseRedirects, let http = response as? HTTPURLResponse, http.statusCode != 101 {
            return WebSocketHandshakeError.rejected(statusCode: http.statusCode)
        }
        return error
    }

    private var isClosed: Bool { stateLock.lock(); defer { stateLock.unlock() }; return closed }
    private func markClosed() -> Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        guard !closed else { return false }
        closed = true
        return true
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        if !isClosed { onOpen?() }
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        guard markClosed() else { return }
        let text = reason.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        let err = closeCode == .normalClosure ? nil : STTError.connection("socket closed (\(closeCode.rawValue)) \(text)")
        onClose?(err)
        session.finishTasksAndInvalidate()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { fail(error) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(refuseRedirects ? nil : request)
    }
}
