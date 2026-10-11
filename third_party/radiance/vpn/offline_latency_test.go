package vpn

import (
	"bufio"
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/pem"
	"errors"
	"fmt"
	"math/big"
	"net"
	"net/http"
	"sync/atomic"
	"testing"
	"time"

	box "github.com/getlantern/lantern-box"
	A "github.com/sagernet/sing-box/adapter"
	"github.com/sagernet/sing-box/adapter/endpoint"
	"github.com/sagernet/sing-box/adapter/outbound"
	"github.com/sagernet/sing-box/experimental/libbox"
	"github.com/sagernet/sing-box/log"
	"github.com/sagernet/sing-box/option"
	M "github.com/sagernet/sing/common/metadata"
	"github.com/sagernet/sing/service"
	"github.com/stretchr/testify/require"
)

type probeCertificates struct {
	values []string
	index  int
}

func (p *probeCertificates) Len() int32    { return int32(len(p.values)) }
func (p *probeCertificates) HasNext() bool { return p.index < len(p.values) }
func (p *probeCertificates) Next() string  { v := p.values[p.index]; p.index++; return v }

type probePlatform struct {
	PlatformInterface
	certificates  []string
	monitorStarts atomic.Int32
	monitorCloses atomic.Int32
}

func (p *probePlatform) SystemCertificates() libbox.StringIterator {
	return &probeCertificates{values: p.certificates}
}

func (*probePlatform) UseProcFS() bool { return false }
func (p *probePlatform) StartDefaultInterfaceMonitor(libbox.InterfaceUpdateListener) error {
	p.monitorStarts.Add(1)
	return nil
}
func (p *probePlatform) CloseDefaultInterfaceMonitor(libbox.InterfaceUpdateListener) error {
	p.monitorCloses.Add(1)
	return nil
}
func (*probePlatform) GetInterfaces() (libbox.NetworkInterfaceIterator, error) { return nil, nil }

type offlineProbeOutbound struct {
	outbound.Adapter
	tlsConfig      *tls.Config
	requireStarted bool
	started        atomic.Bool
	delay          time.Duration
	requests       atomic.Int32
}

func (o *offlineProbeOutbound) Start(stage A.StartStage) error {
	if stage == A.StartStatePostStart {
		o.started.Store(true)
	}
	return nil
}
func (o *offlineProbeOutbound) Close() error { return nil }
func (o *offlineProbeOutbound) DialContext(ctx context.Context, network string, destination M.Socksaddr) (net.Conn, error) {
	if o.requireStarted && !o.started.Load() {
		return nil, errors.New("outbound post-start has not run")
	}
	if network != "tcp" || (destination.Fqdn != "probe.invalid" && destination.Fqdn != "www.gstatic.com") {
		return nil, errors.New("unexpected probe destination")
	}
	client, server := net.Pipe()
	go func() {
		defer server.Close()
		var conn net.Conn = server
		if o.tlsConfig != nil {
			conn = tls.Server(server, o.tlsConfig)
		}
		if deadline, ok := ctx.Deadline(); ok {
			_ = conn.SetDeadline(deadline)
		}
		req, err := http.ReadRequest(bufio.NewReader(conn))
		if err != nil {
			return
		}
		defer req.Body.Close()
		o.requests.Add(1)
		timer := time.NewTimer(o.delay)
		defer timer.Stop()
		select {
		case <-timer.C:
			_, _ = fmt.Fprint(conn, "HTTP/1.1 204 No Content\r\nConnection: close\r\n\r\n")
		case <-ctx.Done():
		}
	}()
	return client, nil
}
func (o *offlineProbeOutbound) ListenPacket(context.Context, M.Socksaddr) (net.PacketConn, error) {
	return nil, errors.New("unused")
}

func probeTLSCertificate(t *testing.T) (tls.Certificate, string) {
	t.Helper()
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	require.NoError(t, err)
	template := &x509.Certificate{SerialNumber: big.NewInt(1), Subject: pkix.Name{CommonName: "probe.invalid"}, DNSNames: []string{"probe.invalid", "www.gstatic.com"}, NotBefore: time.Now().Add(-time.Hour), NotAfter: time.Now().Add(time.Hour), KeyUsage: x509.KeyUsageDigitalSignature, ExtKeyUsage: []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth}}
	der, err := x509.CreateCertificate(rand.Reader, template, template, &key.PublicKey, key)
	require.NoError(t, err)
	return tls.Certificate{Certificate: [][]byte{der}, PrivateKey: key}, string(pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: der}))
}

func TestOfflineLatencyColdStart(t *testing.T) {
	certificate, pemCertificate := probeTLSCertificate(t)
	for _, tc := range []struct {
		name           string
		tls            bool
		requireStarted bool
		delay          time.Duration
		endpoint       bool
		untrusted      bool
	}{
		{name: "complete lifecycle", requireStarted: true},
		{name: "endpoint lifecycle", requireStarted: true, endpoint: true},
		{name: "untrusted HTTPS rejected", tls: true, untrusted: true},
		{name: "platform HTTPS trust", tls: true},
		{name: "cold handshake over two seconds", delay: 2100 * time.Millisecond},
	} {
		t.Run(tc.name, func(t *testing.T) {
			ctx := box.Context(t.Context())
			registry := service.FromContext[A.OutboundRegistry](ctx).(*outbound.Registry)
			o := &offlineProbeOutbound{Adapter: outbound.NewAdapter("socks", "private", []string{"tcp"}, nil), requireStarted: tc.requireStarted, delay: tc.delay}
			link := "http://probe.invalid/generate_204"
			if tc.tls {
				o.tlsConfig = &tls.Config{Certificates: []tls.Certificate{certificate}}
				link = "https://probe.invalid/generate_204"
			}
			outbound.Register[option.StubOptions](registry, "test-probe", func(context.Context, A.Router, log.ContextLogger, string, option.StubOptions) (A.Outbound, error) {
				return o, nil
			})
			platform := &probePlatform{certificates: []string{pemCertificate}}
			if tc.untrusted {
				platform.certificates = nil
			}
			c := NewVPNClient(t.TempDir(), nil, platform)
			outbounds := []option.Outbound{{Type: "test-probe", Tag: "private", Options: &option.StubOptions{}}}
			var endpoints []option.Endpoint
			if tc.endpoint {
				endpointRegistry := service.FromContext[A.EndpointRegistry](ctx).(*endpoint.Registry)
				endpoint.Register[option.StubOptions](endpointRegistry, "test-probe", func(context.Context, A.Router, log.ContextLogger, string, option.StubOptions) (A.Endpoint, error) {
					return o, nil
				})
				endpoints = []option.Endpoint{{Type: "test-probe", Tag: "private", Options: &option.StubOptions{}}}
				outbounds = nil
			}
			results, err := c.RunOfflineURLTests(ctx, t.TempDir(), outbounds, map[string]string{"private": link}, endpoints...)
			require.NoError(t, err)
			require.EqualValues(t, 1, platform.monitorStarts.Load())
			require.EqualValues(t, 1, platform.monitorCloses.Load())
			if tc.untrusted {
				require.Empty(t, results)
				require.Zero(t, o.requests.Load())
				return
			}
			require.Contains(t, results, "private")
			require.Positive(t, results["private"])
			require.EqualValues(t, 1, o.requests.Load())
		})
	}
}

func TestOfflineLatencyWaitsForFreshServerSnapshot(t *testing.T) {
	ctx := box.Context(t.Context())
	registry := service.FromContext[A.OutboundRegistry](ctx).(*outbound.Registry)
	firstOutbound := &offlineProbeOutbound{Adapter: outbound.NewAdapter("socks", "existing", []string{"tcp"}, nil), delay: 100 * time.Millisecond}
	newOutbound := &offlineProbeOutbound{Adapter: outbound.NewAdapter("socks", "new", []string{"tcp"}, nil)}
	outbound.Register[option.StubOptions](registry, "test-probe", func(_ context.Context, _ A.Router, _ log.ContextLogger, tag string, _ option.StubOptions) (A.Outbound, error) {
		if tag == "new" {
			return newOutbound, nil
		}
		return firstOutbound, nil
	})
	c := NewVPNClient(t.TempDir(), nil, &probePlatform{})
	type probeResult struct {
		results map[string]uint16
		err     error
	}
	first := make(chan probeResult, 1)
	go func() {
		results, err := c.RunOfflineURLTests(ctx, t.TempDir(), []option.Outbound{{Type: "test-probe", Tag: "existing", Options: &option.StubOptions{}}}, map[string]string{"existing": "http://probe.invalid/generate_204"})
		first <- probeResult{results, err}
	}()
	require.Eventually(t, func() bool { return firstOutbound.requests.Load() > 0 }, time.Second, time.Millisecond)
	results, err := c.RunOfflineURLTests(ctx, t.TempDir(), []option.Outbound{{Type: "test-probe", Tag: "new", Options: &option.StubOptions{}}}, map[string]string{"new": "http://probe.invalid/generate_204"})
	require.NoError(t, err)
	require.Contains(t, results, "new")
	require.NotContains(t, results, "existing")
	previous := <-first
	require.NoError(t, previous.err)
	require.Contains(t, previous.results, "existing")
	require.EqualValues(t, 1, newOutbound.requests.Load())
}

func TestOfflineLatencyWaitingCanBeCanceled(t *testing.T) {
	c := NewVPNClient(t.TempDir(), nil, nil)
	c.offlineTestDone = make(chan struct{})
	ctx, cancel := context.WithTimeout(t.Context(), 10*time.Millisecond)
	defer cancel()
	_, err := c.RunOfflineURLTests(ctx, "", nil, nil)
	require.ErrorIs(t, err, context.DeadlineExceeded)
	select {
	case <-c.offlineTestDone:
		t.Fatal("a waiting probe closed the active probe's completion channel")
	default:
	}
}

func TestOfflineLatencyConnectWaitsForQueuedProbe(t *testing.T) {
	c := NewVPNClient(t.TempDir(), nil, nil)
	c.tunnel = &tunnel{}
	c.status.Store(Connected)
	firstDone := make(chan struct{})
	cancelRequested := make(chan struct{}, 1)
	c.offlineTestDone = firstDone
	c.offlineTestCancel = func() { cancelRequested <- struct{}{} }
	ctx, cancel := context.WithTimeout(t.Context(), time.Second)
	defer cancel()
	connected := make(chan error, 1)
	go func() { connected <- c.Connect(ctx, BoxOptions{}) }()
	select {
	case <-cancelRequested:
	case <-ctx.Done():
		t.Fatal("Connect did not cancel the active probe")
	}
	queuedDone := make(chan struct{})
	c.mu.Lock()
	c.offlineTestDone = queuedDone
	c.offlineTestCancel = func() { close(queuedDone) }
	c.mu.Unlock()
	close(firstDone)
	require.ErrorIs(t, <-connected, ErrTunnelAlreadyConnected)
	select {
	case <-queuedDone:
	default:
		t.Fatal("Connect started before the queued probe finished")
	}
}
