// Generates a signed HS256 JWT for local testing.
// No external dependencies — stdlib only.
//
// Usage:
//
//	go run scripts/make-token.go
//	go run scripts/make-token.go -user premium-user -type premium
//	go run scripts/make-token.go -user admin-1 -type admin
//	go run scripts/make-token.go -secret myothersecret
package main

import (
	"crypto/hmac"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"flag"
	"fmt"
	"strings"
)

func main() {
	userID := flag.String("user", "user-123", "user ID (sub claim)")
	userType := flag.String("type", "basic", "user type: basic | premium | admin")
	secret := flag.String("secret", "mysecret", "HMAC signing secret")
	exp := flag.Int64("exp", 9999999999, "expiry as Unix timestamp")
	flag.Parse()

	token, err := makeToken(*userID, *userType, *secret, *exp)
	if err != nil {
		fmt.Printf("error: %v\n", err)
		return
	}

	fmt.Printf("Bearer %s\n\n", token)
	fmt.Printf("curl.exe http://localhost:8080/api/search -H \"Authorization: Bearer %s\"\n", token)
}

func makeToken(userID, userType, secret string, exp int64) (string, error) {
	header := map[string]string{"alg": "HS256", "typ": "JWT"}
	payload := map[string]interface{}{
		"sub":       userID,
		"user_type": userType,
		"exp":       exp,
	}

	headerJSON, err := json.Marshal(header)
	if err != nil {
		return "", err
	}
	payloadJSON, err := json.Marshal(payload)
	if err != nil {
		return "", err
	}

	headerB64 := b64(headerJSON)
	payloadB64 := b64(payloadJSON)
	signingInput := headerB64 + "." + payloadB64

	mac := hmac.New(sha256.New, []byte(secret))
	mac.Write([]byte(signingInput))
	sig := base64.RawURLEncoding.EncodeToString(mac.Sum(nil))

	return signingInput + "." + sig, nil
}

func b64(data []byte) string {
	return strings.TrimRight(base64.RawURLEncoding.EncodeToString(data), "=")
}
