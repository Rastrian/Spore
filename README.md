## Spore

Spore is a minimal TCP tunnel implemented in Elixir/OTP. It forwards a local TCP port to a remote server, similar to Bore. Protocol and behavior follow the Rust original so clients and servers can interoperate when configured the same. Inspiration: [bore (Rust)](https://github.com/ekzhang/bore).

### Features
- Control-plane on TCP port 7835 (null-delimited JSON frames)
- Optional HMAC-SHA256 challenge/response authentication
- Server selects/uses a configurable port range for public listeners
- Client proxies between your local service and remote connections
- Pending-connection manager backed by OTP (Registry + DynamicSupervisor) for robust cleanup
- Socket tuning flags (`--sndbuf`, `--recbuf`) for high-throughput/latency paths
 - Optional TLS on control plane (`--tls`); multi-secret auth (comma-separated)
 - Access control lists and limits: `--allow`, `--deny`, `--max-conns-per-ip`
 - Prometheus metrics endpoint (text exposition)

## Install / Build
```bash
mix deps.get
mix escript.build
```
This produces an executable named `spore` in the project directory.

### Optional config file (JSON)
You can pass a JSON config with `--config FILE.json` on both server and client. Supported keys:
`control_port`, `tls`, `cacertfile`, `client_certfile`, `client_keyfile`, `certfile`, `keyfile`, `allow`, `deny`, `max_conns_per_ip`, `metrics_port`, `sndbuf`, `recbuf`.

## Quickstart
### Server (choose a public range)
```bash
./spore server --min-port 20000 --max-port 21000 --bind-addr 0.0.0.0 \
  [--control-port 7835] [--tls --certfile cert.pem --keyfile key.pem] \
  [--allow "10.0.0.0/8,192.168.0.0/16"] [--deny "0.0.0.0/0"] [--max-conns-per-ip 50] \
  [--sndbuf 1048576] [--recbuf 1048576]
```

### Client (forward local 3000; let server assign a port)
```bash
./spore local --local-host 127.0.0.1 --local-port 3000 --to <SERVER_HOST> --port 0 [--control-port 7835] [--sndbuf 1048576] [--recbuf 1048576]
```
Spore prints the assigned public port (for example, `listening at <SERVER_HOST>:20345`).

## Local test (no web app required)
Terminal A (target service):
```bash
python3 -m http.server 25565
```
Terminal B (server):
```bash
./spore server --min-port 20000 --max-port 21000 --bind-addr 127.0.0.1 [--control-port 7835] [--sndbuf 1048576] [--recbuf 1048576]
```
Terminal C (client):
```bash
./spore local --local-host 127.0.0.1 --local-port 25565 --to 127.0.0.1 --port 0 [--control-port 7835] [--sndbuf 1048576] [--recbuf 1048576]
```
Terminal D (access through tunnel):
```bash
curl -v 127.0.0.1:<ASSIGNED_PORT>/
```

## Authentication (optional)
Provide the same secret on both sides to restrict access:
```bash
./spore server --secret "secret1,secret2" [--control-port 7835] [--sndbuf N] [--recbuf N]
./spore local --local-port 3000 --to <SERVER_HOST> --secret SECRET [--control-port 7835] [--sndbuf N] [--recbuf N]
```

## Metrics
Spore exposes basic counters and latency sums in Prometheus text format if `SPORE_METRICS_PORT` or `--metrics-port` is set (server-only). Example:
```
spore_connections_incoming_total 42
spore_connections_accepted_total 40
spore_connections_stale_total 2
spore_bytes_proxied_total 1234567
spore_accept_latency_ms_sum 350
spore_accept_latency_ms_count 40
```

## Interoperability
Spore is designed to speak the same control protocol as Bore. You can mix Rust Bore on one side and Spore on the other as long as secrets and addresses match. See Bore docs for protocol details: [bore (Rust)](https://github.com/ekzhang/bore).

## Notes / Limitations
- TCP only. If you need UDP (for example, Minecraft Bedrock), use a UDP-capable tunnel.
- Pending inbound connections are stored for up to 10 seconds; if the client does not accept within that window, they are dropped. Spore uses a supervised, per-connection process to manage this lifecycle.

## Troubleshooting
- "address in use" starting server: another process is listening on the control port. Use `--control-port` to choose a different one or stop the existing process.
- Client exits with `:eof`: ensure server is reachable at `--to`, secrets match (or are omitted on both), and the control port is open.
- Repeated "removed stale connection": ensure the client is running and a remote connection arrives soon after the client starts (Spore holds pending connections for 10s).
- Low throughput on high-latency links: increase `--sndbuf`/`--recbuf` on both ends to match your bandwidth-delay product.
 - TLS client trust: provide `--cacertfile` on the client or use `--insecure` in test environments.

## License
MIT, following the upstream project.


