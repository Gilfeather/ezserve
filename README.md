# 🚀 ezserve

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

- 🪶 **Ultra-lightweight** - Binary size <100KB (stripped)
- 🔗 **Zero dependencies** - Uses only Zig standard library
- 🌐 **Cross-platform** - Supports macOS/Linux/Windows
- ⚡ **Blazing fast** - Minimal overhead for maximum performance
- 🛠️ **Developer-friendly** - Modern features like CORS, SPA mode, JSON logging

## 🚀 Quick Start

```bash
# Build
zig build

# Start server (serves current directory)
./zig-out/bin/ezserve
# → Server starts at http://127.0.0.1:8000

# Specify port and root directory
./zig-out/bin/ezserve --port 8080 --root ./public

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
| `--log=json`       | Output access logs in JSON format             | false     |
| `--watch`          | Watch for file changes                         | false     |

## 🎯 Usage Examples

```bash
# Basic usage
./ezserve

# For SPA development (Vue.js, React, etc.)
./ezserve --single-page --cors --port 3000

# For LAN access
./ezserve --bind 0.0.0.0 --port 8080

# With JSON access logs
./ezserve --log=json --root ./dist
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

### 🔮 Future Enhancements

#### Version 0.2
- [ ] `ezserve dev` command - Development mode with --watch + --open + --cors
- [ ] File watching (`--watch` option)
- [ ] Browser auto-open (`--open` flag)
- [ ] Better HTTP/1.1 compliance
- [ ] Range requests support
- [ ] ETag support

#### Version 0.3
- [ ] Gzip compression support
- [ ] Configuration file support (.ezserve.toml)
- [ ] IPv6 support
- [ ] HTTPS support (with development certificates)
- [ ] Plugin system
- [ ] WebSocket proxy
- [ ] Load balancing

## 📈 Performance

| Metric | Value |
|--------|-------|
| Binary size | <100KB (stripped) |
| Memory usage | <5MB |
| Startup time | <50ms |
| Concurrent connections | Up to system limits |

## 🆚 Comparison with Other Tools

| Tool | Binary Size | Dependencies | Startup Time | Features |
|------|-------------|--------------|--------------|----------|
| **ezserve** | <100KB | Zero | <50ms | Zig-based, ultra-lightweight |
| Python http.server | ~50MB | Python | ~200ms | Built-in standard |
| Node.js http-server | ~30MB | Node.js | ~300ms | Via npm |
| Go net/http | ~10MB | Zero | ~100ms | Static binary |

## 🔧 Development & Build

```bash
# Development build
zig build

# Release build
zig build -Drelease-fast

# Cross-compilation examples
zig build -Dtarget=x86_64-windows
zig build -Dtarget=x86_64-linux
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