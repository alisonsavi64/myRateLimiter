package proxy

import (
	"encoding/json"
	"net/http"
	"net/http/httputil"
	"net/url"
)

// New returns an httputil.ReverseProxy targeting upstreamURL.
// If upstreamURL is empty it returns an echo handler instead.
func New(upstreamURL string) http.Handler {
	if upstreamURL == "" {
		return http.HandlerFunc(echoHandler)
	}

	target, err := url.Parse(upstreamURL)
	if err != nil {
		panic("invalid UPSTREAM_URL: " + err.Error())
	}

	rp := httputil.NewSingleHostReverseProxy(target)

	// Preserve the original director and patch the Host header
	original := rp.Director
	rp.Director = func(req *http.Request) {
		original(req)
		req.Host = target.Host
	}

	return rp
}

// echoHandler returns request metadata as JSON — used when UPSTREAM_URL is unset.
func echoHandler(w http.ResponseWriter, r *http.Request) {
	headers := make(map[string]string, len(r.Header))
	for k := range r.Header {
		headers[k] = r.Header.Get(k)
	}

	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusOK)
	_ = json.NewEncoder(w).Encode(map[string]interface{}{
		"method":  r.Method,
		"path":    r.URL.Path,
		"query":   r.URL.RawQuery,
		"headers": headers,
		"mode":    "echo",
	})
}
