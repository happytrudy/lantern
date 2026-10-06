package windowsservice

import (
	"context"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"syscall"
	"time"
	"unsafe"

	"golang.org/x/sys/windows"
)

const serviceName = "LanternSvc"

// Connect and server import can run in separate Dart isolates. Serialize
// installation so two simultaneous requests cannot replace the same service.
var serviceOperation = make(chan struct{}, 1)

// EnsureRunning also supports unpacked Windows bundles: their first use
// installs the bundled lanternd with a Windows elevation prompt.
func EnsureRunning(ctx context.Context) error {
	ctx, cancel := context.WithTimeout(ctx, 90*time.Second)
	defer cancel()
	select {
	case serviceOperation <- struct{}{}:
		defer func() { <-serviceOperation }()
	case <-ctx.Done():
		return fmt.Errorf("windows_service_not_ready: %w", ctx.Err())
	}
	return ensure(ctx, windowsController{})
}

type windowsController struct{}

func (windowsController) state(_ context.Context) (serviceState, error) {
	scm, err := windows.OpenSCManager(nil, nil, windows.SC_MANAGER_CONNECT)
	if err != nil {
		return missing, err
	}
	defer windows.CloseServiceHandle(scm)
	name, err := windows.UTF16PtrFromString(serviceName)
	if err != nil {
		return missing, err
	}
	// Query-only access is essential for a UI running as an ordinary user.
	service, err := windows.OpenService(scm, name, windows.SERVICE_QUERY_STATUS)
	if errors.Is(err, windows.ERROR_SERVICE_DOES_NOT_EXIST) {
		return missing, nil
	}
	if err != nil {
		return missing, err
	}
	defer windows.CloseServiceHandle(service)
	var status windows.SERVICE_STATUS_PROCESS
	var bytesNeeded uint32
	err = windows.QueryServiceStatusEx(service, windows.SC_STATUS_PROCESS_INFO,
		(*byte)(unsafe.Pointer(&status)), uint32(unsafe.Sizeof(status)), &bytesNeeded)
	return serviceState(status.CurrentState), err
}

func (windowsController) install(ctx context.Context) error {
	executable, err := os.Executable()
	if err != nil {
		return fmt.Errorf("windows_service_missing_binary: %w", err)
	}
	daemon := filepath.Join(filepath.Dir(executable), "lanternd.exe")
	if _, err := os.Stat(daemon); err != nil {
		return fmt.Errorf("windows_service_missing_binary: %w", err)
	}
	return elevatedCommand(ctx, daemon, "install")
}

func (windowsController) start(ctx context.Context) error {
	return elevatedCommand(ctx, filepath.Join(os.Getenv("SystemRoot"), "System32", "sc.exe"), "start", serviceName)
}

func powershellString(value string) string {
	return "'" + strings.ReplaceAll(value, "'", "''") + "'"
}

func elevatedCommand(ctx context.Context, executable string, args ...string) error {
	quotedArgs := make([]string, len(args))
	for i, arg := range args {
		quotedArgs[i] = powershellString(arg)
	}
	script := "$ErrorActionPreference = 'Stop'; try { " +
		"$process = Start-Process -FilePath " + powershellString(executable) +
		" -ArgumentList @(" + strings.Join(quotedArgs, ",") + ") -Verb RunAs -Wait -PassThru; " +
		"exit $process.ExitCode } catch { " +
		"[Console]::Error.WriteLine($_.Exception.Message); " +
		"$cause = $_.Exception; while ($null -ne $cause) { " +
		"if ($cause -is [System.ComponentModel.Win32Exception] -and " +
		"$cause.NativeErrorCode -in @(5, 1223)) { exit 1223 }; " +
		"$cause = $cause.InnerException }; exit 1 }"
	command := exec.CommandContext(ctx,
		filepath.Join(os.Getenv("SystemRoot"), "System32", "WindowsPowerShell", "v1.0", "powershell.exe"),
		"-NoProfile", "-NonInteractive", "-Command", script)
	command.SysProcAttr = &syscall.SysProcAttr{HideWindow: true}
	output, err := command.CombinedOutput()
	if err == nil {
		return nil
	}
	var exitError *exec.ExitError
	if errors.As(err, &exitError) && exitError.ExitCode() == 1223 {
		return fmt.Errorf("windows_service_permission_required: %w", err)
	}
	return fmt.Errorf("windows_service_start_failed: %w: %s", err, strings.TrimSpace(string(output)))
}
