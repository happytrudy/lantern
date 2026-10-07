package ipc

import (
	"net/http"
	"net/http/httptest"
	"testing"
)

func TestPeerCanAccess(t *testing.T) {
	for _, test := range []struct {
		name       string
		peer       usr
		wantAccess bool
	}{
		{name: "administrator", peer: usr{isAdmin: true}, wantAccess: true},
		{name: "interactive standard user", peer: usr{isInteractive: true}, wantAccess: true},
		{name: "non-interactive user", peer: usr{}, wantAccess: false},
	} {
		t.Run(test.name, func(t *testing.T) {
			if got := peerCanAccess(test.peer); got != test.wantAccess {
				t.Fatalf("peerCanAccess() = %t, want %t", got, test.wantAccess)
			}
		})
	}
}

func TestAuthPeerAllowsInteractiveUser(t *testing.T) {
	handler := authPeer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusNoContent)
	}))
	request := httptest.NewRequest(http.MethodGet, "/vpn/status", nil)
	request = request.WithContext(contextWithUsr(request.Context(), usr{
		uid:           "S-1-5-21-test",
		isInteractive: true,
	}))
	response := httptest.NewRecorder()
	handler.ServeHTTP(response, request)
	if response.Code != http.StatusNoContent {
		t.Fatalf("interactive user status = %d, want %d", response.Code, http.StatusNoContent)
	}
}
