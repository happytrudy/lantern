package main

import (
	"context"
	"fmt"
	"time"

	lanterncore "github.com/getlantern/lantern/lantern-core"
	windowsservice "github.com/getlantern/lantern/lantern-core/windows_service"
)

func checkDaemonReachable(c lanterncore.Core) error {
	if err := windowsservice.EnsureRunning(context.Background()); err != nil {
		return err
	}
	// A running SCM service can still be bringing up its child and named pipe.
	// Use the actual status API with a generous deadline rather than the old
	// 300ms preflight, which incorrectly rejected cold starts on Windows.
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()
	var lastError error
	for {
		probeContext, probeCancel := context.WithTimeout(ctx, 5*time.Second)
		_, lastError = c.Client().VPNStatus(probeContext)
		probeCancel()
		if lastError == nil {
			return nil
		}
		select {
		case <-ctx.Done():
			return fmt.Errorf("windows_service_not_ready: %w", lastError)
		case <-time.After(250 * time.Millisecond):
		}
	}
}
