package privateserver

import (
	"context"
	"crypto/x509"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

type inviteTransport func(*http.Request) (*http.Response, error)

func (f inviteTransport) RoundTrip(r *http.Request) (*http.Response, error) { return f(r) }

func inviteResponse(status int, body string) *http.Response {
	return &http.Response{StatusCode: status, Body: io.NopCloser(strings.NewReader(body)), Header: make(http.Header)}
}

func TestInviteEncodesAliasAndToken(t *testing.T) {
	const name = "朋友 / A?B#C"
	const token = "owner+token&value"
	mux := http.NewServeMux()
	mux.HandleFunc("GET /api/v1/share-link/{name}", func(w http.ResponseWriter, r *http.Request) {
		if r.PathValue("name") != name {
			t.Errorf("manager decoded alias = %q", r.PathValue("name"))
		}
		w.Write([]byte(`{"token":"generated-access-key"}`))
	})
	client := &http.Client{Transport: inviteTransport(func(r *http.Request) (*http.Response, error) {
		if r.Method != http.MethodGet {
			t.Errorf("method = %s", r.Method)
		}
		if r.URL.Scheme != "https" || r.URL.Host != "manager.example:8443" {
			t.Errorf("destination = %s", r.URL.Host)
		}
		if r.URL.Path != "/api/v1/share-link/"+name {
			t.Errorf("path = %q", r.URL.Path)
		}
		if !strings.Contains(r.URL.EscapedPath(), "%2F") {
			t.Error("alias slash was not escaped")
		}
		if r.URL.Query().Get("token") != token {
			t.Error("owner token was not correctly encoded")
		}
		recorder := httptest.NewRecorder()
		mux.ServeHTTP(recorder, r)
		return recorder.Result(), nil
	})}
	key, err := inviteToServer(context.Background(), client, "manager.example", 8443, token, name)
	if err != nil {
		t.Fatal(err)
	}
	if key != "generated-access-key" {
		t.Fatalf("key = %q", key)
	}
}

func TestInviteIPv6ManagerAddress(t *testing.T) {
	client := &http.Client{Transport: inviteTransport(func(r *http.Request) (*http.Response, error) {
		if r.URL.Host != "[2001:db8::1]:8443" {
			t.Errorf("host = %s", r.URL.Host)
		}
		return inviteResponse(http.StatusOK, `{"token":"key"}`), nil
	})}
	_, err := inviteToServer(context.Background(), client, "2001:db8::1", 8443, "token", "guest")
	if err != nil {
		t.Fatal(err)
	}
}

func TestInviteErrorsDoNotRetry(t *testing.T) {
	for _, status := range []int{401, 403, 500} {
		calls := 0
		client := &http.Client{Transport: inviteTransport(func(*http.Request) (*http.Response, error) {
			calls++
			return inviteResponse(status, "error"), nil
		})}
		_, err := inviteToServer(context.Background(), client, "manager.example", 443, "owner-token", "guest")
		if err == nil {
			t.Fatalf("status %d unexpectedly succeeded", status)
		}
		if calls != 1 {
			t.Fatalf("requests = %d", calls)
		}
	}
}

type waitingBody struct{ ctx context.Context }

func (b waitingBody) Read([]byte) (int, error) { <-b.ctx.Done(); return 0, b.ctx.Err() }
func (waitingBody) Close() error               { return nil }

func TestInviteDeadlineCoversResponseBody(t *testing.T) {
	client := &http.Client{Transport: inviteTransport(func(r *http.Request) (*http.Response, error) {
		return &http.Response{StatusCode: http.StatusOK, Body: waitingBody{r.Context()}, Header: make(http.Header)}, nil
	})}
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Millisecond)
	defer cancel()
	_, err := inviteToServer(ctx, client, "manager.example", 443, "owner-token", "guest")
	if err == nil || err.Error() != "private_server_request_timeout" {
		t.Fatalf("err = %v", err)
	}
}

func TestInviteRejectsMissingAddress(t *testing.T) {
	_, err := InviteToServer(context.Background(), "", 443, "owner-token", "guest")
	if err == nil || err.Error() != "private_server_manager_address_missing" {
		t.Fatalf("err = %v", err)
	}
}

func TestInviteRejectsInvalidResponse(t *testing.T) {
	for _, body := range []string{`{}`, `{"token":""}`, "not-json"} {
		client := &http.Client{Transport: inviteTransport(func(*http.Request) (*http.Response, error) {
			return inviteResponse(http.StatusOK, body), nil
		})}
		_, err := inviteToServer(context.Background(), client, "manager.example", 443, "owner-token", "guest")
		if err == nil {
			t.Fatalf("invalid response %q was accepted", body)
		}
	}
}

func TestInviteNetworkErrorsDoNotExposeOwnerToken(t *testing.T) {
	client := &http.Client{Transport: inviteTransport(func(*http.Request) (*http.Response, error) {
		return nil, errors.New("connection refused")
	})}
	_, err := inviteToServer(context.Background(), client, "manager.example", 443, "secret-owner-token", "guest")
	if err == nil || strings.Contains(err.Error(), "secret-owner-token") {
		t.Fatalf("err = %v", err)
	}
}

func TestInviteCertificateFailure(t *testing.T) {
	client := &http.Client{Transport: inviteTransport(func(*http.Request) (*http.Response, error) {
		return nil, x509.UnknownAuthorityError{}
	})}
	_, err := inviteToServer(context.Background(), client, "manager.example", 443, "owner-token", "guest")
	if err == nil || err.Error() != "private_server_certificate_invalid" {
		t.Fatalf("err = %v", err)
	}
}
