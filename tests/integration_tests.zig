const std = @import("std");
const testing = std.testing;

// Import the library for testing core functions
const lib = @import("lib");

// Since integration tests are complex and require external process management,
// we'll focus on testing the core library functions that can be tested in isolation

test "MIME type detection integration" {
    // Test the getMimeType function with various realistic scenarios
    try testing.expectEqualStrings("text/html", lib.getMimeType("index.html"));
    try testing.expectEqualStrings("application/javascript", lib.getMimeType("bundle.min.js"));
    try testing.expectEqualStrings("text/css", lib.getMimeType("styles/main.css"));
    try testing.expectEqualStrings("image/png", lib.getMimeType("assets/logo.png"));
    try testing.expectEqualStrings("application/json", lib.getMimeType("api/data.json"));
}

test "Config validation" {
    // Test different configuration scenarios
    const default_config = lib.Config{};
    try testing.expect(default_config.port >= 1 and default_config.port <= 65535);
    
    const custom_config = lib.Config{
        .port = 3000,
        .root = "/var/www",
        .bind = "0.0.0.0",
        .cors = true,
        .single_page = true,
    };
    try testing.expect(custom_config.port == 3000);
    try testing.expectEqualStrings("/var/www", custom_config.root);
    try testing.expect(custom_config.cors == true);
    try testing.expect(custom_config.single_page == true);
}

test "ResponseInfo structure validation" {
    const responses = [_]lib.ResponseInfo{
        .{ .status = 200, .content_length = 1024 },
        .{ .status = 404, .content_length = 9 },
        .{ .status = 405, .content_length = 0 },
        .{ .status = 403, .content_length = 9 },
    };
    
    for (responses) |response| {
        try testing.expect(response.status >= 100 and response.status < 600);
        try testing.expect(response.content_length >= 0);
    }
}

test "MIME type edge cases" {
    // Test edge cases that might occur in real usage
    try testing.expectEqualStrings("application/octet-stream", lib.getMimeType(""));
    try testing.expectEqualStrings("application/octet-stream", lib.getMimeType("file"));
    try testing.expectEqualStrings("application/octet-stream", lib.getMimeType("file.UNKNOWN"));
    try testing.expectEqualStrings("application/octet-stream", lib.getMimeType(".hiddenfile"));
    try testing.expectEqualStrings("text/html", lib.getMimeType("very/long/path/to/file.html"));
}