/// agent.zig
/// Agente de Mensageria: Componente leve que emite eventos para o ManagerAgent.
/// Não tem acesso direto ao SQLite. Comunica-se exclusivamente via RingBuffer Lock-Free.
/// Pode ser instanciado múltiplas vezes (um por conexão/sessão).

const std = @import("std");
const EventPayload = @import("event_types.zig").EventPayload;
const ManagerAgent = @import("manager_agent.zig").ManagerAgent;

pub const Agent = struct {
    id: u64,
    manager: *ManagerAgent,
    allocator: std.mem.Allocator,
    
    // Estado local em memória (não persistente)
    connection_state: enum { disconnected, connecting, connected, auth_failed },
    session_key: ?[32]u8, // Chave de sessão temporária (será limpa com secureZero)

    const Self = @This();

    pub fn init(id: u64, manager: *ManagerAgent, allocator: std.mem.Allocator) Self {
        return Self{
            .id = id,
            .manager = manager,
            .allocator = allocator,
            .connection_state = .disconnected,
            .session_key = null,
        };
    }

    pub fn deinit(self: *Self) void {
        // Limpeza segura da chave de sessão (Anti-Memory Dump)
        if (self.session_key) |*key| {
            std.mem.secureZero(u8, key);
        }
        self.session_key = null;
    }

    /// Simula recebimento de mensagem e envia para o Manager
    pub fn receiveMessage(self: *Self, chat_id: u64, sender_id: u64, text: []const u8) bool {
        const payload = EventPayload.initText(chat_id, sender_id, text);
        
        const success = self.manager.emitEvent(payload);
        
        if (!success) {
            // Buffer cheio - estratégia de backpressure
            std.debug.print("[Agent {}] Warning: Buffer cheio, mensagem descartada!\n", .{self.id});
        }
        
        return success;
    }

    /// Reporta mudança de presença
    pub fn updatePresence(self: *Self, chat_id: u64, is_online: bool, is_typing: bool) bool {
        const payload = EventPayload.initPresence(chat_id, is_online, is_typing);
        return self.manager.emitEvent(payload);
    }

    /// Estabelece sessão (simulação)
    pub fn establishSession(self: *Self, key: [32]u8) void {
        self.session_key = key;
        self.connection_state = .connected;
        
        // Em produção: enviar evento de status para o Manager
        _ = self.updatePresence(0, true, false);
    }

    /// Finaliza sessão com limpeza segura
    pub fn terminateSession(self: *Self) void {
        if (self.session_key) |*key| {
            std.mem.secureZero(u8, key); // Limpeza criptográfica
        }
        self.session_key = null;
        self.connection_state = .disconnected;
    }

    /// Getter seguro para estado (sem expor chave)
    pub fn isConnected(self: *const Self) bool {
        return self.connection_state == .connected;
    }
};

test "Agent emits events to Manager" {
    // Teste conceitual - requer Manager real instanciado
    // Valida a API do Agente
    var mock_manager: ManagerAgent = undefined;
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    
    var agent = Agent.init(1, &mock_manager, gpa.allocator());
    defer agent.deinit();
    
    // Simular chave de sessão
    var key: [32]u8 = [_]u8{0x42} ** 32;
    agent.establishSession(key);
    
    try std.testing.expect(agent.isConnected());
    
    // Terminar sessão deve limpar chave
    agent.terminateSession();
    try std.testing.expectEqual(@as(?[32]u8, null), agent.session_key);
    try std.testing.expectEqual(false, agent.isConnected());
}
