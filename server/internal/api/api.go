package api

import (
	"context"
	"net/http"
	"strings"
	"time"

	"github.com/danielgtaylor/huma/v2"
	"github.com/danielgtaylor/huma/v2/adapters/humachi"
	"github.com/go-chi/chi/v5"
	"github.com/go-chi/chi/v5/middleware"
	"github.com/ludwigsonnenberg/queens-server/internal/config"
	"github.com/ludwigsonnenberg/queens-server/internal/domain"
	"github.com/ludwigsonnenberg/queens-server/internal/service"
)

type Server struct {
	Svc    *service.Service
	Cfg    *config.Config
	Limits *Limits
	Router chi.Router
	API    huma.API
}

// New wires the middleware chain, outermost first:
//
//	RealIP (only behind a trusted proxy) -> RequestID -> Recoverer -> Timeout
//	-> serverTime -> accessLog -> maxBytes -> Huma
//
// /healthz and /readyz are registered on chi directly so they stay out of the
// generated OpenAPI document.
func New(svc *service.Service, cfg *config.Config) *Server {
	InstallProblemErrors()

	r := chi.NewRouter()
	if cfg.TrustProxy {
		r.Use(middleware.RealIP)
	}
	r.Use(middleware.RequestID)
	r.Use(middleware.Recoverer)
	r.Use(middleware.Timeout(cfg.RequestTimeout))
	r.Use(serverTime(svc.Clock))
	r.Use(accessLog)
	r.Use(maxBytes(cfg.MaxBodyBytes))
	r.Use(withIP(cfg.TrustProxy))

	s := &Server{Svc: svc, Cfg: cfg, Limits: NewLimits(), Router: r}

	r.NotFound(func(w http.ResponseWriter, req *http.Request) {
		writeProblem(w, &Problem{Title: "Not Found", Status: 404, Code: domain.CodeBadRequest})
	})
	r.MethodNotAllowed(func(w http.ResponseWriter, req *http.Request) {
		writeProblem(w, &Problem{Title: "Method Not Allowed", Status: 405, Code: domain.CodeBadRequest})
	})
	r.Get("/healthz", func(w http.ResponseWriter, req *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"status":"ok"}`))
	})
	r.Get("/readyz", func(w http.ResponseWriter, req *http.Request) {
		ctx, cancel := context.WithTimeout(req.Context(), 2*time.Second)
		defer cancel()
		if err := svc.St.Ping(ctx); err != nil {
			writeProblem(w, &Problem{Title: "Service Unavailable", Status: 503, Code: domain.CodeServer})
			return
		}
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"status":"ready"}`))
	})

	humaCfg := huma.DefaultConfig("Queens API", "1.0.0")
	humaCfg.Info.Description = "Identity, results, per-level leaderboards, the league and friends for the Queens puzzle game. " +
		"Errors are application/problem+json and carry a stable ERR_* code plus positional params; the client localises them."
	humaCfg.Servers = []*huma.Server{{URL: "/"}}
	humaCfg.DocsPath = "/docs"
	humaCfg.OpenAPIPath = "/openapi"
	s.API = humachi.New(r, humaCfg)
	s.register()
	return s
}

// auth resolves the bearer token and returns the player, or a Problem.
func (s *Server) auth(ctx context.Context, header string) (*domain.Player, error) {
	token := strings.TrimSpace(strings.TrimPrefix(header, "Bearer "))
	p, err := s.Svc.ResolveToken(ctx, token)
	if err != nil {
		return nil, fromError(err)
	}
	return p, nil
}

// limitPlayer and limitIP return a 429 Problem or nil.
func (s *Server) limit(l *limiter, key string) error {
	ok, retry := l.allow(key, time.Now())
	if ok {
		return nil
	}
	return tooMany(retry)
}

// AuthHeader is embedded in every authenticated request. It is deliberately NOT
// marked required: a missing header must come out as 401 ERR_UNAUTHORIZED from
// the resolver, not as a 422 schema violation, so the client has exactly one
// code path for "not signed in".
type AuthHeader struct {
	Authorization string `header:"Authorization" doc:"Bearer <token>"`
}
