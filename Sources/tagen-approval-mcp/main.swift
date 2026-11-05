import Foundation
import TagenAgents

// stdio MCP server used as Claude Code's --permission-prompt-tool.
// Usage: tagen-approval-mcp --socket <path> --token-env TAGEN_RELAY_TOKEN
var socketPath: String?
var token = ProcessInfo.processInfo.environment["TAGEN_RELAY_TOKEN"] ?? ""
var args = CommandLine.arguments.dropFirst().makeIterator()
while let a = args.next() {
    switch a {
    case "--socket": socketPath = args.next()
    case "--token-env": if let n = args.next() { token = ProcessInfo.processInfo.environment[n] ?? token }
    default: break
    }
}
guard let socketPath, !token.isEmpty else {
    FileHandle.standardError.write(Data("tagen-approval-mcp: --socket and relay token are required\n".utf8))
    exit(2)
}
ApprovalMCPServer(socketPath: socketPath, token: token).runStdio()
