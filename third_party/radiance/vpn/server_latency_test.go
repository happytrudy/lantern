package vpn

import (
	"bufio"
	"context"
	"errors"
	"fmt"
	"net"
	"net/http"
	"sync/atomic"
	"testing"
	"time"

	"crypto/tls"
	A "github.com/sagernet/sing-box/adapter"
	"github.com/sagernet/sing-box/adapter/outbound"
	"github.com/sagernet/sing-box/common/certificate"
	"github.com/sagernet/sing-box/log"
	"github.com/sagernet/sing-box/option"
	M "github.com/sagernet/sing/common/metadata"
	"github.com/sagernet/sing/service"
	"github.com/stretchr/testify/require"
	"log/slog"
)

type latencyOutbound struct {
	A.Outbound
	tag      string
	delay    time.Duration
	fail     atomic.Bool
	requests atomic.Int32
}

func (o *latencyOutbound) Tag() string  { return o.tag }
func (o *latencyOutbound) Type() string { return "socks" }
func (o *latencyOutbound) DialContext(ctx context.Context, network string, destination M.Socksaddr) (net.Conn, error) {
	client, server := net.Pipe()
	go func() {
		defer server.Close()
		req, err := http.ReadRequest(bufio.NewReader(server))
		if err != nil {
			return
		}
		defer req.Body.Close()
		if network != "tcp" || destination.String() != "probe.invalid:80" || req.Host != "probe.invalid" || req.URL.Path != "/generate_204" {
			return
		}
		o.requests.Add(1)
		if o.fail.Load() {
			return
		}
		timer := time.NewTimer(o.delay)
		defer timer.Stop()
		select {
		case <-timer.C:
			fmt.Fprint(server, "HTTP/1.1 204 No Content\r\nConnection: close\r\n\r\n")
		case <-ctx.Done():
		}
	}()
	return client, nil
}

type latencyOutboundManager struct {
	A.OutboundManager
	members map[string]A.Outbound
}

func (m *latencyOutboundManager) Outbound(tag string) (A.Outbound, bool) {
	o, found := m.members[tag]
	return o, found
}

func TestOutboundLatenciesUsesProxyHTTPResponse(t *testing.T) {
	fast := &latencyOutbound{tag: "fast", delay: time.Millisecond}
	slow := &latencyOutbound{tag: "slow", delay: 80 * time.Millisecond}
	broken := &latencyOutbound{tag: "broken"}
	broken.fail.Store(true)
	manager := &latencyOutboundManager{members: map[string]A.Outbound{"fast": fast, "slow": slow, "broken": broken}}
	urls := map[string]string{"fast": "http://probe.invalid/generate_204", "slow": "http://probe.invalid/generate_204", "broken": "http://probe.invalid/generate_204"}
	tags := []string{"fast", "slow", "broken"}
	results, err := testOutboundLatencies(t.Context(), manager, tags, urls, slog.Default())
	require.NoError(t, err)
	require.Len(t, results, 2)
	require.Positive(t, results["fast"])
	require.GreaterOrEqual(t, results["slow"], uint16(80))
	require.Greater(t, results["slow"], results["fast"])
	require.NotContains(t, results, "broken")
	require.EqualValues(t, 1, broken.requests.Load())
	fast.fail.Store(true)
	results, err = testOutboundLatencies(t.Context(), manager, tags, urls, slog.Default())
	require.NoError(t, err)
	require.NotContains(t, results, "fast")
	require.Contains(t, results, "slow")
	require.EqualValues(t, 2, fast.requests.Load())
	canceled, cancel := context.WithCancel(t.Context())
	cancel()
	_, err = testOutboundLatencies(canceled, manager, tags, urls, slog.Default())
	require.ErrorIs(t, err, context.Canceled)
}

func TestTestServerLatenciesWithoutAutoGroup(t *testing.T) {
	cert, pem := probeTLSCertificate(t)
	ctx := t.Context()
	store, err := certificate.NewStore(ctx, log.NewNOPFactory().Logger(), option.CertificateOptions{Certificate: []string{pem}})
	require.NoError(t, err)
	ctx = service.ContextWith[A.CertificateStore](ctx, store)
	o := &offlineProbeOutbound{Adapter: outbound.NewAdapter("socks", "private", []string{"tcp"}, nil), tlsConfig: &tls.Config{Certificates: []tls.Certificate{cert}}}
	c := NewVPNClient(t.TempDir(), nil, nil)
	c.tunnel = &tunnel{ctx: ctx, outboundMgr: &latencyOutboundManager{members: map[string]A.Outbound{"private": o}}}
	results, err := c.TestServerLatencies(t.Context(), "", []option.Outbound{{Tag: "private"}, {Tag: "missing"}})
	require.NoError(t, err)
	require.Positive(t, results["private"])
	require.NotContains(t, results, "missing")
	require.EqualValues(t, 1, o.requests.Load())
}

func TestTestServerLatenciesOfflineCanceled(t *testing.T) {
	c := NewVPNClient(t.TempDir(), nil, nil)
	ctx, cancel := context.WithCancel(t.Context())
	cancel()
	_, err := c.TestServerLatencies(ctx, "", nil)
	require.True(t, errors.Is(err, context.Canceled), "%v", err)
}
