//go:build !windows || !novpn

package lanterncore

// SetSystemProxyEnabled is a no-op for builds that keep the normal TUN path.
// The Windows novpn build provides the real implementation in
// system_proxy_windows.go.
func SetSystemProxyEnabled(_ bool) error { return nil }
