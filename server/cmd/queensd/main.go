// Command queensd is the Queens backend: one static binary that serves the API,
// runs its own migrations, closes league rounds on a ticker and takes nightly
// backups.
package main

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/ludwigsonnenberg/queens-server/internal/api"
	"github.com/ludwigsonnenberg/queens-server/internal/config"
	"github.com/ludwigsonnenberg/queens-server/internal/domain"
	"github.com/ludwigsonnenberg/queens-server/internal/levelset"
	"github.com/ludwigsonnenberg/queens-server/internal/service"
	"github.com/ludwigsonnenberg/queens-server/internal/store/sqlite"
)

// version is set by the linker in CI.
var version = "dev"

func main() {
	if err := run(); err != nil {
		fmt.Fprintln(os.Stderr, "queensd:", err)
		os.Exit(1)
	}
}

func usage() string {
	return `usage: queensd [command]

  serve            run the API (default)
  migrate          apply migrations and exit
  openapi -o FILE  write the OpenAPI document and exit
  backup -o FILE   write a consistent copy of the database and exit
  admin ...        operational commands (see: queensd admin)
`
}

func run() error {
	cmd := "serve"
	if len(os.Args) > 1 {
		cmd = os.Args[1]
	}
	switch cmd {
	case "serve":
		return serve()
	case "migrate":
		return migrateOnly()
	case "openapi":
		return writeOpenAPI(os.Args[2:])
	case "backup":
		return backupCmd(os.Args[2:])
	case "admin":
		return adminCmd(os.Args[2:])
	case "version":
		fmt.Println(version)
		return nil
	case "-h", "--help", "help":
		fmt.Print(usage())
		return nil
	default:
		return fmt.Errorf("unknown command %q\n\n%s", cmd, usage())
	}
}

func setupLogger(cfg *config.Config) {
	opts := &slog.HandlerOptions{Level: cfg.LogLevel}
	var h slog.Handler
	if cfg.IsDev() {
		h = slog.NewTextHandler(os.Stderr, opts)
	} else {
		h = slog.NewJSONHandler(os.Stderr, opts)
	}
	slog.SetDefault(slog.New(h))
}

// open runs the migrations and the level import, then builds the service.
func open(ctx context.Context, cfg *config.Config) (*sqlite.DB, *service.Service, error) {
	db, err := sqlite.Open(cfg.DBPath)
	if err != nil {
		return nil, nil, err
	}
	clock := domain.SystemClock{}
	if err := db.Migrate(ctx, clock.Now()); err != nil {
		db.Close()
		return nil, nil, err
	}
	// Levels are data, not schema: the file is re-imported on every boot. A
	// changed size or difficulty refuses to start here rather than silently
	// invalidating every past score on that level.
	setHash, err := levelset.Sync(ctx, db, levelset.Embedded(), clock.Now())
	if err != nil {
		db.Close()
		return nil, nil, err
	}
	levels, err := db.Repos().Levels.All(ctx)
	if err != nil {
		db.Close()
		return nil, nil, err
	}
	league := domain.DefaultLeagueConfig()
	svc := service.New(db, cfg, clock, league, domain.LeagueConfigHash(), setHash, levels)
	return db, svc, nil
}

func serve() error {
	cfg, err := config.Load()
	if err != nil {
		return err
	}
	setupLogger(cfg)

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	db, svc, err := open(ctx, cfg)
	if err != nil {
		return err
	}
	defer db.Close()
	slog.Info("starting", "version", version, "env", cfg.Env, "db", cfg.DBPath,
		"levels", svc.LevelCount(), "level_set", svc.LevelSetHash)

	srv := api.New(svc, cfg)
	done := make(chan struct{})
	srv.Limits.StartJanitor(done)
	go roundTicker(ctx, svc)
	go sweeper(ctx, svc)
	if cfg.BackupDir != "" {
		go backupLoop(ctx, db, cfg)
	}

	httpSrv := &http.Server{
		Addr:              cfg.Addr,
		Handler:           srv.Router,
		ReadHeaderTimeout: 10 * time.Second,
	}
	errCh := make(chan error, 1)
	go func() {
		slog.Info("listening", "addr", cfg.Addr)
		if err := httpSrv.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
			errCh <- err
		}
	}()

	select {
	case err := <-errCh:
		return err
	case <-ctx.Done():
	}

	slog.Info("shutting down")
	shutCtx, cancel := context.WithTimeout(context.Background(), cfg.ShutdownTimeout)
	defer cancel()
	if err := httpSrv.Shutdown(shutCtx); err != nil {
		slog.Error("graceful shutdown failed", "err", err)
	}
	close(done)
	// Truncate the write-ahead log so the file left behind is a plain database.
	if err := db.Checkpoint(context.Background()); err != nil {
		slog.Error("checkpoint failed", "err", err)
	}
	slog.Info("stopped")
	return nil
}

// roundTicker is the primary round closer. The lazy catch-up on the read paths
// is what makes a cold start, a crashed ticker and a suspended machine heal
// themselves; this keeps the common case cheap.
func roundTicker(ctx context.Context, svc *service.Service) {
	t := time.NewTicker(60 * time.Second)
	defer t.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-t.C:
			if err := svc.CloseDueRounds(ctx); err != nil {
				slog.Error("round ticker", "err", err)
			}
		}
	}
}

func sweeper(ctx context.Context, svc *service.Service) {
	t := time.NewTicker(time.Hour)
	defer t.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-t.C:
			if err := svc.Sweep(ctx); err != nil {
				slog.Error("sweeper", "err", err)
			}
		}
	}
}

func backupLoop(ctx context.Context, db *sqlite.DB, cfg *config.Config) {
	t := time.NewTicker(15 * time.Minute)
	defer t.Stop()
	var lastDay string
	for {
		select {
		case <-ctx.Done():
			return
		case now := <-t.C:
			utc := now.UTC()
			day := utc.Format("20060102")
			if utc.Hour() != cfg.BackupHourUTC || day == lastDay {
				continue
			}
			if err := runBackup(ctx, db, cfg.BackupDir, day); err != nil {
				slog.Error("backup", "err", err)
				continue
			}
			lastDay = day
		}
	}
}

func migrateOnly() error {
	cfg, err := config.Load()
	if err != nil {
		return err
	}
	setupLogger(cfg)
	db, svc, err := open(context.Background(), cfg)
	if err != nil {
		return err
	}
	defer db.Close()
	slog.Info("migrated", "db", cfg.DBPath, "levels", svc.LevelCount())
	return nil
}
