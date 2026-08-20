//! MCP (Model Context Protocol) module for WhatsZig
//! Provides REST, WebSocket, and STDIO interfaces for external tools and AI assistants

pub const server = @import("server.zig");

pub const McpServer = server.McpServer;
pub const Tool = server.Tool;
pub const ToolResult = server.ToolResult;
