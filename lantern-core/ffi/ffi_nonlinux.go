//go:build !linux && !windows

package main

import (
	lanterncore "github.com/getlantern/lantern/lantern-core"
)

// These platforms rely on ConnectVPN to report backend availability.
// Linux and Windows have their own service checks; do not impose the old
// 300ms IPC deadline on platforms with no service-management fallback.
func checkDaemonReachable(c lanterncore.Core) error {
	return nil
}
