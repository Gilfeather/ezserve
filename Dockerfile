FROM alpine:latest AS builder
RUN apk add --no-cache curl xz

# Install Zig
RUN curl -L -o zig.tar.xz https://ziglang.org/download/0.14.0/zig-linux-x86_64-0.14.0.tar.xz && \
    tar -xJf zig.tar.xz && \
    rm zig.tar.xz
ENV PATH="/zig-linux-x86_64-0.14.0:$PATH"

WORKDIR /app
COPY . .
RUN zig build -Doptimize=ReleaseSmall

FROM scratch
COPY --from=builder /app/zig-out/bin/ezserve /ezserve
EXPOSE 8000
ENTRYPOINT ["/ezserve"]
EOF < /dev/null