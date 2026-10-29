package originping

import (
	"bytes"
	"io"
	"net"
	"sync"
	"testing"
	"time"

	"github.com/gobwas/ws"
	"github.com/gobwas/ws/wsutil"
)

// This is exactly the read primitive called by cloudflared 2026.10.3
// (de6376c5af4a67cbc65258682e5a01781827643d), websocket.Conn.Read.
// No Cloudflare endpoint, credentials or user SSH service is involved.
func startOriginRead(t *testing.T, connection net.Conn) <-chan []byte {
	t.Helper()
	done := make(chan []byte, 1)
	go func() {
		data, err := wsutil.ReadClientBinary(connection)
		if err != nil {
			done <- nil
			return
		}
		done <- data
	}()
	return done
}

func connectionPair(t *testing.T) (net.Conn, net.Conn) {
	t.Helper()
	client, server := net.Pipe()
	t.Cleanup(func() { client.Close(); server.Close() })
	client.SetDeadline(time.Now().Add(3 * time.Second))
	server.SetDeadline(time.Now().Add(3 * time.Second))
	return client, server
}

func expectPong(t *testing.T, connection net.Conn, payload []byte) {
	t.Helper()
	messages, err := wsutil.ReadServerMessage(connection, nil)
	if err != nil {
		t.Fatal(err)
	}
	if len(messages) != 1 || messages[0].OpCode != ws.OpPong || !bytes.Equal(messages[0].Payload, payload) {
		t.Fatal("origin did not return a matching pong")
	}
}

func TestCloudflaredOriginReadRepliesToNativeSizedPingBeforeBinary(t *testing.T) {
	client, server := connectionPair(t)
	result := startOriginRead(t, server)
	ping := []byte{0, 1, 2, 3, 0xff, 0xfe, 0xfd, 0xfc}
	if err := wsutil.WriteClientMessage(client, ws.OpPing, ping); err != nil {
		t.Fatal(err)
	}
	expectPong(t, client, ping)
	select {
	case <-result:
		t.Fatal("ping was forwarded to the SSH byte consumer")
	default:
	}
	data := []byte("SSH-2.0-synthetic-test\r\n")
	if err := wsutil.WriteClientBinary(client, data); err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(<-result, data) {
		t.Fatal("binary bytes changed")
	}
}

func TestCloudflaredOriginReadRepliesToPingBetweenBinaryFragments(t *testing.T) {
	client, server := connectionPair(t)
	result := startOriginRead(t, server)
	first := ws.MaskFrameInPlace(ws.NewFrame(ws.OpBinary, false, []byte("first")))
	if err := ws.WriteFrame(client, first); err != nil {
		t.Fatal(err)
	}
	ping := []byte("12345678")
	if err := wsutil.WriteClientMessage(client, ws.OpPing, ping); err != nil {
		t.Fatal(err)
	}
	expectPong(t, client, ping)
	last := ws.MaskFrameInPlace(ws.NewFrame(ws.OpContinuation, true, []byte("last")))
	if err := ws.WriteFrame(client, last); err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(<-result, []byte("firstlast")) {
		t.Fatal("fragmented bytes changed")
	}
}

func TestOriginControlResponseWaitsUntilOriginReadResumes(t *testing.T) {
	client, server := connectionPair(t)
	firstRead := startOriginRead(t, server)
	if err := wsutil.WriteClientBinary(client, []byte("ssh payload")); err != nil {
		t.Fatal(err)
	}
	if len(<-firstRead) == 0 {
		t.Fatal("first origin read failed")
	}
	// stream.Pipe cannot start its next source Read while the SSH destination's
	// Write is blocked. Model that exact pause without changing control logic.
	ping := []byte("12345678")
	written := make(chan error, 1)
	go func() { written <- wsutil.WriteClientMessage(client, ws.OpPing, ping) }()
	client.SetReadDeadline(time.Now().Add(100 * time.Millisecond))
	_, err := ws.ReadHeader(client)
	if timeout, ok := err.(net.Error); !ok || !timeout.Timeout() {
		t.Fatal("expected no pong while origin is not reading")
	}
	client.SetReadDeadline(time.Now().Add(3 * time.Second))
	secondRead := startOriginRead(t, server)
	expectPong(t, client, ping)
	if err := <-written; err != nil {
		t.Fatal(err)
	}
	client.Close()
	select {
	case <-secondRead:
	case <-time.After(time.Second):
		t.Fatal(io.ErrNoProgress)
	}
}

type interleavedOrigin struct {
	input         *bytes.Reader
	output        bytes.Buffer
	lock          sync.Mutex
	headerWritten chan struct{}
	releaseHeader chan struct{}
	headerBlocked bool
}

func (r *interleavedOrigin) Read(p []byte) (int, error) { return r.input.Read(p) }

func (r *interleavedOrigin) Write(p []byte) (int, error) {
	r.lock.Lock()
	n, err := r.output.Write(p)
	block := !r.headerBlocked && len(p) == 2 && p[0] == 0x82
	if block {
		r.headerBlocked = true
	}
	r.lock.Unlock()
	if block {
		close(r.headerWritten)
		<-r.releaseHeader
	}
	return n, err
}

func TestOriginUnlockedControlWriteCanInterleaveBinaryHeaderAndPayload(t *testing.T) {
	var input bytes.Buffer
	if err := wsutil.WriteClientMessage(&input, ws.OpPing, []byte("12345678")); err != nil {
		t.Fatal(err)
	}
	if err := wsutil.WriteClientBinary(&input, []byte("input")); err != nil {
		t.Fatal(err)
	}
	rw := &interleavedOrigin{input: bytes.NewReader(input.Bytes()), headerWritten: make(chan struct{}), releaseHeader: make(chan struct{})}
	data := []byte("server SSH output")
	result := make(chan error, 1)
	var originWriteLock sync.Mutex
	go func() {
		// cloudflared Conn.Write holds this lock around WriteServerBinary.
		originWriteLock.Lock()
		defer originWriteLock.Unlock()
		result <- wsutil.WriteServerBinary(rw, data)
	}()
	<-rw.headerWritten
	// cloudflared Conn.Read passes the raw rw to ReadClientBinary. Its implicit
	// pong write does not take originWriteLock, unlike Conn.Write and ping().
	if _, err := wsutil.ReadClientBinary(rw); err != nil {
		t.Fatal(err)
	}
	close(rw.releaseHeader)
	if err := <-result; err != nil {
		t.Fatal(err)
	}
	frames, err := wsutil.ReadServerMessage(bytes.NewReader(rw.output.Bytes()), nil)
	if err != nil {
		t.Fatal(err)
	}
	if len(frames) != 1 || frames[0].OpCode != ws.OpBinary {
		t.Fatal("expected the initial binary frame header")
	}
	if bytes.Equal(frames[0].Payload, data) {
		t.Fatal("expected the unlocked pong to corrupt binary framing")
	}
}
