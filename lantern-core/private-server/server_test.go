package privateserver

import (
	"context"
	"testing"

	"github.com/getlantern/radiance/servers"
)

type fakePrivateServerRegistry struct {
	server    *servers.Server
	addCalls  int
	addServer func() error
}

func (f *fakePrivateServerRegistry) GetServerByTag(_ context.Context, tag string) (*servers.Server, bool, error) {
	if f.server == nil || f.server.Tag != tag {
		return nil, false, nil
	}
	return f.server, true, nil
}

func (f *fakePrivateServerRegistry) AddPrivateServer(_ context.Context, tag, _ string, _ int, _ string) error {
	f.addCalls++
	if f.addServer != nil {
		if err := f.addServer(); err != nil {
			return err
		}
	}
	f.server = &servers.Server{Tag: tag, Type: "tuic"}
	return nil
}

func TestEnsurePrivateServerSkipsExistingServer(t *testing.T) {
	registry := &fakePrivateServerRegistry{
		server: &servers.Server{Tag: "node1", Type: "hysteria2"},
	}

	protocol, err := ensurePrivateServer(context.Background(), registry, provisionerResponse{Tag: "node1"})
	if err != nil {
		t.Fatalf("ensurePrivateServer() error = %v", err)
	}
	if protocol != "hysteria2" {
		t.Fatalf("protocol = %q, want hysteria2", protocol)
	}
	if registry.addCalls != 0 {
		t.Fatalf("AddPrivateServer called %d times, want 0", registry.addCalls)
	}
}

func TestEnsurePrivateServerRestoresMissingServer(t *testing.T) {
	registry := &fakePrivateServerRegistry{}

	protocol, err := ensurePrivateServer(context.Background(), registry, provisionerResponse{
		Tag:         "node1",
		ExternalIP:  "192.0.2.1",
		Port:        443,
		AccessToken: "secret",
	})
	if err != nil {
		t.Fatalf("ensurePrivateServer() error = %v", err)
	}
	if protocol != "tuic" {
		t.Fatalf("protocol = %q, want tuic", protocol)
	}
	if registry.addCalls != 1 {
		t.Fatalf("AddPrivateServer called %d times, want 1", registry.addCalls)
	}
}
