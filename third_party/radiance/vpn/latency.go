package vpn

import (
	"context"
	"log/slog"
	"sync"
	"time"

	"github.com/sagernet/sing-box/adapter"
	"github.com/sagernet/sing-box/common/urltest"
	C "github.com/sagernet/sing-box/constant"
	"github.com/sagernet/sing-box/option"
)

func latencyTags(outbounds []option.Outbound, endpoints []option.Endpoint) []string {
	tags := make([]string, 0, len(outbounds)+len(endpoints))
	for _, ob := range outbounds {
		tags = append(tags, ob.Tag)
	}
	for _, ep := range endpoints {
		tags = append(tags, ep.Tag)
	}
	return tags
}

func testOutboundLatencies(ctx context.Context, manager adapter.OutboundManager, tags []string, urls map[string]string, logger *slog.Logger) (map[string]uint16, error) {
	results := make(map[string]uint16)
	jobs := make(chan string, len(tags))
	seen := make(map[string]bool, len(tags))
	for _, tag := range tags {
		if !seen[tag] {
			jobs <- tag
			seen[tag] = true
		}
	}
	close(jobs)
	var mu sync.Mutex
	var wg sync.WaitGroup
	for range min(6, len(seen)) {
		wg.Go(func() {
			for tag := range jobs {
				if ctx.Err() != nil {
					return
				}
				ob, found := manager.Outbound(tag)
				if !found {
					logger.Warn("Latency probe missing outbound", "tag", tag)
					continue
				}
				link := urls[tag]
				if link == "" {
					link = urlTestURL
				}
				probeCtx, cancel := context.WithTimeout(ctx, C.TCPTimeout)
				started := time.Now()
				delay, err := urltest.URLTest(probeCtx, link, ob)
				cancel()
				if err != nil {
					logger.Warn("Proxy latency probe failed", "tag", tag, "type", ob.Type(), "elapsed", time.Since(started), "error", err)
					continue
				}
				logger.Info("Proxy latency probe succeeded", "tag", tag, "delay_ms", max(1, delay))
				mu.Lock()
				results[tag] = max(1, delay)
				mu.Unlock()
			}
		})
	}
	wg.Wait()
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	return results, nil
}
