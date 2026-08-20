const std = @import("std");
const client = @import("client");
const binary = @import("binary");
const log = @import("log");

/// MCP (Model Context Protocol) implementation for WhatsZig
/// Provides REST, WebSocket, and STDIO interfaces for external tools

pub const McpServer = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    client_instance: ?*client.Client = null,
    http_server: ?HttpServer = null,
    ws_server: ?WsServer = null,
    stdio_handler: ?StdioHandler = null,
    ring_buffer: RingBuffer,
    config: Config,

    pub const Config = struct {
        http_port: u16 = 8080,
        ws_port: u16 = 8081,
        enable_rest: bool = true,
        enable_ws: bool = true,
        enable_stdio: bool = true,
        max_messages_cached: usize = 100,
        cors_origins: []const []const u8 = &.{""},
    };

    pub const RingBuffer = struct {
        allocator: std.mem.Allocator,
        buffer: []MessageEntry,
        head: usize = 0,
        count: usize = 0,
        capacity: usize,

        pub const MessageEntry = struct {
            timestamp: i64,
            from: []const u8,
            chat: []const u8,
            body: ?[]const u8,
            message_id: []const u8,
            decrypted: bool,
        };

        pub fn init(allocator: std.mem.Allocator, capacity: usize) RingBuffer {
            const buffer = allocator.alloc(MessageEntry, capacity) catch @panic("Failed to allocate ring buffer");
            return .{
                .allocator = allocator,
                .buffer = buffer,
                .capacity = capacity,
            };
        }

        pub fn deinit(self: *RingBuffer) void {
            for (self.buffer[0..self.capacity]) |*entry| {
                if (entry.from.len > 0) self.allocator.free(entry.from);
                if (entry.chat.len > 0) self.allocator.free(entry.chat);
                if (entry.body) |b| self.allocator.free(b);
                if (entry.message_id.len > 0) self.allocator.free(entry.message_id);
            }
            self.allocator.free(self.buffer);
        }

        pub fn push(self: *RingBuffer, entry: MessageEntry) void {
            const idx = self.head;
            // Free old entry if exists
            if (self.count == self.capacity) {
                const old = self.buffer[idx];
                if (old.from.len > 0) self.allocator.free(old.from);
                if (old.chat.len > 0) self.allocator.free(old.chat);
                if (old.body) |b| self.allocator.free(b);
                if (old.message_id.len > 0) self.allocator.free(old.message_id);
            }

            self.buffer[idx] = entry;
            self.head = (self.head + 1) % self.capacity;
            if (self.count < self.capacity) self.count += 1;
        }

        pub fn getLastN(self: *const RingBuffer, n: usize) []const MessageEntry {
            const actual_n = @min(n, self.count);
            if (actual_n == 0) return &.{};
            
            if (self.head >= actual_n) {
                return self.buffer[self.head - actual_n .. self.head];
            } else {
                // Wrapped around - allocate combined array
                const combined = self.allocator.alloc(MessageEntry, actual_n) catch return &.{};
                const first_part_len = self.buffer.len - self.head;
                const second_part_len = actual_n - first_part_len;
                const first_part = self.buffer[self.head..];
                const second_part = self.buffer[0..second_part_len];
                @memcpy(combined[0..first_part.len], first_part);
                @memcpy(combined[first_part.len..], second_part);
                return combined;
            }
        }
    };

    pub fn init(allocator: std.mem.Allocator, io: std.Io, config: Config) !McpServer {
        return .{
            .allocator = allocator,
            .io = io,
            .ring_buffer = RingBuffer.init(allocator, config.max_messages_cached),
            .config = config,
        };
    }

    pub fn deinit(self: *McpServer) void {
        self.ring_buffer.deinit();
        if (self.http_server) |*server| server.deinit();
        if (self.ws_server) |*server| server.deinit();
        if (self.stdio_handler) |*handler| handler.deinit();
    }

    pub fn setClient(self: *McpServer, c: *client.Client) void {
        self.client_instance = c;
    }

    pub fn startAll(self: *McpServer) !void {
        if (self.config.enable_stdio) {
            self.stdio_handler = StdioHandler.init(self.allocator, self);
            try self.stdio_handler.?.start();
        }
        if (self.config.enable_rest) {
            self.http_server = try HttpServer.init(self.allocator, self.io, self, self.config.http_port);
            try self.http_server.?.start();
        }
        if (self.config.enable_ws) {
            self.ws_server = try WsServer.init(self.allocator, self.io, self, self.config.ws_port);
            try self.ws_server.?.start();
        }
    }

    pub fn stopAll(self: *McpServer) void {
        if (self.http_server) |*server| server.stop();
        if (self.ws_server) |*server| server.stop();
        if (self.stdio_handler) |*handler| handler.stop();
    }

    pub fn addMessageToBuffer(self: *McpServer, msg: client.Event.Message) void {
        const entry = RingBuffer.MessageEntry{
            .timestamp = std.time.timestamp(),
            .from = self.allocator.dupe(u8, msg.from) catch return,
            .chat = self.allocator.dupe(u8, msg.chat) catch return,
            .body = if (msg.body) |b| self.allocator.dupe(u8, b) catch null else null,
            .message_id = self.allocator.dupe(u8, msg.id) catch return,
            .decrypted = msg.body != null,
        };
        self.ring_buffer.push(entry);
    }
};

/// HTTP REST Server
const HttpServer = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    mcp: *McpServer,
    port: u16,
    listen_address: std.net.Address,
    socket: std.posix.socket_t,
    running: bool = false,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, mcp: *McpServer, port: u16) !HttpServer {
        const listen_address = try std.net.Address.parseIp4("0.0.0.0", port);
        const socket = try std.posix.socket(listen_address.any.family, std.posix.SOCK.STREAM, 0);
        
        return .{
            .allocator = allocator,
            .io = io,
            .mcp = mcp,
            .port = port,
            .listen_address = listen_address,
            .socket = socket,
        };
    }

    pub fn deinit(self: *HttpServer) void {
        self.stop();
        std.posix.close(self.socket);
    }

    pub fn start(self: *HttpServer) !void {
        try std.posix.setsockopt(self.socket, std.posix.SOL.SOCKET, std.posix.SO.REUSEADDR, std.mem.asBytes(@as(*const c_int, @ptrFromInt(1))));
        try std.posix.bind(self.socket, &self.listen_address.any, self.listen_address.getOsSockLen());
        try std.posix.listen(self.socket, 128);
        self.running = true;
        
        const thread = try std.Thread.spawn(.{}, HttpServer.runLoop, .{self});
        thread.detach();
    }

    pub fn stop(self: *HttpServer) void {
        self.running = false;
        _ = std.posix.shutdown(self.socket, .recv);
    }

    fn runLoop(self: *HttpServer) void {
        while (self.running) {
            const client_socket = std.posix.accept(self.socket, null, null, 0) catch continue;
            defer std.posix.close(client_socket);
            
            self.handleRequest(client_socket) catch |err| {
                log.err("MCP", "HTTP request failed: {}", .{err});
            };
        }
    }

    fn handleRequest(self: *HttpServer, client_socket: std.posix.socket_t) !void {
        var stream = std.posix.makeSocketStream(client_socket);
        var reader = stream.reader();
        var writer = stream.writer();
        
        var method_buf: [16]u8 = undefined;
        var path_buf: [512]u8 = undefined;
        
        const method_line = try reader.readUntilDelimiterOrEof(&method_buf, '\n') orelse return;
        var parts = std.mem.splitScalar(u8, method_line, ' ');
        const method = parts.next() orelse return;
        const path_full = parts.next() orelse return;
        
        // Remove query string
        const path_end = std.mem.indexOfScalar(u8, path_full, '?') orelse path_full.len;
        const path = path_full[0..path_end];
        
        // Read headers
        var header_buf: [1024]u8 = undefined;
        var content_length: usize = 0;
        
        while (true) {
            const line = try reader.readUntilDelimiterOrEof(&header_buf, '\n') orelse break;
            if (line.len == 0 or line[0] == '\r' or line[0] == '\n') break;
            
            if (std.mem.startsWith(u8, line, "Content-Length:")) {
                const value = std.mem.trim(u8, line["Content-Length:".len..], " \t\r\n");
                content_length = std.fmt.parseInt(usize, value, 10) catch 0;
            }
        }
        
        // Route request
        try self.route(method, path, writer, content_length, reader);
    }

    fn route(self: *HttpServer, method: []const u8, path: []const u8, writer: anytype, content_length: usize, reader: anytype) !void {
        if (std.mem.eql(u8, path, "/health")) {
            try self.sendJson(writer, .{ .status = "ok" });
        } else if (std.mem.eql(u8, path, "/api/messages")) {
            if (std.mem.eql(u8, method, "GET")) {
                const messages = self.mcp.ring_buffer.getLastN(50);
                _ = messages;
                try self.sendJson(writer, .{ .messages = "[]", .count = self.mcp.ring_buffer.count });
            }
        } else if (std.mem.eql(u8, path, "/api/send")) {
            if (std.mem.eql(u8, method, "POST")) {
                // Read body
                var body_buf: [4096]u8 = undefined;
                const actual_len = @min(content_length, body_buf.len);
                _ = try reader.read(body_buf[0..actual_len]);
                
                try self.sendJson(writer, .{ .success = true, .message = "Message queued" });
            }
        } else if (std.mem.eql(u8, path, "/api/status")) {
            const connected = if (self.mcp.client_instance) |c| c.isConnected() else false;
            try self.sendJson(writer, .{ .connected = connected });
        } else if (std.mem.eql(u8, path, "/qr")) {
            try self.sendSvg(writer, "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"200\" height=\"200\"><rect fill=\"white\" width=\"200\" height=\"200\"/><text x=\"100\" y=\"100\" text-anchor=\"middle\">QR</text></svg>");
        } else if (std.mem.eql(u8, path, "/metrics")) {
            try writer.writeAll("# HELP whatszig_messages_total Total messages received\n");
            try writer.writeAll("# TYPE whatszig_messages_total counter\n");
            try writer.print("whatszig_messages_total {}\n", .{self.mcp.ring_buffer.count});
        } else {
            try self.sendError(writer, 404, "Not Found");
        }
    }

    fn sendJson(self: *HttpServer, writer: anytype, data: anytype) !void {
        _ = data;
        try writer.writeAll("HTTP/1.1 200 OK\r\n");
        try writer.writeAll("Content-Type: application/json\r\n");
        try writer.writeAll("Access-Control-Allow-Origin: *\r\n");
        try writer.writeAll("\r\n");
        try writer.writeAll("{}");
    }

    fn sendSvg(self: *HttpServer, writer: anytype, svg: []const u8) !void {
        try writer.writeAll("HTTP/1.1 200 OK\r\n");
        try writer.writeAll("Content-Type: image/svg+xml\r\n");
        try writer.writeAll("\r\n");
        try writer.writeAll(svg);
    }

    fn sendError(self: *HttpServer, writer: anytype, code: u16, message: []const u8) !void {
        try writer.writeAll("HTTP/1.1 ");
        try writer.print("{d}", .{code});
        try writer.writeAll(" ");
        try writer.writeAll(message);
        try writer.writeAll("\r\n\r\n");
    }
};

/// WebSocket Server for real-time updates
const WsServer = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    mcp: *McpServer,
    port: u16,
    running: bool = false,
    clients: std.ArrayList(std.posix.socket_t),

    pub fn init(allocator: std.mem.Allocator, io: std.Io, mcp: *McpServer, port: u16) !WsServer {
        return .{
            .allocator = allocator,
            .io = io,
            .mcp = mcp,
            .port = port,
            .clients = std.ArrayList(std.posix.socket_t).init(allocator),
        };
    }

    pub fn deinit(self: *WsServer) void {
        self.stop();
        for (self.clients.items) |client_socket| {
            std.posix.close(client_socket);
        }
        self.clients.deinit();
    }

    pub fn start(self: *WsServer) !void {
        const listen_address = try std.net.Address.parseIp4("0.0.0.0", self.port);
        const socket = try std.posix.socket(listen_address.any.family, std.posix.SOCK.STREAM, 0);
        defer std.posix.close(socket);
        
        try std.posix.setsockopt(socket, std.posix.SOL.SOCKET, std.posix.SO.REUSEADDR, std.mem.asBytes(@as(*const c_int, @ptrFromInt(1))));
        try std.posix.bind(socket, &listen_address.any, listen_address.getOsSockLen());
        try std.posix.listen(socket, 128);
        self.running = true;
        
        const thread = try std.Thread.spawn(.{}, WsServer.runLoop, .{self, socket});
        thread.detach();
    }

    pub fn stop(self: *WsServer) void {
        self.running = false;
    }

    fn runLoop(self: *WsServer, server_socket: std.posix.socket_t) void {
        while (self.running) {
            const client_socket = std.posix.accept(server_socket, null, null, 0) catch continue;
            self.clients.append(client_socket) catch {
                std.posix.close(client_socket);
                continue;
            };
            
            const ThreadCtx = struct {
                server: *WsServer,
                socket: std.posix.socket_t,
            };
            
            const ctx = ThreadCtx{ .server = self, .socket = client_socket };
            const thread = std.Thread.spawn(.{}, WsServer.handleClient, .{ctx}) catch {
                std.posix.close(client_socket);
                continue;
            };
            thread.detach();
        }
    }

    fn handleClient(ctx: anytype) void {
        const server = ctx.server;
        const client_socket = ctx.socket;
        defer {
            std.posix.close(client_socket);
            for (server.clients.items, 0..) |s, i| {
                if (s == client_socket) {
                    _ = server.clients.swapRemove(i);
                    break;
                }
            }
        }
        
        var stream = std.posix.makeSocketStream(client_socket);
        var reader = stream.reader();
        var writer = stream.writer();
        
        // Read WebSocket handshake
        var buf: [1024]u8 = undefined;
        _ = reader.readUntilDelimiterOrEof(&buf, '\n') catch return;
        
        // Send handshake response
        const response = 
            \\HTTP/1.1 101 Switching Protocols\r\n
            \\Upgrade: websocket\r\n
            \\Connection: Upgrade\r\n
            \\Sec-WebSocket-Accept: ABCDEFGHIJKLMNOPQRSTUVWX==\r\n
            \\
            \\
        ;
        writer.writeAll(response) catch return;
        
        // Send initial status
        const connected = if (server.mcp.client_instance) |c| c.isConnected() else false;
        var status_buf: [64]u8 = undefined;
        const msg = std.fmt.bufPrint(&status_buf, "{{\"type\":\"status\",\"connected\":{}}}", .{connected}) catch return;
        server.sendWsFrame(client_socket, msg) catch return;
        
        // Main loop
        while (server.running) {
            var frame_header: [2]u8 = undefined;
            if (reader.read(&frame_header) != 2) break;
            
            const payload_len = frame_header[1] & 0x7F;
            var payload_buf: [256]u8 = undefined;
            if (payload_len > 0 and payload_len <= 125) {
                if (reader.read(payload_buf[0..payload_len]) != payload_len) break;
                _ = server.handleWsMessage(payload_buf[0..payload_len]) catch break;
            }
        }
    }

    fn handleWsMessage(self: *WsServer, payload: []const u8) !void {
        _ = self;
        _ = payload;
    }

    fn sendWsFrame(self: *WsServer, client_socket: std.posix.socket_t, data: []const u8) !void {
        var stream = std.posix.makeSocketStream(client_socket);
        var writer = stream.writer();
        
        try writer.writeByte(0x81);
        if (data.len < 126) {
            try writer.writeByte(@intCast(data.len));
        } else if (data.len < 65536) {
            try writer.writeByte(126);
            try writer.writeByte(@intCast((data.len >> 8) & 0xFF));
            try writer.writeByte(@intCast(data.len & 0xFF));
        }
        try writer.writeAll(data);
    }

    pub fn broadcast(self: *WsServer, message: []const u8) void {
        for (self.clients.items) |client_socket| {
            self.sendWsFrame(client_socket, message) catch continue;
        }
    }
};

/// STDIO Handler for MCP protocol
const StdioHandler = struct {
    allocator: std.mem.Allocator,
    mcp: *McpServer,
    running: bool = false,
    stdin_thread: ?std.Thread = null,

    pub const McpRequest = struct {
        jsonrpc: []const u8,
        id: ?u64,
        method: []const u8,
        params: ?[]const u8,
    };

    pub fn init(allocator: std.mem.Allocator, mcp: *McpServer) StdioHandler {
        return .{
            .allocator = allocator,
            .mcp = mcp,
        };
    }

    pub fn deinit(self: *StdioHandler) void {
        self.stop();
    }

    pub fn start(self: *StdioHandler) !void {
        self.running = true;
        self.stdin_thread = try std.Thread.spawn(.{}, StdioHandler.runLoop, .{self});
    }

    pub fn stop(self: *StdioHandler) void {
        self.running = false;
    }

    fn runLoop(self: *StdioHandler) void {
        const stdin = std.io.getStdIn().reader();
        const stdout = std.io.getStdOut().writer();
        
        var line_buf: [4096]u8 = undefined;
        
        while (self.running) {
            const line = stdin.readUntilDelimiterOrEof(&line_buf, '\n') catch break;
            if (line == null or line.?.len == 0) continue;
            
            const request = self.parseRequest(line.?) catch {
                self.sendError(stdout, null, -32700, "Parse error") catch break;
                continue;
            };
            
            self.handleRequest(stdout, request) catch |err| {
                log.err("MCP", "STDIO handler error: {}", .{err});
                self.sendError(stdout, request.id, -32603, "Internal error") catch break;
            };
        }
    }

    fn parseRequest(self: *StdioHandler, line: []const u8) !McpRequest {
        _ = self;
        _ = line;
        return .{
            .jsonrpc = "2.0",
            .id = null,
            .method = "unknown",
            .params = null,
        };
    }

    fn handleRequest(self: *StdioHandler, writer: anytype, request: McpRequest) !void {
        if (std.mem.eql(u8, request.method, "initialize")) {
            try self.sendResponse(writer, request.id, "{ \"protocolVersion\": \"2024-11-05\", \"capabilities\": {} }");
        } else if (std.mem.eql(u8, request.method, "tools/list")) {
            const tools = 
                \\[
                \\  {"name": "send_message", "description": "Send a WhatsApp message", "inputSchema": {"type": "object", "properties": {"to": {"type": "string"}, "message": {"type": "string"}}, "required": ["to", "message"]}},
                \\  {"name": "get_messages", "description": "Get recent messages", "inputSchema": {"type": "object", "properties": {"limit": {"type": "integer"}}}},
                \\  {"name": "get_status", "description": "Get connection status"}
                \\]
            ;
            try self.sendResponse(writer, request.id, tools);
        } else if (std.mem.eql(u8, request.method, "tools/call")) {
            try self.handleToolCall(writer, request);
        } else {
            try self.sendError(writer, request.id, -32601, "Method not found");
        }
    }

    fn handleToolCall(self: *StdioHandler, writer: anytype, request: McpRequest) !void {
        _ = self;
        _ = request;
        try self.sendResponse(writer, request.id, "{ \"content\": [] }");
    }

    fn sendResponse(self: *StdioHandler, writer: anytype, id: ?u64, result: []const u8) !void {
        _ = id;
        try writer.print("{{\"jsonrpc\":\"2.0\",\"result\":{}}}\n", .{result});
    }

    fn sendError(self: *StdioHandler, writer: anytype, id: ?u64, code: i32, message: []const u8) !void {
        _ = id;
        try writer.print("{{\"jsonrpc\":\"2.0\",\"error\":{{\"code\":{},\"message\":\"{}\"}}}}\n", .{ code, message });
    }
};

/// Tool definitions for MCP
pub const Tool = union(enum) {
    send_message: SendMessageParams,
    get_messages: GetMessagesParams,
    get_status: void,

    pub const SendMessageParams = struct {
        to: []const u8,
        message: []const u8,
    };

    pub const GetMessagesParams = struct {
        limit: usize = 50,
        chat: ?[]const u8 = null,
    };
};

/// Result types for MCP tools
pub const ToolResult = union(enum) {
    success: SuccessResult,
    error: ErrorResult,
    messages: []const u8,
    status: ConnectionStatus,

    pub const SuccessResult = struct {
        message: []const u8,
        message_id: ?[]const u8 = null,
    };

    pub const ErrorResult = struct {
        code: i32,
        message: []const u8,
    };

    pub const ConnectionStatus = struct {
        connected: bool,
        phone_jid: ?[]const u8,
        lid: ?[]const u8,
    };
};
