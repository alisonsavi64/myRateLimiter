package ratelimit

import "strings"

type RouteLimit struct {
	Basic   int
	Premium int
}

// routeOverrides defines per-route limits that override the global defaults.
// Routes are matched by prefix (longest match wins).
var routeOverrides = map[string]RouteLimit{
	"/api/search": {Basic: 20, Premium: 200},
	"/api/export": {Basic: 5, Premium: 50},
}

// LimitFor returns the request-per-minute limit for the given user type and route.
// admin always returns 0 (unlimited). Unknown types default to basic.
func LimitFor(userType, route string, defaultBasic, defaultPremium int) int {
	switch strings.ToLower(userType) {
	case "admin":
		return 0
	case "premium":
		if override, ok := matchRoute(route); ok {
			return override.Premium
		}
		return defaultPremium
	default:
		if override, ok := matchRoute(route); ok {
			return override.Basic
		}
		return defaultBasic
	}
}

func matchRoute(path string) (RouteLimit, bool) {
	// strip query string
	if idx := strings.IndexByte(path, '?'); idx >= 0 {
		path = path[:idx]
	}
	// longest prefix match
	best := ""
	var bestLimit RouteLimit
	for prefix, limit := range routeOverrides {
		if strings.HasPrefix(path, prefix) && len(prefix) > len(best) {
			best = prefix
			bestLimit = limit
		}
	}
	return bestLimit, best != ""
}
