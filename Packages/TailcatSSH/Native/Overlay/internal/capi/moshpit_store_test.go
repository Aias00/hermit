package capi

import (
	"bytes"
	"errors"
	"os"
	"path/filepath"
	"sync"
	"testing"

	"tailscale.com/ipn"
)

func TestMTSealedStoreRoundTripAndPermissions(t *testing.T) {
	dir := t.TempDir()
	key := bytes.Repeat([]byte{42}, 32)
	store, err := newSealedStateStore(dir, key)
	if err != nil {
		t.Fatal(err)
	}
	secret := []byte("private-node-key-never-plaintext")
	if err := store.WriteState("node", secret); err != nil {
		t.Fatal(err)
	}
	raw, err := os.ReadFile(filepath.Join(dir, sealedStateName))
	if err != nil {
		t.Fatal(err)
	}
	if bytes.Contains(raw, secret) || bytes.Contains(raw, []byte("node")) {
		t.Fatal("plaintext in sealed state")
	}
	info, _ := os.Stat(filepath.Join(dir, sealedStateName))
	if info.Mode().Perm() != 0600 {
		t.Fatalf("permissions %v", info.Mode())
	}
	got, _ := store.ReadState("node")
	got[0] = 0
	got, _ = store.ReadState("node")
	if !bytes.Equal(got, secret) {
		t.Fatal("borrowed read buffer")
	}
	if err := store.Close(); err != nil {
		t.Fatal(err)
	}
	reopened, err := newSealedStateStore(dir, key)
	if err != nil {
		t.Fatal(err)
	}
	defer reopened.Close()
	got, err = reopened.ReadState("node")
	if err != nil || !bytes.Equal(got, secret) {
		t.Fatalf("roundtrip %v", err)
	}
	if err := reopened.WriteState("node", nil); err != nil {
		t.Fatal(err)
	}
	if _, err := reopened.ReadState("node"); !errors.Is(err, ipn.ErrStateNotExist) {
		t.Fatal(err)
	}
}

func TestMTSealedStoreWrongKeyAndTamper(t *testing.T) {
	for _, tamper := range []bool{false, true} {
		t.Run(map[bool]string{false: "wrong-key", true: "tampered"}[tamper], func(t *testing.T) {
			dir := t.TempDir()
			key := bytes.Repeat([]byte{1}, 32)
			s, err := newSealedStateStore(dir, key)
			if err != nil {
				t.Fatal(err)
			}
			if err := s.WriteState("key", []byte("secret")); err != nil {
				t.Fatal(err)
			}
			s.Close()
			if tamper {
				p := filepath.Join(dir, sealedStateName)
				raw, _ := os.ReadFile(p)
				raw[len(raw)-1] ^= 1
				os.WriteFile(p, raw, 0600)
			} else {
				key[0]++
			}
			if s, err := newSealedStateStore(dir, key); !errors.Is(err, ErrMTDecrypt) {
				if s != nil {
					s.Close()
				}
				t.Fatalf("expected fail closed, %v", err)
			}
		})
	}
}

func TestMTSealedStoreAtomicFailureKeepsDiskAndMemory(t *testing.T) {
	dir := t.TempDir()
	key := make([]byte, 32)
	s, err := newSealedStateStore(dir, key)
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	if err := s.WriteState("node", []byte("before")); err != nil {
		t.Fatal(err)
	}
	disk, _ := os.ReadFile(s.path)
	s.writeFile = func(string, []byte) error { return errors.New("injected write failure") }
	if err := s.WriteState("node", []byte("after")); !errors.Is(err, ErrMTStorage) {
		t.Fatal(err)
	}
	got, _ := s.ReadState("node")
	if string(got) != "before" {
		t.Fatal("memory committed failed write")
	}
	now, _ := os.ReadFile(s.path)
	if !bytes.Equal(disk, now) {
		t.Fatal("disk changed on failed write")
	}
	if !errors.Is(s.health(), ErrMTStorage) {
		t.Fatal("write failure not sticky")
	}
}

func TestMTSealedStoreSingleOwnerAndSymlink(t *testing.T) {
	dir := t.TempDir()
	key := make([]byte, 32)
	s, err := newSealedStateStore(dir, key)
	if err != nil {
		t.Fatal(err)
	}
	if s2, err := newSealedStateStore(dir, key); !errors.Is(err, ErrMTAlreadyOpen) {
		if s2 != nil {
			s2.Close()
		}
		t.Fatal(err)
	}
	s.Close()
	s, err = newSealedStateStore(dir, key)
	if err != nil {
		t.Fatal(err)
	}
	s.Close()
	target := filepath.Join(t.TempDir(), "unrelated")
	os.WriteFile(target, []byte("do not read"), 0600)
	if err := os.Symlink(target, filepath.Join(dir, sealedStateName)); err != nil {
		t.Fatal(err)
	}
	if s, err := newSealedStateStore(dir, key); !errors.Is(err, ErrMTStorage) {
		if s != nil {
			s.Close()
		}
		t.Fatal(err)
	}
}

func TestMTSealedStoreConcurrentWrites(t *testing.T) {
	s, err := newSealedStateStore(t.TempDir(), make([]byte, 32))
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	var wg sync.WaitGroup
	for i := range 12 {
		wg.Go(func() {
			if err := s.WriteState(ipn.StateKey(string(rune('a'+i))), []byte{byte(i)}); err != nil {
				t.Error(err)
			}
		})
	}
	wg.Wait()
	for i := range 12 {
		got, err := s.ReadState(ipn.StateKey(string(rune('a' + i))))
		if err != nil || len(got) != 1 || got[0] != byte(i) {
			t.Fatal("concurrent update lost")
		}
	}
}
