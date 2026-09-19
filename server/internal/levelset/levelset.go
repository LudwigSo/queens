// Package levelset owns the level table. Levels are DATA, not schema: the file
// is re-imported on every boot (about 100 rows, milliseconds) rather than
// shipped as a migration.
//
//go:generate go run ./internal/levelset/cmd/copylevels
package levelset

import (
	"context"
	"crypto/sha256"
	_ "embed"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"log/slog"
	"sort"

	"github.com/ludwigsonnenberg/queens-server/internal/domain"
	"github.com/ludwigsonnenberg/queens-server/internal/store"
)

// queens.json is a COPY of queens/levels/queens.json: Go embed cannot reach
// outside its module. TestLevelFileInSync is the enforcement and the copier in
// cmd/copylevels is the fix.
//
//go:embed queens.json
var levelJSON []byte

// File is the on-disk shape: an object, not an array.
type File struct {
	Format int         `json:"format"`
	Game   string      `json:"game"`
	Levels []FileLevel `json:"levels"`
}

type FileLevel struct {
	ID         string  `json:"id"`
	Size       int     `json:"size"`
	Regions    [][]int `json:"regions"`
	Solution   []int   `json:"solution"`
	Difficulty int     `json:"difficulty"`
	Stars      int     `json:"stars"`
	Seed       int     `json:"seed"`
}

func Parse(data []byte) (*File, error) {
	var f File
	if err := json.Unmarshal(data, &f); err != nil {
		return nil, fmt.Errorf("level file: %w", err)
	}
	if len(f.Levels) == 0 {
		return nil, fmt.Errorf("level file: no levels")
	}
	seen := map[string]bool{}
	for _, l := range f.Levels {
		if l.ID == "" {
			return nil, fmt.Errorf("level file: an entry has no id")
		}
		if seen[l.ID] {
			return nil, fmt.Errorf("level file: duplicate id %s", l.ID)
		}
		seen[l.ID] = true
		if l.Size < 4 || l.Size > 20 {
			return nil, fmt.Errorf("level %s: implausible size %d", l.ID, l.Size)
		}
		if len(l.Regions) != l.Size || len(l.Solution) != l.Size {
			return nil, fmt.Errorf("level %s: regions/solution do not match size %d", l.ID, l.Size)
		}
		for _, row := range l.Regions {
			if len(row) != l.Size {
				return nil, fmt.Errorf("level %s: a region row is not %d wide", l.ID, l.Size)
			}
		}
	}
	return &f, nil
}

func Embedded() []byte { return levelJSON }

// contentHash covers every field that matters, so a cosmetic edit changes it and
// the level-set ETag with it.
func contentHash(l FileLevel) string {
	b, _ := json.Marshal(struct {
		ID         string  `json:"id"`
		Size       int     `json:"size"`
		Regions    [][]int `json:"regions"`
		Solution   []int   `json:"solution"`
		Difficulty int     `json:"difficulty"`
		Stars      int     `json:"stars"`
		Seed       int     `json:"seed"`
	}{l.ID, l.Size, l.Regions, l.Solution, l.Difficulty, l.Stars, l.Seed})
	sum := sha256.Sum256(b)
	return hex.EncodeToString(sum[:])
}

// SetHash is the hash of the sorted (id, content_hash) list. It is the ETag of
// GET /levels/meta.
func SetHash(pairs [][2]string) string {
	sort.Slice(pairs, func(i, j int) bool { return pairs[i][0] < pairs[j][0] })
	h := sha256.New()
	for _, p := range pairs {
		h.Write([]byte(p[0]))
		h.Write([]byte{0})
		h.Write([]byte(p[1]))
		h.Write([]byte{'\n'})
	}
	return hex.EncodeToString(h.Sum(nil))
}

// Sync upserts the level file into the database and returns the level-set hash.
//
// A changed `size` or `difficulty` REFUSES TO START, naming the id: base and
// par_seconds derive from both, so changing one silently invalidates every past
// score on that level. Cosmetic changes (stars, seed, regions) are applied. A
// level that disappears from the file is kept forever and only logged: old
// results and leaderboard rows still point at it.
//
// Release ordering rule: deploy the server before shipping a client with new
// levels. An old server answers ERR_LEVEL_UNKNOWN and the client falls back to
// offline play for that level rather than blocking the game.
func Sync(ctx context.Context, st store.Store, data []byte, now int64) (string, error) {
	f, err := Parse(data)
	if err != nil {
		return "", err
	}
	var setHash string
	err = st.InTx(ctx, func(ctx context.Context, repos store.Repos) error {
		pairs := make([][2]string, 0, len(f.Levels))
		keep := make([]string, 0, len(f.Levels))
		for _, l := range f.Levels {
			hash := contentHash(l)
			pairs = append(pairs, [2]string{l.ID, hash})
			keep = append(keep, l.ID)

			existing, err := repos.Levels.Get(ctx, l.ID)
			switch {
			case err == domain.ErrNotFound:
				// new level
			case err != nil:
				return err
			default:
				if existing.Size != l.Size || existing.Difficulty != l.Difficulty {
					return fmt.Errorf(
						"level %s changed size or difficulty (%d/%d -> %d/%d): every past score on it would be invalid; "+
							"give the changed board a new id instead",
						l.ID, existing.Size, existing.Difficulty, l.Size, l.Difficulty)
				}
				if existing.ContentHash == hash {
					continue
				}
			}
			regions, _ := json.Marshal(l.Regions)
			solution, _ := json.Marshal(l.Solution)
			lv := &domain.Level{
				ID: l.ID, Size: l.Size, Difficulty: l.Difficulty, Stars: l.Stars, Seed: l.Seed,
				RegionsJSON: string(regions), SolutionJSON: string(solution), ContentHash: hash,
			}
			if err := repos.Levels.Upsert(ctx, lv, now); err != nil {
				return err
			}
		}
		gone, err := repos.Levels.MarkNotInSet(ctx, keep, now)
		if err != nil {
			return err
		}
		for _, id := range gone {
			slog.Warn("level is no longer in the shipped file; keeping the row", "level_id", id)
		}
		setHash = SetHash(pairs)
		return repos.Levels.InsertLevelSet(ctx, setHash, len(f.Levels), now)
	})
	if err != nil {
		return "", err
	}
	return setHash, nil
}
