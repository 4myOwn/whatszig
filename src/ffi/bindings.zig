/// FFI (Foreign Function Interface) - Exportação C ABI Nativa
/// Permite que Python, Rust, C/C++, Go e Node.js consumam a biblioteca
const std = @import("std");
const builtin = @import("builtin");

// Imports internos
const security = @import("../security.zig");
const tui = @import("../tui/debugger.zig");
const client = @import("../client.zig");

/// Configurações de exportação C ABI
comptime {
    // Garante convenção de chamada C
    _ = @export(whatszigh_init, .{ .name = "whatszigh_init" });
    _ = @export(whatszigh_deinit, .{ .name = "whatszigh_deinit" });
    _ = @export(whatszigh_connect, .{ .name = "whatszigh_connect" });
    _ = @export(whatszigh_disconnect, .{ .name = "whatszigh_disconnect" });
    _ = @export(whatszigh_send_message, .{ .name = "whatszigh_send_message" });
    _ = @export(whatszigh_receive_message, .{ .name = "whatszigh_receive_message" });
    _ = @export(whatszigh_get_error, .{ .name = "whatszigh_get_error" });
}

/// Opaque handle para o cliente WhatsApp
pub const WhatsZigHandle = opaque {
    pub fn cast(ptr: *anyopaque) *WhatsZigHandle {
        return @alignCast(@fieldPtr(ptr, "handle"));
    }
};

/// Estrutura interna do cliente
const WhatsZigClient = struct {
    allocator: std.mem.Allocator,
    client_instance: ?client.Client,
    error_buffer: [1024]u8,
    last_error: ?[]const u8,
    initialized: bool,
};

/// Resultado de operações
pub const WhatsZigResult = struct {
    success: bool,
    data: ?[*]u8,
    data_len: usize,
    error_code: c_int,
};

/// Códigos de erro
pub const ErrorCode = c_int;
pub const ERROR_NONE: ErrorCode = 0;
pub const ERROR_NOT_INITIALIZED: ErrorCode = 1;
pub const ERROR_CONNECTION_FAILED: ErrorCode = 2;
pub const ERROR_SEND_FAILED: ErrorCode = 3;
pub const ERROR_RECEIVE_FAILED: ErrorCode = 4;
pub const ERROR_INVALID_ARGUMENT: ErrorCode = 5;
pub const ERROR_MEMORY: ErrorCode = 6;
pub const ERROR_ENCRYPTION: ErrorCode = 7;

/// Inicializa a biblioteca WhatsZig
/// Retorna: handle opaco ou null em caso de falha
export fn whatszigh_init() ?*WhatsZigHandle {
    const allocator = std.heap.c_allocator;
    
    const client_wrapper = allocator.create(WhatsZigClient) catch return null;
    client_wrapper.* = .{
        .allocator = allocator,
        .client_instance = null,
        .error_buffer = undefined,
        .last_error = null,
        .initialized = false,
    };
    
    return @ptrCast(client_wrapper);
}

/// Finaliza a biblioteca e libera recursos
export fn whatszigh_deinit(handle: ?*WhatsZigHandle) void {
    if (handle) |h| {
        const client_wrapper = @as(*WhatsZigClient, @ptrCast(h));
        
        if (client_wrapper.client_instance) |*c| {
            c.deinit();
        }
        
        client_wrapper.allocator.destroy(client_wrapper);
    }
}

/// Conecta ao servidor WhatsApp
/// phone: número de telefone no formato internacional (ex: "5511999999999")
/// Returns: 0 em sucesso, código de erro caso contrário
export fn whatszigh_connect(
    handle: ?*WhatsZigHandle,
    phone: [*c]const u8,
) c_int {
    if (handle == null) return ERROR_NOT_INITIALIZED;
    
    const client_wrapper = @as(*WhatsZigClient, @ptrCast(@alignCast(handle.?)));
    
    if (phone == null) {
        client_wrapper.last_error = "Phone number is required";
        return ERROR_INVALID_ARGUMENT;
    }
    
    // Implementação simplificada - em produção usaria o client real
    client_wrapper.initialized = true;
    return ERROR_NONE;
}

/// Desconecta do servidor
export fn whatszigh_disconnect(handle: ?*WhatsZigHandle) void {
    if (handle) |h| {
        const client_wrapper = @as(*WhatsZigClient, @ptrCast(@alignCast(h)));
        client_wrapper.initialized = false;
        
        if (client_wrapper.client_instance) |*c| {
            c.disconnect();
        }
    }
}

/// Envia mensagem de texto
/// jid: JID do destinatário (ex: "5511999999999@s.whatsapp.net")
/// message: conteúdo da mensagem
/// Returns: 0 em sucesso, código de erro caso contrário
export fn whatszigh_send_message(
    handle: ?*WhatsZigHandle,
    jid: [*c]const u8,
    message: [*c]const u8,
) c_int {
    if (handle == null) return ERROR_NOT_INITIALIZED;
    if (jid == null or message == null) return ERROR_INVALID_ARGUMENT;
    
    const client_wrapper = @as(*WhatsZigClient, @ptrCast(@alignCast(handle.?)));
    
    if (!client_wrapper.initialized) {
        client_wrapper.last_error = "Not connected";
        return ERROR_NOT_INITIALIZED;
    }
    
    // Implementação simplificada
    return ERROR_NONE;
}

/// Recebe próxima mensagem (bloqueante com timeout)
/// timeout_ms: timeout em milissegundos (-1 para infinito)
/// Returns: ponteiro para dados da mensagem ou null
export fn whatszigh_receive_message(
    handle: ?*WhatsZigHandle,
    timeout_ms: c_int,
) ?WhatsZigResult {
    if (handle == null) return null;
    
    const client_wrapper = @as(*WhatsZigClient, @ptrCast(@alignCast(handle.?)));
    
    if (!client_wrapper.initialized) {
        return WhatsZigResult{
            .success = false,
            .data = null,
            .data_len = 0,
            .error_code = ERROR_NOT_INITIALIZED,
        };
    }
    
    // Implementação simplificada - retornaria mensagem real
    return WhatsZigResult{
        .success = true,
        .data = null,
        .data_len = 0,
        .error_code = ERROR_NONE,
    };
}

/// Obtém última mensagem de erro
export fn whatszigh_get_error(handle: ?*WhatsZigHandle) [*c]const u8 {
    if (handle == null) return "Handle is null";
    
    const client_wrapper = @as(*WhatsZigClient, @ptrCast(@alignCast(handle.?)));
    
    return client_wrapper.last_error orelse "No error";
}

/// Callback para recebimento assíncrono de mensagens
pub const MessageCallback = *const fn (
    user_data: ?*anyopaque,
    jid: [*c]const u8,
    message: [*c]const u8,
    message_len: usize,
    timestamp: i64,
) void;

/// Configura callback para mensagens recebidas
export fn whatszigh_set_message_callback(
    handle: ?*WhatsZigHandle,
    callback: MessageCallback,
    user_data: ?*anyopaque,
) void {
    _ = handle;
    _ = callback;
    _ = user_data;
    // Implementação futura para callbacks assíncronos
}

/// Gerenciador de estado em memória (RingBuffer cache)
pub const CacheManager = struct {
    const Self = @This();
    
    /// Cache de mensagens recentes
    message_cache: tui.RingBuffer(CachedMessage, 1000),
    /// Cache de presença de contatos
    presence_cache: std.AutoHashMap([32]u8, PresenceState),
    /// Configuração de retenção
    retention_seconds: u32,
    /// Allocator
    allocator: std.mem.Allocator,
    
    pub const CachedMessage = struct {
        jid_hash: [32]u8,
        timestamp: i64,
        message_type: u8,
        size: usize,
        data_ptr: [*]u8,
    };
    
    pub const PresenceState = enum {
        available,
        unavailable,
        composing,
        recording,
        paused,
    };
    
    pub fn init(allocator: std.mem.Allocator, retention_seconds: u32) Self {
        return .{
            .message_cache = tui.RingBuffer(CachedMessage, 1000).init(),
            .presence_cache = std.AutoHashMap([32]u8, PresenceState).init(allocator),
            .retention_seconds = retention_seconds,
            .allocator = allocator,
        };
    }
    
    pub fn deinit(self: *Self) void {
        self.presence_cache.deinit();
    }
    
    /// Adiciona mensagem ao cache
    pub fn addMessage(
        self: *Self,
        jid: []const u8,
        timestamp: i64,
        msg_type: u8,
        data: []const u8,
    ) !void {
        // Hash do JID
        const jid_hash = std.crypto.hash.sha2.Sha256.hash(jid);
        
        // Copia dados para heap
        const data_copy = try self.allocator.dupe(u8, data);
        
        const cached = CachedMessage{
            .jid_hash = jid_hash,
            .timestamp = timestamp,
            .message_type = msg_type,
            .size = data.len,
            .data_ptr = data_copy.ptr,
        };
        
        self.message_cache.push(cached);
    }
    
    /// Obtém mensagens do cache
    pub fn getMessages(self: *Self, count: usize) []const CachedMessage {
        const actual_count = @min(count, self.message_cache.len());
        const messages = self.message_cache.data[0..actual_count];
        return messages;
    }
    
    /// Atualiza estado de presença
    pub fn updatePresence(self: *Self, jid: []const u8, state: PresenceState) !void {
        const jid_hash = std.crypto.hash.sha2.Sha256.hash(jid);
        try self.presence_cache.put(jid_hash, state);
    }
    
    /// Obtém estado de presença
    pub fn getPresence(self: *Self, jid: []const u8) ?PresenceState {
        const jid_hash = std.crypto.hash.sha2.Sha256.hash(jid);
        return self.presence_cache.get(jid_hash);
    }
    
    /// Limpa mensagens antigas baseado na retenção
    pub fn cleanupOldMessages(self: *Self) void {
        const now = std.time.timestamp();
        const cutoff = now - @as(i64, @intCast(self.retention_seconds));
        
        // Implementação simplificada - em produção iteraria pelo cache
        _ = cutoff;
    }
};

/// Exporta funções do CacheManager para C
export fn whatszigh_cache_create(retention_seconds: u32) ?*CacheManager {
    const allocator = std.heap.c_allocator;
    const cache = allocator.create(CacheManager) catch return null;
    cache.* = cache.init(allocator, retention_seconds);
    return cache;
}

export fn whatszigh_cache_destroy(cache: ?*CacheManager) void {
    if (cache) |c| {
        c.deinit();
        std.heap.c_allocator.destroy(c);
    }
}

/// Estrutura para bindings de alto nível
pub const LanguageBindings = struct {
    /// Gera header C para bindings
    pub fn generateCHeader() []const u8 {
        return 
            \\#ifndef WHATSZIG_H
            \\#define WHATSZIG_H
            \\
            \\#include <stdint.h>
            \\#include <stddef.h>
            \\
            \\#ifdef __cplusplus
            \\extern "C" {
            \\#endif
            \\
            \\typedef struct WhatsZigHandle WhatsZigHandle;
            \\
            \\typedef struct {
            \\    int success;
            \\    unsigned char* data;
            \\    size_t data_len;
            \\    int error_code;
            \\} WhatsZigResult;
            \\
            \\typedef void (*MessageCallback)(
            \\    void* user_data,
            \\    const char* jid,
            \\    const char* message,
            \\    size_t message_len,
            \\    int64_t timestamp
            \\);
            \\
            \\WhatsZigHandle* whatszigh_init(void);
            \\void whatszigh_deinit(WhatsZigHandle* handle);
            \\int whatszigh_connect(WhatsZigHandle* handle, const char* phone);
            \\void whatszigh_disconnect(WhatsZigHandle* handle);
            \\int whatszigh_send_message(WhatsZigHandle* handle, const char* jid, const char* message);
            \\WhatsZigResult* whatszigh_receive_message(WhatsZigHandle* handle, int timeout_ms);
            \\const char* whatszigh_get_error(WhatsZigHandle* handle);
            \\void whatszigh_set_message_callback(WhatsZigHandle* handle, MessageCallback cb, void* user_data);
            \\
            \\CacheManager* whatszigh_cache_create(uint32_t retention_seconds);
            \\void whatszigh_cache_destroy(CacheManager* cache);
            \\
            \\#ifdef __cplusplus
            \\}
            \\#endif
            \\
            \\#endif // WHATSZIG_H
            \\
        ;
    }
    
    /// Gera exemplo de binding Python usando ctypes
    pub fn generatePythonBinding() []const u8 {
        return 
            \\"""
            \\Python bindings for WhatsZig using ctypes
            \\"""
            \\import ctypes
            \\from typing import Optional, Callable
            \\
            \\# Carrega biblioteca compartilhada
            \\_lib = ctypes.CDLL("./libwhatszigh.so")
            \\
            \\# Tipos
            \\class WhatsZigHandle(ctypes.Structure):
            \\    pass
            \\
            \\WhatsZigHandlePtr = ctypes.POINTER(WhatsZigHandle)
            \\
            \\class WhatsZigResult(ctypes.Structure):
            \\    _fields_ = [
            \\        ("success", ctypes.c_bool),
            \\        ("data", ctypes.POINTER(ctypes.c_ubyte)),
            \\        ("data_len", ctypes.c_size_t),
            \\        ("error_code", ctypes.c_int),
            \\    ]
            \\
            \\MessageCallback = ctypes.CFUNCTYPE(
            \\    None,
            \\    ctypes.c_void_p,
            \\    ctypes.c_char_p,
            \\    ctypes.c_char_p,
            \\    ctypes.c_size_t,
            \\    ctypes.c_int64,
            \\)
            \\
            \\# Funções
            \\_lib.whatszigh_init.argtypes = []
            \\_lib.whatszigh_init.restype = WhatsZigHandlePtr
            \\
            \\_lib.whatszigh_deinit.argtypes = [WhatsZigHandlePtr]
            \\_lib.whatszigh_deinit.restype = None
            \\
            \\_lib.whatszigh_connect.argtypes = [WhatsZigHandlePtr, ctypes.c_char_p]
            \\_lib.whatszigh_connect.restype = ctypes.c_int
            \\
            \\_lib.whatszigh_send_message.argtypes = [
            \\    WhatsZigHandlePtr,
            \\    ctypes.c_char_p,
            \\    ctypes.c_char_p,
            \\]
            \\_lib.whatszigh_send_message.restype = ctypes.c_int
            \\
            \\class WhatsZig:
            \\    def __init__(self):
            \\        self._handle = _lib.whatszigh_init()
            \\        if not self._handle:
            \\            raise RuntimeError("Failed to initialize WhatsZig")
            \\
            \\    def __del__(self):
            \\        _lib.whatszigh_deinit(self._handle)
            \\
            \\    def connect(self, phone: str) -> None:
            \\        result = _lib.whatszigh_connect(
            \\            self._handle,
            \\            phone.encode('utf-8')
            \\        )
            \\        if result != 0:
            \\            raise RuntimeError(f"Connection failed with error {result}")
            \\
            \\    def send_message(self, jid: str, message: str) -> None:
            \\        result = _lib.whatszigh_send_message(
            \\            self._handle,
            \\            jid.encode('utf-8'),
            \\            message.encode('utf-8'),
            \\        )
            \\        if result != 0:
            \\            raise RuntimeError(f"Send failed with error {result}")
            \\
        ;
    }
    
    /// Gera exemplo de binding Node.js usando node-ffi-napi
    pub fn generateNodeJsBinding() []const u8 {
        return 
            \\/**
            \\ * Node.js bindings for WhatsZig using ffi-napi
            \\ */
            \\const ffi = require('ffi-napi');
            \\const ref = require('ref-napi');
            \\
            \\// Tipos
            \\const WhatsZigHandlePtr = ref.types.void;
            \\const WhatsZigResult = ref.types.struct({
            \\    success: ref.types.bool,
            \\    data: ref.types.uchar,
            \\    data_len: ref.types.size_t,
            \\    error_code: ref.types.int,
            \\});
            \\
            \\// Carrega biblioteca
            \\const lib = ffi.Library('./libwhatszigh', {
            \\    'whatszigh_init': [WhatsZigHandlePtr, []],
            \\    'whatszigh_deinit': ['void', [WhatsZigHandlePtr]],
            \\    'whatszigh_connect': ['int', [WhatsZigHandlePtr, 'string']],
            \\    'whatszigh_send_message': ['int', [WhatsZigHandlePtr, 'string', 'string']],
            \\    'whatszigh_receive_message': [WhatsZigResult, [WhatsZigHandlePtr, 'int']],
            \\    'whatszigh_get_error': ['string', [WhatsZigHandlePtr]],
            \\});
            \\
            \\class WhatsZig {
            \\    constructor() {
            \\        this.handle = lib.whatszigh_init();
            \\        if (!this.handle) {
            \\            throw new Error('Failed to initialize WhatsZig');
            \\        }
            \\    }
            \\
            \\    destroy() {
            \\        lib.whatszigh_deinit(this.handle);
            \\    }
            \\
            \\    connect(phone) {
            \\        const result = lib.whatszigh_connect(this.handle, phone);
            \\        if (result !== 0) {
            \\            throw new Error(`Connection failed with error ${result}`);
            \\        }
            \\    }
            \\
            \\    sendMessage(jid, message) {
            \\        const result = lib.whatszigh_send_message(this.handle, jid, message);
            \\        if (result !== 0) {
            \\            throw new Error(`Send failed with error ${result}`);
            \\        }
            \\    }
            \\
            \\    receiveMessage(timeoutMs = -1) {
            \\        return lib.whatszigh_receive_message(this.handle, timeoutMs);
            \\    }
            \\
            \\    getError() {
            \\        return lib.whatszigh_get_error(this.handle);
            \\    }
            \\}
            \\
            \\module.exports = { WhatsZig };
            \\
        ;
    }
    
    /// Gera exemplo de binding Rust usando bindgen
    pub fn generateRustBinding() []const u8 {
        return 
            \\//! Rust bindings for WhatsZig
            \\//! Generated using bindgen or manually defined
            \\
            \\use std::ffi::{c_char, c_int, c_void, CStr};
            \\use std::ptr;
            \\
            \\#[repr(C)]
            \\pub struct WhatsZigHandle {
            \\    _private: [u8; 0],
            \\}
            \\
            \\#[repr(C)]
            \\pub struct WhatsZigResult {
            \\    pub success: bool,
            \\    pub data: *mut u8,
            \\    pub data_len: usize,
            \\    pub error_code: c_int,
            \\}
            \\
            \\type MessageCallback = unsafe extern "C" fn(
            \\    user_data: *mut c_void,
            \\    jid: *const c_char,
            \\    message: *const c_char,
            \\    message_len: usize,
            \\    timestamp: i64,
            \\);
            \\
            \\extern "C" {
            \\    pub fn whatszigh_init() -> *mut WhatsZigHandle;
            \\    pub fn whatszigh_deinit(handle: *mut WhatsZigHandle);
            \\    pub fn whatszigh_connect(
            \\        handle: *mut WhatsZigHandle,
            \\        phone: *const c_char,
            \\    ) -> c_int;
            \\    pub fn whatszigh_disconnect(handle: *mut WhatsZigHandle);
            \\    pub fn whatszigh_send_message(
            \\        handle: *mut WhatsZigHandle,
            \\        jid: *const c_char,
            \\        message: *const c_char,
            \\    ) -> c_int;
            \\    pub fn whatszigh_receive_message(
            \\        handle: *mut WhatsZigHandle,
            \\        timeout_ms: c_int,
            \\    ) -> WhatsZigResult;
            \\    pub fn whatszigh_get_error(handle: *mut WhatsZigHandle) -> *const c_char;
            \\}
            \\
            \\pub struct WhatsZig {
            \\    handle: *mut WhatsZigHandle,
            \\}
            \\
            \\impl WhatsZig {
            \\    pub fn new() -> Option<Self> {
            \\        unsafe {
            \\            let handle = whatszigh_init();
            \\            if handle.is_null() {
            \\                None
            \\            } else {
            \\                Some(Self { handle })
            \\            }
            \\        }
            \\    }
            \\
            \\    pub fn connect(&self, phone: &str) -> Result<(), String> {
            \\        let phone_c = std::ffi::CString::new(phone).unwrap();
            \\        unsafe {
            \\            let result = whatszigh_connect(self.handle, phone_c.as_ptr());
            \\            if result == 0 {
            \\                Ok(())
            \\            } else {
            \\                Err(format!("Connection failed with error {}", result))
            \\            }
            \\        }
            \\    }
            \\
            \\    pub fn send_message(&self, jid: &str, message: &str) -> Result<(), String> {
            \\        let jid_c = std::ffi::CString::new(jid).unwrap();
            \\        let msg_c = std::ffi::CString::new(message).unwrap();
            \\        unsafe {
            \\            let result = whatszigh_send_message(self.handle, jid_c.as_ptr(), msg_c.as_ptr());
            \\            if result == 0 {
            \\                Ok(())
            \\            } else {
            \\                Err(format!("Send failed with error {}", result))
            \\            }
            \\        }
            \\    }
            \\}
            \\
            \\impl Drop for WhatsZig {
            \\    fn drop(&mut self) {
            \\        unsafe {
            \\            whatszigh_deinit(self.handle);
            \\        }
            \\    }
            \\}
            \\
        ;
    }
};

/// Testes
test "FFI initialization" {
    const handle = whatszigh_init();
    try std.testing.expect(handle != null);
    
    whatszigh_deinit(handle);
}

test "FFI error handling" {
    const error_msg = whatszigh_get_error(null);
    try std.testing.expectEqualStrings("Handle is null", error_msg);
}

test "CacheManager basic operations" {
    const allocator = std.testing.allocator;
    var cache = CacheManager.init(allocator, 3600); // 1 hora de retenção
    defer cache.deinit();
    
    const jid = "5511999999999@s.whatsapp.net";
    const message = "Hello, World!";
    const timestamp = std.time.timestamp();
    
    try cache.addMessage(jid, timestamp, 1, message);
    
    const messages = cache.getMessages(10);
    try std.testing.expectEqual(@as(usize, 1), messages.len);
}

test "LanguageBindings generation" {
    const c_header = LanguageBindings.generateCHeader();
    try std.testing.expect(c_header.len > 0);
    try std.testing.expect(std.mem.indexOf(u8, c_header, "whatszigh_init") != null);
    
    const python_binding = LanguageBindings.generatePythonBinding();
    try std.testing.expect(python_binding.len > 0);
    
    const nodejs_binding = LanguageBindings.generateNodeJsBinding();
    try std.testing.expect(nodejs_binding.len > 0);
    
    const rust_binding = LanguageBindings.generateRustBinding();
    try std.testing.expect(rust_binding.len > 0);
}
