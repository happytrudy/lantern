package windowsservice

import (
	"context"
	"fmt"
	"time"
)

type serviceState uint32

const (
	missing         serviceState = 0
	stopped         serviceState = 1
	startPending    serviceState = 2
	stopPending     serviceState = 3
	running         serviceState = 4
	continuePending serviceState = 5
	pausePending    serviceState = 6
)

type controller interface {
	state(context.Context) (serviceState, error)
	install(context.Context) error
	start(context.Context) error
}

// ensure starts the privileged VPN backend when necessary. The Flutter UI can
// run without administrator rights; only installation/start requests elevate.
func ensure(ctx context.Context, control controller) error {
	ticker := time.NewTicker(200 * time.Millisecond)
	defer ticker.Stop()
	requested := false
	for {
		if err := ctx.Err(); err != nil {
			return fmt.Errorf("windows_service_not_ready: %w", err)
		}
		state, err := control.state(ctx)
		if err != nil {
			return fmt.Errorf("windows_service_not_ready: %w", err)
		}
		switch state {
		case running:
			return nil
		case missing, stopped:
			if requested {
				return fmt.Errorf("windows_service_start_failed: service stopped after start request")
			}
			requested = true
			if state == missing {
				err = control.install(ctx)
			} else {
				err = control.start(ctx)
			}
			if err != nil {
				return err
			}
			continue
		case startPending, stopPending, continuePending, pausePending:
			// SCM can accept a start request before the service is running.
		default:
			return fmt.Errorf("windows_service_start_failed: unsupported service state %d", state)
		}
		select {
		case <-ctx.Done():
			return fmt.Errorf("windows_service_not_ready: %w", ctx.Err())
		case <-ticker.C:
		}
	}
}
