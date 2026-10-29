// Copyright (c) Moshpit contributors. SPDX-License-Identifier: MIT
package capi

import (
	"bytes"
	"crypto/aes"
	"crypto/cipher"
	"crypto/rand"
	"encoding/json"
	"errors"
	"io"
	"os"
	"path/filepath"
	"sync"

	"golang.org/x/sys/unix"
	"tailscale.com/ipn"
)

var (
	ErrMTStorage     = errors.New("Tailscale secure storage is unavailable")
	ErrMTDecrypt     = errors.New("Tailscale secure storage cannot be decrypted")
	ErrMTAlreadyOpen = errors.New("Tailscale state is already in use")
	ErrMTAuth        = errors.New("Tailscale login is required")
	ErrMTApproval    = errors.New("Tailscale device approval is required")
)

const sealedStateName = "moshpit-tailscale.state"
const sealedStateMax = 16 << 20

var sealedStateMagic = []byte("MOSHPIT-TSNET-STATE-1\x00")

// sealedStateStore persists the entire key/value store in one authenticated
// transaction. The encryption key belongs to Keychain, never to this directory.
// A cross-process lock prevents two nodes from forking the same persisted identity.
type sealedStateStore struct {
	mu        sync.Mutex
	path      string
	aead      cipher.AEAD
	state     map[ipn.StateKey][]byte
	lock      *os.File
	writeFile func(string, []byte) error
	failure   error
	closed    bool
}

func newSealedStateStore(directory string, key []byte) (_ *sealedStateStore, err error) {
	if len(key) != 32 || !filepath.IsAbs(directory) || filepath.Clean(directory) != directory {
		return nil, ErrArgument
	}
	info, err := os.Lstat(directory)
	if err != nil || !info.IsDir() || info.Mode()&os.ModeSymlink != 0 {
		return nil, ErrMTStorage
	}
	// Canonical spelling also prevents aliases from bypassing the live-node lock.
	canonical, err := filepath.EvalSymlinks(directory)
	if err != nil {
		return nil, ErrMTStorage
	}
	lockFD, err := unix.Open(filepath.Join(canonical, ".moshpit-tailscale.lock"), unix.O_CREAT|unix.O_RDWR|unix.O_CLOEXEC|unix.O_NOFOLLOW, 0600)
	if err != nil {
		return nil, ErrMTStorage
	}
	lock := os.NewFile(uintptr(lockFD), "Tailscale state lock")
	defer func() {
		if err != nil {
			lock.Close()
		}
	}()
	if err = unix.Flock(lockFD, unix.LOCK_EX|unix.LOCK_NB); err != nil {
		if errors.Is(err, unix.EWOULDBLOCK) {
			return nil, ErrMTAlreadyOpen
		}
		return nil, ErrMTStorage
	}
	block, err := aes.NewCipher(key)
	if err != nil {
		return nil, ErrArgument
	}
	aead, err := cipher.NewGCM(block)
	if err != nil {
		return nil, ErrMTStorage
	}
	store := &sealedStateStore{path: filepath.Join(canonical, sealedStateName), aead: aead,
		state: map[ipn.StateKey][]byte{}, lock: lock, writeFile: atomicSealedWrite}
	raw, err := readSealedFile(store.path)
	if errors.Is(err, os.ErrNotExist) {
		return store, nil
	}
	if err != nil {
		return nil, ErrMTStorage
	}
	if len(raw) < len(sealedStateMagic)+aead.NonceSize()+aead.Overhead() || !bytes.HasPrefix(raw, sealedStateMagic) {
		return nil, ErrMTDecrypt
	}
	nonce := raw[len(sealedStateMagic) : len(sealedStateMagic)+aead.NonceSize()]
	plaintext, err := aead.Open(nil, nonce, raw[len(sealedStateMagic)+aead.NonceSize():], sealedStateMagic)
	if err != nil {
		return nil, ErrMTDecrypt
	}
	defer clear(plaintext)
	if err := json.Unmarshal(plaintext, &store.state); err != nil || store.state == nil {
		return nil, ErrMTDecrypt
	}
	return store, nil
}

func readSealedFile(path string) ([]byte, error) {
	fd, err := unix.Open(path, unix.O_RDONLY|unix.O_CLOEXEC|unix.O_NOFOLLOW, 0)
	if err != nil {
		return nil, err
	}
	file := os.NewFile(uintptr(fd), "Tailscale sealed state")
	defer file.Close()
	info, err := file.Stat()
	if err != nil || !info.Mode().IsRegular() || info.Size() > sealedStateMax {
		return nil, ErrMTStorage
	}
	value, err := io.ReadAll(io.LimitReader(file, sealedStateMax+1))
	if err != nil || len(value) > sealedStateMax {
		return nil, ErrMTStorage
	}
	return value, nil
}

// The only commit point is rename. Any error before it leaves the previous file
// intact. Data is fsync'ed before the rename; no fallible work follows the commit.
func atomicSealedWrite(path string, value []byte) error {
	file, err := os.CreateTemp(filepath.Dir(path), ".moshpit-tsnet-sealed-*")
	if err != nil {
		return err
	}
	temp := file.Name()
	defer os.Remove(temp)
	if _, err = file.Write(value); err != nil {
		file.Close()
		return err
	}
	if err = file.Sync(); err != nil {
		file.Close()
		return err
	}
	if err = file.Close(); err != nil {
		return err
	}
	return os.Rename(temp, path)
}

func (s *sealedStateStore) ReadState(id ipn.StateKey) ([]byte, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.closed {
		return nil, ErrMTStorage
	}
	value, ok := s.state[id]
	if !ok {
		return nil, ipn.ErrStateNotExist
	}
	return bytes.Clone(value), nil
}

func (s *sealedStateStore) WriteState(id ipn.StateKey, value []byte) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.closed {
		return ErrMTStorage
	}
	next := make(map[ipn.StateKey][]byte, len(s.state)+1)
	for key, existing := range s.state {
		next[key] = existing
	}
	if value == nil {
		delete(next, id)
	} else {
		next[id] = bytes.Clone(value)
	}
	plaintext, err := json.Marshal(next)
	if err != nil || len(plaintext) > sealedStateMax-1024 {
		s.failure = ErrMTStorage
		return ErrMTStorage
	}
	defer clear(plaintext)
	nonce := make([]byte, s.aead.NonceSize())
	if _, err := rand.Read(nonce); err != nil {
		s.failure = ErrMTStorage
		return ErrMTStorage
	}
	blob := append(bytes.Clone(sealedStateMagic), nonce...)
	blob = s.aead.Seal(blob, nonce, plaintext, sealedStateMagic)
	if err := s.writeFile(s.path, blob); err != nil {
		s.failure = ErrMTStorage
		return ErrMTStorage
	}
	s.state = next
	// A prior persistence failure remains fail-closed for this node lifetime.
	return nil
}

func (s *sealedStateStore) health() error { s.mu.Lock(); defer s.mu.Unlock(); return s.failure }

func (s *sealedStateStore) Close() error {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.closed {
		return nil
	}
	s.closed = true
	for key, value := range s.state {
		clear(value)
		delete(s.state, key)
	}
	s.aead = nil
	return s.lock.Close()
}
