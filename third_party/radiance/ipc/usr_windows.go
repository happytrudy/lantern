package ipc

import (
	"fmt"
	"log/slog"
	"slices"

	"golang.org/x/sys/windows"
)

func usrFromToken(t windows.Token) (p usr, err error) {
	u, err := t.GetTokenUser()
	if err != nil {
		return p, fmt.Errorf("failed to get token user: %w", err)
	}
	uname, _, _, err := u.User.Sid.LookupAccount("")
	if err != nil {
		return p, fmt.Errorf("failed to lookup account name: %w", err)
	}
	isAdm, err := isAdmin(t)
	if err != nil {
		slog.Warn("failed to check admin status", "error", err)
		isAdm = false
	}
	isInteractive, err := isInteractive(t)
	if err != nil {
		slog.Warn("failed to check interactive user status", "error", err)
		isInteractive = false
	}
	return usr{
		uid:           u.User.Sid.String(),
		uname:         uname,
		isAdmin:       isAdm,
		isInteractive: isInteractive,
	}, nil
}

func isInteractive(t windows.Token) (bool, error) {
	interactiveSid, err := windows.CreateWellKnownSid(windows.WinInteractiveSid)
	if err != nil {
		return false, fmt.Errorf("failed to create interactive sid: %w", err)
	}
	tokenGroups, err := t.GetTokenGroups()
	if err != nil {
		return false, fmt.Errorf("failed to get token groups: %w", err)
	}
	return slices.ContainsFunc(tokenGroups.AllGroups(), func(g windows.SIDAndAttributes) bool {
		return windows.EqualSid(g.Sid, interactiveSid)
	}), nil
}

func isAdmin(t windows.Token) (bool, error) {
	adminSid, err := windows.CreateWellKnownSid(windows.WinBuiltinAdministratorsSid)
	if err != nil {
		return false, fmt.Errorf("failed to create admin sid: %w", err)
	}
	tokenGroups, err := t.GetTokenGroups()
	if err != nil {
		return false, fmt.Errorf("failed to get token groups: %w", err)
	}
	return slices.ContainsFunc(tokenGroups.AllGroups(), func(g windows.SIDAndAttributes) bool {
		return windows.EqualSid(g.Sid, adminSid)
	}), nil
}
