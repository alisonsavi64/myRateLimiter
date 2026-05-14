package config

import (
	"os"
	"strconv"
)

type Config struct {
	Port               string
	UpstreamURL        string
	RedisHost          string
	RedisPort          string
	RedisMode          string
	SentinelHost1      string
	SentinelHost2      string
	SentinelHost3      string
	SentinelMasterName string
	RateLimitBasic     int
	RateLimitPremium   int
}

func Load() *Config {
	return &Config{
		Port:               getEnv("PORT", "8080"),
		UpstreamURL:        getEnv("UPSTREAM_URL", ""),
		RedisHost:          getEnv("REDIS_HOST", "localhost"),
		RedisPort:          getEnv("REDIS_PORT", "6379"),
		RedisMode:          getEnv("REDIS_MODE", "direct"),
		SentinelHost1:      getEnv("SENTINEL_HOST_1", "sentinel-1"),
		SentinelHost2:      getEnv("SENTINEL_HOST_2", "sentinel-2"),
		SentinelHost3:      getEnv("SENTINEL_HOST_3", "sentinel-3"),
		SentinelMasterName: getEnv("SENTINEL_MASTER_NAME", "mymaster"),
		RateLimitBasic:     getEnvInt("RATE_LIMIT_BASIC", 60),
		RateLimitPremium:   getEnvInt("RATE_LIMIT_PREMIUM", 600),
	}
}

func getEnv(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}

func getEnvInt(key string, fallback int) int {
	if v := os.Getenv(key); v != "" {
		if n, err := strconv.Atoi(v); err == nil {
			return n
		}
	}
	return fallback
}
