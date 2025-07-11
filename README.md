# 🚀 ezserve v0.3.0

**Ultra-lightweight, zero-dependency development HTTP server written in Zig**

[![Build Status](https://github.com/tomas/ezserve/workflows/build/badge.svg)](https://github.com/tomas/ezserve/actions)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

## 💡 Overview

**ezserve** (Easy Serve) is an ultra-compact, cross-platform HTTP server built exclusively with Zig's standard library.

```bash
# Instantly serve current directory with just one command
./ezserve
```

## ✨ Features

- 🪶 **Ultra-lightweight** - Binary size <70KB (ReleaseSmall) or <100KB (ReleaseFast)
- 🔗 **Zero dependencies** - Uses only Zig standard library
- 🌐 **Cross-platform** - Supports macOS/Linux/Windows
- ⚡ **Blazing fast** - Multi-threaded with queue-based architecture
- 🛠️ **Developer-friendly** - Development mode, auto-open browser, file watching
- 🚀 **Production-ready** - Range requests, ETag support, HTTP/1.1 compliance

## 🚀 Quick Start

```bash
# Build
zig build

# Start server (serves current directory)
./zig-out/bin/ezserve
# → Server starts at http://127.0.0.1:8000

# Development mode with auto-open browser
./zig-out/bin/ezserve dev

# Specify port and root directory
./zig-out/bin/ezserve --port 8080 --root ./public

# High-performance production server
./zig-out/bin/ezserve --threads 16 --bind 0.0.0.0 --port 80

# Run tests
zig build test               # Run all tests
zig build test-unit          # Run unit tests only
zig build test-integration   # Run integration tests only
```

## 📋 CLI Options

| Option             | Description                                    | Default   |
|--------------------|------------------------------------------------|-----------|
| `--port <number>`  | Specify port number                            | 8000      |
| `--root <path>`    | Specify document root directory                | .         |
| `--bind <IP>`      | Specify bind address                           | 127.0.0.1 |
| `--single-page`    | SPA mode (return index.html on 404)           | false     |
| `--cors`           | Add CORS headers                               | false     |
| `--no-dirlist`     | Disable directory listing                      | false     |
| `--log=json`       | Output access logs in JSON format (works in release builds) | false     |
| `--threads <num>`  | Number of worker threads (default: auto, max 8) | auto      |
| `--watch`          | Watch for file changes                         | false     |
| `--open`           | Auto-open browser after server start          | false     |

## 🎯 Usage Examples

```bash
# Basic usage
./ezserve

# Development mode (CORS + auto-open + file watching)
./ezserve dev

# For SPA development (Vue.js, React, etc.)
./ezserve --single-page --cors --port 3000

# Development with custom settings
./ezserve dev --port 3000 --root ./src

# For LAN access
./ezserve --bind 0.0.0.0 --port 8080


# High-performance server with custom thread count
./ezserve --threads 16 --bind 0.0.0.0



# Minimal binary size for embedded/Docker
zig build -Doptimize=ReleaseSmall
./zig-out/bin/ezserve --root ./public  # Only 68KB!

```

## 🛠️ Implementation Status

### ✅ Completed
- [x] CLI argument parsing
- [x] Server startup and TCP connection handling
- [x] HTTP request line parsing
- [x] File serving (GET /path → file response)
- [x] SPA mode (return index.html on 404)
- [x] CORS header support
- [x] Automatic MIME type detection
- [x] JSON access logging (basic implementation)
- [x] `--bind` option (for LAN access)
- [x] `--no-dirlist` option (disable directory listing)
- [x] `--log=json` option (log format selection)
- [x] Default index.html serving for root path

### 🚧 High Priority Improvements
- [x] **Port conflict handling** - Graceful error when port is in use
- [x] **HEAD method support** - For curl -I compatibility and CDN integration
- [x] **Buffer overflow protection** - Handle large headers safely (upgraded to 8KB limit)

### 🔧 Medium Priority Improvements
- [x] **MIME type optimization** - Use HashMap for faster lookups
- [x] **Memory allocation optimization** - Reduce allocator usage
- [x] **Better error messages** - User-friendly error reporting
- [x] `--help` option (display usage)
- [x] **Comprehensive test suite** - Unit and integration tests
- [x] **Multi-threading support** - Configurable worker threads with `--threads`
- [x] **Queue-based architecture** - Eliminates socket errors and race conditions
- [x] **Binary size optimization** - ReleaseSmall (68KB) vs ReleaseFast (99KB)

### 🔮 Future Enhancements

#### Version 0.3 ✅ COMPLETED
- [x] `ezserve dev` command - Development mode with --watch + --open + --cors
- [x] File watching (`--watch` option)
- [x] Browser auto-open (`--open` flag)
- [x] Better HTTP/1.1 compliance
- [x] Range requests support (HTTP 206 Partial Content)
- [x] ETag support (content-based cache validation)

#### Version 0.4
- [ ] Gzip compression support
- [ ] Configuration file support (.ezserve.toml)
- [ ] IPv6 support
- [ ] HTTPS support (with development certificates)
- [ ] Plugin system
- [ ] WebSocket proxy
- [ ] Load balancing

## 📊 JSON Logging

ezserve supports structured JSON logging for production environments:

### Development vs Production Logging

```bash
# Development: Standard logs only (debug builds)
./ezserve
# Output: 127.0.0.1 GET 200 1024 /index.html

# Production: JSON logs work in release builds
zig build -Doptimize=ReleaseFast
./zig-out/bin/ezserve --log=json
# Output: {"timestamp":1703123456,"method":"GET","path":"/","status":200,"content_length":1024,"client_ip":"127.0.0.1"}
```

### JSON Log Format

```json
{
  "timestamp": 1703123456,
  "method": "GET", 
  "path": "/index.html",
  "status": 200,
  "content_length": 1024,
  "client_ip": "192.168.1.100"
}
```

### Log Aggregation Integration

Compatible with popular log aggregation tools:
- **ELK Stack**: Direct Elasticsearch ingestion
- **Grafana Loki**: Structured log queries
- **Fluentd/Vector**: JSON parsing ready
- **CloudWatch/Datadog**: Production monitoring

## 📈 Performance

| Metric | ReleaseSmall | ReleaseFast |
|--------|--------------|-------------|
| Binary size | 68KB | 99KB |
| Memory usage | <5MB | <5MB |
| Startup time | <50ms | <50ms |
| Throughput | ~1600 req/s | ~1800 req/s |
| Read errors | <100 (0.5%) | <80 (0.4%) |
| Concurrent connections | Up to system limits | Up to system limits |

## 🆚 Comparison with Other Tools

| Tool | Binary Size | Dependencies | Startup Time | Features |
|------|-------------|--------------|--------------|----------|
| **ezserve** | 68KB-99KB | Zero | <50ms | Zig-based, dev mode, multi-threading |
| Python http.server | ~50MB | Python | ~200ms | Built-in standard |
| Node.js http-server | ~30MB | Node.js | ~300ms | Via npm |
| Go net/http | ~10MB | Zero | ~100ms | Static binary |
| nginx | ~1MB | libc | ~100ms | Full web server |

## 🔧 Development & Build

```bash
# Development build (includes file watching and browser auto-open)
zig build

# Performance optimized build (99KB, max speed)
zig build -Doptimize=ReleaseFast

# Size optimized build (68KB, good speed)
zig build -Doptimize=ReleaseSmall

# Cross-compilation examples
zig build -Doptimize=ReleaseFast -Dtarget=x86_64-windows
zig build -Doptimize=ReleaseFast -Dtarget=x86_64-linux
zig build -Doptimize=ReleaseFast -Dtarget=aarch64-linux
```

## 🧪 Testing

The project includes a comprehensive test suite with both unit and integration tests.

### Test Structure
```
tests/
├── test_files/          # Test assets for integration tests
│   └── test.html        # Sample HTML file
└── integration_tests.zig # HTTP endpoint tests

src/
├── lib.zig             # Core library with embedded unit tests
└── main.zig             # Application entry point
```

### Running Tests
```bash
# Run all tests
zig build test

# Run only unit tests (fast)
zig build test-unit

# Run only integration tests (requires building executable)
zig build test-integration
```

### Test Coverage
- **Unit Tests**: MIME type detection, configuration structures, response handling
- **Integration Tests**: HTTP GET/HEAD requests, error responses (404, 405), file serving
- **Edge Cases**: Unknown file extensions, malformed requests, port conflicts

## 🤝 Contributing

Pull requests and issues are always welcome!

1. Fork the repository
2. Create a feature branch (`git checkout -b feature/amazing-feature`)
3. Commit your changes (`git commit -m 'Add amazing feature'`)
4. Push to the branch (`git push origin feature/amazing-feature`)
5. Open a pull request

## 📝 License

MIT License - see the [LICENSE](LICENSE) file for details. 