// Copyright (c) Moshpit contributors. SPDX-License-Identifier: MIT
package capi

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io"
	"net"
	"net/netip"
	"net/url"
	"sort"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"

	"tailscale.com/ipn/ipnstate"
	"tailscale.com/tsnet"
	"tailscale.com/types/logger"
)

type tailscaleConfig struct {
	StateDirectory string `json:"state_directory"`
	Hostname       string `json:"hostname"`
	ControlURL     string `json:"control_url,omitempty"`
}

type tailscaleBackend interface {
	Start() error
	Status(context.Context) (*ipnstate.Status, error)
	Login(context.Context) error
	Logout(context.Context) error
	Dial(context.Context, string, string) (net.Conn, error)
	Close() error
}
type embeddedBackend struct{ server *tsnet.Server }

func (b *embeddedBackend) Start() error { return b.server.Start() }
func (b *embeddedBackend) Status(ctx context.Context) (*ipnstate.Status, error) {
	lc, err := b.server.LocalClient()
	if err != nil {
		return nil, err
	}
	return lc.Status(ctx)
}
func (b *embeddedBackend) Login(ctx context.Context) error {
	lc, err := b.server.LocalClient()
	if err != nil {
		return err
	}
	return lc.StartLoginInteractive(ctx)
}
func (b *embeddedBackend) Logout(ctx context.Context) error {
	lc, err := b.server.LocalClient()
	if err != nil {
		return err
	}
	return lc.Logout(ctx)
}
func (b *embeddedBackend) Dial(ctx context.Context, network, address string) (net.Conn, error) {
	if network != "tcp" {
		return nil, ErrArgument
	}
	destination, err := netip.ParseAddrPort(address)
	if err != nil {
		return nil, ErrArgument
	}
	return b.server.MoshpitDialPeerTCP(ctx, destination)
}
func (b *embeddedBackend) Close() error { return b.server.Close() }

type tailscaleNode struct {
	backend     tailscaleBackend
	store       *sealedStateStore
	controlURL  string
	startOnce   sync.Once
	startCalled atomic.Bool
	startDone   chan struct{}
	startErr    error // published by closing startDone
	lifecycle   gate
	epoch       atomic.Uint64
}

func NewTailscaleNode(configJSON string, encryptionKey []byte) (Handle, error) {
	if len(configJSON) > 16384 {
		return 0, ErrArgument
	}
	var config tailscaleConfig
	decoder := json.NewDecoder(strings.NewReader(configJSON))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&config); err != nil {
		return 0, ErrArgument
	}
	if decoder.Decode(new(any)) != io.EOF {
		return 0, ErrArgument
	}
	if len(config.Hostname) == 0 || len(config.Hostname) > 63 || strings.Trim(config.Hostname, "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-") != "" || strings.HasPrefix(config.Hostname, "-") || strings.HasSuffix(config.Hostname, "-") {
		return 0, ErrArgument
	}
	if config.ControlURL == "" {
		config.ControlURL = "https://controlplane.tailscale.com"
	}
	parsed, err := url.Parse(config.ControlURL)
	if err != nil || parsed.Scheme != "https" || parsed.Host == "" || parsed.User != nil || parsed.RawQuery != "" || parsed.Fragment != "" {
		return 0, ErrArgument
	}
	store, err := newSealedStateStore(config.StateDirectory, encryptionKey)
	if err != nil {
		return 0, err
	}
	node := &tailscaleNode{
		backend: &embeddedBackend{server: &tsnet.Server{Dir: config.StateDirectory, Store: store,
			Hostname: config.Hostname, ControlURL: config.ControlURL, UserLogf: logger.Discard, Logf: logger.Discard,
			MoshpitExplicitLoginOnly: true}},
		store: store, controlURL: strings.TrimSuffix(config.ControlURL, "/"), startDone: make(chan struct{}), lifecycle: newGate(),
	}
	id, err := register(node, 0)
	if err != nil {
		store.Close()
	}
	return id, err
}

// Start initializes the tsnet engine once. Its own startup has no context API;
// the caller can stop waiting without freeing resources underneath initialization.
// Closing the node joins initialization before closing its backend and store.
func (n *tailscaleNode) start(ctx context.Context) error {
	if err := ctx.Err(); err != nil {
		return err
	}
	n.startOnce.Do(func() { n.startCalled.Store(true); go func() { n.startErr = n.backend.Start(); close(n.startDone) }() })
	select {
	case <-ctx.Done():
		return ctx.Err()
	case <-n.startDone:
	}
	if n.startErr != nil {
		return n.startErr
	}
	return n.store.health()
}
func (n *tailscaleNode) close() error {
	var err error
	if n.startCalled.Load() {
		<-n.startDone
		err = n.backend.Close()
	}
	return errors.Join(err, n.store.Close())
}

func StartTailscaleNode(id, token Handle) error {
	return use[*tailscaleNode](id, token, func(ctx context.Context, e *entry, n *tailscaleNode) error { return n.start(ctx) })
}

type TailscalePeer struct {
	ID       string   `json:"id"`
	Hostname string   `json:"hostname"`
	DNSName  string   `json:"dns_name"`
	IPs      []string `json:"ips"`
	Online   bool     `json:"online"`
}
type TailscaleStatus struct {
	SchemaVersion   int             `json:"schema_version"`
	BackendState    string          `json:"backend_state"`
	AuthURL         string          `json:"auth_url"`
	TailnetName     string          `json:"tailnet_name"`
	UserLogin       string          `json:"user_login"`
	AccountIdentity *string         `json:"account_identity"`
	Self            *TailscalePeer  `json:"self"`
	Peers           []TailscalePeer `json:"peers"`
	HealthIssues    []string        `json:"health_issues"`
}

// Health strings may contain authentication URLs, account names, and network
// addresses. Export only fixed classifications, never the original messages.
// Unrecognized warnings are deliberately omitted rather than guessed at.
func projectHealthIssues(messages []string) []string {
	issues := make(map[string]bool)
	for _, message := range messages {
		message = strings.ToLower(message)
		if strings.Contains(message, "network is down") || strings.Contains(message, "network is unreachable") || strings.Contains(message, "no route to host") {
			issues["network_unavailable"] = true
		}
		if strings.Contains(message, "lookup ") && (strings.Contains(message, "no such host") || strings.Contains(message, "server misbehaving") || strings.Contains(message, "timeout") || strings.Contains(message, "temporary failure in name resolution")) {
			issues["dns_unavailable"] = true
		}
		if strings.Contains(message, "x509:") || strings.Contains(message, "tls:") || strings.Contains(message, "tls handshake") {
			issues["tls_failure"] = true
		}
		if strings.Contains(message, "context deadline exceeded") || strings.Contains(message, "i/o timeout") || strings.Contains(message, "timed out") || strings.Contains(message, "tls handshake timeout") {
			issues["timeout"] = true
		}
		if strings.Contains(message, "unable to connect to the tailscale coordination server") ||
			(strings.Contains(message, "last login error was:") && (strings.Contains(message, "dial tcp") || strings.Contains(message, "dial udp") || strings.Contains(message, "connection refused") || strings.Contains(message, "connection reset") || strings.Contains(message, "unexpected eof"))) {
			issues["control_unreachable"] = true
		}
	}
	result := make([]string, 0, len(issues))
	for issue := range issues {
		result = append(result, issue)
	}
	sort.Strings(result)
	return result
}

func projectPeer(peer *ipnstate.PeerStatus) *TailscalePeer {
	if peer == nil {
		return nil
	}
	result := &TailscalePeer{ID: string(peer.ID), Hostname: peer.HostName, DNSName: strings.TrimSuffix(peer.DNSName, "."), IPs: []string{}, Online: peer.Online}
	for _, ip := range peer.TailscaleIPs {
		result.IPs = append(result.IPs, ip.String())
	}
	return result
}
func projectStatus(status *ipnstate.Status, controlURL string) TailscaleStatus {
	out := TailscaleStatus{SchemaVersion: 1, BackendState: status.BackendState, Peers: []TailscalePeer{}, Self: projectPeer(status.Self), HealthIssues: projectHealthIssues(status.Health)}
	if auth, err := url.Parse(status.AuthURL); err == nil && auth.Scheme == "https" && auth.Host != "" && auth.User == nil {
		out.AuthURL = status.AuthURL
	}
	if status.CurrentTailnet != nil {
		out.TailnetName = status.CurrentTailnet.Name
	}
	if status.Self != nil {
		out.UserLogin = status.User[status.Self.UserID].LoginName
		if status.Self.UserID != 0 && status.CurrentTailnet != nil {
			tailnetID := string(status.CurrentTailnet.StableID)
			if tailnetID == "" {
				tailnetID = status.CurrentTailnet.Name
			}
			value := sha256.Sum256([]byte(controlURL + "\x00" + tailnetID + "\x00" + strconv.FormatInt(int64(status.Self.UserID), 10)))
			identity := "tailscale:" + hex.EncodeToString(value[:])
			out.AccountIdentity = &identity
		}
	}
	for _, peer := range status.Peer {
		if p := projectPeer(peer); p != nil {
			out.Peers = append(out.Peers, *p)
		}
	}
	sort.Slice(out.Peers, func(i, j int) bool { return out.Peers[i].ID < out.Peers[j].ID })
	return out
}
func TailscaleNodeStatus(id, token Handle) (string, error) {
	var result string
	err := use[*tailscaleNode](id, token, func(ctx context.Context, e *entry, n *tailscaleNode) error {
		if err := n.store.health(); err != nil {
			return err
		}
		status := &ipnstate.Status{BackendState: "Stopped"}
		if n.startCalled.Load() {
			select {
			case <-n.startDone:
				if n.startErr != nil {
					return n.startErr
				}
				var err error
				status, err = n.backend.Status(ctx)
				if err != nil {
					return err
				}
			default:
				status.BackendState = "Starting"
			}
		}
		raw, err := json.Marshal(projectStatus(status, n.controlURL))
		result = string(raw)
		return err
	})
	return result, err
}
func LoginTailscaleNode(id, token Handle) error {
	return use[*tailscaleNode](id, token, func(ctx context.Context, e *entry, n *tailscaleNode) error {
		if err := n.lifecycle.lock(ctx); err != nil {
			return err
		}
		defer n.lifecycle.unlock()
		if err := n.start(ctx); err != nil {
			return err
		}
		status, err := n.backend.Status(ctx)
		if err != nil {
			return err
		}
		if status.BackendState == "Running" {
			return nil
		}
		return n.backend.Login(ctx)
	})
}
func LogoutTailscaleNode(id, token Handle) error {
	return use[*tailscaleNode](id, token, func(ctx context.Context, e *entry, n *tailscaleNode) error {
		if err := n.lifecycle.lock(ctx); err != nil {
			return err
		}
		defer n.lifecycle.unlock()
		if err := n.start(ctx); err != nil {
			return err
		}
		n.epoch.Add(1)
		registry.Lock()
		var children []Handle
		if current := registry.entries[e.id]; current != nil {
			for child := range current.children {
				children = append(children, child)
			}
		}
		registry.Unlock()
		for _, child := range children {
			_ = Close(child)
		}
		if err := n.backend.Logout(ctx); err != nil {
			return err
		}
		return n.store.health()
	})
}
func validateTailscaleHost(host string) bool {
	if len(host) == 0 || len(host) > 253 || strings.ContainsAny(host, "\x00/:[]@ \t\r\n") { // IPv6 is separately accepted.
		_, err := netip.ParseAddr(host)
		return err == nil && !strings.Contains(host, "%")
	}
	for _, r := range host {
		if r > 127 {
			return false
		}
	}
	return true
}

// Resolve exclusively against the current netmap: no public DNS lookup, no
// stale cached mapping, no ambiguous short hostname and no subnet-route scope.
func resolveTailscalePeer(status *ipnstate.Status, host string) (netip.Addr, error) {
	normalized := strings.TrimSuffix(strings.ToLower(host), ".")
	requestedIP, isIP := netip.ParseAddr(host)
	var match netip.Addr
	var matchID string
	for _, peer := range status.Peer {
		if peer == nil {
			continue
		}
		named := isIP != nil && (strings.EqualFold(strings.TrimSuffix(peer.DNSName, "."), normalized) || strings.EqualFold(peer.HostName, normalized))
		var candidate netip.Addr
		for _, ip := range peer.TailscaleIPs {
			if isIP == nil && ip == requestedIP {
				candidate = ip
				break
			}
			if named && (!candidate.IsValid() || ip.Is4()) {
				candidate = ip
			}
		}
		if !candidate.IsValid() {
			continue
		}
		if match.IsValid() && matchID != string(peer.ID) {
			return netip.Addr{}, ErrArgument
		}
		match, matchID = candidate, string(peer.ID)
	}
	if !match.IsValid() {
		return netip.Addr{}, ErrArgument
	}
	return match, nil
}
func DialTailscaleNode(id, token Handle, host string, port uint16) (result Handle, err error) {
	if port == 0 || !validateTailscaleHost(host) {
		return 0, ErrArgument
	}
	err = use[*tailscaleNode](id, token, func(ctx context.Context, e *entry, n *tailscaleNode) error {
		if !n.startCalled.Load() {
			return ErrMTAuth
		}
		if err := n.start(ctx); err != nil {
			return err
		}
		epoch := n.epoch.Load()
		status, err := n.backend.Status(ctx)
		if err != nil {
			return err
		}
		switch status.BackendState {
		case "Running":
		case "NeedsMachineAuth":
			return ErrMTApproval
		default:
			return ErrMTAuth
		}
		peerIP, err := resolveTailscalePeer(status, host)
		if err != nil {
			return err
		}
		conn, err := n.backend.Dial(ctx, "tcp", net.JoinHostPort(peerIP.String(), strconv.Itoa(int(port))))
		if err != nil {
			return err
		}
		if err := n.lifecycle.lock(ctx); err != nil {
			conn.Close()
			return err
		}
		defer n.lifecycle.unlock()
		if epoch != n.epoch.Load() {
			conn.Close()
			return ErrMTAuth
		}
		if err := n.store.health(); err != nil {
			conn.Close()
			return err
		}
		result, err = publishConnection(ctx, e.id, conn, TCP)
		return err
	})
	return
}

// Native errors exported to the app are fixed messages. No path, backend
// response, private state, auth URL, key or peer address is interpolated.
func TailscaleErrorCode(err error) int {
	switch {
	case errors.Is(err, ErrMTStorage):
		return 7
	case errors.Is(err, ErrMTDecrypt):
		return 8
	case errors.Is(err, ErrMTAlreadyOpen):
		return 9
	case errors.Is(err, ErrMTAuth):
		return 10
	case errors.Is(err, ErrMTApproval):
		return 11
	}
	return ErrorCode(err)
}
func TailscaleErrorMessage(code int) string {
	switch code {
	case InvalidArgument:
		return "Invalid Tailscale configuration"
	case Closed:
		return "Tailscale resource is closed"
	case Timeout:
		return "Tailscale operation timed out"
	case Cancelled:
		return "Tailscale operation was cancelled"
	case EOF:
		return "Tailscale stream ended"
	case 7:
		return ErrMTStorage.Error()
	case 8:
		return ErrMTDecrypt.Error()
	case 9:
		return ErrMTAlreadyOpen.Error()
	case 10:
		return ErrMTAuth.Error()
	case 11:
		return ErrMTApproval.Error()
	default:
		return "Tailscale operation failed"
	}
}
