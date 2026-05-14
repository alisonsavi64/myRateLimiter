package middleware

import (
	"encoding/json"
	"fmt"
	"log"
	"net/http"

	jwtpkg "go-app/internal/jwt"
	"go-app/internal/ratelimit"
)

type RateLimitMiddleware struct {
	limiter          *ratelimit.Limiter
	defaultBasic     int
	defaultPremium   int
}

func NewRateLimit(limiter *ratelimit.Limiter, defaultBasic, defaultPremium int) *RateLimitMiddleware {
	return &RateLimitMiddleware{
		limiter:        limiter,
		defaultBasic:   defaultBasic,
		defaultPremium: defaultPremium,
	}
}

func (m *RateLimitMiddleware) Handler(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		authHeader := r.Header.Get("Authorization")

		var userID, userType string
		claims, err := jwtpkg.ExtractClaims(authHeader)
		if err != nil {
			// No valid JWT → treat as anonymous basic user
			userID = "anonymous"
			userType = "basic"
		} else {
			userID = claims.UserID
			userType = claims.UserType
		}

		limit := ratelimit.LimitFor(userType, r.URL.Path, m.defaultBasic, m.defaultPremium)

		result, err := m.limiter.Check(r.Context(), userID, r.URL.RequestURI(), limit)
		if err != nil {
			log.Printf("rate limit check error user=%s: %v", userID, err)
			// fail-open
			next.ServeHTTP(w, r)
			return
		}

		setRateLimitHeaders(w, result)

		// Also inject user context headers for the upstream
		r.Header.Set("X-User-ID", userID)
		r.Header.Set("X-User-Type", userType)

		if !result.Allowed {
			log.Printf("rate limit exceeded user=%s type=%s route=%s", userID, userType, r.URL.Path)
			w.Header().Set("Content-Type", "application/json")
			w.Header().Set("Retry-After", "60")
			w.WriteHeader(http.StatusTooManyRequests)
			_ = json.NewEncoder(w).Encode(map[string]interface{}{
				"error":       "rate limit exceeded",
				"retry_after": 60,
			})
			return
		}

		next.ServeHTTP(w, r)
	})
}

func setRateLimitHeaders(w http.ResponseWriter, result *ratelimit.Result) {
	if result.Limit > 0 {
		w.Header().Set("X-RateLimit-Limit", fmt.Sprintf("%d", result.Limit))
		w.Header().Set("X-RateLimit-Remaining", fmt.Sprintf("%d", result.Remaining))
		w.Header().Set("X-RateLimit-Reset", fmt.Sprintf("%d", result.Reset))
	}
}
