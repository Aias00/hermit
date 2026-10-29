// Copyright (c) Moshpit contributors. SPDX-License-Identifier: MIT
package main

/*
#include "moshpit_tailscale.h"
*/
import "C"

import (
	"github.com/tailscale/tailcat/internal/capi"
	"unsafe"
)

func mtGuard(out **C.char, fn func() error) (code C.int32_t) {
	if out != nil {
		*out = nil
	}
	defer func() {
		if recover() != nil {
			code = C.int32_t(capi.Failure)
			if out != nil {
				*out = C.CString("Tailscale operation failed")
			}
		}
	}()
	if err := fn(); err != nil {
		value := capi.TailscaleErrorCode(err)
		if out != nil {
			*out = C.CString(capi.TailscaleErrorMessage(value))
		}
		return C.int32_t(value)
	}
	return 0
}

//export mt_abi_version
func mt_abi_version() C.uint32_t { return 1 }

//export mt_node_new
func mt_node_new(config *C.char, key *C.uint8_t, keyLen C.size_t, out *C.tc_handle, err **C.char) C.int32_t {
	return mtGuard(err, func() error {
		return handle(out, func() (capi.Handle, error) {
			if key == nil || keyLen != 32 || config == nil {
				return 0, capi.ErrArgument
			}
			return capi.NewTailscaleNode(C.GoString(config), unsafe.Slice((*byte)(unsafe.Pointer(key)), 32))
		})
	})
}

//export mt_node_start
func mt_node_start(node C.tc_handle, token C.tc_token, err **C.char) C.int32_t {
	return mtGuard(err, func() error { return capi.StartTailscaleNode(capi.Handle(node), capi.Handle(token)) })
}

//export mt_node_status
func mt_node_status(node C.tc_handle, token C.tc_token, out, err **C.char) C.int32_t {
	return mtGuard(err, func() error {
		return text(out, func() (string, error) { return capi.TailscaleNodeStatus(capi.Handle(node), capi.Handle(token)) })
	})
}

//export mt_node_start_login
func mt_node_start_login(node C.tc_handle, token C.tc_token, err **C.char) C.int32_t {
	return mtGuard(err, func() error { return capi.LoginTailscaleNode(capi.Handle(node), capi.Handle(token)) })
}

//export mt_node_logout
func mt_node_logout(node C.tc_handle, token C.tc_token, err **C.char) C.int32_t {
	return mtGuard(err, func() error { return capi.LogoutTailscaleNode(capi.Handle(node), capi.Handle(token)) })
}

//export mt_node_dial
func mt_node_dial(node C.tc_handle, token C.tc_token, host *C.char, port C.uint16_t, out *C.tc_handle, err **C.char) C.int32_t {
	return mtGuard(err, func() error {
		return handle(out, func() (capi.Handle, error) {
			return capi.DialTailscaleNode(capi.Handle(node), capi.Handle(token), C.GoString(host), uint16(port))
		})
	})
}
