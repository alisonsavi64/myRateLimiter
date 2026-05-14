package ratelimit

import (
	"context"
	"fmt"
	"math/rand"
	"strings"
	"time"

	"github.com/redis/go-redis/v9"
)

type Result struct {
	Allowed   bool
	Remaining int
	Reset     int64
	Limit     int
}

type Limiter struct {
	client redis.UniversalClient
}

func NewDirect(host, port string) *Limiter {
	client := redis.NewClient(&redis.Options{
		Addr:         fmt.Sprintf("%s:%s", host, port),
		DialTimeout:  200 * time.Millisecond,
		ReadTimeout:  200 * time.Millisecond,
		WriteTimeout: 200 * time.Millisecond,
	})
	return &Limiter{client: client}
}

func NewSentinel(masterName string, sentinelAddrs []string) *Limiter {
	client := redis.NewFailoverClient(&redis.FailoverOptions{
		MasterName:    masterName,
		SentinelAddrs: sentinelAddrs,
		DialTimeout:   200 * time.Millisecond,
		ReadTimeout:   200 * time.Millisecond,
		WriteTimeout:  200 * time.Millisecond,
	})
	return &Limiter{client: client}
}

// Check runs a sliding window rate limit for the given userID + route.
// Key namespace: rl:proxy:<userID>:<normalizedRoute> — no collision with NGINX (rl:<ip>) or Lambda (rl:user:<id>).
// limit=0 means unlimited.
func (l *Limiter) Check(ctx context.Context, userID, route string, limit int) (*Result, error) {
	now := time.Now()
	resetEpoch := now.Unix() + 60

	if limit <= 0 {
		return &Result{Allowed: true, Remaining: -1, Limit: 0, Reset: resetEpoch}, nil
	}

	nowMs := now.UnixMilli()
	windowStart := nowMs - 60_000
	key := fmt.Sprintf("rl:proxy:%s:%s", userID, normalizeRoute(route))
	member := fmt.Sprintf("%d:%d", nowMs, rand.Int63())

	pipe := l.client.Pipeline()
	pipe.ZAdd(ctx, key, redis.Z{Score: float64(nowMs), Member: member})
	pipe.ZRemRangeByScore(ctx, key, "-inf", fmt.Sprintf("%d", windowStart))
	zcardCmd := pipe.ZCard(ctx, key)
	pipe.Expire(ctx, key, 61*time.Second)

	if _, err := pipe.Exec(ctx); err != nil {
		// fail-open: Redis unavailable → allow the request
		return &Result{Allowed: true, Remaining: limit, Limit: limit, Reset: resetEpoch}, nil
	}

	count := int(zcardCmd.Val())
	remaining := limit - count
	if remaining < 0 {
		remaining = 0
	}

	return &Result{
		Allowed:   count <= limit,
		Remaining: remaining,
		Reset:     resetEpoch,
		Limit:     limit,
	}, nil
}

// normalizeRoute strips query strings and converts path to a Redis-safe key segment.
// /api/v1/users?page=1 → api:v1:users
func normalizeRoute(path string) string {
	if idx := strings.IndexByte(path, '?'); idx >= 0 {
		path = path[:idx]
	}
	path = strings.Trim(path, "/")
	if path == "" {
		return "root"
	}
	return strings.ReplaceAll(path, "/", ":")
}
