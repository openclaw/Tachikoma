struct JSONRPCNotification<P: Encodable>: Encodable {
    let jsonrpc: String
    let method: String
    let params: P
}

struct JSONRPCResponse<R: Decodable>: Decodable {
    let jsonrpc: String
    let result: R?
    let error: JSONRPCError?
    let id: JSONRPCID?
}

struct JSONRPCResponseHeader: Decodable {
    let id: JSONRPCID?
    let method: String?

    var responseID: JSONRPCID? {
        self.method == nil ? self.id : nil
    }
}

enum JSONRPCID: Decodable, Equatable {
    case int(Int)
    case string(String)
    case null
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let i = try? container.decode(Int.self) {
            self = .int(i)
            return
        }
        if let s = try? container.decode(String.self) {
            self = .string(s)
            return
        }
        if container.decodeNil() {
            self = .null
            return
        }
        throw DecodingError.typeMismatch(
            JSONRPCID.self,
            .init(codingPath: decoder.codingPath, debugDescription: "Unsupported id type"),
        )
    }
}

struct JSONRPCError: Decodable {
    let code: Int
    let message: String
}

/// Shared JSON-RPC types for HTTP transport
struct HTTPJSONRPCRequest<P: Encodable>: Encodable {
    let jsonrpc = "2.0"
    let method: String
    let params: P
    let id: Int
}
