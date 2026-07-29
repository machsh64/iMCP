import Foundation
import MCP

/// 使用 API Key 验证 HTTP 请求的自定义验证器。
///
/// 支持两种认证方式：
/// - `Authorization: Bearer <key>`（标准方式，兼容 MCP 客户端）
/// - `x-api-key: <key>`（简化方式，用于工具链集成）
struct APIKeyValidator: HTTPRequestValidator {
    private let apiKey: String

    init(apiKey: String) {
        self.apiKey = apiKey
    }

    func validate(_ request: HTTPRequest, context: HTTPValidationContext) -> HTTPResponse? {
        // 支持 Authorization: Bearer <key>
        if let auth = request.header("Authorization"),
            auth.hasPrefix("Bearer ")
        {
            let token = String(auth.dropFirst(7))
            if token == apiKey {
                return nil
            }
            return .error(
                statusCode: 401,
                .invalidRequest("Unauthorized: Invalid API key"),
                sessionID: context.sessionID
            )
        }

        // 支持 x-api-key 头（简化方式）
        if let apiKeyHeader = request.header("x-api-key") {
            if apiKeyHeader == apiKey {
                return nil
            }
            return .error(
                statusCode: 401,
                .invalidRequest("Unauthorized: Invalid API key"),
                sessionID: context.sessionID
            )
        }

        // 未提供任何认证信息
        return .error(
            statusCode: 401,
            .invalidRequest(
                "Unauthorized: Missing API key. Use 'Authorization: Bearer <key>' or 'x-api-key' header"
            ),
            sessionID: context.sessionID
        )
    }
}
