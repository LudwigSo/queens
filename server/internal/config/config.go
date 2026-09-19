// Package config reads the whole server configuration from the environment.
// No file, no Viper: one environment does not need a configuration language.
package config

import (
	"fmt"
	"log/slog"
	"os"
	"strconv"
	"strings"
	"time"
)

type Config struct {
	Addr        string
	DBPath      string
	Env         string // "dev" or "prod"
	LogLevel    slog.Level
	TrustProxy  bool
	TokenPepper string

	CooldownSeconds int64
	SessionTTL      int64 // freshness window; acceptance is fixed at 30 days
	// NoSessionGraceUntil suppresses the weight-8 no_session flag for results
	// finished before this instant, so the pending_results queued by clients
	// that shipped before the server existed do not flag honest players.
	NoSessionGraceUntil int64

	BackupDir     string
	BackupHourUTC int

	ShutdownTimeout time.Duration
	RequestTimeout  time.Duration
	MaxBodyBytes    int64
}

func Load() (*Config, error) {
	c := &Config{
		Addr:            env("QUEENS_ADDR", ":8080"),
		DBPath:          env("QUEENS_DB", "queens.db"),
		Env:             env("QUEENS_ENV", "dev"),
		TrustProxy:      envBool("QUEENS_TRUST_PROXY", false),
		TokenPepper:     os.Getenv("QUEENS_TOKEN_PEPPER"),
		CooldownSeconds: envInt64("QUEENS_COOLDOWN_SECONDS", 7*86400),
		SessionTTL:      envInt64("QUEENS_SESSION_TTL", 6*3600),
		BackupDir:       env("QUEENS_BACKUP_DIR", ""),
		BackupHourUTC:   int(envInt64("QUEENS_BACKUP_HOUR_UTC", 3)),
		ShutdownTimeout: 15 * time.Second,
		RequestTimeout:  10 * time.Second,
		MaxBodyBytes:    32 << 10,
	}
	c.NoSessionGraceUntil = envInt64("QUEENS_NO_SESSION_GRACE_UNTIL", 0)

	switch strings.ToLower(env("QUEENS_LOG_LEVEL", "info")) {
	case "debug":
		c.LogLevel = slog.LevelDebug
	case "warn":
		c.LogLevel = slog.LevelWarn
	case "error":
		c.LogLevel = slog.LevelError
	default:
		c.LogLevel = slog.LevelInfo
	}

	if c.Env != "dev" && c.Env != "prod" {
		return nil, fmt.Errorf("QUEENS_ENV must be dev or prod, got %q", c.Env)
	}
	// The pepper protects the session HMAC. A generated one would invalidate
	// every outstanding session on restart, which is fine in dev and data loss
	// in production.
	if c.TokenPepper == "" {
		if c.Env == "prod" {
			return nil, fmt.Errorf("QUEENS_TOKEN_PEPPER is required when QUEENS_ENV=prod")
		}
		c.TokenPepper = "dev-insecure-pepper"
	}
	if c.CooldownSeconds < 0 {
		return nil, fmt.Errorf("QUEENS_COOLDOWN_SECONDS must not be negative")
	}
	if c.BackupHourUTC < 0 || c.BackupHourUTC > 23 {
		return nil, fmt.Errorf("QUEENS_BACKUP_HOUR_UTC must be 0..23")
	}
	return c, nil
}

func (c *Config) IsDev() bool { return c.Env == "dev" }

func env(key, def string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return def
}

func envInt64(key string, def int64) int64 {
	v := os.Getenv(key)
	if v == "" {
		return def
	}
	n, err := strconv.ParseInt(v, 10, 64)
	if err != nil {
		return def
	}
	return n
}

func envBool(key string, def bool) bool {
	v := strings.ToLower(os.Getenv(key))
	switch v {
	case "1", "true", "yes", "on":
		return true
	case "0", "false", "no", "off":
		return false
	}
	return def
}
