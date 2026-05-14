package jwt

import (
	"errors"
	"strings"

	"github.com/golang-jwt/jwt/v5"
)

type Claims struct {
	UserID   string
	UserType string
}

var ErrMissingToken = errors.New("missing token")
var ErrInvalidToken = errors.New("invalid token")

// ExtractClaims parses the Authorization header and returns user claims.
// Signature is not re-verified — NGINX upstream already validated it.
func ExtractClaims(authHeader string) (*Claims, error) {
	raw := extractBearer(authHeader)
	if raw == "" {
		return nil, ErrMissingToken
	}

	p := jwt.NewParser()
	parsed, _, err := p.ParseUnverified(raw, jwt.MapClaims{})
	if err != nil {
		return nil, ErrInvalidToken
	}

	mapClaims, ok := parsed.Claims.(jwt.MapClaims)
	if !ok {
		return nil, ErrInvalidToken
	}

	userID := extractString(mapClaims, "sub")
	if userID == "" {
		return nil, ErrInvalidToken
	}

	return &Claims{
		UserID:   userID,
		UserType: extractUserType(mapClaims),
	}, nil
}

func extractBearer(header string) string {
	parts := strings.SplitN(header, " ", 2)
	if len(parts) != 2 || !strings.EqualFold(parts[0], "bearer") {
		return ""
	}
	return strings.TrimSpace(parts[1])
}

func extractString(claims jwt.MapClaims, key string) string {
	if v, ok := claims[key]; ok {
		if s, ok := v.(string); ok {
			return s
		}
	}
	return ""
}

func extractUserType(claims jwt.MapClaims) string {
	if t := extractString(claims, "user_type"); t != "" {
		return t
	}
	return extractString(claims, "role")
}
