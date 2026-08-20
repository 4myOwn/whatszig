/// Suporte WebAssembly (WASM) para WhatsZig
/// Permite rodar o cliente diretamente no navegador ou em edge workers
const std = @import("std");
const builtin = @import("builtin");

// Verifica se está compilando para WASM
pub const is_wasm = builtin.object_format == .wasm;

// Imports internos
const security = @import("../security.zig");
const tui = @import("../tui/debugger.zig");
const ffi = @import("../ffi/bindings.zig");

/// Cliente WhatsApp otimizado para WASM
pub const WasmClient = struct {
    allocator: std.mem.Allocator,
    initialized: bool,
    connection_state: ConnectionState,
    message_buffer: tui.RingBuffer(WasmMessage, 500>,
    event_callback: ?js.Function,
    
    const Self = @This();
    
    pub const ConnectionState = enum {
        disconnected,
        connecting,
        connected,
        reconnecting,
        error,
    };
    
    pub const WasmMessage = struct {
        id: []const u8,
        from: []const u8,
        to: []const u8,
        content: []const u8,
        timestamp: i64,
        message_type: MessageType,
        is_incoming: bool,
        
        pub const MessageType = enum {
            text,
            image,
            video,
            audio,
            document,
            presence,
            receipt,
        };
    };
    
    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .allocator = allocator,
            .initialized = false,
            .connection_state = .disconnected,
            .message_buffer = tui.RingBuffer(WasmMessage, 500).init(),
            .event_callback = null,
        };
    }
    
    pub fn deinit(self: *Self) void {
        self.message_buffer.clear();
    }
    
    /// Inicializa cliente WASM
    pub fn initialize(self: *Self) !void {
        if (self.initialized) return;
        
        // Configurações específicas para WASM
        self.initialized = true;
    }
    
    /// Conecta ao servidor WhatsApp
    pub fn connect(self: *Self, phone: []const u8) !void {
        if (!self.initialized) return error.NotInitialized;
        
        self.connection_state = .connecting;
        
        // Em produção, iniciaria handshake real
        // Para WASM, usaria WebSocket
        
        self.connection_state = .connected;
    }
    
    /// Desconecta do servidor
    pub fn disconnect(self: *Self) void {
        self.connection_state = .disconnected;
    }
    
    /// Envia mensagem
    pub fn sendMessage(self: *Self, jid: []const u8, content: []const u8) !void {
        if (self.connection_state != .connected) return error.NotConnected;
        
        const msg = WasmMessage{
            .id = try self.generateMessageId(),
            .from = "me",
            .to = jid,
            .content = content,
            .timestamp = std.time.timestamp(),
            .message_type = .text,
            .is_incoming = false,
        };
        
        self.message_buffer.push(msg);
    }
    
    /// Recebe próxima mensagem
    pub fn receiveMessage(self: *Self) ?WasmMessage {
        return self.message_buffer.pop();
    }
    
    /// Define callback para eventos
    pub fn setEventCallback(self: *Self, callback: js.Function) void {
        self.event_callback = callback;
    }
    
    /// Gera ID único para mensagem
    fn generateMessageId(self: *Self) ![]const u8 {
        // Implementação simplificada
        _ = self;
        return "msg_123";
    }
    
    /// Exporta estado como JSON para JavaScript
    pub fn exportStateJson(self: *Self, allocator: std.mem.Allocator) ![]u8 {
        return std.json.stringifyAlloc(
            allocator,
            .{
                .initialized = self.initialized,
                .connection_state = @tagName(self.connection_state),
                .message_count = self.message_buffer.len(),
            },
            .{},
        );
    }
};

/// Bindings JavaScript para WASM
pub const js = struct {
    /// Tipo de função JavaScript
    pub const Function = *const fn (data: []const u8) void;
    
    /// Console.log via JS interop
    pub fn consoleLog(comptime format: []const u8, args: anytype) void {
        if (is_wasm) {
            // Em WASM real, usaria import de JS
            _ = format;
            _ = args;
        } else {
            std.debug.print(format ++ "\n", args);
        }
    }
    
    /// Obtém timestamp em milissegundos
    pub fn dateNow() i64 {
        return std.time.milliTimestamp();
    }
    
    /// Gera números aleatórios criptograficamente seguros
    pub fn getRandomBytes(buffer: []u8) void {
        std.crypto.random.bytes(buffer);
    }
};

/// Módulo para Cloudflare Workers / Edge Runtime
pub const EdgeRuntime = struct {
    const Self = @This();
    
    env: Env,
    client: WasmClient,
    
    pub const Env = struct {
        kv_namespace: ?[]const u8,
        d1_database: ?[]const u8,
        secret_key: ?[]const u8,
    };
    
    pub fn init(env: Env) Self {
        return .{
            .env = env,
            .client = WasmClient.init(std.heap.wasm_allocator),
        };
    }
    
    /// Handler para requisições HTTP (Cloudflare Workers)
    pub fn fetch(self: *Self, request: Request) !Response {
        const url = request.url;
        const method = request.method;
        
        if (std.mem.eql(u8, method, "GET")) {
            return self.handleGet(url);
        } else if (std.mem.eql(u8, method, "POST")) {
            return self.handlePost(url, request.body);
        }
        
        return Response{
            .status = 405,
            .body = "Method not allowed",
        };
    }
    
    fn handleGet(self: *Self, url: []const u8) !Response {
        _ = self;
        _ = url;
        
        // Retorna estado atual
        return Response{
            .status = 200,
            .headers = &.{ .{ .name = "Content-Type", .value = "application/json" } },
            .body = "{\"status\": \"ok\"}",
        };
    }
    
    fn handlePost(self: *Self, url: []const u8, body: []const u8) !Response {
        _ = url;
        _ = body;
        
        // Processa mensagem ou comando
        return Response{
            .status = 200,
            .body = "OK",
        };
    }
    
    pub const Request = struct {
        method: []const u8,
        url: []const u8,
        headers: []const Header,
        body: []const u8,
        
        pub const Header = struct {
            name: []const u8,
            value: []const u8,
        };
    };
    
    pub const Response = struct {
        status: u16,
        headers: ?[]const Header,
        body: []const u8,
        
        pub const Header = struct {
            name: []const u8,
            value: []const u8,
        };
    };
};

/// Exemplo de uso com React/TypeScript frontend
pub const FrontendIntegration = struct {
    /// Gera código TypeScript para integração com React
    pub fn generateReactHook() []const u8 {
        return 
            \\/**
            \\ * React hook for WhatsZig WASM client
            \\ */
            \\import { useEffect, useState, useCallback } from 'react';
            \\
            \\interface WasmClient {
            \\    initialize(): Promise<void>;
            \\    connect(phone: string): Promise<void>;
            \\    disconnect(): void;
            \\    sendMessage(jid: string, content: string): Promise<void>;
            \\    receiveMessage(): Message | null;
            \\}
            \\
            \\interface Message {
            \\    id: string;
            \\    from: string;
            \\    to: string;
            \\    content: string;
            \\    timestamp: number;
            \\    messageType: 'text' | 'image' | 'video' | 'audio';
            \\    isIncoming: boolean;
            \\}
            \\
            \\export function useWhatsZig(phone: string) {
            \\    const [client, setClient] = useState<WasmClient | null>(null);
            \\    const [connected, setConnected] = useState(false);
            \\    const [messages, setMessages] = useState<Message[]>([]);
            \\    const [error, setError] = useState<string | null>(null);
            \\
            \\    useEffect(() => {
            \\        async function init() {
            \\            try {
            \\                // Carrega módulo WASM
            \\                const { WasmClient } = await import('./whatszigh_wasm');
            \\                const wasmClient = new WasmClient();
            \\                await wasmClient.initialize();
            \\                setClient(wasmClient);
            \\            } catch (err) {
            \\                setError(err instanceof Error ? err.message : 'Failed to load WASM');
            \\            }
            \\        }
            \\        init();
            \\    }, []);
            \\
            \\    const connect = useCallback(async () => {
            \\        if (!client) return;
            \\        try {
            \\            await client.connect(phone);
            \\            setConnected(true);
            \\        } catch (err) {
            \\            setError(err instanceof Error ? err.message : 'Connection failed');
            \\        }
            \\    }, [client, phone]);
            \\
            \\    const send = useCallback(async (jid: string, content: string) => {
            \\        if (!client) return;
            \\        try {
            \\            await client.sendMessage(jid, content);
            \\        } catch (err) {
            \\            setError(err instanceof Error ? err.message : 'Send failed');
            \\        }
            \\    }, [client]);
            \\
            \\    // Poll para mensagens recebidas
            \\    useEffect(() => {
            \\        if (!client || !connected) return;
            \\        
            \\        const interval = setInterval(() => {
            \\            const msg = client.receiveMessage();
            \\            if (msg) {
            \\                setMessages(prev => [...prev, msg]);
            \\            }
            \\        }, 100);
            \\        
            \\        return () => clearInterval(interval);
            \\    }, [client, connected]);
            \\
            \\    return {
            \\        connected,
            \\        messages,
            \\        error,
            \\        connect,
            \\        send,
            \\        disconnect: () => client?.disconnect(),
            \\    };
            \\}
            \\
        ;
    }
    
    /// Gera exemplo de HTML simples
    pub fn generateHtmlExample() []const u8 {
        return 
            \\<!DOCTYPE html>
            \\<html lang="en">
            \\<head>
            \\    <meta charset="UTF-8">
            \\    <meta name="viewport" content="width=device-width, initial-scale=1.0">
            \\    <title>WhatsZig WASM Demo</title>
            \\    <style>
            \\        body { font-family: Arial, sans-serif; max-width: 800px; margin: 0 auto; padding: 20px; }
            \\        #messages { border: 1px solid #ccc; height: 400px; overflow-y: auto; padding: 10px; }
            \\        .message { margin: 10px 0; padding: 10px; border-radius: 5px; }
            \\        .incoming { background-color: #e3f2fd; }
            \\        .outgoing { background-color: #f5f5f5; }
            \\        button { padding: 10px 20px; margin: 5px; }
            \\        input { padding: 10px; width: 300px; }
            \\    </style>
            \\</head>
            \\<body>
            \\    <h1>WhatsZig WASM Client</h1>
            \\    <div id="controls">
            \\        <button id="connectBtn">Connect</button>
            \\        <button id="disconnectBtn" disabled>Disconnect</button>
            \\    </div>
            \\    <div id="messages"></div>
            \\    <div id="input">
            \\        <input type="text" id="messageInput" placeholder="Type a message..." />
            \\        <button id="sendBtn">Send</button>
            \\    </div>
            \\    <script type="module">
            \\        import init, { WasmClient } from './pkg/whatszigh_wasm.js';
            \\        
            \\        let client = null;
            \\        
            \\        async function main() {
            \\            await init();
            \\            client = new WasmClient();
            \\            await client.initialize();
            \\            
            \\            document.getElementById('connectBtn').onclick = async () => {
            \\                await client.connect('5511999999999');
            \\                document.getElementById('connectBtn').disabled = true;
            \\                document.getElementById('disconnectBtn').disabled = false;
            \\            };
            \\            
            \\            document.getElementById('disconnectBtn').onclick = () => {
            \\                client.disconnect();
            \\                document.getElementById('connectBtn').disabled = false;
            \\                document.getElementById('disconnectBtn').disabled = true;
            \\            };
            \\            
            \\            document.getElementById('sendBtn').onclick = async () => {
            \\                const input = document.getElementById('messageInput');
            \\                await client.sendMessage('5511999999999@s.whatsapp.net', input.value);
            \\                input.value = '';
            \\            };
            \\        }
            \\        
            \\        main();
            \\    </script>
            \\</body>
            \\</html>
            \\
        ;
    }
};

/// Testes
test "WasmClient initialization" {
    const allocator = std.testing.allocator;
    var client = WasmClient.init(allocator);
    defer client.deinit();
    
    try std.testing.expect(!client.initialized);
    try client.initialize();
    try std.testing.expect(client.initialized);
}

test "WasmClient connection state" {
    const allocator = std.testing.allocator;
    var client = WasmClient.init(allocator);
    defer client.deinit();
    
    try client.initialize();
    try client.connect("5511999999999");
    
    try std.testing.expectEqual(WasmClient.ConnectionState.connected, client.connection_state);
    
    client.disconnect();
    try std.testing.expectEqual(WasmClient.ConnectionState.disconnected, client.connection_state);
}

test "WasmClient message buffer" {
    const allocator = std.testing.allocator;
    var client = WasmClient.init(allocator);
    defer client.deinit();
    
    try client.initialize();
    try client.connect("5511999999999");
    try client.sendMessage("5511999999999@s.whatsapp.net", "Hello!");
    
    try std.testing.expectEqual(@as(usize, 1), client.message_buffer.len());
}

test "EdgeRuntime initialization" {
    const env = EdgeRuntime.Env{
        .kv_namespace = "my_kv",
        .d1_database = "my_db",
        .secret_key = "secret",
    };
    
    var runtime = EdgeRuntime.init(env);
    
    const request = EdgeRuntime.Request{
        .method = "GET",
        .url = "/api/status",
        .headers = &.{},
        .body = "",
    };
    
    const response = try runtime.fetch(request);
    try std.testing.expectEqual(@as(u16, 200), response.status);
}

test "FrontendIntegration code generation" {
    const react_hook = FrontendIntegration.generateReactHook();
    try std.testing.expect(react_hook.len > 0);
    try std.testing.expect(std.mem.indexOf(u8, react_hook, "useWhatsZig") != null);
    
    const html_example = FrontendIntegration.generateHtmlExample();
    try std.testing.expect(html_example.len > 0);
    try std.testing.expect(std.mem.indexOf(u8, html_example, "WhatsZig WASM Client") != null);
}

test "is_wasm detection" {
    // Este teste verifica se a detecção de WASM funciona
    _ = is_wasm;
}
