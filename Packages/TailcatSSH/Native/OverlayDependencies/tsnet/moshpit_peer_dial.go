// Copyright (c) Moshpit contributors. SPDX-License-Identifier: MIT
package tsnet

import (
	"context"
	"errors"
	"net"
	"net/netip"
)

// MoshpitDialPeerTCP is the deliberately narrow app embedding path. Server.Dial
// delegates to UserDial, which can fall back to the system network when a route
// is not in the tailnet. We only accept an already resolved, currently known
// peer address and always use the userspace WireGuard netstack. A peer removal
// race can fail the connection, but can never redirect it onto the system VPN
// or ordinary network. Subnet routes, exit nodes and self-dial are not supported.
func (s *Server) MoshpitDialPeerTCP(ctx context.Context, destination netip.AddrPort) (net.Conn, error) {
	if !destination.IsValid() || destination.Port() == 0 {
		return nil, errors.New("invalid Tailscale peer address")
	}
	if err := s.Start(); err != nil {
		return nil, err
	}
	if err := s.awaitRunning(ctx); err != nil {
		return nil, err
	}
	peer, ok := s.lb.PeerForIP(destination.Addr())
	if !ok || peer.IsSelf || !peer.Node.Valid() {
		return nil, errors.New("Tailscale peer unavailable")
	}
	// PeerForIP also resolves subnet/exit routes. Require the address to belong
	// to the peer itself, not merely a prefix that peer can route.
	exact := false
	for _, address := range peer.Node.Addresses().All() {
		if address.Bits() == destination.Addr().BitLen() && address.Addr() == destination.Addr() {
			exact = true
			break
		}
	}
	if !exact {
		return nil, errors.New("Tailscale peer unavailable")
	}
	v4, v6 := s.TailscaleIPs()
	source := v4
	if destination.Addr().Is6() {
		source = v6
	}
	if !source.IsValid() {
		return nil, errors.New("Tailscale address family unavailable")
	}
	connection, err := s.netstack.DialContextTCPWithBind(ctx, source, destination)
	if err != nil {
		return nil, err
	}
	return connection, nil
}
