package main

import (
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"time"

	"go-app/internal/config"
	"go-app/internal/middleware"
	"go-app/internal/proxy"
	"go-app/internal/ratelimit"
)

func main() {
	cfg := config.Load()

	var limiter *ratelimit.Limiter
	if cfg.RedisMode == "sentinel" {
		limiter = ratelimit.NewSentinel(cfg.SentinelMasterName, []string{
			fmt.Sprintf("%s:26379", cfg.SentinelHost1),
			fmt.Sprintf("%s:26379", cfg.SentinelHost2),
			fmt.Sprintf("%s:26379", cfg.SentinelHost3),
		})
	} else {
		limiter = ratelimit.NewDirect(cfg.RedisHost, cfg.RedisPort)
	}

	rl := middleware.NewRateLimit(limiter, cfg.RateLimitBasic, cfg.RateLimitPremium)
	upstream := proxy.New(cfg.UpstreamURL)

	mux := http.NewServeMux()

	// Health endpoint — exempt from rate limiting (used by ALB and NGINX health checks)
	mux.HandleFunc("/health", healthHandler)

	// All other requests: rate limit middleware → proxy to upstream
	mux.Handle("/", rl.Handler(upstream))

	addr := ":" + cfg.Port
	log.Printf("proxy starting on %s upstream=%q redis=%s mode=%s",
		addr, cfg.UpstreamURL, cfg.RedisHost, cfg.RedisMode)

	if err := http.ListenAndServe(addr, mux); err != nil {
		log.Fatalf("server failed: %v", err)
	}
}

func healthHandler(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		http.Error(w, "Method Not Allowed", http.StatusMethodNotAllowed)
		return
	}
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusOK)
	_ = json.NewEncoder(w).Encode(map[string]string{
		"status":    "ok",
		"timestamp": time.Now().UTC().Format(time.RFC3339),
	})
}
