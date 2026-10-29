// Command recorder is a CLIProxyAPI native plugin that writes every proxied
// request and response, with its usage record, to ClickHouse. Conversation
// history is deduplicated into content-addressed blobs (internal/dedup).
// Build with -buildmode=c-shared; the C ABI lives in internal/cabi.
package main

import "github.com/NicolaiSchmid/agent-infra/hosts/forge/prometheus/recorder/internal/cabi"

var instance = newPlugin(cabi.Log)

func init() {
	cabi.Serve(cabi.Plugin{Handle: instance.handle, Shutdown: instance.shutdown})
}

func main() {}
