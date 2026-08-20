/// ring_buffer.zig
/// Implementação de Lock-Free Ring Buffer para o Message Broker
/// Utiliza atomics do Zig para garantir segurança em cenários multi-thread (Agentes vs Manager)

const std = @import("std");
const atomic = std.atomic;
const BrokerEvent = @import("event_types.zig").BrokerEvent;
const EventPayload = @import("event_types.zig").EventPayload;

const RingBuffer = struct {
    buffer: []BrokerEvent,
    capacity: usize,
    head: atomic.Value(usize), // Índice de escrita (Producer - Agentes)
    tail: atomic.Value(usize), // Índice de leitura (Consumer - Manager)
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, comptime size: comptime_int) !Self {
        const buffer = try allocator.alloc(BrokerEvent, size);
        
        // Inicializar todos os slots
        for (buffer, 0..) |_, i| {
            buffer[i] = BrokerEvent.init();
        }

        return Self{
            .buffer = buffer,
            .capacity = size,
            .head = atomic.Value(usize).init(0),
            .tail = atomic.Value(usize).init(0),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Self) void {
        self.allocator.free(self.buffer);
    }

    /// Push não-bloqueante (Producer)
    /// Retorna true se sucesso, false se buffer cheio
    pub fn push(self: *Self, payload: EventPayload) bool {
        const current_head = self.head.load(.acquire);
        const next_head = (current_head + 1) % self.capacity;

        // Verificar se está cheio
        if (next_head == self.tail.load(.acquire)) {
            return false; // Buffer full, descarta ou trata backpressure no agente
        }

        // Escrever dados no slot
        const slot_index = current_head % self.capacity;
        const slot = &self.buffer[slot_index];
        
        // Copiar payload
        slot.payload = payload;
        slot.sequence.store(current_head, .release);
        
        // Marcar como usado (barreira de memória)
        slot.slot_used.store(true, .seq_cst);
        
        // Atualizar head
        self.head.store(next_head, .release);
        
        return true;
    }

    /// Pop não-bloqueante (Consumer)
    /// Retorna null se vazio, ou o payload lido
    pub fn pop(self: *Self) ?EventPayload {
        const current_tail = self.tail.load(.acquire);
        
        // Verificar se está vazio
        if (current_tail == self.head.load(.acquire)) {
            return null;
        }

        const slot_index = current_tail % self.capacity;
        const slot = &self.buffer[slot_index];

        // Esperar o slot estar pronto (caso haja race condition mínima)
        while (!slot.slot_used.load(.acquire)) {
            std.cpu.pause();
        }

        const payload = slot.payload;
        
        // Limpar slot para reuso seguro (secure zeroing opcional para dados sensíveis)
        slot.slot_used.store(false, .release);
        // Opcional: std.mem.secureZero(u8, std.mem.asBytes(&slot.payload));

        // Atualizar tail
        const next_tail = (current_tail + 1) % self.capacity;
        self.tail.store(next_tail, .release);

        return payload;
    }

    /// Retorna número aproximado de itens no buffer (pode variar em concorrência)
    pub fn count(self: *Self) usize {
        const h = self.head.load(.acquire);
        const t = self.tail.load(.acquire);
        
        if (h >= t) {
            return h - t;
        } else {
            return self.capacity - t + h;
        }
    }
};

test "RingBuffer basic operations" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    var rb = try RingBuffer.init(alloc, 4); // Capacidade pequena para teste
    defer rb.deinit();

    const payload = EventPayload.initText(100, 200, "Test Message");
    
    // Push
    try std.testing.expect(rb.push(payload));
    try std.testing.expectEqual(@as(usize, 1), rb.count());

    // Pop
    const popped = rb.pop();
    try std.testing.expect(popped != null);
    try std.testing.expectEqualStrings("Test Message", popped.?.getTextSlice());
    try std.testing.expectEqual(@as(usize, 0), rb.count());

    // Pop vazio
    try std.testing.expectEqual(@as(?EventPayload, null), rb.pop());
}

test "RingBuffer overflow handling" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    var rb = try RingBuffer.init(alloc, 2); // Capacidade 2
    defer rb.deinit();

    const p1 = EventPayload.initText(1, 1, "Msg1");
    const p2 = EventPayload.initText(2, 2, "Msg2");
    const p3 = EventPayload.initText(3, 3, "Msg3");

    try std.testing.expect(rb.push(p1));
    try std.testing.expect(rb.push(p2));
    
    // Terceiro push deve falhar (buffer cheio)
    try std.testing.expectEqual(false, rb.push(p3));
}
