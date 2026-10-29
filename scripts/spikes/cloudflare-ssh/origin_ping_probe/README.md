# Pinned cloudflared origin ping investigation

This local probe uses the exact `wsutil.ReadClientBinary` primitive called by
cloudflared **2026.10.3**, commit
`de6376c5af4a67cbc65258682e5a01781827643d`. It does not start a tunnel, contact an
Access application, read credentials, or modify the app. It is not a run of the
full official binary or proof of what happened on a particular real connection.

```sh
go test -mod=readonly -timeout=10s -count=1 -v .
```

The 2026-10-27 local run passed **4 tests** in 0.452 seconds. Dependencies are
pinned in `go.mod`/`go.sum`; the `gobwas/ws v1.2.1` module checksum is
`h1:F2aeBZrm2NDsc7vbovKrWSogd4wvfAxg0FQ89/iqOTk=`, matching the pinned
cloudflared `go.sum`. Network fetch is only required to populate Go's normal
module cache; after that, the same tests run with `GOPROXY=off`.

## Results

1. A masked eight-byte client ping receives an unmasked pong with identical
   payload, before any binary data. Control bytes do not enter the SSH stream.
2. A ping between binary continuation frames also receives the matching pong;
   the binary payload remains intact.
3. A pause between origin reads delays pong handling. This models the source
   read loop waiting for an SSH destination write; it does not establish that
   the real fixture experienced that backpressure.
4. A deterministic concurrent-write schedule reproduces a separate upstream
   framing defect: `Conn.Write` locks `WriteServerBinary`, but `Conn.Read` passes
   the raw writer to `ReadClientBinary`, whose automatic pong write bypasses
   that lock. `ws.WriteFrame` writes a binary header and payload separately.
   Inserting a pong between those writes corrupts the binary message. The test
   deliberately forces that schedule; it does not measure its frequency on a
   real Cloudflare transport.

The hypothesis that the pinned origin simply ignores client pings is therefore
false. The independent unlocked-control-write defect is reproducible locally.
Neither finding proves the cause of the recorded simulator disconnect.

## Source chain

- [cloudflared websocket.Conn](https://github.com/cloudflare/cloudflared/blob/de6376c5af4a67cbc65258682e5a01781827643d/websocket/connection.go):
  `Read`, `Write`, `ping`, and their lock boundaries.
- [cloudflared stream pipe](https://github.com/cloudflare/cloudflared/blob/de6376c5af4a67cbc65258682e5a01781827643d/stream/stream.go)
  and [copy loop](https://github.com/cloudflare/cloudflared/blob/de6376c5af4a67cbc65258682e5a01781827643d/cfio/copy.go):
  each source read waits for its destination write before continuing.
- [gobwas helper.go v1.2.1](https://github.com/gobwas/ws/blob/v1.2.1/wsutil/helper.go):
  `readData` installs and invokes `ControlFrameHandler`, including mid-message
  controls.
- [gobwas handler.go v1.2.1](https://github.com/gobwas/ws/blob/v1.2.1/wsutil/handler.go):
  `HandlePing` copies the received payload into its pong reply.
- [gobwas write.go v1.2.1](https://github.com/gobwas/ws/blob/v1.2.1/write.go):
  `WriteFrame` has separate header and payload writes.

## Real-run evidence still needed

The original native adapter started its 10-second pong deadline when a ping
was queued, without waiting for its write completion. Separate native tests
reproduced premature closure with 8 seconds in the queue plus a 5-second reply,
and a stale deadline when a matching pong arrived synchronously during writing.
The corrected adapter retains the 20-second interval and 10-second pong budget,
but starts the latter after write completion. A pending ping has its own bounded
10-second no-write-progress deadline; individual completed frames reset that
deadline, without extending the deadline for an already-written ping. This fixes
reproduced native timer defects; it does not fix or prove exposure to the upstream
concurrent control-write defect. No native masking or readable-byte comparison
defect was found in this audit.

The mini SFTP run reported `tcpShutdown`/`Already closed` after 39.504 seconds;
the phone SFTP run succeeded after 39.870 seconds. These totals include dialing
and SSH authentication, so they do not identify a 30-second WS heartbeat failure.
Citadel can consume the parent-channel error and leave a child SFTP channel with
only the later TCP-shutdown symptom.

Record monotonic times for WS upgrade, ping queued/flushed, matching pong,
incoming close, and the first local close/error reason. Only then attribute a
real failure to missing pong, malformed framing, remote EOF, or another cause.
The original real-session disconnect remains unclassified until those
observations exist, even after fixing the independently reproduced timer defects.
