/// event_types.zig
/// Definições centrais de eventos e payloads para o sistema de mensageria.
/// Garante tipagem estrita e compatibilidade entre Agentes e Manager.

const std = @import("std");
const mem = std.mem;

/// Tipos de eventos suportados pelo sistema
pub const EventType = enum(u8) {
    message_text = 0,
    message_media = 1,
    presence_update = 2,
    connection_status = 3,
    ack_read = 4,
    ack_delivered = 5,
    group_action = 6,
    custom = 255,
};

/// Payload unificado para transferência eficiente no RingBuffer
/// Tamanho fixo otimizado para cache-line (evita alocações dinâmicas no broker)
pub const EventPayload = struct {
    event_type: EventType,
    
    // Identificadores
    chat_id: u64,       // ID do chat/contato (hash ou ID numérico)
    sender_id: u64,     // ID do remetente
    timestamp: u64,     // Unix timestamp
    
    // Dados variáveis (uso inteligente de union para economizar espaço)
    data: union {
        text: struct {
            content: [256]u8, // Buffer fixo para textos curtos/médios
            len: usize,
        },
        media: struct {
            mime_type: [32]u8,
            url_or_path: [512]u8, // Caminho local ou URL temporária
            size_bytes: u64,
        },
        presence: struct {
            is_online: bool,
            last_seen: u64,
            typing: bool,
        },
        status: struct {
            code: u8, // 0: Desconectado, 1: Conectando, 2: Conectado, 3: Auth Failed
            reason: [64]u8,
        },
        ack: struct {
            message_id: u64,
            ack_type: u8,
        },
        raw: [512]u8, // Fallback para dados brutos se necessário
    },

    pub fn initText(chat: u64, sender: u64, text: []const u8) EventPayload {
        var payload = EventPayload{
            .event_type = .message_text,
            .chat_id = chat,
            .sender_id = sender,
            .timestamp = @intCast(std.time.timestamp()),
            .data = undefined,
        };
        
        const max_len = @min(text.len, 255);
        @memcpy(payload.data.text.content[0..max_len], text[0..max_len]);
        // Preencher resto com zeros para segurança (memory hygiene)
        if (max_len < 256) {
            @memset(payload.data.text.content[max_len..], 0);
        }
        payload.data.text.len = max_len;
        
        return payload;
    }

    pub fn initPresence(chat: u64, online: bool, typing: bool) EventPayload {
        return EventPayload{
            .event_type = .presence_update,
            .chat_id = chat,
            .sender_id = 0, // Sistema
            .timestamp = @intCast(std.time.timestamp()),
            .data = .{
                .presence = .{
                    .is_online = online,
                    .last_seen = @intCast(std.time.timestamp()),
                    .typing = typing,
                },
            },
        };
    }
    
    pub fn getTextSlice(self: *const EventPayload) []const u8 {
        if (self.event_type != .message_text) return "";
        return self.data.text.content[0..self.data.text.len];
    }
};

/// Estrutura do Evento completo no Buffer
pub const BrokerEvent = struct {
    slot_used: std.atomic.Value(bool),
    payload: EventPayload,
    sequence: std.atomic.Value(u64), // Para detecção de perda de pacotes

    pub fn init() BrokerEvent {
        return BrokerEvent{
            .slot_used = std.atomic.Value(bool).init(false),
            .payload = undefined,
            .sequence = std.atomic.Value(u64).init(0),
        };
    }
};

test "EventPayload initialization" {
    const text = "Hello, Zig MCP!";
    const payload = EventPayload.initText(12345, 67890, text);
    
    try std.testing.expectEqual(payload.event_type, .message_text);
    try std.testing.expectEqualStrings(payload.getTextSlice(), text);
    try std.testing.expectEqual(payload.chat_id, 12345);
}
