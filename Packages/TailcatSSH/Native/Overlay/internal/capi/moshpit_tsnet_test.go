package capi

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http/httptest"
	"net/netip"
	"strings"
	"sync/atomic"
	"tailscale.com/ipn/ipnstate"
	"tailscale.com/tailcfg"
	"tailscale.com/tsnet"
	"tailscale.com/tstest/integration/testcontrol"
	"tailscale.com/types/key"
	"tailscale.com/types/logger"
	"testing"
	"time"
)

type fakeMTBackend struct {
	starts    atomic.Int32
	logins    atomic.Int32
	closes    atomic.Int32
	startGate <-chan struct{}
	status    *ipnstate.Status
	dial      func(context.Context, string, string) (net.Conn, error)
}

func (f *fakeMTBackend) Start() error {
	f.starts.Add(1)
	if f.startGate != nil {
		<-f.startGate
	}
	return nil
}
func (f *fakeMTBackend) Status(context.Context) (*ipnstate.Status, error) { return f.status, nil }
func (f *fakeMTBackend) Login(context.Context) error                      { f.logins.Add(1); return nil }
func (f *fakeMTBackend) Logout(context.Context) error                     { return nil }
func (f *fakeMTBackend) Dial(ctx context.Context, network, address string) (net.Conn, error) {
	return f.dial(ctx, network, address)
}
func (f *fakeMTBackend) Close() error { f.closes.Add(1); return nil }
func fakeMTNode(t *testing.T, f *fakeMTBackend) (Handle, *tailscaleNode) {
	t.Helper()
	if f.status != nil && f.status.Peer == nil {
		f.status.Peer = map[key.NodePublic]*ipnstate.PeerStatus{key.NewNode().Public(): {ID: "test-peer", HostName: "node", DNSName: "server.tailnet.ts.net.", TailscaleIPs: []netip.Addr{netip.MustParseAddr("100.64.0.3")}}}
	}
	store, err := newSealedStateStore(t.TempDir(), make([]byte, 32))
	if err != nil {
		t.Fatal(err)
	}
	n := &tailscaleNode{backend: f, store: store, startDone: make(chan struct{}), lifecycle: newGate(), controlURL: "https://controlplane.tailscale.com"}
	id, err := register(n, 0)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { Close(id) })
	return id, n
}
func mtToken(t *testing.T, timeout time.Duration) Handle {
	t.Helper()
	h, err := NewToken(int64(timeout))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { Close(h) })
	return h
}

func TestMTNodeOfflineStatusNoImplicitLogin(t *testing.T) {
	f := &fakeMTBackend{}
	id, _ := fakeMTNode(t, f)
	status, err := TailscaleNodeStatus(id, NoCancel)
	if err != nil || !strings.Contains(status, `"backend_state":"Stopped"`) {
		t.Fatalf("%v %s", err, status)
	}
	if _, err := DialTailscaleNode(id, NoCancel, "node", 22); !errors.Is(err, ErrMTAuth) {
		t.Fatal(err)
	}
	if f.starts.Load() != 0 || f.logins.Load() != 0 {
		t.Fatal("status/dial initiated enrollment")
	}
}

func TestMTHealthProjectionClassifiesFailuresWithoutLeakingDetails(t *testing.T) {
	tests := []struct {
		name, warning string
		want          []string
	}{
		{"network", "Tailscale cannot connect because the network is down. Check your Internet connection.", []string{"network_unavailable"}},
		{"dns", "You are logged out. The last login error was: fetching key: lookup private.example on 192.0.2.1:53: no such host", []string{"dns_unavailable"}},
		{"dns timeout", "You are logged out. The last login error was: lookup private.example: i/o timeout", []string{"dns_unavailable", "timeout"}},
		{"certificate", "You are logged out. The last login error was: x509: certificate signed by unknown authority", []string{"tls_failure"}},
		{"handshake timeout", "You are logged out. The last login error was: net/http: TLS handshake timeout", []string{"timeout", "tls_failure"}},
		{"dial", "You are logged out. The last login error was: dial tcp 192.0.2.2:443: connection refused", []string{"control_unreachable"}},
		{"route", "You are logged out. The last login error was: dial tcp 192.0.2.2:443: network is unreachable", []string{"control_unreachable", "network_unavailable"}},
		{"control", "Unable to connect to the Tailscale coordination server to synchronize the state of your tailnet.", []string{"control_unreachable"}},
		{"deadline", "You are logged out. The last login error was: context deadline exceeded", []string{"timeout"}},
		{"normal signed out", "You are logged out.", []string{}},
		{"unrecognized", "Account SECRET_ACCOUNT needs authorization at https://login.tailscale.com/a/SECRET_TOKEN", []string{}},
		{"unrelated warning", "This is an unstable version of Tailscale meant for testing and development purposes.", []string{}},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := projectHealthIssues([]string{tt.warning, tt.warning})
			if strings.Join(got, ",") != strings.Join(tt.want, ",") {
				t.Fatalf("classifications = %v, want %v", got, tt.want)
			}
		})
	}
	status := projectStatus(&ipnstate.Status{
		BackendState: "NeedsLogin",
		Health:       []string{"You are logged out. The last login error was: Get https://login.tailscale.com/a/SECRET_TOKEN?email=SECRET_ACCOUNT: dial tcp 192.0.2.99:443: i/o timeout"},
	}, "https://controlplane.tailscale.com")
	raw, err := json.Marshal(status)
	if err != nil {
		t.Fatal(err)
	}
	for _, sensitive := range []string{"SECRET_TOKEN", "SECRET_ACCOUNT", "192.0.2.99", "last login error", "login.tailscale.com"} {
		if strings.Contains(string(raw), sensitive) {
			t.Fatalf("projected status leaked native health details")
		}
	}
	if !strings.Contains(string(raw), `"health_issues":["control_unreachable","timeout"]`) {
		t.Fatal("projected status omitted safe classifications")
	}
}
func TestMTStartCancellationJoinsInitializationOnClose(t *testing.T) {
	gate := make(chan struct{})
	f := &fakeMTBackend{startGate: gate}
	id, n := fakeMTNode(t, f)
	if err := StartTailscaleNode(id, mtToken(t, 10*time.Millisecond)); !errors.Is(err, context.DeadlineExceeded) {
		t.Fatal(err)
	}
	done := make(chan error, 1)
	go func() { done <- Close(id) }()
	select {
	case <-done:
		t.Fatal("closed store while initialization active")
	case <-time.After(10 * time.Millisecond):
	}
	close(gate)
	select {
	case err := <-done:
		if err != nil {
			t.Fatal(err)
		}
	case <-time.After(time.Second):
		t.Fatal("close did not finish")
	}
	if f.closes.Load() != 1 {
		t.Fatal("backend not closed")
	}
	if _, err := n.store.ReadState("x"); !errors.Is(err, ErrMTStorage) {
		t.Fatal("store still open")
	}
}
func TestMTDialRequiresApprovalAndDoesNotLogin(t *testing.T) {
	f := &fakeMTBackend{status: &ipnstate.Status{BackendState: "NeedsMachineAuth"}}
	id, _ := fakeMTNode(t, f)
	if err := StartTailscaleNode(id, NoCancel); err != nil {
		t.Fatal(err)
	}
	if _, err := DialTailscaleNode(id, NoCancel, "node", 22); !errors.Is(err, ErrMTApproval) {
		t.Fatal(err)
	}
	if f.logins.Load() != 0 {
		t.Fatal("dial initiated login")
	}
}
func TestMTStreamsReuseTailcatLifetimeAndEOF(t *testing.T) {
	var remote net.Conn
	f := &fakeMTBackend{status: &ipnstate.Status{BackendState: "Running"}, dial: func(ctx context.Context, n, a string) (net.Conn, error) {
		local, r := net.Pipe()
		remote = r
		return local, nil
	}}
	id, _ := fakeMTNode(t, f)
	StartTailscaleNode(id, NoCancel)
	stream, err := DialTailscaleNode(id, NoCancel, "server.tailnet.ts.net", 22)
	if err != nil {
		t.Fatal(err)
	}
	payload := []byte("你好\x00\xffSSH")
	go func() { remote.Write(payload); remote.Close() }()
	buf := make([]byte, 128)
	count, err := Read(stream, mtToken(t, time.Second), buf)
	if err != nil || !bytes.Equal(buf[:count], payload) {
		t.Fatalf("binary data %d %v", count, err)
	}
	if _, err := Read(stream, NoCancel, buf); !errors.Is(err, io.EOF) {
		t.Fatal(err)
	}
	if err := Close(id); err != nil {
		t.Fatal(err)
	}
	if _, err := Read(stream, NoCancel, buf); !errors.Is(err, ErrHandle) {
		t.Fatal("node did not retire stream")
	}
}
func TestMTDialCancellationAndLogoutGeneration(t *testing.T) {
	started := make(chan struct{})
	release := make(chan struct{})
	var remote net.Conn
	f := &fakeMTBackend{status: &ipnstate.Status{BackendState: "Running"}, dial: func(ctx context.Context, n, a string) (net.Conn, error) {
		close(started)
		select {
		case <-ctx.Done():
			return nil, ctx.Err()
		case <-release:
		}
		local, r := net.Pipe()
		remote = r
		return local, nil
	}}
	id, _ := fakeMTNode(t, f)
	StartTailscaleNode(id, NoCancel)
	done := make(chan error, 1)
	go func() { _, err := DialTailscaleNode(id, mtToken(t, time.Second), "node", 22); done <- err }()
	<-started
	if err := LogoutTailscaleNode(id, NoCancel); err != nil {
		t.Fatal(err)
	}
	close(release)
	if err := <-done; !errors.Is(err, ErrMTAuth) {
		t.Fatalf("dial survived logout: %v", err)
	}
	defer remote.Close()
	remote.SetReadDeadline(time.Now().Add(time.Second))
	if _, err := remote.Read(make([]byte, 1)); !errors.Is(err, io.EOF) {
		t.Fatal("rejected stream leaked")
	}
}
func TestMTStatusProjectionNoPrivateDataAndStableIdentity(t *testing.T) {
	self := &ipnstate.PeerStatus{ID: "self-id", UserID: 123, HostName: "phone", TailscaleIPs: []netip.Addr{netip.MustParseAddr("100.64.0.2")}}
	status := &ipnstate.Status{BackendState: "Running", Self: self, CurrentTailnet: &ipnstate.TailnetStatus{Name: "tailnet", StableID: "tn-stable"}, User: map[tailcfg.UserID]tailcfg.UserProfile{123: {LoginName: "person@example.test"}}, Peer: map[key.NodePublic]*ipnstate.PeerStatus{key.NewNode().Public(): {ID: "server", HostName: "mini", DNSName: "mini.tailnet.ts.net.", Online: true}}}
	a := projectStatus(status, "https://controlplane.tailscale.com")
	status.CurrentTailnet.Name = "renamed"
	b := projectStatus(status, "https://controlplane.tailscale.com")
	if a.AccountIdentity == nil || b.AccountIdentity == nil || *a.AccountIdentity != *b.AccountIdentity {
		t.Fatal("identity not stable")
	}
	c := projectStatus(status, "https://other.example.test")
	if *a.AccountIdentity == *c.AccountIdentity {
		t.Fatal("control namespaces collide")
	}
	raw, _ := json.Marshal(a)
	for _, forbidden := range []string{"PrivateKey", "NodeKey", "Health", "Capabilities", "PublicKey"} {
		if strings.Contains(string(raw), forbidden) {
			t.Fatal("unsafe status field")
		}
	}
	if a.Peers[0].DNSName != "mini.tailnet.ts.net" {
		t.Fatal("DNS projection")
	}
}
func TestMTConfigAndErrorsFailClosed(t *testing.T) {
	for _, input := range []string{`{}`, `{"state_directory":"/tmp","hostname":"x","unexpected":true}`, `{"state_directory":"/tmp","hostname":"x","control_url":"http://example.com"}`} {
		if _, err := NewTailscaleNode(input, make([]byte, 32)); !errors.Is(err, ErrArgument) {
			t.Fatalf("invalid accepted: %v", err)
		}
	}
	if TailscaleErrorMessage(TailscaleErrorCode(fmt.Errorf("secret token=%s", "hidden"))) != "Tailscale operation failed" {
		t.Fatal("raw error leaked")
	}
	for _, host := range []string{"", "https://example.com", "node:22", "a\x00b", "name with space"} {
		if validateTailscaleHost(host) {
			t.Fatal("invalid host accepted")
		}
	}
}

func TestMTOnlyKnownPeersNoPublicDNSOrNetworkFallback(t *testing.T) {
	status := &ipnstate.Status{Peer: map[key.NodePublic]*ipnstate.PeerStatus{
		key.NewNode().Public(): {ID: "one", HostName: "mini", DNSName: "mini.tailnet.ts.net.", TailscaleIPs: []netip.Addr{netip.MustParseAddr("100.64.0.3")}},
	}}
	for _, host := range []string{"100.64.0.3", "mini", "MINI.tailnet.ts.net."} {
		got, err := resolveTailscalePeer(status, host)
		if err != nil || got.String() != "100.64.0.3" {
			t.Fatalf("known peer %q: %v", host, err)
		}
	}
	for _, host := range []string{"1.1.1.1", "127.0.0.1", "100.64.0.4", "example.com", "mini.attacker.test"} {
		if _, err := resolveTailscalePeer(status, host); !errors.Is(err, ErrArgument) {
			t.Fatalf("nonpeer accepted: %q", host)
		}
	}
	status.Peer[key.NewNode().Public()] = &ipnstate.PeerStatus{ID: "two", HostName: "mini", TailscaleIPs: []netip.Addr{netip.MustParseAddr("100.64.0.4")}}
	if _, err := resolveTailscalePeer(status, "mini"); !errors.Is(err, ErrArgument) {
		t.Fatal("ambiguous hostname accepted")
	}
}
func TestMTRealEngineLocalStartupAndClose(t *testing.T) {
	config, _ := json.Marshal(tailscaleConfig{StateDirectory: t.TempDir(), Hostname: "moshpit-native-test", ControlURL: "https://127.0.0.1:1"})
	id, err := NewTailscaleNode(string(config), make([]byte, 32))
	if err != nil {
		t.Fatal(err)
	}
	defer Close(id)
	if err := StartTailscaleNode(id, mtToken(t, 10*time.Second)); err != nil {
		t.Fatal(err)
	}
	if _, err := TailscaleNodeStatus(id, mtToken(t, time.Second)); err != nil {
		t.Fatal(err)
	}
	if err := Close(id); err != nil {
		t.Fatal(err)
	}
}

// Use the actual upstream control protocol to distinguish restoring a node
// from enrolling it. No production tailnet, browser, auth key or DERP is used.
func TestMTRealEngineRequiresExplicitInteractiveLogin(t *testing.T) {
	control := &testcontrol.Server{RequireAuth: true, Logf: logger.Discard, DERPMap: &tailcfg.DERPMap{}}
	server := httptest.NewServer(control)
	defer server.Close()
	control.HTTPTestServer = server
	store, err := newSealedStateStore(t.TempDir(), make([]byte, 32))
	if err != nil {
		t.Fatal(err)
	}
	backend := &embeddedBackend{server: &tsnet.Server{Dir: t.TempDir(), Store: store, Hostname: "moshpit-explicit-login-test",
		ControlURL: server.URL, AuthKey: "ambient-key-must-not-be-used", MoshpitExplicitLoginOnly: true, UserLogf: logger.Discard, Logf: logger.Discard}}
	node := &tailscaleNode{backend: backend, store: store, controlURL: server.URL, startDone: make(chan struct{}), lifecycle: newGate()}
	id, err := register(node, 0)
	if err != nil {
		t.Fatal(err)
	}
	defer Close(id)
	if err := StartTailscaleNode(id, mtToken(t, 5*time.Second)); err != nil {
		t.Fatal("engine startup failed")
	}
	until := time.Now().Add(300 * time.Millisecond)
	for time.Now().Before(until) {
		status, err := backend.Status(context.Background())
		if err != nil {
			t.Fatal("status failed")
		}
		if status.AuthURL != "" || status.BackendState == "Running" {
			t.Fatal("start implicitly enrolled or requested a login")
		}
		time.Sleep(20 * time.Millisecond)
	}
	if err := LoginTailscaleNode(id, mtToken(t, 5*time.Second)); err != nil {
		t.Fatal("explicit login failed")
	}
	until = time.Now().Add(5 * time.Second)
	for time.Now().Before(until) {
		status, err := backend.Status(context.Background())
		if err != nil {
			t.Fatal("status failed")
		}
		if status.AuthURL != "" {
			return
		}
		time.Sleep(20 * time.Millisecond)
	}
	t.Fatal("explicit login did not produce a login URL")
}
