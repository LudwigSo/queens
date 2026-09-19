// Package api is the HTTP layer: Huma v2 over chi. The handlers are thin; every
// decision lives in internal/service.
package api

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"

	"github.com/danielgtaylor/huma/v2"
	"github.com/ludwigsonnenberg/queens-server/internal/domain"
)

// Problem is RFC 9457 application/problem+json plus the two fields the client
// needs: a stable ERR_* code and its positional parameters. The client turns
// them into a localised sentence; the server never sends prose.
type Problem struct {
	Type     string              `json:"type,omitempty"`
	Title    string              `json:"title"`
	Status   int                 `json:"status"`
	Detail   string              `json:"detail,omitempty" doc:"English, for developers. Never shown to a player."`
	Instance string              `json:"instance,omitempty" doc:"Request id."`
	Code     string              `json:"code" doc:"ERR_* key the client localises."`
	Params   []any               `json:"params" doc:"Positional parameters for the localised string."`
	Errors   []*huma.ErrorDetail `json:"errors,omitempty" doc:"Field-level validation details."`
}

func (p *Problem) Error() string { return p.Code }

func (p *Problem) GetStatus() int { return p.Status }

func (p *Problem) ContentType(ct string) string {
	if ct == "application/json" {
		return "application/problem+json"
	}
	return ct
}

// fieldCodes upgrades a generic validation failure to the specific code the
// client already has a translation for.
var fieldCodes = map[string]string{
	"body.nickname": domain.CodeNicknameLength,
	"body.code":     domain.CodeFriendCodeFmt,
}

func codeForStatus(status int) string {
	switch status {
	case http.StatusUnauthorized:
		return domain.CodeUnauthorized
	case http.StatusForbidden:
		return domain.CodeBanned
	case http.StatusTooManyRequests:
		return domain.CodeRateLimited
	case http.StatusInternalServerError, http.StatusBadGateway,
		http.StatusServiceUnavailable, http.StatusGatewayTimeout:
		return domain.CodeServer
	default:
		return domain.CodeBadRequest
	}
}

// InstallProblemErrors makes Huma's own validation failures carry a code too,
// so the client has exactly one way to render an error.
func InstallProblemErrors() {
	huma.NewError = func(status int, msg string, errs ...error) huma.StatusError {
		p := &Problem{
			Title:  http.StatusText(status),
			Status: status,
			Detail: msg,
			Code:   codeForStatus(status),
			Params: []any{},
		}
		for _, e := range errs {
			var d *huma.ErrorDetail
			if errors.As(e, &d) {
				p.Errors = append(p.Errors, d)
				if c, ok := fieldCodes[d.Location]; ok && p.Code == domain.CodeBadRequest {
					p.Code = c // the first mapped location wins
				}
			}
		}
		return p
	}
}

// fromError turns anything a service returned into a Problem.
func fromError(err error) *Problem {
	var ce *domain.CodedError
	if errors.As(err, &ce) {
		params := ce.Params
		if params == nil {
			params = []any{}
		}
		return &Problem{
			Title: http.StatusText(ce.Status), Status: ce.Status,
			Code: ce.Code, Params: params, Detail: ce.Detail,
		}
	}
	if errors.Is(err, domain.ErrNotFound) {
		return &Problem{Title: http.StatusText(404), Status: 404, Code: domain.CodeBadRequest, Params: []any{}}
	}
	return &Problem{
		Title: http.StatusText(500), Status: 500, Code: domain.CodeServer, Params: []any{},
		Detail: err.Error(),
	}
}

// errorOf is what every handler returns: nil on success.
func errorOf(err error) error {
	if err == nil {
		return nil
	}
	return fromError(err)
}

// writeProblem emits a Problem from plain middleware, which is outside Huma.
func writeProblem(w http.ResponseWriter, p *Problem) {
	if p.Params == nil {
		p.Params = []any{}
	}
	w.Header().Set("Content-Type", "application/problem+json")
	w.WriteHeader(p.Status)
	_ = json.NewEncoder(w).Encode(p)
}

func contextWithIP(ctx context.Context, ip string) context.Context {
	return context.WithValue(ctx, ipKey, ip)
}

// ipFrom is the rate-limit key. It is never used to ban or flag a player:
// carriers put tens of thousands of people behind one address.
func ipFrom(ctx context.Context) string {
	ip, _ := ctx.Value(ipKey).(string)
	if ip == "" {
		return "unknown"
	}
	return ip
}
