/// manager_agent_root.zig
/// Ponto de entrada público do módulo ManagerAgent
/// Expõe a API completa para uso externo

pub const event_types = @import("event_types.zig");
pub const ring_buffer = @import("ring_buffer.zig");
pub const manager_agent = @import("manager_agent.zig");
pub const agent = @import("agent.zig");

// Re-exportações para conveniência
pub const EventType = event_types.EventType;
pub const EventPayload = event_types.EventPayload;
pub const BrokerEvent = event_types.BrokerEvent;
pub const RingBuffer = ring_buffer.RingBuffer;
pub const ManagerConfig = manager_agent.ManagerConfig;
pub const ManagerAgent = manager_agent.ManagerAgent;
pub const Agent = agent.Agent;

/// Versão do módulo
pub const version = struct {
    major: u32 = 0,
    minor: u32 = 1,
    patch: u32 = 0,
    
    pub fn comptimeString() []const u8 {
        return "0.1.0";
    }
};

/// Exemplo completo de uso do sistema
pub fn exampleUsage() void {
    const std = @import("std");
    
    // Este é um exemplo ilustrativo - não executa em tempo de compilação
    // devido a dependências de runtime (allocators, threads, DB)
    
    /*
    pub fn main() !void {
        var gpa = std.heap.GeneralPurposeAllocator(.{}){};
        defer _ = gpa.deinit();
        const alloc = gpa.allocator();
        
        // 1. Criar Manager (única instância)
        var manager = try ManagerAgent.init(alloc, .{
            .db_path = "messages.db",
            .buffer_size = 2048,
        });
        defer manager.deinit();
        
        // 2. Iniciar processador em background
        try manager.startBackgroundProcessor();
        
        // 3. Criar múltiplos Agentes
        var agent1 = Agent.init(1, &manager, alloc);
        defer agent1.deinit();
        
        var agent2 = Agent.init(2, &manager, alloc);
        defer agent2.deinit();
        
        // 4. Agentes emitem eventos (thread-safe)
        _ = agent1.receiveMessage(12345, 67890, "Olá do Agente 1!");
        _ = agent2.receiveMessage(12345, 67891, "Resposta do Agente 2!");
        
        // 5. Reportar presença
        _ = agent1.updatePresence(12345, true, false);
        
        // 6. Aguardar processamento (em app real, isso seria um loop ou wait)
        std.time.sleep(2_000_000_000); // 2 segundos
        
        std.debug.print("Mensagens enviadas com sucesso!\n", .{});
    }
    */
}

test "Module exports" {
    // Verifica se todos os tipos estão exportados corretamente
    _ = EventType.message_text;
    _ = RingBuffer;
    _ = ManagerAgent;
    _ = Agent;
    _ = version.comptimeString();
}
