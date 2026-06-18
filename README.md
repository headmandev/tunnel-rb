# [tunnel-rb](https://github.com/headmandev/tunnel-rb)

Expose a local HTTP server (e.g. a Rails app on port 3000) to the internet through a tunnel server. A tunnel **client** running on your machine maintains a persistent control connection to the tunnel **server**; incoming browser traffic hits the server and is forwarded through the client to your local process.

**By default, no server setup is required.** The client connects to the hosted tunnel server at [tunnel-rb.dev](https://tunnel-rb.dev) and prints a public HTTPS URL you can open or share. Run your own server only if you want to self-host a private instance.

Built with plain Ruby — blocking I/O and threads, no runtime gem dependencies (system **OpenSSL** required).

## Requirements

Ruby **2.7+** and **OpenSSL 1.1.1+** with TLS 1.3 support. Verify with:

```bash
ruby -ropenssl -e 'puts OpenSSL::OPENSSL_VERSION'
```

Full OS packages, development deps, and optional tools: [Requirements (detailed)](#requirements-detailed).

## Installation

```bash
gem install tunnel-rb
```

This installs the `tunnel` client on your `PATH`:

```bash
tunnel 3000
```

From source:

```bash
git clone https://github.com/headmandev/tunnel-rb.git
cd tunnel-rb
bundle install
bundle exec rake install   # or: gem build tunnel-rb.gemspec && gem install tunnel-rb-*.gem
```

Without installing the gem (from a checkout):

```bash
ruby tunnel.rb 3000
```

The root-level script `tunnel.rb` (and `bin/tunnel`) remain for development checkout.

## Requirements (detailed)

### Runtime

- **Ruby 2.7+** (tested on 2.7 and 3.4)
- **OpenSSL 1.1.1+** with TLS 1.3 support — the client and server load Ruby's `openssl` extension at startup; the default client connects to the hosted server over **TLS 1.3**. Ruby must be built with OpenSSL linked in (`ruby -ropenssl -e 'puts OpenSSL::OPENSSL_VERSION'` should succeed).
  - macOS: satisfied by the system Ruby or [Homebrew](https://brew.sh/) Ruby (`brew install openssl@3` if compiling Ruby from source).
  - Debian/Ubuntu: `sudo apt install openssl ca-certificates` (`libssl-dev` only if you compile Ruby yourself).
  - Fedora/RHEL: `sudo dnf install openssl ca-certificates`.
- **Trusted CA certificates** on the host — default client verification uses the OS CA store (`ca-certificates` on Linux). Not needed when using `--no-tls-verify` or `--no-tls`.
- **No runtime gem dependencies** — Ruby stdlib only (`socket`, `json`, `openssl`, etc.).

### Development (from source / running tests)

- [Bundler](https://bundler.io/) — `bundle install`
- **minitest** and **rake** — declared as development dependencies in the gemspec

### Optional

- **OpenSSL CLI** — generate self-signed certs for local TLS testing (see [TLS](#tls-optional)).
- **nginx** (or similar) — TLS termination on the public HTTP port in production (see [Production notes](#production-notes)).

## Quick start

Start your local app, then run the client with its port — no `--server-host` or other server options needed:

```bash
rails server -p 3000   # or any local HTTP server

tunnel 3000
# from checkout: ruby tunnel.rb 3000
```

The client connects to the hosted server at **tunnel-rb.dev** (control host: `server.tunnel-rb.dev`) and prints a public URL:

```
🚀 [Tunnel] Ready! https://1ef59cf5.tunnel-rb.dev -> localhost:3000 (server: TLS)
```

Open that URL in a browser, or:

```bash
curl -I https://1ef59cf5.tunnel-rb.dev/
```

Each run gets a unique subdomain. TLS to the server is on by default.

> **Self-hosting:** Run your own server with `ruby tunnel-server.rb` only if you want a private instance instead of the hosted tunnel-rb.dev service. See [Quick start (self-hosted)](#quick-start-self-hosted).

## Start here (3 common scenarios)

1. Hosted default (fastest): `tunnel 3000`
2. Self-hosted local dev (plaintext server):
   - Terminal 1: `ruby tunnel-server.rb`
   - Terminal 2: `ruby tunnel.rb 3000 --server-host localhost --no-tls`
3. Self-hosted production (TLS + reverse proxy):
   - Set `RELAY_DOMAIN`, `RELAY_TLS_CERT`, `RELAY_TLS_KEY`, and usually `RELAY_URL_PORT=`
   - Start: `ruby tunnel-server.rb`
   - Connect: `ruby tunnel.rb 3000 --server-host your-control-host`

### Library API

```ruby
require "tunnel_rb"

TunnelRb::Client.new(
  local_port: 3000,
  server_host: "server.tunnel-rb.dev", # hosted server (same default as the CLI)
  server_port: 7777,
  tls: true
).start

TunnelRb::Server.new(
  control_port: 7777,
  public_port: 8080,
  domain: "localhost"
).start
```

## Architecture

```
Browser                    Tunnel Server                        Tunnel Client              Local App
   |                            |                                      |                        |
   |  HTTP (public port)        |                                      |                        |
   |--------------------------->|  new_connection (control port)       |                        |
   |                            |------------------------------------->|                        |
   |                            |  bind + data socket (control port)   |                        |
   |                            |<-------------------------------------|                        |
   |                            |         proxy bytes                  |  TCP (local port)      |
   |                            |------------------------------------->|----------------------->|
   |                            |<-------------------------------------|<-----------------------|
   |<---------------------------|                                      |                        |
```

The tunnel server listens on two ports:


| Port               | Role                                         | Who connects   |
| ------------------ | -------------------------------------------- | -------------- |
| **7777** (control) | Registration, ping/pong, data-socket handoff | Tunnel clients |
| **8080** (public)  | Incoming HTTP from browsers / nginx          | End users      |


Each tunneled HTTP request uses **two** TCP connections on the control port:

1. The long-lived **control channel** (register, ping, `new_connection` commands).
2. A short-lived **data channel** (`bind` with a `conn_id`) that carries the actual HTTP bytes.

## Quick start (self-hosted)

Use this when you run your own tunnel server (e.g. local development or a private deployment) instead of the hosted tunnel-rb.dev service.

**Terminal 1 — tunnel server**

```bash
ruby tunnel-server.rb
```

**Terminal 2 — your local app** (example: Rails on 3000)

```bash
rails server -p 3000
```

**Terminal 3 — tunnel client**

The client connects over TLS by default. The local server above runs plaintext, so disable TLS with `--no-tls`:

```bash
ruby tunnel.rb 3000 --no-tls
# after gem install: tunnel 3000 --no-tls
```

The client prints a public URL, e.g.:

```
🚀 [Tunnel] Ready! https://a1b2c3d4.localhost:8080 -> localhost:3000
```

For local plaintext testing, send a request over `http://` with the generated host:

```bash
curl -H "Host: a1b2c3d4.localhost:8080" http://127.0.0.1:8080/
```

The `Host` header must match the assigned subdomain. For local testing the default domain is `localhost` and the URL includes the public port (`:8080`), so curling `127.0.0.1:8080` with `Host: <subdomain>.localhost:8080` needs no `/etc/hosts` edits.

> Note: the registration URL is always printed as `https://...` because production traffic is expected behind a TLS edge (e.g. nginx). In local self-hosted mode (`ruby tunnel-server.rb` with no TLS on `public_port`), access the public port via `http://`.

Point the client at your server with `--server-host localhost --no-tls` (plaintext local server) or set `SERVER_HOST` / `SERVER_PORT` for a remote instance.

---

## Tunnel server

### Running

```bash
ruby tunnel-server.rb
```

Press **Ctrl+C** or send **SIGTERM** for graceful shutdown (listeners closed, thread pools drained, tokens persisted).

### Configuration

`TunnelRb::Server` accepts keyword arguments:


| Option          | Default                                   | Description                                                                   |
| --------------- | ----------------------------------------- | ----------------------------------------------------------------------------- |
| `control_port`  | _(required)_                              | Tunnel client control plane                                                   |
| `public_port`   | _(required)_                              | Public HTTP edge (port the server binds/listens on)                           |
| `domain`        | _(required)_                              | Base domain for the registration URL (`https://{subdomain}.{domain}`)         |
| `url_port`      | `nil`                                     | Port shown in the registration URL; `nil` omits it (e.g. nginx on 443)        |
| `tokens_path`   | `/tmp/tunnel-rb-server-tokens.json`       | Persistent token store                                                        |
| `tls_cert`      | `nil`                                     | PEM cert path; enables TLS on the control port when set with `tls_key`        |
| `tls_key`       | `nil`                                     | PEM private key path; enables TLS on the control port when set with `tls_cert`|
| `logger`        | `TunnelRb::Server::Logger.new`             | Injectable logger (stdout/stderr)                                             |

`control_port`, `public_port`, and `domain` are required keyword arguments. When started via `ruby tunnel-server.rb` they're supplied from environment variables (defaults shown):

| Env var              | Default          | Maps to        |
| -------------------- | ---------------- | -------------- |
| `RELAY_CONTROL_PORT` | `7777`           | `control_port` |
| `RELAY_PUBLIC_PORT`  | `8080`           | `public_port`  |
| `RELAY_DOMAIN`       | `localhost`      | `domain`       |
| `RELAY_URL_PORT`     | `public_port`    | `url_port`     |

`RELAY_URL_PORT` defaults to the public port, so locally the printed URL is `https://<subdomain>.localhost:8080`. Behind a reverse proxy (e.g. nginx terminating TLS on 443), the server's `8080` is internal — set `RELAY_URL_PORT=` (empty) so the URL drops the port:

```bash
# Local dev: URL shows the port (https://<sub>.localhost:8080)
ruby tunnel-server.rb

# Production behind nginx: clients see https://<sub>.tunnel.example.com (no port)
RELAY_DOMAIN=tunnel.example.com RELAY_URL_PORT= ruby tunnel-server.rb
```

Example with custom options:

```ruby
require "tunnel_rb/server"

TunnelRb::Server.new(
  control_port: 7777,
  public_port: 8080,
  domain: "tunnel.example.com",
  tokens_path: "/var/lib/tunnel-rb/tokens.json"
).start
```

### Server components

```
lib/tunnel_rb/server/
  server.rb           Coordinator — wires components, signal handlers, shutdown
  control_server.rb   Port 7777 — accept, handshake pool, read loop, ping loop
  public_server.rb    Port 8080 — HTTP routing, pending connections, byte proxy
  client_registry.rb  Connected clients (subdomain ↔ socket)
  token_store.rb      Token persistence and subdomain assignment
  pending_connections.rb  conn_id ↔ Queue handoff between public and control sides
  thread_pool.rb      Bounded worker pools with backpressure
  http_request.rb     Header parsing + X-Forwarded-* injection
  socket_helpers.rb   TCP keepalive tuning
  tls.rb              Optional TLS context + listener wrapping for the control port
  logger.rb           Structured logging wrapper
  client.rb           Per-client state object
```

### Limits and behaviour


| Setting                  | Value                   | Effect                                           |
| ------------------------ | ----------------------- | ------------------------------------------------ |
| Handshake pool           | 64 workers + 64 queue   | Backpressure on control-port connection floods   |
| Public pool              | 200 workers + 200 queue | Backpressure on HTTP connection floods           |
| Ping interval            | 30 s                    | Keeps NAT mappings alive                         |
| Missed pongs             | 3                       | Unresponsive clients are disconnected            |
| HTTP header read timeout | 5 s                     | Slowloris protection on public port              |
| Data socket wait         | 10 s                    | Timeout if client does not bind in time          |
| Control line max         | 16 KiB                  | Slowloris protection on control read loop        |
| Token TTL                | 24 h                    | Tokens expire when no client holds the subdomain |
| Token cleanup            | every 10 min            | Background sweep of expired tokens               |


### Token persistence

On first registration the server assigns a random subdomain (e.g. `a1b2c3d4`) and issues a reconnect **token**. Tokens are written to disk so a client can reconnect after a disconnect and keep the same subdomain.

- Connected clients: token stays valid regardless of TTL.
- Disconnected clients: token expires after 24 hours unless the client reconnects in time.

### Production notes

- Put **nginx** (or similar) in front of the public port for TLS termination. Forward `Host` unchanged so subdomain routing works.
- The server binds `0.0.0.0` on both ports.
- There is no authentication beyond the reconnect token — treat the control port as trusted infrastructure.
- Environment variables currently keep the `RELAY_*` prefix for backward compatibility.

---

## TLS (optional)

TLS can be enabled on the **control port** (`7777`) to encrypt the server ↔ tunnel-client link. Because both the long-lived control channel and the short-lived data sockets flow through this port, enabling it encrypts all traffic between the client and the server. The public HTTP port (`8080`) is unaffected — keep terminating its TLS at nginx as before.

The two sides default differently: the **server** runs plaintext unless a cert and key are supplied, while the **client** connects over TLS (and verifies against the system CA store) **by default** — use `--no-tls` to talk to a plaintext server.

### Generating a self-signed cert (for testing)

```bash
openssl req -x509 -newkey rsa:2048 -nodes -keyout server.key -out server.crt -days 365 -subj "/CN=localhost"
```

### Server

Pass `tls_cert` / `tls_key`, or set the `RELAY_TLS_CERT` / `RELAY_TLS_KEY` env vars when starting the server:

```bash
RELAY_TLS_CERT=server.crt RELAY_TLS_KEY=server.key ruby tunnel-server.rb
```

```ruby
TunnelRb::Server.new(
  control_port: 7777,
  public_port: 8080,
  tls_cert: "server.crt",
  tls_key: "server.key"
).start
```

On startup the server logs whether the control plane is running with TLS enabled.

For **Let's Encrypt**, point `tls_cert` / `RELAY_TLS_CERT` at **`fullchain.pem`**, not `cert.pem`. The server sends the entire chain to clients; a leaf cert alone causes `certificate verify failed (unable to get local issuer certificate)` on the client. A single PEM file (e.g. a self-signed test cert) still works — the server loads one or more certificates from the file.

```bash
RELAY_TLS_CERT=/etc/letsencrypt/live/server.example.com/fullchain.pem \
RELAY_TLS_KEY=/etc/letsencrypt/live/server.example.com/privkey.pem \
ruby tunnel-server.rb
```

### Client

TLS and certificate verification are **on by default**. Connecting to a server with a publicly trusted cert needs no flags:

```bash
# Default: TLS on, verified against the system CA store (e.g. a Let's Encrypt cert).
ruby tunnel.rb 3000 --server-host server.example.com

# Custom CA: verify against a specific CA bundle instead of the system store.
ruby tunnel.rb 3000 --server-host server.example.com --tls-ca ca.pem

# Self-signed server: keep TLS but skip verification.
ruby tunnel.rb 3000 --server-host server.example.com --no-tls-verify

# Plaintext server (local dev / tests): disable TLS entirely.
ruby tunnel.rb 3000 --no-tls
```

The same options are available via `RELAY_TLS` / `RELAY_TLS_VERIFY` (`1`/`true`/`yes`, default on) and `RELAY_TLS_CA`.

`--[no-]tls` applies **only to connections to the server** (control and data sockets). The link to your local app (e.g. Rails on `:3000`) is always plain TCP — even when server TLS is on.

The client has three TLS verification modes (TLS itself is toggled with `--[no-]tls`):

| Mode          | Flags                       | Verification                                                  |
| ------------- | --------------------------- | ------------------------------------------------------------- |
| System CAs    | _(default)_                 | `VERIFY_PEER` against the OS trusted CA store + hostname check |
| Custom CA     | `--tls-ca PATH`             | `VERIFY_PEER` against the given CA cert/bundle + hostname check |
| Insecure      | `--no-tls-verify`           | None (`VERIFY_NONE`) — accepts any cert, for self-signed servers |

`--tls-ca` takes precedence over the system-CA default if both are in effect.

> Note: because verification is on by default, a self-signed server needs `--no-tls-verify`, and a plaintext server needs `--no-tls`. Both verifying modes include a hostname check.

---

## Tunnel client

### Running

By default the client uses the hosted server — just pass the local port:

```bash
tunnel 3000
ruby tunnel.rb 3000 --help
```

For a self-hosted server:

```bash
ruby tunnel.rb 3000 --server-host localhost --no-tls   # local plaintext server
ruby tunnel.rb 3000 --server-host server.example.com    # your own deployment
```

TLS is on by default (see [TLS](#tls-optional)); pass `--no-tls` when the server is plaintext (local dev with `ruby tunnel-server.rb`).

The local port can be passed as the first positional argument or via the `LOCAL_PORT` environment variable. The client exits with status 1 if neither is set.

### Configuration


| Flag           | Env var        | Default     | Description                                                      |
| -------------- | -------------- | ----------- | ---------------------------------------------------------------- |
| (positional)   | `LOCAL_PORT`   | —           | Port of the local service (required)                             |
| `--local-host` | `LOCAL_HOST`   | `localhost` | Host of the local service                                        |
| `--server-host` | `SERVER_HOST`   | `server.tunnel-rb.dev` | Server control host; default is the hosted tunnel-rb.dev service |
| `--server-port` | `SERVER_PORT`   | `7777`      | Server control port; only change for self-hosted servers        |
| `--[no-]tls`        | `RELAY_TLS`        | `true`  | Connect to the server over TLS (use `--no-tls` for local/testing) |
| `--[no-]tls-verify` | `RELAY_TLS_VERIFY` | `true`  | Verify the server cert against the system CA store                |
| `--tls-ca`          | `RELAY_TLS_CA`     | —       | CA cert/bundle to verify the server instead of the system store   |


Examples:

```bash
SERVER_HOST=server.example.com LOCAL_PORT=3000 ruby tunnel.rb
ruby tunnel.rb 3000 --local-host 127.0.0.1
```

### Behaviour

1. Opens a connection to the server control port (5 s connect timeout), wrapped in TLS unless `--no-tls` is set.
2. Sends `register` (with optional `token` on reconnect).
3. Receives `{ status: "ok", url: "...", token: "..." }`.
4. Enters a read loop on the control socket:
  - `**ping**` → replies with `**pong**` (keeps the connection alive through NAT).
  - `**new_connection**` → opens a fresh connection to the server (TLS when enabled, plain TCP with `--no-tls`), sends `bind` with the given `conn_id`, then proxies bytes between server and the local service over plain TCP.
5. If the local service is unreachable (connection refused, host unreachable, DNS failure, connect timeout), the client sends a `502 Bad Gateway` HTTP response back through the server instead of dropping the connection.
6. On disconnect, the client reconnects automatically with **exponential backoff** (1 s → 2 s → 4 s → … capped at 30 s, reset to 1 s after a successful registration), reusing the saved token.

### Reconnection

The client stores the token from the registration response. On reconnect it sends:

```json
{"action":"register","token":"<hex-token>"}
```

The server revokes the old token, closes the previous control socket, and restores the same subdomain.

### TCP keepalive

Both client and server enable TCP keepalive (idle 60 s, interval 30 s, 3 probes) to detect dead peers through NAT/firewalls.

---

## Wire protocol

All messages are **newline-delimited JSON** (one object per line).

### Client → server (first message on every TCP connection)


| `action`   | Fields             | Purpose                                           |
| ---------- | ------------------ | ------------------------------------------------- |
| `register` | `token` (optional) | Claim or reclaim a subdomain                      |
| `bind`     | `conn_id`          | Attach a data socket to a pending browser request |


### Server → client (on control channel)


| `action` / field                                | Purpose               |
| ----------------------------------------------- | --------------------- |
| `{ status: "ok", url: "...", token: "..." }`    | Registration response |
| `{ action: "ping" }`                            | Liveness check        |
| `{ action: "new_connection", conn_id: "uuid" }` | Open a data channel   |


### Client → server (on control channel, after register)


| `action`             | Purpose       |
| -------------------- | ------------- |
| `{ action: "pong" }` | Reply to ping |


### Request flow (one HTTP request)

```
1. Browser → server:8080   GET /path  Host: xxxx.tunnel-rb.dev
2. Server → client (control):  {"action":"new_connection","conn_id":"<uuid>"}
3. Client → server (new TCP):  {"action":"bind","conn_id":"<uuid>"}
4. Server forwards buffered HTTP headers on the data socket
5. Client connects to localhost:3000, proxies bytes both ways
6. Connection closes when either side finishes
```

---

## Testing

Requires Ruby stdlib only (minitest).

```bash
# All tests
bundle exec rake test

# or manually:
ruby -Ilib -Itest -e 'Dir["test/**/*_test.rb"].each { |f| require_relative f }'

# Unit tests (TokenStore)
ruby -Ilib -Itest test/server/token_store_test.rb

# End-to-end (real server on ephemeral ports, fake tunnel client, HTTP request)
ruby -Ilib -Itest test/server/integration_test.rb
```

Integration tests start a real `TunnelRb::Server` on random free ports with an isolated token file. They do **not** touch `/tmp/tunnel-rb-server-tokens.json`.

---

## Project layout

```
exe/tunnel                Gem executable (client)
lib/tunnel_rb/            Client library + CLI
lib/tunnel_rb/server/      Server (run from checkout: ruby tunnel-server.rb)
tunnel-rb.gemspec         Gem specification
bin/                      Development entry points
tunnel.rb                 Development shim (client)
tunnel-server.rb           Server entry point (checkout only)
test/server/               Unit and integration tests
```

