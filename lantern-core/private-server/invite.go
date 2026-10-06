package privateserver

import (
	"context"
	"crypto/x509"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"time"

	"github.com/getlantern/radiance/bypass"
)

const inviteTimeout = 20 * time.Second

// InviteToServer talks only to the configured private manager. Unlike the
// daemon's retrying client, this request has one deadline covering DNS, TLS and
// the response body, and does not retry or forward the admin token on redirects.
func InviteToServer(ctx context.Context, host string, port int, token, name string) (string, error) {
	transport := &http.Transport{
		DialContext:           bypass.DialContext,
		TLSHandshakeTimeout:   10 * time.Second,
		ResponseHeaderTimeout: 15 * time.Second,
	}
	defer transport.CloseIdleConnections()
	client := &http.Client{
		Transport:     transport,
		Timeout:       inviteTimeout,
		CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse },
	}
	ctx, cancel := context.WithTimeout(ctx, inviteTimeout)
	defer cancel()
	return inviteToServer(ctx, client, host, port, token, name)
}

func inviteToServer(ctx context.Context, client *http.Client, host string, port int, token, name string) (string, error) {
	host = strings.TrimSpace(host)
	name = strings.TrimSpace(name)
	if host == "" || port < 1 || port > 65535 {
		return "", errors.New("private_server_manager_address_missing")
	}
	if strings.TrimSpace(token) == "" {
		return "", errors.New("access_token_missing")
	}
	if name == "" {
		return "", errors.New("server_alias_cannot_be_empty")
	}
	u := &url.URL{
		Scheme:   "https",
		Host:     net.JoinHostPort(strings.Trim(host, "[]"), strconv.Itoa(port)),
		Path:     "/api/v1/share-link/" + name,
		RawPath:  "/api/v1/share-link/" + url.PathEscape(name),
		RawQuery: url.Values{"token": {token}}.Encode(),
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, u.String(), nil)
	if err != nil {
		return "", errors.New("private_server_manager_address_missing")
	}
	resp, err := client.Do(req)
	if err != nil {
		// url.Error contains the complete URL, including the owner token.
		var urlErr *url.Error
		if errors.As(err, &urlErr) {
			err = urlErr.Err
		}
		var networkError net.Error
		if errors.Is(err, context.DeadlineExceeded) || ctx.Err() == context.DeadlineExceeded ||
			(errors.As(err, &networkError) && networkError.Timeout()) {
			return "", errors.New("private_server_request_timeout")
		}
		var unknownAuthority x509.UnknownAuthorityError
		var invalidCertificate x509.CertificateInvalidError
		var hostnameError x509.HostnameError
		if errors.As(err, &unknownAuthority) || errors.As(err, &invalidCertificate) || errors.As(err, &hostnameError) {
			return "", errors.New("private_server_certificate_invalid")
		}
		return "", fmt.Errorf("private server share request failed: %w", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode == http.StatusUnauthorized || resp.StatusCode == http.StatusForbidden {
		return "", errors.New("private_server_owner_token_invalid")
	}
	if resp.StatusCode != http.StatusOK {
		return "", fmt.Errorf("private server share request returned HTTP %d", resp.StatusCode)
	}
	var result struct {
		Token string `json:"token"`
	}
	if err := json.NewDecoder(io.LimitReader(resp.Body, 64*1024)).Decode(&result); err != nil {
		if ctx.Err() == context.DeadlineExceeded {
			return "", errors.New("private_server_request_timeout")
		}
		return "", errors.New("invalid private server share response")
	}
	if strings.TrimSpace(result.Token) == "" {
		return "", errors.New("invalid private server share response")
	}
	return result.Token, nil
}
