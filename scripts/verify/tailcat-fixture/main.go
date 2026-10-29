// A disposable Tailcat gateway for the loopback input fixture. Only a fresh
// allowlisted client can reach the test sshd; no user terminal is exposed.
// Build from the pinned upstream module downloaded by build-tailcat.sh:
//   go build -o /absolute/path/to/fixture /absolute/path/to/this/main.go
package main

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"os"
	"os/signal"
	"strconv"
	"syscall"
	"time"

	"github.com/tailscale/tailcat"
	"tailscale.com/types/key"
)

type fixture struct {
	Kind              string `json:"kind"`
	Status            string `json:"status"`
	Directory         string `json:"fixture_dir"`
	Username          string `json:"username"`
	Port              int    `json:"port"`
	Fingerprint       string `json:"fingerprint"`
	ReceiptURL        string `json:"receipt_url"`
	Address           string `json:"address"`
	ClientPrivateKey  string `json:"client_private_key"`
	ClientPublicKey   string `json:"client_public_key"`
	ServerPublicKey   string `json:"server_public_key"`
	PID               int    `json:"pid"`
}

func save(path string, f fixture) error {
	data, err := json.MarshalIndent(f, "", "  ")
	if err != nil { return err }
	if err := os.WriteFile(path+".new", data, 0600); err != nil { return err }
	return os.Rename(path+".new", path)
}

func run(inputPath, outputPath string) error {
	data, err := os.ReadFile(inputPath)
	if err != nil { return fmt.Errorf("cannot read input fixture") }
	var f fixture
	if json.Unmarshal(data, &f) != nil || f.Kind != "moshpit-input-fixture-v1" || f.Status != "ready" || f.Port < 1 || f.Port > 65535 {
		return fmt.Errorf("invalid input fixture")
	}
	if _, err := os.Stat(outputPath); !os.IsNotExist(err) { return fmt.Errorf("output already exists") }
	clientKey := key.NewNode()
	serverKey := key.NewNode()
	server := &tailcat.Server{
		Key: serverKey,
		Logf: func(string, ...any) {},
		AllowClient: func(k key.NodePublic) bool { return k == clientKey.Public() },
		OnTCP: func(port uint16) func(net.Conn) {
			if int(port) != f.Port { return nil }
			return func(remote net.Conn) {
				defer remote.Close()
				local, err := net.DialTimeout("tcp", net.JoinHostPort("127.0.0.1", strconv.Itoa(f.Port)), 3*time.Second)
				if err != nil { return }
				defer local.Close()
				done := make(chan struct{})
				go func() { io.Copy(local, remote); local.Close(); close(done) }()
				io.Copy(remote, local)
				remote.Close()
				<-done
			}
		},
	}
	ctx, cancel := context.WithTimeout(context.Background(), 45*time.Second)
	defer cancel()
	if err := server.StartContext(ctx); err != nil { return fmt.Errorf("tailcat fixture startup failed") }
	defer server.Close()
	clientPrivate, _ := clientKey.MarshalText()
	f.Kind, f.Status, f.PID = "moshpit-tailcat-fixture-v1", "ready", os.Getpid()
	f.Address, f.ClientPrivateKey = string(server.TailcatAddr()), string(clientPrivate)
	f.ClientPublicKey, f.ServerPublicKey = clientKey.Public().String(), serverKey.Public().String()
	if err := save(outputPath, f); err != nil { return fmt.Errorf("cannot save private fixture") }
	fmt.Println("Tailcat fixture ready (credentials saved to private file)")
	signals := make(chan os.Signal, 1)
	signal.Notify(signals, syscall.SIGINT, syscall.SIGTERM)
	defer signal.Stop(signals)
	<-signals
	// Store only path classes, never network endpoints or keys, in the report.
	var direct, relayed int
	for _, peer := range server.Status().Peer {
		if peer.CurAddr != "" { direct++ } else if peer.Relay != "" { relayed++ }
	}
	fmt.Printf("Tailcat fixture stopped: direct_peers=%d relayed_peers=%d\n", direct, relayed)
	f.Status = "stopped"
	return save(outputPath, f)
}

func main() {
	if len(os.Args) != 3 { fmt.Fprintln(os.Stderr, "usage: tailcat-fixture input-state output-state"); os.Exit(2) }
	if err := run(os.Args[1], os.Args[2]); err != nil { fmt.Fprintln(os.Stderr, err); os.Exit(1) }
}
