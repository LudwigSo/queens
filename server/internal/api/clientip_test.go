package api

import (
	"net/http"
	"net/http/httptest"
	"testing"
)

// The rate limiters key on clientIP, and the registration bucket is the one
// that stops account farming. A proxy appends the peer it saw to whatever the
// caller sent, so anything but the right-most element is attacker-controlled.
func TestClientIPTakesTheRightmostForwardedForEntry(t *testing.T) {
	cases := []struct {
		name       string
		trustProxy bool
		forwarded  string
		remote     string
		want       string
	}{
		{"no proxy trusted, header ignored", false, "203.0.113.9", "198.51.100.4:51000", "198.51.100.4"},
		{"no header", true, "", "198.51.100.4:51000", "198.51.100.4"},
		{"single entry written by the proxy", true, "198.51.100.4", "127.0.0.1:8721", "198.51.100.4"},
		{"forged left-most is ignored", true, "203.0.113.9, 198.51.100.4", "127.0.0.1:8721", "198.51.100.4"},
		{"a whole forged chain is ignored", true, "1.1.1.1, 2.2.2.2, 198.51.100.4", "127.0.0.1:8721", "198.51.100.4"},
		{"spaces are trimmed", true, "203.0.113.9,   198.51.100.4  ", "127.0.0.1:8721", "198.51.100.4"},
		{"IPv6 proxy entry", true, "203.0.113.9, 2001:db8::1", "127.0.0.1:8721", "2001:db8::1"},
		// Junk must not become a limiter key: a bucket is allocated for any
		// string before it is checked, and they live for two hours.
		{"junk falls back to the peer", true, "not-an-ip", "198.51.100.4:51000", "198.51.100.4"},
		{"junk right-most falls back to the peer", true, "198.51.100.9, drop table", "198.51.100.4:51000", "198.51.100.4"},
		{"empty right-most falls back to the peer", true, "198.51.100.9,", "198.51.100.4:51000", "198.51.100.4"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			r := httptest.NewRequest(http.MethodGet, "/v1/time", nil)
			r.RemoteAddr = tc.remote
			if tc.forwarded != "" {
				r.Header.Set("X-Forwarded-For", tc.forwarded)
			}
			if got := clientIP(r, tc.trustProxy); got != tc.want {
				t.Fatalf("clientIP(%q, trust=%v) = %q, want %q",
					tc.forwarded, tc.trustProxy, got, tc.want)
			}
		})
	}
}

// X-Real-IP and True-Client-IP are what chi's RealIP used to honour. Our proxy
// neither sets nor strips them, so they must not reach the limiter key.
func TestClientIPIgnoresOtherForwardingHeaders(t *testing.T) {
	r := httptest.NewRequest(http.MethodGet, "/v1/time", nil)
	r.RemoteAddr = "198.51.100.4:51000"
	r.Header.Set("X-Real-IP", "203.0.113.9")
	r.Header.Set("True-Client-IP", "203.0.113.10")
	if got := clientIP(r, true); got != "198.51.100.4" {
		t.Fatalf("clientIP = %q, want the peer 198.51.100.4", got)
	}
}
