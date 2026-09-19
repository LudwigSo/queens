package main

import (
	"context"
	"flag"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"

	"github.com/danielgtaylor/huma/v2"
	"github.com/ludwigsonnenberg/queens-server/internal/api"
	"github.com/ludwigsonnenberg/queens-server/internal/config"
	"github.com/ludwigsonnenberg/queens-server/internal/domain"
	"github.com/ludwigsonnenberg/queens-server/internal/service"
	"github.com/ludwigsonnenberg/queens-server/internal/store"
	"github.com/ludwigsonnenberg/queens-server/internal/store/sqlite"
)

// OpenAPIDocument builds the spec without touching a database, so the drift test
// and the generator can both call it.
func OpenAPIDocument() ([]byte, error) {
	cfg := &config.Config{
		Env: "dev", TokenPepper: "spec", CooldownSeconds: domain.CooldownDefault,
		SessionTTL: domain.SessionFreshness, RequestTimeout: 10 * time.Second, MaxBodyBytes: 32 << 10,
	}
	svc := service.New(nil, cfg, domain.SystemClock{}, domain.DefaultLeagueConfig(),
		domain.LeagueConfigHash(), "", nil)
	srv := api.New(svc, cfg)
	return srv.API.OpenAPI().YAML()
}

func writeOpenAPI(args []string) error {
	fs := flag.NewFlagSet("openapi", flag.ExitOnError)
	out := fs.String("o", "openapi.yaml", "output file")
	if err := fs.Parse(args); err != nil {
		return err
	}
	data, err := OpenAPIDocument()
	if err != nil {
		return err
	}
	if *out == "-" {
		_, err := os.Stdout.Write(data)
		return err
	}
	if err := os.WriteFile(*out, data, 0o644); err != nil {
		return err
	}
	fmt.Printf("wrote %s (%d bytes)\n", *out, len(data))
	return nil
}

var _ huma.API // keep the huma import meaningful if the helper above changes

func backupCmd(args []string) error {
	fs := flag.NewFlagSet("backup", flag.ExitOnError)
	out := fs.String("o", "", "output file (default: <QUEENS_BACKUP_DIR>/queens-<date>.db)")
	if err := fs.Parse(args); err != nil {
		return err
	}
	cfg, err := config.Load()
	if err != nil {
		return err
	}
	setupLogger(cfg)
	db, err := sqlite.Open(cfg.DBPath)
	if err != nil {
		return err
	}
	defer db.Close()
	if *out != "" {
		return backupTo(context.Background(), db, *out)
	}
	if cfg.BackupDir == "" {
		return fmt.Errorf("pass -o or set QUEENS_BACKUP_DIR")
	}
	return runBackup(context.Background(), db, cfg.BackupDir, time.Now().UTC().Format("20060102"))
}

func backupTo(ctx context.Context, db *sqlite.DB, path string) error {
	tmp := path + ".tmp"
	_ = os.Remove(tmp)
	if err := db.BackupTo(ctx, tmp); err != nil {
		return err
	}
	if err := os.Rename(tmp, path); err != nil {
		return err
	}
	fmt.Println("wrote", path)
	return nil
}

// runBackup writes one dated copy and keeps the newest 14.
func runBackup(ctx context.Context, db *sqlite.DB, dir, day string) error {
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return err
	}
	if err := backupTo(ctx, db, filepath.Join(dir, "queens-"+day+".db")); err != nil {
		return err
	}
	entries, err := os.ReadDir(dir)
	if err != nil {
		return err
	}
	var names []string
	for _, e := range entries {
		if !e.IsDir() && strings.HasPrefix(e.Name(), "queens-") && strings.HasSuffix(e.Name(), ".db") {
			names = append(names, e.Name())
		}
	}
	sort.Sort(sort.Reverse(sort.StringSlice(names)))
	for i := 14; i < len(names); i++ {
		_ = os.Remove(filepath.Join(dir, names[i]))
	}
	return nil
}

func adminUsage() string {
	return `usage: queensd admin <command>

  flags --player ID [--limit N]   list a player's anti-cheat signals
  exclude --player ID             shadow-exclude (quarantine groups, hidden boards)
  unexclude --player ID           clear a shadow exclusion and reset the score
  ban --player ID                 block the account (403 on every request)
  unban --player ID
  rename --player ID --to NAME    rename a player (the moderation remedy)
  players [--limit N]             list recent players

There is no admin HTTP surface: that is an authentication, authorisation and
audit problem this service does not need on day one.
`
}

func adminCmd(args []string) error {
	if len(args) == 0 {
		fmt.Print(adminUsage())
		return nil
	}
	sub := args[0]
	fs := flag.NewFlagSet("admin "+sub, flag.ExitOnError)
	player := fs.String("player", "", "player id")
	to := fs.String("to", "", "new nickname (rename)")
	limit := fs.Int("limit", 50, "maximum rows")
	if err := fs.Parse(args[1:]); err != nil {
		return err
	}

	cfg, err := config.Load()
	if err != nil {
		return err
	}
	setupLogger(cfg)
	ctx := context.Background()
	db, svc, err := open(ctx, cfg)
	if err != nil {
		return err
	}
	defer db.Close()

	needsPlayer := func() error {
		if *player == "" {
			return fmt.Errorf("--player is required")
		}
		return nil
	}

	switch sub {
	case "flags":
		if err := needsPlayer(); err != nil {
			return err
		}
		flags, err := db.Repos().Flags.ListByPlayer(ctx, *player, *limit)
		if err != nil {
			return err
		}
		score, updatedAt, shadow, err := db.Repos().Flags.ReadAnomaly(ctx, *player)
		if err != nil {
			return err
		}
		now := svc.Clock.Now()
		fmt.Printf("anomaly %.2f (decayed %.2f), shadow_excluded=%v\n",
			score, domain.DecayAnomaly(score, updatedAt, now), shadow)
		for _, f := range flags {
			detail := ""
			if f.DetailJSON != nil {
				detail = *f.DetailJSON
			}
			fmt.Printf("%s  %-26s %4.1f  %s\n",
				time.Unix(f.CreatedAt, 0).UTC().Format(time.RFC3339), f.Signal, f.Weight, detail)
		}
		return nil

	case "exclude", "unexclude":
		if err := needsPlayer(); err != nil {
			return err
		}
		return db.InTx(ctx, func(ctx context.Context, r store.Repos) error {
			score, updatedAt, _, err := r.Flags.ReadAnomaly(ctx, *player)
			if err != nil {
				return err
			}
			if sub == "unexclude" {
				// Reset the score too, or the next flag would re-exclude at once.
				score, updatedAt = 0, svc.Clock.Now()
			}
			return r.Flags.WriteAnomaly(ctx, *player, score, updatedAt, sub == "exclude")
		})

	case "ban", "unban":
		if err := needsPlayer(); err != nil {
			return err
		}
		var at *int64
		if sub == "ban" {
			now := svc.Clock.Now()
			at = &now
		}
		return db.Repos().Players.SetBanned(ctx, *player, at)

	case "rename":
		if err := needsPlayer(); err != nil {
			return err
		}
		if *to == "" {
			return fmt.Errorf("--to is required")
		}
		nick, err := domain.NormalizeNickname(*to)
		if err != nil {
			return err
		}
		return db.Repos().Players.UpdateNickname(ctx, *player, nick, svc.Clock.Now())

	case "players":
		players, err := db.Repos().Players.List(ctx, *limit)
		if err != nil {
			return err
		}
		for _, p := range players {
			fmt.Printf("%s  %-16s %-10s pts=%-6d games=%-4d %s\n",
				p.ID, p.Nickname, p.Tier, p.TierPoints, p.Games, p.FriendCode)
		}
		return nil

	default:
		return fmt.Errorf("unknown admin command %q\n\n%s", sub, adminUsage())
	}
}
