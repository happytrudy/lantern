package windowsservice

import (
	"context"
	"errors"
	"strings"
	"testing"
	"time"
)

type fakeController struct {
	states             []serviceState
	queryError         error
	actionError        error
	installed, started int
}

func (c *fakeController) state(context.Context) (serviceState, error) {
	state := c.states[0]
	if len(c.states) > 1 {
		c.states = c.states[1:]
	}
	return state, c.queryError
}

func (c *fakeController) install(context.Context) error {
	c.installed++
	return c.actionError
}

func (c *fakeController) start(context.Context) error {
	c.started++
	return c.actionError
}

func TestEnsureServiceLifecycle(t *testing.T) {
	for _, test := range []struct {
		name           string
		states         []serviceState
		install, start int
	}{
		{"running service needs no elevation", []serviceState{running}, 0, 0},
		{"portable install starts bundled backend", []serviceState{missing, running}, 1, 0},
		{"stopped service starts without reinstall", []serviceState{stopped, running}, 0, 1},
		{"starting service is awaited", []serviceState{startPending, running}, 0, 0},
		{"stopping service can be started afterwards", []serviceState{stopPending, stopped, running}, 0, 1},
	} {
		t.Run(test.name, func(t *testing.T) {
			control := &fakeController{states: test.states}
			ctx, cancel := context.WithTimeout(context.Background(), time.Second)
			defer cancel()
			if err := ensure(ctx, control); err != nil {
				t.Fatal(err)
			}
			if control.installed != test.install || control.started != test.start {
				t.Fatalf("install=%d start=%d; want install=%d start=%d", control.installed, control.started, test.install, test.start)
			}
		})
	}
}

func TestEnsureDoesNotRetryRejectedElevation(t *testing.T) {
	denied := errors.New("windows_service_permission_required")
	control := &fakeController{states: []serviceState{missing}, actionError: denied}
	if err := ensure(context.Background(), control); !errors.Is(err, denied) {
		t.Fatalf("got %v; want elevation error", err)
	}
	if control.installed != 1 || control.started != 0 {
		t.Fatal("rejected elevation must not be retried")
	}
}

func TestEnsureStoppedAfterStartFailsPromptly(t *testing.T) {
	control := &fakeController{states: []serviceState{stopped}}
	if err := ensure(context.Background(), control); err == nil || !strings.Contains(err.Error(), "windows_service_start_failed") {
		t.Fatalf("got %v; want startup failure", err)
	}
	if control.started != 1 {
		t.Fatal("failed startup must not loop through elevation prompts")
	}
}

func TestEnsureHonorsDeadline(t *testing.T) {
	control := &fakeController{states: []serviceState{startPending}}
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Millisecond)
	defer cancel()
	if err := ensure(ctx, control); !errors.Is(err, context.DeadlineExceeded) {
		t.Fatalf("got %v; want deadline exceeded", err)
	}
}

func TestEnsurePreservesSCMError(t *testing.T) {
	queryError := errors.New("access denied")
	control := &fakeController{states: []serviceState{missing}, queryError: queryError}
	if err := ensure(context.Background(), control); !errors.Is(err, queryError) {
		t.Fatalf("got %v; want original SCM error", err)
	}
	if control.installed != 0 || control.started != 0 {
		t.Fatal("query errors must not trigger installation")
	}
}
