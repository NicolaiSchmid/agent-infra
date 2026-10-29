// Copied from github.com/lachieh/cliproxyapi-plugins internal/cabi (MIT,
// Copyright (c) Lachlan Heywood). Unchanged apart from this header.

// Package cabi is the C ABI shared by every plugin in this repository. A
// plugin's main package calls Serve from init, and the library built with
// -buildmode=c-shared exports cliproxy_plugin_init for the CLIProxyAPI host.
package cabi

/*
#include <stdint.h>
#include <stdlib.h>

typedef struct {
	void* ptr;
	size_t len;
} cliproxy_buffer;

typedef int (*cliproxy_host_call_fn)(void*, const char*, const uint8_t*, size_t, cliproxy_buffer*);
typedef void (*cliproxy_host_free_fn)(void*, size_t);

typedef struct {
	uint32_t abi_version;
	void* host_ctx;
	cliproxy_host_call_fn call;
	cliproxy_host_free_fn free_buffer;
} cliproxy_host_api;

typedef int (*cliproxy_plugin_call_fn)(char*, uint8_t*, size_t, cliproxy_buffer*);
typedef void (*cliproxy_plugin_free_fn)(void*, size_t);
typedef void (*cliproxy_plugin_shutdown_fn)(void);

typedef struct {
	uint32_t abi_version;
	cliproxy_plugin_call_fn call;
	cliproxy_plugin_free_fn free_buffer;
	cliproxy_plugin_shutdown_fn shutdown;
} cliproxy_plugin_api;

extern int cliproxyPluginCall(char*, uint8_t*, size_t, cliproxy_buffer*);
extern void cliproxyPluginFree(void*, size_t);
extern void cliproxyPluginShutdown(void);

static const cliproxy_host_api* stored_host;

static void store_host_api(const cliproxy_host_api* host) { stored_host = host; }

static int call_host_api(const char* method, const uint8_t* request, size_t request_len, cliproxy_buffer* response) {
	if (stored_host == NULL || stored_host->call == NULL) { return 1; }
	return stored_host->call(stored_host->host_ctx, method, request, request_len, response);
}

static void free_host_buffer(void* ptr, size_t len) {
	if (stored_host != NULL && stored_host->free_buffer != NULL && ptr != NULL) { stored_host->free_buffer(ptr, len); }
}
*/
import "C"

import (
	"encoding/json"
	"errors"
	"fmt"
	"sync/atomic"
	"unsafe"
)

const abiVersion = 1

// Plugin is what a plugin gives Serve.
type Plugin struct {
	// Handle answers one host call. Its result is sent as the envelope's
	// result; an error is sent as an error envelope (see Error).
	Handle func(method string, request []byte) (any, error)
	// Shutdown runs when the host unloads the library. It may be nil.
	Shutdown func()
}

// Error is an error with an envelope code, such as "unknown_method" or
// "invalid_config". Other errors are sent with the code "plugin_error".
type Error struct {
	Code    string
	Message string
}

func (e *Error) Error() string { return e.Code + ": " + e.Message }

var (
	plugin Plugin
	// hostAvailable guards host callbacks: the host frees its API table on unload.
	hostAvailable atomic.Bool
)

// ErrHostUnavailable is returned by CallHost before init or after shutdown.
var ErrHostUnavailable = errors.New("host is not available")

// Serve registers the plugin. Call it from the main package's init.
func Serve(p Plugin) { plugin = p }

//export cliproxy_plugin_init
func cliproxy_plugin_init(host *C.cliproxy_host_api, api *C.cliproxy_plugin_api) C.int {
	if api == nil {
		return 1
	}
	if host != nil {
		C.store_host_api(host)
		hostAvailable.Store(true)
	}
	api.abi_version = C.uint32_t(abiVersion)
	api.call = C.cliproxy_plugin_call_fn(C.cliproxyPluginCall)
	api.free_buffer = C.cliproxy_plugin_free_fn(C.cliproxyPluginFree)
	api.shutdown = C.cliproxy_plugin_shutdown_fn(C.cliproxyPluginShutdown)
	return 0
}

//export cliproxyPluginCall
func cliproxyPluginCall(method *C.char, request *C.uint8_t, requestLen C.size_t, response *C.cliproxy_buffer) (code C.int) {
	if response != nil {
		response.ptr = nil
		response.len = 0
	}
	// A panic would cross the cgo boundary and take the whole proxy down.
	defer func() {
		if r := recover(); r != nil {
			writeResponse(response, errorEnvelope("plugin_panic", fmt.Sprint(r)))
			code = 1
		}
	}()
	if method == nil {
		writeResponse(response, errorEnvelope("invalid_method", "method is required"))
		return 1
	}
	var body []byte
	if request != nil && requestLen > 0 {
		body = C.GoBytes(unsafe.Pointer(request), C.int(requestLen))
	}
	raw, err := Dispatch(C.GoString(method), body)
	writeResponse(response, raw)
	if err != nil {
		return 1
	}
	return 0
}

//export cliproxyPluginFree
func cliproxyPluginFree(ptr unsafe.Pointer, _ C.size_t) {
	if ptr != nil {
		C.free(ptr)
	}
}

//export cliproxyPluginShutdown
func cliproxyPluginShutdown() {
	if plugin.Shutdown != nil {
		plugin.Shutdown()
	}
	hostAvailable.Store(false)
}

// Dispatch runs a host call through the registered plugin and encodes the
// result as a response envelope. The host reads an error envelope the same
// way whatever the return code, so errors are always enveloped.
func Dispatch(method string, request []byte) ([]byte, error) {
	if plugin.Handle == nil {
		err := &Error{Code: "plugin_error", Message: "plugin did not call cabi.Serve"}
		return errorEnvelope(err.Code, err.Message), err
	}
	result, err := plugin.Handle(method, request)
	if err != nil {
		var e *Error
		if errors.As(err, &e) {
			return errorEnvelope(e.Code, e.Message), err
		}
		return errorEnvelope("plugin_error", err.Error()), err
	}
	raw, err := json.Marshal(result)
	if err != nil {
		return errorEnvelope("plugin_error", err.Error()), err
	}
	return json.Marshal(envelope{OK: true, Result: raw})
}

type envelope struct {
	OK     bool            `json:"ok"`
	Result json.RawMessage `json:"result,omitempty"`
	Error  *envelopeError  `json:"error,omitempty"`
}

type envelopeError struct {
	Code    string `json:"code"`
	Message string `json:"message"`
}

func errorEnvelope(code, message string) []byte {
	raw, _ := json.Marshal(envelope{Error: &envelopeError{Code: code, Message: message}})
	return raw
}

func writeResponse(response *C.cliproxy_buffer, raw []byte) {
	if response == nil || len(raw) == 0 {
		return
	}
	response.ptr = C.CBytes(raw)
	response.len = C.size_t(len(raw))
}

// CallHost invokes a host callback and returns its result. It is safe to call
// from any goroutine, and returns ErrHostUnavailable once the host has unloaded
// the library.
func CallHost(method string, payload any) (json.RawMessage, error) {
	if !hostAvailable.Load() {
		return nil, ErrHostUnavailable
	}
	raw, err := json.Marshal(payload)
	if err != nil {
		return nil, err
	}
	cMethod := C.CString(method)
	defer C.free(unsafe.Pointer(cMethod))
	var req *C.uint8_t
	if len(raw) > 0 {
		p := C.CBytes(raw)
		defer C.free(p)
		req = (*C.uint8_t)(p)
	}
	var response C.cliproxy_buffer
	code := C.call_host_api(cMethod, req, C.size_t(len(raw)), &response)
	var out []byte
	if response.ptr != nil {
		out = C.GoBytes(response.ptr, C.int(response.len))
		C.free_host_buffer(response.ptr, response.len)
	}
	if len(out) == 0 {
		return nil, fmt.Errorf("%s: no response (code %d)", method, int(code))
	}
	var env envelope
	if err := json.Unmarshal(out, &env); err != nil {
		return nil, fmt.Errorf("%s: decode envelope: %w", method, err)
	}
	if !env.OK {
		if env.Error != nil {
			return nil, fmt.Errorf("%s: %s: %s", method, env.Error.Code, env.Error.Message)
		}
		return nil, fmt.Errorf("%s failed", method)
	}
	return env.Result, nil
}

// Log writes to the CLIProxyAPI log through the host.log callback.
func Log(level, message string, fields map[string]any) {
	_, _ = CallHost("host.log", map[string]any{"level": level, "message": message, "fields": fields})
}
