# PartyFault

PartyFault is a protocol-agnostic TCP and UDP fault proxy for Swift programs using the modern,
typed `Network.framework` API introduced in Apple OS 26. It is useful for exercising reconnect,
fallback, ordering, timeout, and backpressure behavior without teaching the proxy anything about
your application protocol.

The library provides deterministic, independently configurable client-to-server and
server-to-client links. UDP supports loss, delay, jitter, duplication, and windowed reordering.
TCP supports delay, jitter, bandwidth throttling, blackholes, connection cuts, and resets. The CLI
exposes a live JSON-over-TCP control socket plus a metrics command; it does not run an HTTP server.

```sh
swift run --package-path PartyFault partyfault serve \
  --upstream-host 127.0.0.1 --tcp 9000 --udp 9000 --control 9900

swift run --package-path PartyFault partyfault control 127.0.0.1:9900 metrics
swift run --package-path PartyFault partyfault control 127.0.0.1:9900 profile profile.json
swift run --package-path PartyFault partyfault control 127.0.0.1:9900 cut
```

The `serve` command prints one JSON `ProxyEndpoints` object after both listeners are ready. Point a
client at those TCP and UDP ports. Profiles are clamped to safe bounds and seeded, so a scenario can
be reproduced in CI.

PartyFault is licensed under Apache-2.0.
