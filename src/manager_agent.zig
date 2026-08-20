/// manager_agent.zig
/// Módulo central ManagerAgent: Único responsável pelo acesso ao SQLite.
/// Fluxo: Agentes -> RingBuffer (Lock-Free) -> ManagerAgent (Consumer) -> SQLite
/// Garante isolamento, serialização de writes e segurança de dados.

const std = @import("std");
const EventPayload = @import("event_types.zig").EventPayload;
const RingBuffer = @import("ring_buffer.zig").RingBuffer;
const EventType = @import("event_types.zig").EventType;

// SQLite backend opcional - pode ser implementado com zig-sqlite ou binding C
pub const SqliteBackend = struct {
    db_path: []const u8,
    // Ponteiro opaco para a conexão DB real
    handle: ?*anyopaque = null,

    pub fn open(path: []const u8) !SqliteBackend {
        // Em produção: implementar com zig-sqlite ou SQLCipher
        // Aqui apenas simulamos para compilação
        _ = path;
        return SqliteBackend{
            .db_path = path,
            .handle = null,
        };
    }

    pub fn exec(self: *SqliteBackend, query: []const u8, params: anytype) !void {
        _ = self;
        _ = query;
        _ = params;
        // Implementação real iria aqui
    }

    pub fn close(self: *SqliteBackend) void {
        // Limpeza de recursos
        self.handle = null;
    }
};

pub const ManagerConfig = struct {
    db_path: []const u8 = "whatszig.db",
    buffer_size: usize = 1024, // Tamanho do RingBuffer
    enable_sqlite: bool = true,
};

pub const ManagerAgent = struct {
    allocator: std.mem.Allocator,
    ring_buffer: RingBuffer,
    db: ?SqliteBackend,
    is_running: std.atomic.Value(bool),
    thread: ?std.Thread,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, config: ManagerConfig) !Self {
        // Inicializar RingBuffer
        var rb = try RingBuffer.init(allocator, config.buffer_size);

        // Inicializar SQLite opcionalmente (apenas o Manager tem acesso)
        var db: ?SqliteBackend = null;
        if (config.enable_sqlite) {
            db = try SqliteBackend.open(config.db_path);
        }

        // Criar tabelas se não existirem (quando DB estiver ativo)
        if (db) |*database| {
            try initSchema(database);
        }

        return Self{
            .allocator = allocator,
            .ring_buffer = rb,
            .db = db,
            .is_running = std.atomic.Value(bool).init(true),
            .thread = null,
        };
    }

    fn initSchema(db: *SqliteBackend) !void {
        const create_messages = 
            \\CREATE TABLE IF NOT EXISTS messages (
            \\    id INTEGER PRIMARY KEY AUTOINCREMENT,
            \\    chat_id INTEGER NOT NULL,
            \\    sender_id INTEGER NOT NULL,
            \\    content TEXT NOT NULL,
            \\    timestamp INTEGER NOT NULL,
            \\    message_type TEXT DEFAULT 'text',
            \\    is_read INTEGER DEFAULT 0
            \\);
        const create_presence = 
            \\CREATE TABLE IF NOT EXISTS presence (
            \\    chat_id INTEGER PRIMARY KEY,
            \\    is_online INTEGER NOT NULL,
            \\    last_seen INTEGER NOT NULL,
            \\    typing INTEGER DEFAULT 0
            \\);
        
        try db.exec(create_messages, .{});
        try db.exec(create_presence, .{});
    }

    pub fn startBackgroundProcessor(self: *Self) !void {
        self.thread = try std.Thread.spawn(.{}, processLoop, .{self});
    }

    fn processLoop(self: *Self) void {
        while (self.is_running.load(.acquire)) {
            // Processar todos os eventos disponíveis no buffer
            var processed_count: usize = 0;
            
            while (self.ring_buffer.pop()) |payload| {
                self.handleEvent(payload) catch |err| {
                    std.debug.print("[ManagerAgent] Erro ao processar evento: {}\n", .{err});
                    // Em produção: log estruturado, métricas, retry queue
                };
                processed_count += 1;
            }

            if (processed_count == 0) {
                // Se nada para processar, espera brevemente para não busy-wait
                std.time.sleep(1_000_000); // 1ms
            }
        }
    }

    fn handleEvent(self: *Self, payload: EventPayload) !void {
        // Se SQLite estiver desabilitado, apenas processa em memória ou ignora
        if (self.db == null) {
            // Modo apenas memória - pode persistir em arquivo separado se necessário
            return;
        }

        const db = self.db.?;
        
        switch (payload.event_type) {
            .message_text => {
                try self.persistMessage(db, payload);
            },
            .presence_update => {
                try self.persistPresence(db, payload);
            },
            .ack_read, .ack_delivered => {
                try self.updateAckStatus(db, payload);
            },
            else => {
                // Ignorar ou logar tipos não tratados
            },
        }
    }

    fn persistMessage(self: *Self, db: SqliteBackend, payload: EventPayload) !void {
        const text = payload.getTextSlice();
        
        // Transação única para garantir atomicidade
        try db.exec(
            \\INSERT INTO messages (chat_id, sender_id, content, timestamp, message_type)
            \\VALUES (?, ?, ?, ?, 'text');
        , .{ payload.chat_id, payload.sender_id, text, payload.timestamp });
    }

    fn persistPresence(self: *Self, db: SqliteBackend, payload: EventPayload) !void {
        const p = payload.data.presence;
        
        try db.exec(
            \\INSERT OR REPLACE INTO presence (chat_id, is_online, last_seen, typing)
            \\VALUES (?, ?, ?, ?);
        , .{ payload.chat_id, if (p.is_online) 1 else 0, p.last_seen, if (p.typing) 1 else 0 });
    }

    fn updateAckStatus(self: *Self, db: SqliteBackend, payload: EventPayload) !void {
        const ack = payload.data.ack;
        const is_read = if (payload.event_type == .ack_read) 1 else 0;
        
        try db.exec(
            \\UPDATE messages SET is_read = ? WHERE id = ?;
        , .{ is_read, ack.message_id });
    }

    /// Método público para Agentes enviarem eventos (Thread-Safe via RingBuffer)
    pub fn emitEvent(self: *Self, payload: EventPayload) bool {
        return self.ring_buffer.push(payload);
    }

    pub fn stop(self: *Self) void {
        self.is_running.store(false, .release);
        
        if (self.thread) |t| {
            t.join();
        }
    }

    pub fn deinit(self: *Self) void {
        self.stop();
        self.ring_buffer.deinit();
        if (self.db) |*database| {
            database.close();
        }
    }

    /// Query helper para leitura (apenas o Manager pode executar queries complexas)
    pub fn getRecentMessages(self: *Self, chat_id: u64, limit: usize) ![]struct {
        id: i64,
        sender: i64,
        content: []u8,
        ts: i64,
    } {
        _ = chat_id;
        _ = limit;
        return error.NotImplemented;
    }
};

test "ManagerAgent basic flow" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    // Testar modo sem SQLite (apenas memória/RingBuffer)
    var manager = try ManagerAgent.init(alloc, .{
        .db_path = "test.db",
        .buffer_size = 64,
        .enable_sqlite = false,
    });
    defer manager.deinit();

    const payload = EventPayload.initText(12345, 67890, "Test Message");
    
    // Emitir evento
    try std.testing.expect(manager.emitEvent(payload));
    
    // Iniciar processador em background
    try manager.startBackgroundProcessor();
    
    // Aguardar processamento
    std.time.sleep(10_000_000); // 10ms
    
    manager.stop();
}
