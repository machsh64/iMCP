import Foundation
import MCP
import Network
import OSLog

private let log = Logger.server

// MARK: - HTTP MCPServer

/// 基于 Streamable HTTP 协议的 MCP 服务器。
///
/// 使用 Network.framework 创建 HTTP 服务器，通过 `StatefulHTTPServerTransport`
/// 提供符合 MCP Streamable HTTP 规范的服务。支持：
/// - 局域网访问（绑定 0.0.0.0）
/// - API Key 认证
/// - Session 管理
/// - SSE 流式响应
actor HTTPMCPServer {
    private var listener: NWListener?
    private var pathMonitor: NWPathMonitor?
    private var isRunning = false
    private var isListenerReady = false
    private var isRestarting = false
    private let port: Int
    private let host: String
    private let endpoint: String
    private var apiKey: String

    /// 用于创建 MCP.Server 的工厂闭包
    typealias ServerFactory = @Sendable (String, StatefulHTTPServerTransport) async -> MCP.Server

    private let serverFactory: ServerFactory

    /// Session 管理
    private var sessions: [String: SessionContext] = [:]

    struct SessionContext {
        let server: MCP.Server
        let transport: StatefulHTTPServerTransport
        let createdAt: Date
        var lastAccessedAt: Date
    }

    // MARK: - Init

    init(
        port: Int,
        host: String = "0.0.0.0",
        endpoint: String = "/mcp",
        apiKey: String,
        serverFactory: @escaping ServerFactory
    ) {
        self.port = port
        self.host = host
        self.endpoint = endpoint
        self.apiKey = apiKey
        self.serverFactory = serverFactory
    }

    // MARK: - Lifecycle

    var isServerRunning: Bool {
        isRunning
    }

    func start() async throws {
        guard !isRunning else { return }
        isRunning = true

        try createAndStartListener()
        startPathMonitoring()
        log.notice("HTTP MCP server started on \(self.host):\(self.port)\(self.endpoint)")
    }

    func stop() async {
        isRunning = false
        pathMonitor?.cancel()
        pathMonitor = nil
        listener?.cancel()
        listener = nil
        isListenerReady = false

        // 关闭所有 session
        for (sessionID, context) in sessions {
            await context.transport.disconnect()
            log.debug("Closed HTTP MCP session: \(sessionID)")
        }
        sessions.removeAll()

        log.info("HTTP MCP server stopped")
    }

    // MARK: - Listener 管理与网络恢复

    /// 创建并启动 NWListener
    private func createAndStartListener() throws {
        let parameters = NWParameters.tcp
        parameters.acceptLocalOnly = false  // 允许局域网访问
        parameters.includePeerToPeer = false

        if let tcpOptions = parameters.defaultProtocolStack.internetProtocol
            as? NWProtocolIP.Options
        {
            tcpOptions.version = .v4
        }

        guard let port = NWEndpoint.Port(rawValue: UInt16(self.port)) else {
            throw MCPError.internalError("Invalid port: \(self.port)")
        }

        let listener = try NWListener(using: parameters, on: port)
        self.listener = listener

        listener.stateUpdateHandler = { [weak self] state in
            Task { await self?.handleListenerState(state) }
        }

        listener.newConnectionHandler = { [weak self] connection in
            Task { @MainActor in
                guard let self else { return }
                await self.handleConnection(connection)
            }
        }

        listener.start(queue: .main)
    }

    /// 处理 listener 状态变化
    private func handleListenerState(_ state: NWListener.State) async {
        switch state {
        case .ready:
            isListenerReady = true
            log.info("HTTP MCP server ready on \(self.host):\(self.port)\(self.endpoint)")
        case .waiting(let error):
            isListenerReady = false
            log.warning("HTTP MCP server waiting: \(error.localizedDescription)")
        case .failed(let error):
            isListenerReady = false
            log.error("HTTP MCP server failed: \(error.localizedDescription)")
            // 失败后立即尝试重启（网络恢复后也会再触发一次）
            await restartListener()
        case .cancelled:
            isListenerReady = false
            log.info("HTTP MCP server cancelled")
        case .setup:
            log.debug("HTTP MCP server setting up...")
        @unknown default:
            log.debug("HTTP MCP server unknown state")
        }
    }

    /// 启动网络路径监控，检测断网重连
    private func startPathMonitoring() {
        guard pathMonitor == nil else { return }

        let monitor = NWPathMonitor()
        self.pathMonitor = monitor

        monitor.pathUpdateHandler = { [weak self] path in
            Task { await self?.handlePathUpdate(path) }
        }

        monitor.start(queue: .main)
    }

    /// 处理网络路径变化：网络恢复后自动重启 listener
    private func handlePathUpdate(_ path: NWPath) async {
        // 网络恢复且 listener 未就绪时，重启 listener
        if path.status == .satisfied {
            if isRunning, !isListenerReady {
                log.info("Network path restored, restarting HTTP MCP listener")
                await restartListener()
            }
        } else {
            // 网络断开：主动标记 listener 未就绪，
            // 即使 listener 未收到 .waiting/.failed 回调也能在恢复时重启
            isListenerReady = false
            log.warning("Network path unavailable")
        }
    }

    /// 重启 listener（带防抖，避免并发重复重启）
    private func restartListener() async {
        guard isRunning, !isRestarting else { return }
        isRestarting = true
        defer { isRestarting = false }

        listener?.cancel()
        listener = nil
        isListenerReady = false

        // 短暂等待旧 listener 完全释放端口
        try? await Task.sleep(for: .milliseconds(300))

        do {
            try createAndStartListener()
            log.notice("HTTP MCP listener restarted on \(self.host):\(self.port)")
        } catch {
            log.error("Failed to restart HTTP MCP listener: \(error.localizedDescription)")
        }
    }

    func updateAPIKey(_ newKey: String) {
        apiKey = newKey
        log.info("HTTP MCP server API key updated")
    }

    // MARK: - Connection Handling

    private func handleConnection(_ connection: NWConnection) async {
        connection.start(queue: .main)

        // 为每个连接单独处理（HTTP/1.1 默认支持 keep-alive，但这里简化处理）
        do {
            try await processHTTPConnection(connection)
        } catch {
            log.debug("HTTP connection error: \(error.localizedDescription)")
        }

        connection.cancel()
    }

    private func processHTTPConnection(_ connection: NWConnection) async throws {
        // 读取完整的 HTTP 请求
        let requestData = try await readHTTPRequest(connection)

        guard let request = parseHTTPRequest(requestData) else {
            try await sendHTTPResponse(
                connection,
                statusCode: 400,
                headers: ["Content-Type": "application/json"],
                body: jsonErrorBody(code: -32700, message: "Bad Request: Unable to parse HTTP request")
            )
            return
        }

        // 验证 endpoint 路径
        let requestPath = request.path ?? "/"
        guard requestPath == endpoint else {
            try await sendHTTPResponse(
                connection,
                statusCode: 404,
                headers: ["Content-Type": "application/json"],
                body: jsonErrorBody(code: -32000, message: "Not Found: \(requestPath)")
            )
            return
        }

        // 构建验证管道
        let validationPipeline = StandardValidationPipeline(validators: [
            APIKeyValidator(apiKey: apiKey),
            AcceptHeaderValidator(mode: .sseRequired),
            ContentTypeValidator(),
            ProtocolVersionValidator(),
            SessionValidator(),
        ])

        // 获取 session ID（从请求头）
        let sessionID = request.header(HTTPHeaderName.sessionID)

        // 路由到现有 session
        if let sessionID, var session = sessions[sessionID] {
            session.lastAccessedAt = Date()
            sessions[sessionID] = session

            let response = await session.transport.handleRequest(request)
            try await sendHTTPResponse(connection, response: response)

            // DELETE 请求后清理 session
            if request.method.uppercased() == "DELETE" && response.statusCode == 200 {
                sessions.removeValue(forKey: sessionID)
            }
            return
        }

        // 检查是否为初始化请求
        if request.method.uppercased() == "POST",
            let body = request.body,
            let kind = JSONRPCMessageKind(data: body),
            kind.isInitializeRequest
        {
            let newSessionID = UUID().uuidString

            let transport = StatefulHTTPServerTransport(
                sessionIDGenerator: FixedSessionIDGenerator(sessionID: newSessionID),
                validationPipeline: validationPipeline,
                logger: nil
            )

            do {
                let server = await serverFactory(newSessionID, transport)
                try await server.start(transport: transport)

                sessions[newSessionID] = SessionContext(
                    server: server,
                    transport: transport,
                    createdAt: Date(),
                    lastAccessedAt: Date()
                )

                let response = await transport.handleRequest(request)

                // 如果初始化失败，清理 session
                if case .error = response {
                    sessions.removeValue(forKey: newSessionID)
                    await transport.disconnect()
                }

                try await sendHTTPResponse(connection, response: response)
            } catch {
                await transport.disconnect()
                try await sendHTTPResponse(
                    connection,
                    statusCode: 500,
                    headers: ["Content-Type": "application/json"],
                    body: jsonErrorBody(code: -32603, message: "Internal error: \(error.localizedDescription)")
                )
            }
            return
        }

        // 无 session 且非初始化请求
        if sessionID != nil {
            try await sendHTTPResponse(
                connection,
                statusCode: 404,
                headers: ["Content-Type": "application/json"],
                body: jsonErrorBody(code: -32000, message: "Not Found: Session not found or expired")
            )
        } else {
            try await sendHTTPResponse(
                connection,
                statusCode: 400,
                headers: ["Content-Type": "application/json"],
                body: jsonErrorBody(code: -32600, message: "Bad Request: Missing MCP-Session-Id header")
            )
        }
    }

    // MARK: - HTTP Read/Write Helpers

    /// 构建 JSON-RPC 错误响应体
    private func jsonErrorBody(code: Int, message: String) -> Data {
        // 转义 message 中的特殊 JSON 字符
        let escapedMessage = message
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\t", with: "\\t")
        let json = """
            {"jsonrpc":"2.0","error":{"code":\(code),"message":"\(escapedMessage)"},"id":null}
            """
        return json.data(using: .utf8) ?? Data()
    }

    /// 从连接中读取完整的 HTTP 请求数据
    private func readHTTPRequest(_ connection: NWConnection) async throws -> Data {
        var accumulatedData = Data()
        let headerDelimiter = Data([0x0D, 0x0A, 0x0D, 0x0A])  // \r\n\r\n

        // 先读取请求头
        while true {
            let chunk = try await readFromConnection(connection, maxLength: 4096)
            guard !chunk.isEmpty else { break }
            accumulatedData.append(chunk)

            // 找到 header 结束标记
            if accumulatedData.range(of: headerDelimiter) != nil {
                break
            }
        }

        // 查找 Content-Length（如果 header 不完整则返回已有数据，由 parseHTTPRequest 返回 nil 处理）
        guard let headerRange = accumulatedData.range(of: headerDelimiter) else {
            return accumulatedData
        }
        let headerEnd = headerRange.upperBound
        let headerData = accumulatedData[..<headerEnd]
        let headerString = String(data: headerData, encoding: .utf8) ?? ""

        var contentLength = 0
        for line in headerString.components(separatedBy: "\r\n") {
            if line.lowercased().hasPrefix("content-length:") {
                let value = line.dropFirst(15).trimmingCharacters(in: .whitespaces)
                contentLength = Int(value) ?? 0
            }
        }

        // 读取 body（如果有）
        var remainingBody = contentLength - (accumulatedData.count - headerEnd)
        while remainingBody > 0 {
            let chunk = try await readFromConnection(connection, maxLength: max(remainingBody, 1024))
            guard !chunk.isEmpty else { break }
            accumulatedData.append(chunk)
            remainingBody -= chunk.count
        }

        return accumulatedData
    }

    /// 从 NWConnection 读取数据
    private func readFromConnection(_ connection: NWConnection, maxLength: Int) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            connection.receive(
                minimumIncompleteLength: 1,
                maximumLength: maxLength
            ) { data, _, isComplete, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let data {
                    continuation.resume(returning: data)
                } else if isComplete {
                    continuation.resume(returning: Data())
                } else {
                    continuation.resume(returning: Data())
                }
            }
        }
    }

    /// 解析原始 HTTP 请求数据为 HTTPRequest
    private func parseHTTPRequest(_ data: Data) -> HTTPRequest? {
        let headerDelimiter = Data([0x0D, 0x0A, 0x0D, 0x0A])
        guard let headerRange = data.range(of: headerDelimiter) else {
            return nil
        }

        let headerData = data[..<headerRange.lowerBound]
        let bodyData = data[headerRange.upperBound...]

        guard let headerString = String(data: headerData, encoding: .utf8) else {
            return nil
        }

        let lines = headerString.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }

        let requestParts = requestLine.components(separatedBy: " ")
        guard requestParts.count >= 2 else { return nil }

        let method = requestParts[0]
        let path = requestParts[1]

        // 解析 headers
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colonIndex = line.firstIndex(of: ":") else { continue }
            let name = line[..<colonIndex].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: colonIndex)...].trimmingCharacters(in: .whitespaces)

            // 合并重复 header 值
            if let existing = headers[name] {
                headers[name] = existing + ", " + value
            } else {
                headers[name] = value
            }
        }

        let body: Data? = bodyData.isEmpty ? nil : Data(bodyData)

        return HTTPRequest(
            method: method,
            headers: headers,
            body: body,
            path: path
        )
    }

    /// 发送 HTTPResponse
    private func sendHTTPResponse(_ connection: NWConnection, response: HTTPResponse) async throws {
        switch response {
        case .stream(let sseStream, let headers):
            try await sendSSEStreamResponse(connection, headers: headers, stream: sseStream)
        default:
            let statusCode = response.statusCode
            let headers = response.headers
            let body = response.bodyData
            try await sendHTTPResponse(connection, statusCode: statusCode, headers: headers, body: body)
        }
    }

    /// 发送标准 HTTP 响应
    private func sendHTTPResponse(
        _ connection: NWConnection,
        statusCode: Int,
        headers: [String: String],
        body: Data?
    ) async throws {
        var responseString = "HTTP/1.1 \(statusCode) \(HTTPStatusReason.string(for: statusCode))\r\n"

        var allHeaders = headers
        if let body, allHeaders["Content-Length"] == nil {
            allHeaders["Content-Length"] = "\(body.count)"
        }
        if allHeaders["Connection"] == nil {
            allHeaders["Connection"] = "close"
        }

        for (name, value) in allHeaders {
            responseString += "\(name): \(value)\r\n"
        }
        responseString += "\r\n"

        var responseData = Data(responseString.utf8)
        if let body {
            responseData.append(body)
        }

        try await sendAll(connection, data: responseData)
    }

    /// 发送 SSE 流式响应
    private func sendSSEStreamResponse(
        _ connection: NWConnection,
        headers: [String: String],
        stream: AsyncThrowingStream<Data, Swift.Error>
    ) async throws {
        let statusCode = 200
        var responseString = "HTTP/1.1 \(statusCode) \(HTTPStatusReason.string(for: statusCode))\r\n"

        var allHeaders = headers
        if allHeaders["Connection"] == nil {
            allHeaders["Connection"] = "close"
        }
        // 使用 chunked 传输编码来支持流式 SSE
        allHeaders["Transfer-Encoding"] = "chunked"

        for (name, value) in allHeaders {
            responseString += "\(name): \(value)\r\n"
        }
        responseString += "\r\n"

        // 先发送响应头
        try await sendAll(connection, data: Data(responseString.utf8))

        // 然后流式发送 SSE 事件（使用 chunked encoding）
        do {
            for try await chunk in stream {
                // Chunked encoding: <hex size>\r\n<data>\r\n
                let sizeHex = String(chunk.count, radix: 16).uppercased()
                var chunkedData = Data("\(sizeHex)\r\n".utf8)
                chunkedData.append(chunk)
                chunkedData.append(Data("\r\n".utf8))

                try await sendAll(connection, data: chunkedData)
            }
            // 发送结束 chunk
            try await sendAll(connection, data: Data("0\r\n\r\n".utf8))
        } catch {
            log.debug("SSE stream interrupted: \(error.localizedDescription)")
        }
    }

    /// 发送所有数据
    private func sendAll(_ connection: NWConnection, data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(
                content: data,
                completion: .contentProcessed { error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume()
                    }
                }
            )
        }
    }
}

// MARK: - FixedSessionIDGenerator

/// 固定 session ID 生成器，用于在 HTTPApp 层面控制 session ID
private struct FixedSessionIDGenerator: SessionIDGenerator {
    let sessionID: String
    func generateSessionID() -> String { sessionID }
}

// MARK: - HTTP Status Reason

/// HTTP 状态码对应的原因短语
private enum HTTPStatusReason {
    static func string(for code: Int) -> String {
        switch code {
        case 200: return "OK"
        case 202: return "Accepted"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        case 405: return "Method Not Allowed"
        case 406: return "Not Acceptable"
        case 409: return "Conflict"
        case 415: return "Unsupported Media Type"
        case 421: return "Misdirected Request"
        case 500: return "Internal Server Error"
        default: return "Unknown"
        }
    }
}

// MARK: - JSON-RPC Message Kind (Re-exported)

/// 从 MCP SDK 获取的 JSON-RPC 消息类型分类器
/// (此类型在 MCP SDK 中是 package 级别，这里重新声明以用于 HTTP 路由)
private enum JSONRPCMessageKind {
    case request(id: String, method: String)
    case notification(method: String)
    case response(id: String)

    init?(data: Data) {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        let id = Self.extractID(from: json)

        if let method = json["method"] as? String {
            if let id {
                self = .request(id: id, method: method)
            } else {
                self = .notification(method: method)
            }
        } else if json["result"] != nil || json["error"] != nil {
            guard let id else { return nil }
            self = .response(id: id)
        } else {
            return nil
        }
    }

    var isInitializeRequest: Bool {
        if case .request(_, let method) = self {
            return method == "initialize"
        }
        return false
    }

    private static func extractID(from json: [String: Any]) -> String? {
        if let stringID = json["id"] as? String {
            return stringID
        } else if let intID = json["id"] as? Int {
            return String(intID)
        }
        return nil
    }
}
