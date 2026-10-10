//go:build windows && novpn

package lanterncore

import (
	"fmt"
	"sync"

	"golang.org/x/sys/windows"
	"golang.org/x/sys/windows/registry"
)

const (
	internetSettingsPath          = `Software\Microsoft\Windows\CurrentVersion\Internet Settings`
	lanternProxyBackupPath        = `Software\Lantern\SystemProxyBackup`
	proxyAddress                  = "127.0.0.1:1080"
	internetOptionSettingsChanged = 39
	internetOptionRefresh         = 37
)

var systemProxyMu sync.Mutex

// SetSystemProxyEnabled makes the Windows current user's WinINet proxy point
// at the novpn sing-box mixed inbound. The previous values are kept in a
// separate per-user registry key and restored when the connection stops.
func SetSystemProxyEnabled(enabled bool) error {
	systemProxyMu.Lock()
	defer systemProxyMu.Unlock()

	if enabled {
		return enableSystemProxy()
	}
	return disableSystemProxy()
}

func enableSystemProxy() error {
	settings, err := registry.OpenKey(
		registry.CURRENT_USER,
		internetSettingsPath,
		registry.QUERY_VALUE|registry.SET_VALUE,
	)
	if err != nil {
		return fmt.Errorf("open Windows Internet proxy settings: %w", err)
	}
	defer settings.Close()

	backup, _, err := registry.CreateKey(
		registry.CURRENT_USER,
		lanternProxyBackupPath,
		registry.QUERY_VALUE|registry.SET_VALUE|registry.CREATE_SUB_KEY,
	)
	if err != nil {
		return fmt.Errorf("create Lantern proxy backup: %w", err)
	}
	defer backup.Close()

	active, _, activeErr := backup.GetIntegerValue("Active")
	if activeErr != nil || active == 0 {
		if err := saveProxyValue(settings, backup, "ProxyEnable", true); err != nil {
			return err
		}
		if err := saveProxyValue(settings, backup, "ProxyServer", false); err != nil {
			return err
		}
		if err := saveProxyValue(settings, backup, "ProxyOverride", false); err != nil {
			return err
		}
		if err := backup.SetDWordValue("Active", 1); err != nil {
			return fmt.Errorf("mark Lantern proxy backup active: %w", err)
		}
	}

	if err := settings.SetDWordValue("ProxyEnable", 1); err != nil {
		return fmt.Errorf("enable Windows proxy: %w", err)
	}
	if err := settings.SetStringValue("ProxyServer", proxyAddress); err != nil {
		return fmt.Errorf("set Windows proxy server: %w", err)
	}
	if err := settings.SetStringValue("ProxyOverride", "<local>"); err != nil {
		return fmt.Errorf("set Windows proxy bypass: %w", err)
	}
	refreshWinInetSettings()
	return nil
}

func disableSystemProxy() error {
	settings, err := registry.OpenKey(
		registry.CURRENT_USER,
		internetSettingsPath,
		registry.QUERY_VALUE|registry.SET_VALUE,
	)
	if err != nil {
		return fmt.Errorf("open Windows Internet proxy settings: %w", err)
	}
	defer settings.Close()

	backup, err := registry.OpenKey(
		registry.CURRENT_USER,
		lanternProxyBackupPath,
		registry.QUERY_VALUE|registry.SET_VALUE,
	)
	if err == nil {
		defer backup.Close()
		if active, _, activeErr := backup.GetIntegerValue("Active"); activeErr == nil && active != 0 {
			if err := restoreProxyValue(settings, backup, "ProxyEnable", true); err != nil {
				return err
			}
			if err := restoreProxyValue(settings, backup, "ProxyServer", false); err != nil {
				return err
			}
			if err := restoreProxyValue(settings, backup, "ProxyOverride", false); err != nil {
				return err
			}
			_ = registry.DeleteKey(registry.CURRENT_USER, lanternProxyBackupPath)
			_ = registry.DeleteKey(registry.CURRENT_USER, `Software\Lantern`)
			refreshWinInetSettings()
			return nil
		}
	}

	// If the process was restarted before disconnecting, only disable a proxy
	// that still points at Lantern's own listener. This avoids clobbering a
	// proxy configured independently by the user.
	server, _, serverErr := settings.GetStringValue("ProxyServer")
	if serverErr == nil && server == proxyAddress {
		if err := settings.SetDWordValue("ProxyEnable", 0); err != nil {
			return fmt.Errorf("disable orphaned Windows proxy: %w", err)
		}
		refreshWinInetSettings()
	}
	return nil
}

func saveProxyValue(settings, backup registry.Key, name string, dword bool) error {
	if dword {
		value, _, err := settings.GetIntegerValue(name)
		if err == registry.ErrNotExist {
			if err := backup.SetDWordValue(name+"Present", 0); err != nil {
				return fmt.Errorf("save missing %s state: %w", name, err)
			}
			return nil
		}
		if err != nil {
			return fmt.Errorf("read %s: %w", name, err)
		}
		if err := backup.SetDWordValue(name+"Present", 1); err != nil {
			return fmt.Errorf("save %s presence: %w", name, err)
		}
		if err := backup.SetDWordValue(name, uint32(value)); err != nil {
			return fmt.Errorf("save %s: %w", name, err)
		}
		return nil
	}

	value, _, err := settings.GetStringValue(name)
	if err == registry.ErrNotExist {
		if err := backup.SetDWordValue(name+"Present", 0); err != nil {
			return fmt.Errorf("save missing %s state: %w", name, err)
		}
		return nil
	}
	if err != nil {
		return fmt.Errorf("read %s: %w", name, err)
	}
	if err := backup.SetDWordValue(name+"Present", 1); err != nil {
		return fmt.Errorf("save %s presence: %w", name, err)
	}
	if err := backup.SetStringValue(name, value); err != nil {
		return fmt.Errorf("save %s: %w", name, err)
	}
	return nil
}

func restoreProxyValue(settings, backup registry.Key, name string, dword bool) error {
	present, _, err := backup.GetIntegerValue(name + "Present")
	if err != nil || present == 0 {
		if err := settings.DeleteValue(name); err != nil && err != registry.ErrNotExist {
			return fmt.Errorf("delete restored %s: %w", name, err)
		}
		return nil
	}
	if dword {
		value, _, err := backup.GetIntegerValue(name)
		if err != nil {
			return fmt.Errorf("read saved %s: %w", name, err)
		}
		if err := settings.SetDWordValue(name, uint32(value)); err != nil {
			return fmt.Errorf("restore %s: %w", name, err)
		}
		return nil
	}
	value, _, err := backup.GetStringValue(name)
	if err != nil {
		return fmt.Errorf("read saved %s: %w", name, err)
	}
	if err := settings.SetStringValue(name, value); err != nil {
		return fmt.Errorf("restore %s: %w", name, err)
	}
	return nil
}

func refreshWinInetSettings() {
	dll := windows.NewLazySystemDLL("wininet.dll")
	proc := dll.NewProc("InternetSetOptionW")
	_, _, _ = proc.Call(0, internetOptionSettingsChanged, 0, 0)
	_, _, _ = proc.Call(0, internetOptionRefresh, 0, 0)
}
