package service

import (
	"context"
	"log/slog"

	"github.com/ludwigsonnenberg/queens-server/internal/domain"
	"github.com/ludwigsonnenberg/queens-server/internal/store"
)

// Sweep drops what has aged out. Sessions are the bulk of it: they are only
// useful for the 30-day acceptance window, and the consumed ones are kept a
// while longer so a flag can still name the session it came from.
func (s *Service) Sweep(ctx context.Context) error {
	now := s.now()
	return s.St.InTx(ctx, func(ctx context.Context, r store.Repos) error {
		n, err := r.Sessions.DeleteUnconsumedBefore(ctx, now-domain.SessionAcceptance)
		if err != nil {
			return err
		}
		m, err := r.Sessions.DeleteConsumedBefore(ctx, now-90*86400)
		if err != nil {
			return err
		}
		// Yesterday's daily counters are no longer consulted.
		c, err := r.Rates.DeleteBefore(ctx, now/86400-1)
		if err != nil {
			return err
		}
		// Flags are an audit log: keep them long enough to answer "I was
		// excluded and I did not cheat", not forever.
		f, err := r.Flags.DeleteBefore(ctx, now-180*86400)
		if err != nil {
			return err
		}
		t, err := r.Players.DeleteRevokedTokensBefore(ctx, now-30*86400)
		if err != nil {
			return err
		}
		if n+m+c+f+t > 0 {
			slog.Info("swept", "sessions_unconsumed", n, "sessions_consumed", m,
				"rate_counters", c, "flags", f, "tokens", t)
		}
		return nil
	})
}
