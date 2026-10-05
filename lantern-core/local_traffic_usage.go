package lanterncore

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"sync"
	"time"

	"github.com/getlantern/radiance/ipc"
)

const localTrafficUsageFile = "local_traffic_usage.json"

// localTrafficUsage is the device-local daily traffic counter. It deliberately
// has no allotment or enforcement logic: bytes are only displayed to the user.
type localTrafficUsage struct {
	mu       sync.Mutex
	path     string
	client   *ipc.Client
	ctx      context.Context
	day      string
	bytes    int64
	sessions map[string]int64
}

type localTrafficUsageFileData struct {
	Day      string           `json:"day"`
	Bytes    int64            `json:"bytes"`
	Sessions map[string]int64 `json:"sessions,omitempty"`
}

func newLocalTrafficUsage(dataDir string, client *ipc.Client, ctx context.Context) *localTrafficUsage {
	u := &localTrafficUsage{
		path:     filepath.Join(dataDir, localTrafficUsageFile),
		client:   client,
		ctx:      ctx,
		day:      localTrafficUsageDay(time.Now()),
		sessions: make(map[string]int64),
	}
	u.load()
	return u
}

func localTrafficUsageDay(now time.Time) string {
	return now.Format("2006-01-02")
}

func (u *localTrafficUsage) load() {
	if u.path == "" {
		return
	}
	raw, err := os.ReadFile(u.path)
	if err != nil {
		return
	}
	var saved localTrafficUsageFileData
	if json.Unmarshal(raw, &saved) != nil || saved.Day != u.day {
		return
	}
	u.bytes = maxInt64(saved.Bytes, 0)
	for key, value := range saved.Sessions {
		if value >= 0 {
			u.sessions[key] = value
		}
	}
}

func (u *localTrafficUsage) persistLocked() {
	if u.path == "" {
		return
	}
	data := localTrafficUsageFileData{
		Day:      u.day,
		Bytes:    u.bytes,
		Sessions: u.sessions,
	}
	raw, err := json.Marshal(data)
	if err != nil {
		return
	}
	if err := os.MkdirAll(filepath.Dir(u.path), 0o755); err != nil {
		return
	}
	_ = os.WriteFile(u.path, raw, 0o600)
}

func (u *localTrafficUsage) refresh() {
	if u == nil || u.client == nil {
		return
	}
	sessions, err := u.client.VPNSessions(u.ctx, 0)
	if err != nil {
		return
	}
	now := time.Now()
	u.mu.Lock()
	defer u.mu.Unlock()
	day := localTrafficUsageDay(now)
	if day != u.day {
		u.day = day
		u.bytes = 0
		u.sessions = make(map[string]int64)
	}
	seen := make(map[string]int64, len(sessions))
	for _, session := range sessions {
		key := session.ConnectedAt.UTC().Format(time.RFC3339Nano) + "|" + session.Server.Tag
		total := maxInt64(session.BytesUp, 0) + maxInt64(session.BytesDown, 0)
		previous := u.sessions[key]
		if total > previous {
			u.bytes += total - previous
		}
		seen[key] = total
	}
	// Retain only sessions still reported by the daemon. This keeps the state
	// bounded while the persisted byte total remains durable across restarts.
	u.sessions = seen
	u.persistLocked()
}

func (u *localTrafficUsage) run(ctx context.Context) {
	if u == nil {
		return
	}
	ticker := time.NewTicker(10 * time.Second)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			u.refresh()
		}
	}
}

func (u *localTrafficUsage) snapshot() (string, error) {
	if u == nil {
		return "", fmt.Errorf("local traffic usage is unavailable")
	}
	u.refresh()
	u.mu.Lock()
	defer u.mu.Unlock()
	now := time.Now()
	start := time.Date(now.Year(), now.Month(), now.Day(), 0, 0, 0, 0, now.Location())
	end := start.Add(24 * time.Hour)
	response := map[string]any{
		"enabled": true,
		"usage": map[string]any{
			"bytesAllotted":      0,
			"bytesUsed":          u.bytes,
			"allotmentStartTime": start.Format(time.RFC3339),
			"allotmentEndTime":   end.Format(time.RFC3339),
		},
	}
	raw, err := json.Marshal(response)
	return string(raw), err
}

func maxInt64(value, fallback int64) int64 {
	if value < fallback {
		return fallback
	}
	return value
}
