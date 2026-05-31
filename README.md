# tunnel-rb

Expose a local HTTP server (e.g. a Rails app on port 3000) to the internet through a relay. A tunnel **client** running on your machine maintains a persistent control connection to a relay **server**; incoming browser traffic hits the server and is forwarded through the client to your local process.

Built with plain Ruby — blocking I/O and threads, no external gems required to run.

## Architecture

```
Browser                    Relay Server                         Tunnel Client              Local App
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

The relay server listens on two ports:


| Port               | Role                                         | Who connects   |
| ------------------ | -------------------------------------------- | -------------- |
| **7777** (control) | Registration, ping/pong, data-socket handoff | Tunnel clients |
| **8080** (public)  | Incoming HTTP from browsers / nginx          | End users      |


Each tunneled HTTP request uses **two** TCP connections on the control port:

1. The long-lived **control channel** (register, ping, `new_connection` commands).
2. A short-lived **data channel** (`bind` with a `conn_id`) that carries the actual HTTP bytes.

## Quick start (local)

**Terminal 1 — relay server**

```bash
bin/relay_server
# or: ruby relay_server.rb
```

**Terminal 2 — your local app** (example: Rails on 3000)

```bash
rails server -p 3000
```

**Terminal 3 — tunnel client**

The client connects over TLS by default. The local relay above runs plaintext, so disable TLS with `--no-tls`:

```bash
ruby tunnel.rb 3000 --no-tls
```

The client prints a public URL, e.g.:

```
🚀 [Tunnel] Ready! https://a1b2c3d4.localhost:8080 -> localhost:3000
```

Send a request through the tunnel:

```bash
curl -H "Host: a1b2c3d4.localhost:8080" http://127.0.0.1:8080/
```

The `Host` header must match the assigned subdomain. For local testing the default domain is `localhost` and the URL includes the public port (`:8080`), so curling `127.0.0.1:8080` with `Host: <subdomain>.localhost:8080` needs no `/etc/hosts` edits.

---

## Relay server

### Running

```bash
bin/relay_server
# or
ruby relay_server.rb
```

Press **Ctrl+C** or send **SIGTERM** for graceful shutdown (listeners closed, thread pools drained, tokens persisted).

### Configuration

`Relay::Server` accepts keyword arguments:


| Option          | Default                                   | Description                                                                   |
| --------------- | ----------------------------------------- | ----------------------------------------------------------------------------- |
| `control_port`  | `7777`                                    | Tunnel client control plane                                                   |
| `public_port`   | `8080`                                    | Public HTTP edge (port the relay binds/listens on)                            |
| `domain`        | `"tunnel.test"`                           | Base domain for the registration URL (`https://{subdomain}.{domain}`)         |
| `url_port`      | `nil`                                     | Port shown in the registration URL; `nil` omits it (e.g. nginx on 443)        |
| `tokens_path`   | `/tmp/tunnel-rb-relay-server-tokens.json` | Persistent token store                                                        |
| `tls_cert`      | `nil`                                     | PEM cert path; enables TLS on the control port when set with `tls_key`        |
| `tls_key`       | `nil`                                     | PEM private key path; enables TLS on the control port when set with `tls_cert`|
| `logger`        | `Relay::Logger.new`                       | Injectable logger (stdout/stderr)                                             |

When started via `bin/relay_server`, the control port, public port, and domain can be set with environment variables (defaults shown):

| Env var              | Default          | Maps to        |
| -------------------- | ---------------- | -------------- |
| `RELAY_CONTROL_PORT` | `7777`           | `control_port` |
| `RELAY_PUBLIC_PORT`  | `8080`           | `public_port`  |
| `RELAY_DOMAIN`       | `localhost`      | `domain`       |
| `RELAY_URL_PORT`     | `public_port`    | `url_port`     |

`RELAY_URL_PORT` defaults to the public port, so locally the printed URL is `https://<subdomain>.localhost:8080`. Behind a reverse proxy (e.g. nginx terminating TLS on 443), the relay's `8080` is internal — set `RELAY_URL_PORT=` (empty) so the URL drops the port:

```bash
# Local dev: URL shows the port (https://<sub>.localhost:8080)
bin/relay_server

# Production behind nginx: clients see https://<sub>.tunnel.example.com (no port)
RELAY_DOMAIN=tunnel.example.com RELAY_URL_PORT= bin/relay_server
```

Example with custom options:

```ruby
require "relay/server"

Relay::Server.new(
  control_port: 7777,
  public_port: 8080,
  domain: "tunnel.example.com",
  tokens_path: "/var/lib/tunnel-rb/tokens.json"
).start
```

### Server components

```
lib/relay/
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

---

## TLS (optional)

TLS can be enabled on the **control port** (`7777`) to encrypt the relay ↔ tunnel-client link. Because both the long-lived control channel and the short-lived data sockets flow through this port, enabling it encrypts all traffic between the client and the relay. The public HTTP port (`8080`) is unaffected — keep terminating its TLS at nginx as before.

The two sides default differently: the **server** runs plaintext unless a cert and key are supplied, while the **client** connects over TLS (and verifies against the system CA store) **by default** — use `--no-tls` to talk to a plaintext relay.

### Generating a self-signed cert (for testing)

```bash
openssl req -x509 -newkey rsa:2048 -nodes -keyout relay.key -out relay.crt -days 365 -subj "/CN=localhost"
```

### Server

Pass `tls_cert` / `tls_key`, or set the `RELAY_TLS_CERT` / `RELAY_TLS_KEY` env vars when using `bin/relay_server`:

```bash
RELAY_TLS_CERT=relay.crt RELAY_TLS_KEY=relay.key bin/relay_server
```

```ruby
Relay::Server.new(
  control_port: 7777,
  public_port: 8080,
  tls_cert: "relay.crt",
  tls_key: "relay.key"
).start
```

On startup the server logs whether the control plane is running with TLS enabled.

### Client

TLS and certificate verification are **on by default**. Connecting to a relay with a publicly trusted cert needs no flags:

```bash
# Default: TLS on, verified against the system CA store (e.g. a Let's Encrypt cert).
ruby tunnel.rb 3000 --relay-host relay.example.com

# Custom CA: verify against a specific CA bundle instead of the system store.
ruby tunnel.rb 3000 --relay-host relay.example.com --tls-ca ca.pem

# Self-signed relay: keep TLS but skip verification.
ruby tunnel.rb 3000 --relay-host relay.example.com --no-tls-verify

# Plaintext relay (local dev / tests): disable TLS entirely.
ruby tunnel.rb 3000 --no-tls
```

The same options are available via `RELAY_TLS` / `RELAY_TLS_VERIFY` (`1`/`true`/`yes`, default on) and `RELAY_TLS_CA`.

The client has three TLS verification modes (TLS itself is toggled with `--[no-]tls`):

| Mode          | Flags                       | Verification                                                  |
| ------------- | --------------------------- | ------------------------------------------------------------- |
| System CAs    | _(default)_                 | `VERIFY_PEER` against the OS trusted CA store + hostname check |
| Custom CA     | `--tls-ca PATH`             | `VERIFY_PEER` against the given CA cert/bundle + hostname check |
| Insecure      | `--no-tls-verify`           | None (`VERIFY_NONE`) — accepts any cert, for self-signed relays |

`--tls-ca` takes precedence over the system-CA default if both are in effect.

> Note: because verification is on by default, a self-signed relay needs `--no-tls-verify`, and a plaintext relay needs `--no-tls`. Both verifying modes include a hostname check.

---

## Tunnel client

### Running

```bash
ruby tunnel.rb 3000 --no-tls
ruby tunnel.rb 3000 --relay-host relay.example.com --relay-port 7777
ruby tunnel.rb --help
```

TLS is on by default (see [TLS](#tls-optional)); pass `--no-tls` when the relay is plaintext (local dev/testing).

The local port can be passed as the first positional argument or via the `LOCAL_PORT` environment variable. The client exits with status 1 if neither is set.

### Configuration


| Flag           | Env var        | Default     | Description                                                      |
| -------------- | -------------- | ----------- | ---------------------------------------------------------------- |
| (positional)   | `LOCAL_PORT`   | —           | Port of the local service (required)                             |
| `--local-host` | `LOCAL_HOST`   | `localhost` | Host of the local service                                        |
| `--relay-host` | `RELAY_HOST`   | `localhost` | Relay server host                                                |
| `--relay-port` | `RELAY_PORT`   | `7777`      | Relay server control port                                        |
| `--[no-]tls`        | `RELAY_TLS`        | `true`  | Connect to the relay over TLS (use `--no-tls` for local/testing) |
| `--[no-]tls-verify` | `RELAY_TLS_VERIFY` | `true`  | Verify the relay cert against the system CA store                |
| `--tls-ca`          | `RELAY_TLS_CA`     | —       | CA cert/bundle to verify the relay instead of the system store   |


Examples:

```bash
RELAY_HOST=relay.example.com LOCAL_PORT=3000 ruby tunnel.rb
ruby tunnel.rb 3000 --local-host 127.0.0.1
```

### Behaviour

1. Opens a connection to the relay control port (5 s connect timeout), wrapped in TLS unless `--no-tls` is set.
2. Sends `register` (with optional `token` on reconnect).
3. Receives `{ status: "ok", url: "...", token: "..." }`.
4. Enters a read loop on the control socket:
  - `**ping**` → replies with `**pong**` (keeps the connection alive through NAT).
  - `**new_connection**` → opens a fresh connection (same TLS setting), sends `bind` with the given `conn_id`, proxies bytes between relay and the local service.
5. If the local service is unreachable (connection refused, host unreachable, DNS failure, connect timeout), the client sends a `502 Bad Gateway` HTTP response back through the relay instead of dropping the connection.
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
1. Browser → server:8080   GET /path  Host: xxxx.tunnel.test
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
ruby -Ilib -Itest -e 'Dir["test/**/*_test.rb"].each { |f| require_relative f }'

# Unit tests (TokenStore)
ruby -Ilib -Itest test/relay/token_store_test.rb

# End-to-end (real server on ephemeral ports, fake tunnel client, HTTP request)
ruby -Ilib -Itest test/relay/integration_test.rb
```

Integration tests start a real `Relay::Server` on random free ports with an isolated token file. They do **not** touch `/tmp/tunnel-rb-relay-server-tokens.json`.

---

## Project layout

```
bin/relay_server          Entry point
lib/relay/                Server implementation
relay_server.rb           Compatibility shim
tunnel.rb                 Tunnel client
relay.rb                  Legacy single-file prototype (not used by bin/relay_server)
test/relay/               Unit and integration tests
```

## Requirements

- Ruby 3.x (tested on 3.4)
- No gems required to run the server or client

