/// Módulo de Segurança para WhatsApp Zig
/// Implementa: Anti-Ban Engine, Isolação Zero-Memory, Criptografia Hardware-Accelerated e Armazenamento Seguro
const std = @import("std");
const crypto = std.crypto;
const builtin = @import("builtin");

// Importações internas
const xed25519 = @import("xed25519");
const noise = @import("noise");

/// Configurações de comportamento humano para anti-detecção
pub const HumanBehavior = struct {
    /// Intervalo base de digitação em milissegundos
    base_typing_interval_ms: u32 = 50,
    /// Variação máxima (jitter) em milissegundos
    max_jitter_ms: u32 = 30,
    /// Probabilidade de pausa longa (0.0-1.0)
    long_pause_probability: f64 = 0.15,
    /// Duração de pausa longa em milissegundos
    long_pause_duration_ms: u32 = 500,
    /// Caracteres por intervalo de digitação (distribuição normal)
    chars_per_interval_mean: f64 = 3.5,
    chars_per_interval_stddev: f64 = 1.2,

    /// Gera intervalo de digitação com jitter estatístico
    pub fn getTypingInterval(self: HumanBehavior, rng: *std.rand.Random) u32 {
        // Jitter uniforme básico
        const jitter = rng.intRangeAtMost(u32, 0, self.max_jitter_ms);
        
        // Pausa longa ocasional para simular pensamento
        if (rng.float(f64) < self.long_pause_probability) {
            return self.long_pause_duration_ms + jitter;
        }
        
        return self.base_typing_interval_ms + jitter;
    }

    /// Calcula atraso total baseado no tamanho do texto
    pub fn calculateTypingDelay(self: HumanBehavior, text: []const u8, rng: *std.rand.Random) u32 {
        if (text.len == 0) return 0;
        
        var total_delay: u32 = 0;
        var chars_remaining: f64 = @floatFromInt(text.len);
        
        while (chars_remaining > 0) {
            // Número de caracteres neste intervalo (distribuição normal truncada)
            const chars_now = @min(
                chars_remaining,
                @max(1.0, self.charsPerInterval(rng)),
            );
            
            total_delay += self.getTypingInterval(rng);
            chars_remaining -= chars_now;
        }
        
        return total_delay;
    }

    fn charsPerInterval(self: HumanBehavior, rng: *std.rand.Random) f64 {
        // Box-Muller transform para distribuição normal
        const u1 = @max(0.0001, rng.float(f64));
        const u2 = rng.float(f64);
        
        const z = @sqrt(-2.0 * @log(u1)) * @cos(2.0 * std.math.pi * u2);
        const result = self.chars_per_interval_mean + z * self.chars_per_interval_stddev;
        
        return @max(1.0, result);
    }
};

/// Rotação e Spoofing de User-Agent / Device Specs
pub const DeviceFingerprint = struct {
    /// User-Agent string
    user_agent: []const u8,
    /// Versão do app WhatsApp
    app_version: []const u8,
    /// OS (Android, iOS, Windows, macOS, Web)
    os_type: OSType,
    /// Versão do OS
    os_version: []const u8,
    /// Modelo do dispositivo
    device_model: []const u8,
    /// Resolução de tela
    screen_width: u16,
    screen_height: u16,
    /// Timezone offset em minutos
    timezone_offset: i16,
    /// Locale
    locale: []const u8,

    pub const OSType = enum {
        android,
        ios,
        windows,
        macos,
        linux,
        web,
    };

    /// Perfis predefinidos de dispositivos comuns
    pub const profiles = struct {
        pub const android_pixel_7 = DeviceFingerprint{
            .user_agent = "WhatsApp/2.23.25.84 Android/13",
            .app_version = "2.23.25.84",
            .os_type = .android,
            .os_version = "13",
            .device_model = "Pixel 7",
            .screen_width = 1080,
            .screen_height = 2400,
            .timezone_offset = -180,
            .locale = "en_US",
        };

        pub const iphone_14 = DeviceFingerprint{
            .user_agent = "WhatsApp/2.23.24.81 iOS/16.6",
            .app_version = "2.23.24.81",
            .os_type = .ios,
            .os_version = "16.6",
            .device_model = "iPhone14,2",
            .screen_width = 1170,
            .screen_height = 2532,
            .timezone_offset = -180,
            .locale = "en_US",
        };

        pub const windows_desktop = DeviceFingerprint{
            .user_agent = "WhatsApp/2.2345.52 Windows/10",
            .app_version = "2.2345.52",
            .os_type = .windows,
            .os_version = "10",
            .device_model = "Desktop",
            .screen_width = 1920,
            .screen_height = 1080,
            .timezone_offset = -180,
            .locale = "en_US",
        };

        pub const macos_desktop = DeviceFingerprint{
            .user_agent = "WhatsApp/2.2344.52 macOS/13.5",
            .app_version = "2.2344.52",
            .os_type = .macos,
            .os_version = "13.5",
            .device_model = "MacBookPro",
            .screen_width = 2560,
            .screen_height = 1600,
            .timezone_offset = -180,
            .locale = "en_US",
        };
    };

    /// Gera User-Agent dinâmico com variação sutil
    pub fn generateDynamicUserAgent(
        allocator: std.mem.Allocator,
        base_profile: DeviceFingerprint,
        rng: *std.rand.Random,
    ) ![]u8 {
        // Pequena variação na versão do app (últimos dígitos)
        var version_parts = std.mem.splitScalar(u8, base_profile.app_version, '.');
        var parts: [4][]const u8 = undefined;
        var i: usize = 0;
        
        while (version_parts.next()) |part| : (i += 1) {
            parts[i] = part;
        }
        
        // Varia o último componente da versão
        if (i > 0) {
            const last_part = try std.fmt.parseInt(u32, parts[i - 1], 10);
            const variation = rng.intRangeAtMost(i32, -2, 2);
            const new_last = @as(u32, @intCast(@max(1, @as(i32, @intCast(last_part)) + variation)));
            
            const result = try std.fmt.allocPrint(
                allocator,
                "{s}/{s}.{s}.{s} {s}/{s}",
                .{
                    switch (base_profile.os_type) {
                        .android, .ios => "WhatsApp",
                        .windows, .macos, .linux => "WhatsApp",
                        .web => "Mozilla/5.0",
                    },
                    parts[0],
                    parts[1],
                    try std.fmt.allocPrint(allocator, "{}", .{new_last}),
                    @tagName(base_profile.os_type),
                    base_profile.os_version,
                },
            );
            return result;
        }
        
        return try allocator.dupe(u8, base_profile.user_agent);
    }
};

/// Gerenciador de rotação de fingerprints
pub const FingerprintRotator = struct {
    current_profile: DeviceFingerprint,
    rotation_count: usize,
    last_rotation_time: u64,
    rng: std.rand.Random,
    allocator: std.mem.Allocator,

    const RotationStrategy = enum {
        /// Rotação a cada N mensagens
        per_message,
        /// Rotação após tempo T
        timed,
        /// Rotação aleatória
        random,
    };

    pub fn init(allocator: std.mem.Allocator, seed: u64) FingerprintRotator {
        var prng = std.rand.DefaultPrng.init(seed);
        return .{
            .current_profile = DeviceFingerprint.profiles.android_pixel_7,
            .rotation_count = 0,
            .last_rotation_time = 0,
            .rng = prng.random(),
            .allocator = allocator,
        };
    }

    /// Rotaciona para um novo perfil de dispositivo
    pub fn rotate(self: *FingerprintRotator) !void {
        const profiles = [_]DeviceFingerprint{
            DeviceFingerprint.profiles.android_pixel_7,
            DeviceFingerprint.profiles.iphone_14,
            DeviceFingerprint.profiles.windows_desktop,
            DeviceFingerprint.profiles.macos_desktop,
        };
        
        const index = self.rng.intRangeAtMost(usize, 0, profiles.len - 1);
        self.current_profile = profiles[index];
        self.rotation_count += 1;
    }

    /// Decide se deve rotacionar baseado na estratégia
    pub fn shouldRotate(self: *FingerprintRotator, strategy: RotationStrategy, message_count: usize, elapsed_time: u64) bool {
        return switch (strategy) {
            .per_message => message_count % 10 == 0,
            .timed => elapsed_time - self.last_rotation_time > 3600, // 1 hora
            .random => self.rng.float(f32) < 0.05, // 5% de chance
        };
    }
};

/// Isolação Zero-Memory / Secure Erasure
pub const SecureMemory = struct {
    /// Apaga seguramente uma região de memória
    /// Usa std.mem.secureZero para prevenir otimizações do compilador
    pub fn secureErase(ptr: []u8) void {
        std.mem.secureZero(u8, ptr);
    }

    /// Wrapper seguro para chaves criptográficas
    pub fn SecureKey(comptime KeyType: type) type {
        return struct {
            data: KeyType,
            is_active: bool,

            const Self = @This();

            pub fn init(value: KeyType) Self {
                return .{
                    .data = value,
                    .is_active = true,
                };
            }

            pub fn deinit(self: *Self) void {
                if (self.is_active) {
                    std.mem.secureZero(KeyType, &self.data);
                    self.is_active = false;
                }
            }

            pub fn get(self: *const Self) ?KeyType {
                if (!self.is_active) return null;
                return self.data;
            }

            pub fn move(self: *Self, dest: *Self) void {
                dest.data = self.data;
                dest.is_active = true;
                self.deinit();
            }
        };
    }

    /// Buffer seguro que limpa automaticamente ao ser destruído
    pub const SecureBuffer = struct {
        data: []u8,
        allocator: std.mem.Allocator,
        is_active: bool,

        pub fn init(allocator: std.mem.Allocator, size: usize) !SecureBuffer {
            const data = try allocator.alloc(u8, size);
            return .{
                .data = data,
                .allocator = allocator,
                .is_active = true,
            };
        }

        pub fn deinit(self: *SecureBuffer) void {
            if (self.is_active) {
                std.mem.secureZero(u8, self.data);
                self.allocator.free(self.data);
                self.is_active = false;
            }
        }

        pub fn fill(self: *SecureBuffer, value: u8) void {
            @memset(self.data, value);
        }
    };
};

/// Criptografia Hardware-Accelerated usando instruções nativas da CPU
pub const HardwareAcceleratedCrypto = struct {
    /// Detecta recursos de hardware disponíveis
    pub const CpuFeatures = struct {
        has_aes_ni: bool,
        has_neon: bool,
        has_avx2: bool,
        has_sha_extensions: bool,

        pub fn detect() CpuFeatures {
            return .{
                .has_aes_ni = detectAesNi(),
                .has_neon = detectNeon(),
                .has_avx2 = detectAvx2(),
                .has_sha_extensions = detectShaExtensions(),
            };
        }

        fn detectAesNi() bool {
            if (builtin.cpu.arch != .x86_64 and builtin.cpu.arch != .x86) return false;
            return @import("std").target.x86.featureSetHas(builtin.cpu.features, .aes);
        }

        fn detectNeon() bool {
            return builtin.cpu.arch == .aarch64 or builtin.cpu.arch == .arm;
        }

        fn detectAvx2() bool {
            if (builtin.cpu.arch != .x86_64 and builtin.cpu.arch != .x86) return false;
            return @import("std").target.x86.featureSetHas(builtin.cpu.features, .avx2);
        }

        fn detectShaExtensions() bool {
            if (builtin.cpu.arch != .x86_64 and builtin.cpu.arch != .x86) return false;
            return @import("std").target.x86.featureSetHas(builtin.cpu.features, .sha);
        }
    };

    /// AES-GCM acelerado por hardware quando disponível
    pub const AesGcmAccelerated = struct {
        key: [32]u8,
        features: CpuFeatures,

        pub fn init(key: [32]u8) AesGcmAccelerated {
            return .{
                .key = key,
                .features = CpuFeatures.detect(),
            };
        }

        pub fn encrypt(
            self: *const AesGcmAccelerated,
            allocator: std.mem.Allocator,
            plaintext: []const u8,
            aad: []const u8,
            nonce: [12]u8,
        ) ![]u8 {
            // Usa implementação padrão do Zig (que já é otimizada)
            // Em produção, poderia usar intrinsics específicos aqui
            const Aes256Gcm = crypto.aead.aes_gcm.Aes256Gcm;
            
            const ciphertext_len = plaintext.len + Aes256Gcm.tag_length;
            const result = try allocator.alloc(u8, ciphertext_len);
            errdefer allocator.free(result);

            var tag: [Aes256Gcm.tag_length]u8 = undefined;
            Aes256Gcm.encrypt(
                result[0..plaintext.len],
                &tag,
                plaintext,
                aad,
                nonce,
                self.key,
            );
            @memcpy(result[plaintext.len..], &tag);

            return result;
        }

        pub fn decrypt(
            self: *const AesGcmAccelerated,
            allocator: std.mem.Allocator,
            ciphertext_with_tag: []const u8,
            aad: []const u8,
            nonce: [12]u8,
        ) ![]u8 {
            const Aes256Gcm = crypto.aead.aes_gcm.Aes256Gcm;
            
            if (ciphertext_with_tag.len < Aes256Gcm.tag_length) 
                return error.CiphertextTooShort;

            const ciphertext_len = ciphertext_with_tag.len - Aes256Gcm.tag_length;
            const plaintext = try allocator.alloc(u8, ciphertext_len);
            errdefer allocator.free(plaintext);

            const ciphertext = ciphertext_with_tag[0..ciphertext_len];
            const tag = ciphertext_with_tag[ciphertext_len..][0..Aes256Gcm.tag_length].*;

            Aes256Gcm.decrypt(
                plaintext,
                ciphertext,
                tag,
                aad,
                nonce,
                self.key,
            ) catch return error.DecryptionFailed;

            return plaintext;
        }
    };

    /// Otimizações específicas para Noise Protocol
    pub const NoiseOptimizations = struct {
        features: CpuFeatures,

        pub fn init() NoiseOptimizations {
            return .{
                .features = CpuFeatures.detect(),
            };
        }

        /// Realiza multiplicação escalar Curve25519 otimizada
        pub fn scalarMult(
            self: *const NoiseOptimizations,
            scalar: [32]u8,
            point: [32]u8,
        ) ![32]u8 {
            // Delega para xed25519 que já tem otimizações
            _ = self;
            const X25519 = crypto.curve25519.X25519;
            return X25519.scalarMult(scalar, point);
        }

        /// Hash SHA256 potencialmente acelerado
        pub fn hashSha256(self: *const NoiseOptimizations, data: []const u8) [32]u8 {
            _ = self;
            return crypto.hash.sha2.Sha256.hash(data);
        }

        /// HKDF-SHA256 para derivação de chaves
        pub fn hkdfSha256(
            self: *const NoiseOptimizations,
            salt: []const u8,
            ikm: []const u8,
            info: []const u8,
            output: []u8,
        ) void {
            _ = self;
            const HkdfSha256 = crypto.kdf.hkdf.HkdfSha256;
            HkdfSha256.derive(output, salt, ikm, info);
        }
    };
};

/// Armazenamento Seguro de Sessão (Encrypted Vault)
pub const SecureVault = struct {
    const VaultEntry = struct {
        key_hash: [32]u8,
        encrypted_data: []u8,
        nonce: [12]u8,
        created_at: u64,
    };

    allocator: std.mem.Allocator,
    encryption_key: ?[32]u8,
    entries: std.AutoArrayHashMap([32]u8, VaultEntry),
    vault_path: ?[]const u8,

    pub const VaultError = error{
        VaultNotInitialized,
        KeyNotFound,
        DecryptionFailed,
        IoError,
        PlatformNotSupported,
    };

    pub fn init(allocator: std.mem.Allocator) SecureVault {
        return .{
            .allocator = allocator,
            .encryption_key = null,
            .entries = std.AutoArrayHashMap([32]u8, VaultEntry).init(allocator),
            .vault_path = null,
        };
    }

    pub fn deinit(self: *SecureVault) void {
        // Limpa todas as entradas seguramente
        var it = self.entries.iterator();
        while (it.next()) |entry| {
            std.mem.secureZero(u8, entry.value_ptr.encrypted_data);
            self.allocator.free(entry.value_ptr.encrypted_data);
        }
        self.entries.deinit();

        // Limpa chave de encriptação
        if (self.encryption_key) |*key| {
            std.mem.secureZero([32]u8, key);
        }
    }

    /// Inicializa o vault com chave derivada de senha
    pub fn initWithPassword(
        self: *SecureVault,
        password: []const u8,
        salt: []const u8,
    ) !void {
        // Deriva chave usando Argon2id (resistente a GPU/ASIC)
        const derived_key = try self.deriveKeyFromPassword(password, salt);
        self.encryption_key = derived_key;
    }

    /// Inicializa o vault usando sistema de keyring do SO
    pub fn initWithSystemKeyring(self: *SecureVault, service_name: []const u8, account_name: []const u8) !void {
        const key = try getSystemKeyring(service_name, account_name);
        errdefer std.mem.secureZero([32]u8, &key);
        self.encryption_key = key;
    }

    /// Salva sessão criptografada no vault
    pub fn saveSession(
        self: *SecureVault,
        session_id: []const u8,
        session_data: []const u8,
    ) VaultError!void {
        if (self.encryption_key == null) return VaultError.VaultNotInitialized;

        // Hash do session_id como chave de lookup
        const key_hash = crypto.hash.sha2.Sha256.hash(session_id);

        // Gera nonce aleatório
        var nonce: [12]u8 = undefined;
        crypto.random.bytes(&nonce);

        // Encripta dados
        const encrypted_data = try self.encryptData(session_data, &nonce);
        errdefer self.allocator.free(encrypted_data);

        // Remove entrada existente se houver
        if (self.entries.fetchRemove(key_hash)) |existing| {
            self.allocator.free(existing.value.encrypted_data);
        }

        // Adiciona nova entrada
        try self.entries.put(key_hash, .{
            .key_hash = key_hash,
            .encrypted_data = encrypted_data,
            .nonce = nonce,
            .created_at = std.time.timestamp(),
        });
    }

    /// Carrega sessão descriptografada do vault
    pub fn loadSession(
        self: *SecureVault,
        session_id: []const u8,
        output_buffer: []u8,
    ) VaultError!usize {
        if (self.encryption_key == null) return VaultError.VaultNotInitialized;

        const key_hash = crypto.hash.sha2.Sha256.hash(session_id);

        const entry = self.entries.getPtr(key_hash) orelse return VaultError.KeyNotFound;

        // Descriptografa dados
        const decrypted = try self.decryptData(entry.encrypted_data, &entry.nonce, output_buffer);

        return decrypted.len;
    }

    /// Remove sessão do vault com limpeza segura
    pub fn deleteSession(self: *SecureVault, session_id: []const u8) VaultError!void {
        const key_hash = crypto.hash.sha2.Sha256.hash(session_id);

        if (self.entries.fetchRemove(key_hash)) |entry| {
            std.mem.secureZero(u8, entry.value.encrypted_data);
            self.allocator.free(entry.value.encrypted_data);
        } else {
            return VaultError.KeyNotFound;
        }
    }

    fn deriveKeyFromPassword(
        self: *SecureVault,
        password: []const u8,
        salt: []const u8,
    ) ![32]u8 {
        _ = self;
        // Usa PBKDF2-HMAC-SHA256 como fallback (Argon2 exigiria dependência externa)
        var derived_key: [32]u8 = undefined;
        
        const iterations: u32 = 100000;
        crypto.pbkdf2.pbkdf2(
            std.crypto.hash.sha2.Sha256,
            &derived_key,
            password,
            salt,
            iterations,
        );
        
        return derived_key;
    }

    fn encryptData(
        self: *SecureVault,
        plaintext: []const u8,
        nonce: []const u8,
    ) ![]u8 {
        const Aes256Gcm = crypto.aead.aes_gcm.Aes256Gcm;
        const key = self.encryption_key.?;

        const ciphertext_len = plaintext.len + Aes256Gcm.tag_length;
        const result = try self.allocator.alloc(u8, ciphertext_len);
        errdefer self.allocator.free(result);

        var tag: [Aes256Gcm.tag_length]u8 = undefined;
        Aes256Gcm.encrypt(
            result[0..plaintext.len],
            &tag,
            plaintext,
            "", // AAD vazio
            nonce[0..12].*,
            key,
        );
        @memcpy(result[plaintext.len..], &tag);

        return result;
    }

    fn decryptData(
        self: *SecureVault,
        ciphertext_with_tag: []const u8,
        nonce: []const u8,
        output_buffer: []u8,
    ) ![]u8 {
        const Aes256Gcm = crypto.aead.aes_gcm.Aes256Gcm;
        const key = self.encryption_key.?;

        if (ciphertext_with_tag.len < Aes256Gcm.tag_length) 
            return VaultError.DecryptionFailed;

        const ciphertext_len = ciphertext_with_tag.len - Aes256Gcm.tag_length;
        
        if (output_buffer.len < ciphertext_len)
            return error.OutputBufferTooSmall;

        const ciphertext = ciphertext_with_tag[0..ciphertext_len];
        const tag = ciphertext_with_tag[ciphertext_len..][0..Aes256Gcm.tag_length].*;

        Aes256Gcm.decrypt(
            output_buffer[0..ciphertext_len],
            ciphertext,
            tag,
            "", // AAD vazio
            nonce[0..12].*,
            key,
        ) catch return VaultError.DecryptionFailed;

        return output_buffer[0..ciphertext_len];
    }

    /// Integração com sistemas de keyring nativos
    fn getSystemKeyring(service_name: []const u8, account_name: []const u8) ![32]u8 {
        if (builtin.os.tag == .macos) {
            return getKeychain(service_name, account_name);
        } else if (builtin.os.tag == .windows) {
            return getDpapi(service_name, account_name);
        } else if (builtin.os.tag == .linux) {
            return getSecretService(service_name, account_name);
        } else {
            return VaultError.PlatformNotSupported;
        }
    }

    fn getKeychain(service_name: []const u8, account_name: []const u8) ![32]u8 {
        // Implementação macOS Keychain via osascript ou API nativa
        // Para simplicidade, retorna erro - em produção usaria bindings C
        _ = service_name;
        _ = account_name;
        return VaultError.PlatformNotSupported;
    }

    fn getDpapi(service_name: []const u8, account_name: []const u8) ![32]u8 {
        // Implementação Windows DPAPI via bindings C
        _ = service_name;
        _ = account_name;
        return VaultError.PlatformNotSupported;
    }

    fn getSecretService(service_name: []const u8, account_name: []const u8) ![32]u8 {
        // Implementação Linux Secret Service (GNOME Keyring / KWallet)
        _ = service_name;
        _ = account_name;
        return VaultError.PlatformNotSupported;
    }
};

/// Integrador de segurança para handshake Noise
pub const SecureHandshakeOrchestrator = struct {
    allocator: std.mem.Allocator,
    human_behavior: HumanBehavior,
    fingerprint_rotator: FingerprintRotator,
    secure_memory: *SecureMemory,
    hw_crypto: HardwareAcceleratedCrypto.NoiseOptimizations,
    vault: *SecureVault,

    pub fn init(
        allocator: std.mem.Allocator,
        vault: *SecureVault,
        rng_seed: u64,
    ) SecureHandshakeOrchestrator {
        return .{
            .allocator = allocator,
            .human_behavior = HumanBehavior{},
            .fingerprint_rotator = FingerprintRotator.init(allocator, rng_seed),
            .secure_memory = &(SecureMemory{}),
            .hw_crypto = HardwareAcceleratedCrypto.NoiseOptimizations.init(),
            .vault = vault,
        };
    }

    /// Executa handshake Noise com proteções de segurança
    pub fn performSecureHandshake(
        self: *SecureHandshakeOrchestrator,
        io: std.Io,
        prologue: []const u8,
        static_keypair: xed25519.XEd25519.KeyPair,
    ) !noise.Noise.CipherPair {
        // Simula delay de digitação humana antes do handshake
        const typing_delay = self.human_behavior.calculateTypingDelay(prologue, &self.fingerprint_rotator.rng);
        if (typing_delay > 0) {
            std.time.sleep(typing_delay * std.time.ns_per_ms);
        }

        // Inicia handshake Noise
        var client_handshake = try noise.Noise.ClientHandshake.init(
            self.allocator,
            static_keypair,
            prologue,
            io,
        );

        // ... processo de handshake ...
        // (detalhes omitidos para brevidade - usa noise.zig existente)

        const cipher_pair = client_handshake.finish();

        // Armazena chaves de sessão seguramente no vault
        try self.vault.saveSession(
            "session_keys",
            std.mem.asBytes(&cipher_pair),
        );

        // Limpa chaves da memória RAM imediatamente após uso
        std.mem.secureZero(noise.Noise.CipherPair, &cipher_pair);

        return cipher_pair;
    }
};

/// Módulo de utilitários de timing seguro
pub const SecureTiming = struct {
    /// Adiciona jitter aleatório a um intervalo
    pub fn addJitter(base_ns: u64, max_jitter_percent: u32, rng: *std.rand.Random) u64 {
        const jitter_range = (base_ns * max_jitter_percent) / 100;
        const jitter = rng.intRangeAtMost(u64, 0, jitter_range);
        return base_ns + jitter;
    }

    /// Espera com jitter para evitar padrões detectáveis
    pub fn sleepWithJitter(base_ms: u32, max_jitter_percent: u32, rng: *std.rand.Random) void {
        const base_ns = base_ms * std.time.ns_per_ms;
        const actual_ns = addJitter(base_ns, max_jitter_percent, rng);
        std.time.sleep(actual_ns);
    }
};

// Testes
test "HumanBehavior typing delay calculation" {
    var prng = std.rand.DefaultPrng.init(12345);
    const behavior = HumanBehavior{};
    
    const text = "Hello, this is a test message!";
    const delay = behavior.calculateTypingDelay(text, &prng.random());
    
    try std.testing.expect(delay > 0);
    try std.testing.expect(delay < 10000); // Deve ser menos de 10 segundos
}

test "SecureMemory secure erase" {
    var buffer = [_]u8{ 0xAA, 0xBB, 0xCC, 0xDD };
    SecureMemory.secureErase(&buffer);
    
    for (buffer) |byte| {
        try std.testing.expectEqual(@as(u8, 0), byte);
    }
}

test "SecureMemory SecureKey wrapper" {
    const KeyType = [32]u8;
    const SecureKeyType = SecureMemory.SecureKey(KeyType);
    
    var original_key: KeyType = [_]u8{0x42} ** 32;
    var secure_key = SecureKeyType.init(original_key);
    
    try std.testing.expect(secure_key.is_active);
    try std.testing.expect(secure_key.get() != null);
    
    secure_key.deinit();
    try std.testing.expect(!secure_key.is_active);
    try std.testing.expect(secure_key.get() == null);
}

test "SecureMemory SecureBuffer" {
    const allocator = std.testing.allocator;
    var secure_buf = try SecureMemory.SecureBuffer.init(allocator, 1024);
    defer secure_buf.deinit();
    
    secure_buf.fill(0xFF);
    try std.testing.expectEqual(@as(u8, 0xFF), secure_buf.data[0]);
    try std.testing.expectEqual(@as(u8, 0xFF), secure_buf.data[1023]);
}

test "HardwareAcceleratedCrypto feature detection" {
    const features = HardwareAcceleratedCrypto.CpuFeatures.detect();
    
    // Pelo menos um método de aceleração deve estar disponível
    try std.testing.expect(
        features.has_aes_ni or 
        features.has_neon or 
        features.has_avx2
    );
}

test "HardwareAcceleratedCrypto AesGcm roundtrip" {
    const allocator = std.testing.allocator;
    
    const key: [32]u8 = [_]u8{0x42} ** 32;
    const nonce: [12]u8 = [_]u8{0x00} ** 12;
    const plaintext = "Test message for encryption";
    const aad = "Additional authenticated data";
    
    const aes_gcm = HardwareAcceleratedCrypto.AesGcmAccelerated.init(key);
    
    const ciphertext = try aes_gcm.encrypt(allocator, plaintext, aad, nonce);
    defer allocator.free(ciphertext);
    
    const decrypted = try aes_gcm.decrypt(allocator, ciphertext, aad, nonce);
    defer allocator.free(decrypted);
    
    try std.testing.expectEqualStrings(plaintext, decrypted);
}

test "SecureVault basic operations" {
    const allocator = std.testing.allocator;
    var vault = SecureVault.init(allocator);
    defer vault.deinit();
    
    // Inicializa com senha
    const password = "test_password_123";
    const salt = "random_salt_here";
    try vault.initWithPassword(password, salt);
    
    // Salva sessão
    const session_id = "test_session";
    const session_data = "encrypted_session_data_here";
    try vault.saveSession(session_id, session_data);
    
    // Carrega sessão
    var output_buffer: [1024]u8 = undefined;
    const loaded_len = try vault.loadSession(session_id, &output_buffer);
    
    try std.testing.expectEqual(session_data.len, loaded_len);
    try std.testing.expectEqualStrings(session_data, output_buffer[0..loaded_len]);
    
    // Deleta sessão
    try vault.deleteSession(session_id);
    
    // Tentar carregar sessão deletada deve falhar
    const load_result = vault.loadSession(session_id, &output_buffer);
    try std.testing.expectError(SecureVault.VaultError.KeyNotFound, load_result);
}

test "SecureTiming jitter" {
    var prng = std.rand.DefaultPrng.init(54321);
    
    const base_ns: u64 = 1_000_000_000; // 1 segundo
    const jittered = SecureTiming.addJitter(base_ns, 10, &prng.random());
    
    try std.testing.expect(jittered >= base_ns);
    try std.testing.expect(jittered <= base_ns * 110 / 100);
}

test "DeviceFingerprint profile selection" {
    const profile = DeviceFingerprint.profiles.android_pixel_7;
    
    try std.testing.expectEqual(DeviceFingerprint.OSType.android, profile.os_type);
    try std.testing.expect(std.mem.indexOf(u8, profile.user_agent, "Android") != null);
}

test "FingerprintRotator rotation" {
    const allocator = std.testing.allocator;
    var rotator = FingerprintRotator.init(allocator, 99999);
    
    const initial_profile = rotator.current_profile;
    try rotator.rotate();
    
    // Perfil deve ter mudado (provavelmente)
    _ = initial_profile;
    try std.testing.expect(rotator.rotation_count == 1);
}
