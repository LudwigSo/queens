package api

import (
	"log/slog"
	"net"
	"net/http"
	"strconv"
	"sync"
	"time"

	"github.com/go-chi/chi/v5/middleware"
	"github.com/ludwigsonnenberg/queens-server/internal/domain"
	"golang.org/x/time/rate"
)

// serverTime stamps every response, including problems, 204s and 304s.
// Backend.now_utc() on the client is synchronous and cannot await, so the client
// keeps an offset from this header instead of asking for the time.
func serverTime(clock domain.Clock) func(http.Handler) http.Handler {
	return func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			w.Header().Set("X-Server-Time", strconv.FormatInt(clock.Now(), 10))
			next.ServeHTTP(w, r)
		})
	}
}

// maxBytes caps the request body. 32 KiB is far more than any payload here.
func maxBytes(n int64) func(http.Handler) http.Handler {
	return func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			r.Body = http.MaxBytesReader(w, r.Body, n)
			next.ServeHTTP(w, r)
		})
	}
}

func accessLog(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		start := time.Now()
		ww := middleware.NewWrapResponseWriter(w, r.ProtoMajor)
		next.ServeHTTP(ww, r)
		slog.Info("request",
			"method", r.Method, "path", r.URL.Path, "status", ww.Status(),
			"bytes", ww.BytesWritten(), "ms", time.Since(start).Milliseconds(),
			"request_id", middleware.GetReqID(r.Context()))
	})
}

// clientIP honours X-Forwarded-For only behind a trusted proxy. Without that
// check every limit would be spoofable with a header.
func clientIP(r *http.Request, trustProxy bool) string {
	if trustProxy {
		if v := r.Header.Get("X-Forwarded-For"); v != "" {
			for i := 0; i < len(v); i++ {
				if v[i] == ',' {
					return trimSpace(v[:i])
				}
			}
			return trimSpace(v)
		}
	}
	host, _, err := net.SplitHostPort(r.RemoteAddr)
	if err != nil {
		return r.RemoteAddr
	}
	return host
}

func trimSpace(s string) string {
	for len(s) > 0 && (s[0] == ' ' || s[0] == '\t') {
		s = s[1:]
	}
	for len(s) > 0 && (s[len(s)-1] == ' ' || s[len(s)-1] == '\t') {
		s = s[:len(s)-1]
	}
	return s
}

// limiter is a sharded token-bucket map with a janitor. IP limits must be
// generous and must NEVER ban or flag a player: carriers put tens of thousands
// of people behind one address.
type limiter struct {
	mu      sync.Mutex
	buckets map[string]*bucket
	rate    rate.Limit
	burst   int
}

type bucket struct {
	lim  *rate.Limiter
	seen time.Time
}

func newLimiter(perHour, burst int) *limiter {
	return &limiter{
		buckets: map[string]*bucket{},
		rate:    rate.Limit(float64(perHour) / 3600.0),
		burst:   burst,
	}
}

// allow reports whether the key may proceed, and how long to wait if not.
func (l *limiter) allow(key string, now time.Time) (bool, int) {
	l.mu.Lock()
	defer l.mu.Unlock()
	b, ok := l.buckets[key]
	if !ok {
		b = &bucket{lim: rate.NewLimiter(l.rate, l.burst)}
		l.buckets[key] = b
	}
	b.seen = now
	if b.lim.AllowN(now, 1) {
		return true, 0
	}
	retry := int(b.lim.Reserve().Delay().Seconds()) + 1
	if retry < 1 {
		retry = 1
	}
	return false, retry
}

func (l *limiter) sweep(olderThan time.Duration, now time.Time) {
	l.mu.Lock()
	defer l.mu.Unlock()
	for k, b := range l.buckets {
		if now.Sub(b.seen) > olderThan {
			delete(l.buckets, k)
		}
	}
}

// Limits holds the in-process buckets. The daily counters live in the database
// so a restart does not reset a long window.
type Limits struct {
	registerIP *limiter
	gamesP     *limiter
	gamesIP    *limiter
	resultsP   *limiter
	resultsIP  *limiter
	friendsP   *limiter
	friendsIP  *limiter
	readsP     *limiter
	readsIP    *limiter
}

func NewLimits() *Limits {
	return &Limits{
		// Registration is the limit that actually matters: it is what stops
		// account farming, which is what stops someone filling a 30-player
		// Bronze group with sockpuppets.
		registerIP: newLimiter(5, 5),
		gamesP:     newLimiter(30, 10),
		gamesIP:    newLimiter(200, 50),
		resultsP:   newLimiter(40, 10),
		resultsIP:  newLimiter(300, 60),
		friendsP:   newLimiter(20, 10),
		friendsIP:  newLimiter(60, 20),
		readsP:     newLimiter(600, 60),
		readsIP:    newLimiter(3000, 200),
	}
}

func (l *Limits) sweep(now time.Time) {
	for _, x := range []*limiter{l.registerIP, l.gamesP, l.gamesIP, l.resultsP, l.resultsIP,
		l.friendsP, l.friendsIP, l.readsP, l.readsIP} {
		x.sweep(2*time.Hour, now)
	}
}

// StartJanitor drops idle buckets every ten minutes.
func (l *Limits) StartJanitor(stop <-chan struct{}) {
	go func() {
		t := time.NewTicker(10 * time.Minute)
		defer t.Stop()
		for {
			select {
			case <-stop:
				return
			case now := <-t.C:
				l.sweep(now)
			}
		}
	}()
}

func tooMany(retry int) *Problem {
	return &Problem{
		Title: http.StatusText(429), Status: 429,
		Code: domain.CodeRateLimited, Params: []any{retry},
	}
}

// ipKey carries the resolved client IP into the Huma handlers, which only see a
// context.
type ipKeyType int

const ipKey ipKeyType = 0

func withIP(trustProxy bool) func(http.Handler) http.Handler {
	return func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			ctx := contextWithIP(r.Context(), clientIP(r, trustProxy))
			next.ServeHTTP(w, r.WithContext(ctx))
		})
	}
}
