/// TUI (Terminal User Interface) Embutida / Debugger em Tempo Real
/// Aproveita a velocidade do Zig para criar interface no terminal
const std = @import("std");
const builtin = @import("builtin");

/// Estado da interface TUI
pub const TuiState = struct {
    /// Mensagens recentes em buffer circular
    messages: RingBuffer(Message, 100>,
    /// Status das conexões
    connection_status: ConnectionStatus,
    /// Estatísticas de tráfego
    traffic_stats: TrafficStats,
    /// Chaves de criptografia ativas (apenas metadados)
    crypto_keys: KeyMetadata,
    /// Terminal dimensions
    width: u16,
    height: u16,
    /// Scroll offset
    scroll_offset: usize,
    /// Modo de visualização atual
    view_mode: ViewMode,
};

pub const Message = struct {
    timestamp: i64,
    direction: Direction,
    jid: []const u8,
    content_preview: []const u8,
    message_type: MessageType,
    encrypted: bool,
    frame_id: u32,
};

pub const Direction = enum {
    inbound,
    outbound,
    system,
};

pub const MessageType = enum {
    text,
    image,
    video,
    audio,
    document,
    presence,
    receipt,
    unknown,
};

pub const ConnectionStatus = struct {
    connected: bool,
    server: []const u8,
    latency_ms: u32,
    last_ping: i64,
    reconnect_count: u32,
};

pub const TrafficStats = struct {
    messages_in: u64,
    messages_out: u64,
    bytes_in: u64,
    bytes_out: u64,
    frames_processed: u64,
    errors: u64,
    start_time: i64,
};

pub const KeyMetadata = struct {
    session_id: [32]u8,
    created_at: i64,
    last_used: i64,
    ratchet_count: u64,
    is_active: bool,
};

pub const ViewMode = enum {
    messages,
    traffic,
    crypto,
    protobuf,
    settings,
};

/// Buffer circular para mensagens em memória
pub fn RingBuffer(comptime T: type, comptime capacity: usize) type {
    return struct {
        data: [capacity]T,
        head: usize,
        tail: usize,
        count: usize,

        const Self = @This();

        pub fn init() Self {
            return .{
                .data = undefined,
                .head = 0,
                .tail = 0,
                .count = 0,
            };
        }

        pub fn push(self: *Self, item: T) void {
            self.data[self.tail] = item;
            self.tail = (self.tail + 1) % capacity;
            
            if (self.count == capacity) {
                // Buffer cheio, move head
                self.head = (self.head + 1) % capacity;
            } else {
                self.count += 1;
            }
        }

        pub fn pop(self: *Self) ?T {
            if (self.count == 0) return null;
            
            const item = self.data[self.head];
            self.head = (self.head + 1) % capacity;
            self.count -= 1;
            return item;
        }

        pub fn get(self: *const Self, index: usize) ?const T {
            if (index >= self.count) return null;
            const actual_index = (self.head + index) % capacity;
            return &self.data[actual_index];
        }

        pub fn clear(self: *Self) void {
            self.head = 0;
            self.tail = 0;
            self.count = 0;
        }

        pub fn len(self: *const Self) usize {
            return self.count;
        }

        pub fn isEmpty(self: *const Self) bool {
            return self.count == 0;
        }

        pub fn isFull(self: *const Self) bool {
            return self.count == capacity;
        }
    };
}

/// Terminal renderer usando ANSI escape codes
pub const TerminalRenderer = struct {
    writer: anytype,
    state: *TuiState,
    alt_screen_active: bool,

    const Self = @This();

    pub fn init(writer: anytype, state: *TuiState) Self {
        return .{
            .writer = writer,
            .state = state,
            .alt_screen_active = false,
        };
    }

    /// Entra em modo tela alternativa
    pub fn enterAltScreen(self: *Self) !void {
        try self.writer.writeAll("\x1b[?1049h"); // Enter alt screen
        try self.writer.writeAll("\x1b[2J");     // Clear screen
        try self.writer.writeAll("\x1b[H");      // Move to home
        self.alt_screen_active = true;
    }

    /// Sai do modo tela alternativa
    pub fn exitAltScreen(self: *Self) !void {
        if (self.alt_screen_active) {
            try self.writer.writeAll("\x1b[?1049l"); // Exit alt screen
            self.alt_screen_active = false;
        }
    }

    /// Limpa a tela
    pub fn clear(self: *Self) !void {
        try self.writer.writeAll("\x1b[2J\x1b[H");
    }

    /// Move cursor para posição
    pub fn moveCursor(self: *Self, row: u16, col: u16) !void {
        try std.fmt.format(self.writer, "\x1b[{d};{d}H", .{ row + 1, col + 1 });
    }

    /// Esconde cursor
    pub fn hideCursor(self: *Self) !void {
        try self.writer.writeAll("\x1b[?25l");
    }

    /// Mostra cursor
    pub fn showCursor(self: *Self) !void {
        try self.writer.writeAll("\x1b[?25h");
    }

    /// Define cor do texto
    pub fn setColor(self: *Self, fg: Color, bg: ?Color) !void {
        try std.fmt.format(self.writer, "\x1b[{d}m", .{@intFromEnum(fg)});
        if (bg) |background| {
            try std.fmt.format(self.writer, "\x1b[{d}m", .{@intFromEnum(background) + 10});
        }
    }

    /// Reseta atributos
    pub fn resetAttributes(self: *Self) !void {
        try self.writer.writeAll("\x1b[0m");
    }

    /// Renderiza header da aplicação
    pub fn renderHeader(self: *Self) !void {
        try self.moveCursor(0, 0);
        try self.setColor(.cyan, null);
        try self.writer.writeAll("╔══════════════════════════════════════════════════════════╗\n");
        try self.writer.writeAll("║  WhatsZig Debugger - Real-time Message Inspector         ║\n");
        try self.writer.writeAll("╚══════════════════════════════════════════════════════════╝\n");
        try self.resetAttributes();
    }

    /// Renderiza status bar
    pub fn renderStatusBar(self: *Self) !void {
        try self.moveCursor(self.height - 2, 0);
        try self.setColor(.reverse, null);
        
        const status_str = if (self.state.connection_status.connected) 
            "● Connected" 
        else 
            "○ Disconnected";
        
        try std.fmt.format(
            self.writer,
            " {s} | Latency: {d}ms | Mode: {s} | Messages: {d} | Q: Quit ",
            .{
                status_str,
                self.state.connection_status.latency_ms,
                @tagName(self.state.view_mode),
                self.state.messages.len(),
            },
        );
        
        // Preenche resto da linha
        var i: usize = 0;
        const line_len = 68;
        while (i < self.width - line_len) : (i += 1) {
            try self.writer.writeAll(" ");
        }
        
        try self.resetAttributes();
    }

    /// Renderiza lista de mensagens
    pub fn renderMessages(self: *Self) !void {
        const start_row: u16 = 4;
        const max_rows = self.height - 6;
        
        var i: usize = 0;
        var displayed: usize = 0;
        
        while (i < self.state.messages.len() and displayed < max_rows) : (i += 1) {
            const msg_idx = if (self.state.scroll_offset > i) 
                continue 
            else 
                i - self.state.scroll_offset;
            
            if (msg_idx >= self.state.messages.len()) break;
            
            const msg = self.state.messages.get(msg_idx).?;
            try self.renderMessageRow(start_row + @as(u16, @intCast(displayed)), msg);
            displayed += 1;
        }
    }

    fn renderMessageRow(self: *Self, row: u16, msg: Message) !void {
        try self.moveCursor(row, 0);
        
        // Ícone de direção
        const dir_icon = switch (msg.direction) {
            .inbound => "←",
            .outbound => "→",
            .system => "•",
        };
        
        const dir_color = switch (msg.direction) {
            .inbound => Color.green,
            .outbound => Color.blue,
            .system => Color.yellow,
        };
        
        try self.setColor(dir_color, null);
        try std.fmt.format(self.writer, "[{s}] ", .{dir_icon});
        try self.resetAttributes();
        
        // Timestamp
        const ts = std.time.timestamp();
        _ = ts;
        try std.fmt.format(self.writer, "{d:0>2}:{d:0>2}:{d:0>2} ", .{
            @as(u32, @intCast(@mod(@divFloor(@abs(msg.timestamp), 3600), 24))),
            @as(u32, @intCast(@mod(@divFloor(@abs(msg.timestamp), 60), 60))),
            @as(u32, @intCast(@mod(@abs(msg.timestamp), 60))),
        });
        
        // JID
        try self.setColor(.white, null);
        try std.fmt.format(self.writer, "{s:<20} ", .{msg.jid});
        try self.resetAttributes();
        
        // Preview do conteúdo
        const preview = if (msg.content_preview.len > 40)
            msg.content_preview[0..40]
        else
            msg.content_preview;
        
        try self.writer.writeAll(preview);
        
        // Indicador de criptografia
        if (msg.encrypted) {
            try self.setColor(.magenta, null);
            try self.writer.writeAll(" 🔒");
            try self.resetAttributes();
        }
    }

    /// Renderiza estatísticas de tráfego
    pub fn renderTrafficStats(self: *Self) !void {
        const start_row: u16 = 4;
        
        try self.moveCursor(start_row, 0);
        try self.setColor(.cyan, null);
        try self.writer.writeAll("┌─────────────────────────────────────────┐\n");
        try self.writer.writeAll("│  Traffic Statistics                     │\n");
        try self.writer.writeAll("├─────────────────────────────────────────┤\n");
        try self.resetAttributes();
        
        try std.fmt.format(
            self.writer,
            "│ Messages In:  {d:>10}                    │\n" ++
            "│ Messages Out: {d:>10}                    │\n" ++
            "│ Bytes In:     {d:>10}                    │\n" ++
            "│ Bytes Out:    {d:>10}                    │\n" ++
            "│ Frames:       {d:>10}                    │\n" ++
            "│ Errors:       {d:>10}                    │\n",
            .{
                self.state.traffic_stats.messages_in,
                self.state.traffic_stats.messages_out,
                self.state.traffic_stats.bytes_in,
                self.state.traffic_stats.bytes_out,
                self.state.traffic_stats.frames_processed,
                self.state.traffic_stats.errors,
            },
        );
        
        try self.setColor(.cyan, null);
        try self.writer.writeAll("└─────────────────────────────────────────┘\n");
        try self.resetAttributes();
    }

    /// Renderiza informações de criptografia
    pub fn renderCryptoInfo(self: *Self) !void {
        const start_row: u16 = 4;
        
        try self.moveCursor(start_row, 0);
        try self.setColor(.magenta, null);
        try self.writer.writeAll("┌─────────────────────────────────────────┐\n");
        try self.writer.writeAll("│  Cryptography Status                    │\n");
        try self.writer.writeAll("├─────────────────────────────────────────┤\n");
        try self.resetAttributes();
        
        const key_hex = std.fmt.bytesToHex(self.state.crypto_keys.session_id, .lower);
        
        try std.fmt.format(
            self.writer,
            "│ Session ID: {s}  │\n" ++
            "│ Ratchet Count: {d:>18}       │\n" ++
            "│ Active: {s:>25}    │\n",
            .{
                key_hex[0..32],
                self.state.crypto_keys.ratchet_count,
                if (self.state.crypto_keys.is_active) "Yes" else "No",
            },
        );
        
        try self.setColor(.magenta, null);
        try self.writer.writeAll("└─────────────────────────────────────────┘\n");
        try self.resetAttributes();
    }

    /// Renderiza dump de frames Protobuf
    pub fn renderProtobufDump(self: *Self, frame_data: []const u8) !void {
        const start_row: u16 = 4;
        const max_lines = self.height - 6;
        
        try self.moveCursor(start_row, 0);
        try self.setColor(.yellow, null);
        try self.writer.writeAll("Protobuf Frame Dump:\n");
        try self.resetAttributes();
        
        var line_start: usize = 0;
        var line_num: usize = 0;
        
        while (line_start < frame_data.len and line_num < max_lines) : (line_num += 1) {
            const line_end = @min(line_start + 16, frame_data.len);
            const line = frame_data[line_start..line_end];
            
            try std.fmt.format(self.writer, "{d:08X}  ", .{line_start});
            
            // Hex dump
            for (line) |byte| {
                try std.fmt.format(self.writer, "{X:0>2} ", .{byte});
            }
            
            // Padding
            var i: usize = line.len;
            while (i < 16) : (i += 1) {
                try self.writer.writeAll("   ");
            }
            
            try self.writer.writeAll("  ");
            
            // ASCII dump
            for (line) |byte| {
                const c = if (byte >= 32 and byte < 127) byte else '.';
                try std.fmt.format(self.writer, "{c}", .{c});
            }
            
            try self.writer.writeAll("\n");
            line_start += 16;
        }
    }

    /// Renderiza frame completo baseado no modo atual
    pub fn render(self: *Self) !void {
        try self.clear();
        try self.renderHeader();
        try self.renderStatusBar();
        
        switch (self.state.view_mode) {
            .messages => try self.renderMessages(),
            .traffic => try self.renderTrafficStats(),
            .crypto => try self.renderCryptoInfo(),
            .protobuf => {}, // Requer dados externos
            .settings => {}, // Implementar depois
        }
    }

    pub fn deinit(self: *Self) !void {
        try self.exitAltScreen();
        try self.showCursor();
        try self.resetAttributes();
    }
};

pub const Color = enum(u8) {
    black = 30,
    red = 31,
    green = 32,
    yellow = 33,
    blue = 34,
    magenta = 35,
    cyan = 36,
    white = 37,
    default = 39,
    reverse = 7,
};

/// Gerenciador de input do teclado
pub const InputHandler = struct {
    reader: anytype,
    state: *TuiState,
    running: bool,

    const Self = @This();

    pub fn init(reader: anytype, state: *TuiState) Self {
        return .{
            .reader = reader,
            .state = state,
            .running = true,
        };
    }

    /// Processa input do usuário
    pub fn handleInput(self: *Self) !void {
        var buf: [4]u8 = undefined;
        const n = try self.reader.read(&buf);
        
        if (n == 0) {
            self.running = false;
            return;
        }
        
        if (n >= 1) {
            switch (buf[0]) {
                'q' => {
                    self.running = false;
                    return;
                },
                'j', 'G' => {
                    // Scroll down
                    if (self.state.scroll_offset < self.state.messages.len()) {
                        self.state.scroll_offset += 1;
                    }
                },
                'k', 'g' => {
                    // Scroll up
                    if (self.state.scroll_offset > 0) {
                        self.state.scroll_offset -= 1;
                    }
                },
                '1' => self.state.view_mode = .messages,
                '2' => self.state.view_mode = .traffic,
                '3' => self.state.view_mode = .crypto,
                '4' => self.state.view_mode = .protobuf,
                'r' => {
                    // Refresh/reset
                    self.state.scroll_offset = 0;
                },
                else => {},
            }
        }
        
        // Escape sequences (setas)
        if (n >= 3 and buf[0] == 0x1B and buf[1] == '[') {
            switch (buf[2]) {
                'A' => { // Up
                    if (self.state.scroll_offset > 0) {
                        self.state.scroll_offset -= 1;
                    }
                },
                'B' => { // Down
                    if (self.state.scroll_offset < self.state.messages.len()) {
                        self.state.scroll_offset += 1;
                    }
                },
                else => {},
            }
        }
    }

    pub fn isRunning(self: *const Self) bool {
        return self.running;
    }
};

/// TUI principal
pub const DebuggerTui = struct {
    allocator: std.mem.Allocator,
    state: TuiState,
    renderer: ?TerminalRenderer,
    input_handler: ?InputHandler,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .allocator = allocator,
            .state = .{
                .messages = RingBuffer(Message, 100).init(),
                .connection_status = .{
                    .connected = false,
                    .server = "",
                    .latency_ms = 0,
                    .last_ping = 0,
                    .reconnect_count = 0,
                },
                .traffic_stats = .{
                    .messages_in = 0,
                    .messages_out = 0,
                    .bytes_in = 0,
                    .bytes_out = 0,
                    .frames_processed = 0,
                    .errors = 0,
                    .start_time = std.time.timestamp(),
                },
                .crypto_keys = .{
                    .session_id = [_]u8{0} ** 32,
                    .created_at = 0,
                    .last_used = 0,
                    .ratchet_count = 0,
                    .is_active = false,
                },
                .width = 80,
                .height = 24,
                .scroll_offset = 0,
                .view_mode = .messages,
            },
            .renderer = null,
            .input_handler = null,
        };
    }

    pub fn deinit(self: *Self) void {
        // Cleanup se necessário
    }

    /// Adiciona mensagem ao buffer
    pub fn addMessage(
        self: *Self,
        direction: Direction,
        jid: []const u8,
        content: []const u8,
        msg_type: MessageType,
        encrypted: bool,
        frame_id: u32,
    ) void {
        const msg = Message{
            .timestamp = std.time.timestamp(),
            .direction = direction,
            .jid = jid,
            .content_preview = content,
            .message_type = msg_type,
            .encrypted = encrypted,
            .frame_id = frame_id,
        };
        self.state.messages.push(msg);
    }

    /// Atualiza estatísticas de tráfego
    pub fn updateTrafficStats(
        self: *Self,
        bytes_in: u64,
        bytes_out: u64,
        frames: u64,
    ) void {
        self.state.traffic_stats.bytes_in += bytes_in;
        self.state.traffic_stats.bytes_out += bytes_out;
        self.state.traffic_stats.frames_processed += frames;
    }

    /// Executa loop principal da TUI
    pub fn run(self: *Self) !void {
        const stdout = std.io.getStdOut().writer();
        const stdin = std.io.getStdIn().reader();
        
        var renderer = TerminalRenderer.init(stdout, &self.state);
        var input_handler = InputHandler.init(stdin, &self.state);
        
        self.renderer = renderer;
        self.input_handler = input_handler;
        
        // Configura terminal raw mode
        try self.setRawMode(true);
        try renderer.enterAltScreen();
        try renderer.hideCursor();
        
        errdefer {
            renderer.exitAltScreen() catch {};
            renderer.showCursor() catch {};
            self.setRawMode(false) catch {};
        }
        
        // Loop principal
        while (input_handler.isRunning()) {
            try renderer.render();
            try input_handler.handleInput();
            
            // Small delay para evitar CPU spike
            std.time.sleep(16 * std.time.ns_per_ms); // ~60 FPS
        }
        
        // Cleanup
        try renderer.exitAltScreen();
        try renderer.showCursor();
        try self.setRawMode(false);
    }

    fn setRawMode(self: *Self, enable: bool) !void {
        if (builtin.os.tag == .windows) {
            // Windows-specific raw mode
            return;
        }
        
        const stdin_fd = std.posix.STDIN_FILENO;
        
        if (enable) {
            // Raw mode: desabilita echo, line buffering, etc.
            try std.posix.system(ioctl.TCGETS, stdin_fd, @intFromPtr(&termios));
            const orig = termios;
            termios.lflag &= ~@as(u32, @bitCast(std.posix.termios.ECHO));
            termios.lflag &= ~@as(u32, @bitCast(std.posix.termios.ICANON));
            termios.cflag |= @as(u32, @bitCast(std.posix.termios.CS8));
            termios.iflag &= ~@as(u32, @bitCast(std.posix.termios.ISTRIP));
            termios.iflag &= ~@as(u32, @bitCast(std.posix.termios.INPCK));
            termios.cc[std.posix.termios.VMIN] = 1;
            termios.cc[std.posix.termios.VTIME] = 0;
            try std.posix.system(ioctl.TCSETS, stdin_fd, @intFromPtr(&termios));
        } else {
            // Restaura modo original
            // Em produção, salvaríamos o estado original
        }
    }
};

// Constants para ioctl (Linux)
const ioctl = struct {
    pub const TCGETS: u32 = 0x5401;
    pub const TCSETS: u32 = 0x5402;
};

var termios: std.posix.termios = undefined;

/// Exemplo de uso e testes
test "RingBuffer basic operations" {
    var ring = RingBuffer(u32, 10).init();
    
    try std.testing.expectEqual(@as(usize, 0), ring.len());
    try std.testing.expect(ring.isEmpty());
    
    ring.push(1);
    ring.push(2);
    ring.push(3);
    
    try std.testing.expectEqual(@as(usize, 3), ring.len());
    try std.testing.expectEqual(@as(?u32, 1), ring.pop());
    try std.testing.expectEqual(@as(?u32, 2), ring.pop());
    
    try std.testing.expectEqual(@as(usize, 1), ring.len());
}

test "RingBuffer overflow handling" {
    var ring = RingBuffer(u32, 3).init();
    
    ring.push(1);
    ring.push(2);
    ring.push(3);
    ring.push(4); // Deve remover o primeiro
    
    try std.testing.expectEqual(@as(usize, 3), ring.len());
    try std.testing.expectEqual(@as(?u32, 2), ring.pop());
    try std.testing.expectEqual(@as(?u32, 3), ring.pop());
    try std.testing.expectEqual(@as(?u32, 4), ring.pop());
    try std.testing.expectEqual(@as(?u32, null), ring.pop());
}

test "TuiState initialization" {
    const allocator = std.testing.allocator;
    var tui = DebuggerTui.init(allocator);
    defer tui.deinit();
    
    try std.testing.expectEqual(@as(usize, 0), tui.state.messages.len());
    try std.testing.expect(!tui.state.connection_status.connected);
    try std.testing.expectEqual(ViewMode.messages, tui.state.view_mode);
}
