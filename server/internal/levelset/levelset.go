// Package levelset owns the level table. Levels are DATA, not schema, and they
// are append-only: a level file is imported additively, on every boot (the copy
// embedded in the binary) and by `queensd admin levels import` (any file, at
// run time). Clients download what they do not have yet, so a new level needs
// neither a client release nor a server deploy.
package levelset

import (
	"context"
	"crypto/sha256"
	_ "embed"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"sort"

	"github.com/ludwigsonnenberg/queens-server/internal/domain"
	"github.com/ludwigsonnenberg/queens-server/internal/store"
)

// queens.json is a COPY of queens/levels/queens.json: Go embed cannot reach
// outside its module. TestLevelFileInSync is the enforcement and the copier in
// cmd/copylevels is the fix (run it from server/: go run ./internal/levelset/cmd/copylevels).
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

// Parse decodes a level file and validates every board, including that its
// solution is the only one. Nothing in a file that fails here is imported.
func Parse(data []byte) (*File, error) {
	var f File
	if err := json.Unmarshal(data, &f); err != nil {
		return nil, fmt.Errorf("level file: %w", err)
	}
	if f.Format != 1 {
		return nil, fmt.Errorf("level file: unsupported format %d", f.Format)
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
		if err := domain.ValidateBoard(l.Size, l.Regions, l.Solution); err != nil {
			return nil, fmt.Errorf("level %s: %w", l.ID, err)
		}
		if l.Stars < 1 || l.Stars > 5 {
			return nil, fmt.Errorf("level %s: stars %d outside 1..5", l.ID, l.Stars)
		}
	}
	return &f, nil
}

func Embedded() []byte { return levelJSON }

// ContentHash covers every field that matters. Two files that disagree on any
// of them for the same id disagree on the hash, which is how Import tells an
// edited board from a re-import.
func ContentHash(l FileLevel) string {
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

// Report says what an import did.
type Report struct {
	Added     int    // new levels, published after the last one
	Published int    // stored but unpublished levels that got a position
	Unchanged int    // already published, identical
	Total     int    // published levels after the import
	SetHash   string // hash over every stored level
}

// Import adds the file's levels to the database, inside the given repos (one
// transaction). It is additive and idempotent:
//
//   - A new id is stored and published after the current last position, in
//     file order. Clients see it the next time they compare level counts.
//   - A known id must be byte-for-byte the same board. Anything else -- a
//     different size, difficulty, region, solution, even stars -- is REFUSED,
//     naming the id. Clients compare counts, not contents, so an edited level
//     would never reach a device that already has the old one, and scores on it
//     would compare different puzzles. Give a fixed board a new id instead.
//   - A level missing from the file is left alone. Nothing is ever unpublished.
//
// A stored level without a position (position 0: rows from before imports were
// additive, or the first boot after migration 0003) is published in file
// order, which reproduces the order of the file bundled in the APK.
func Import(ctx context.Context, repos store.Repos, f *File, now int64) (Report, error) {
	var rep Report
	next, err := repos.Levels.MaxPosition(ctx)
	if err != nil {
		return rep, err
	}
	for _, l := range f.Levels {
		hash := ContentHash(l)
		existing, err := repos.Levels.Get(ctx, l.ID)
		switch {
		case err == domain.ErrNotFound:
			regions, _ := json.Marshal(l.Regions)
			solution, _ := json.Marshal(l.Solution)
			next++
			if err := repos.Levels.Insert(ctx, &domain.Level{
				ID: l.ID, Size: l.Size, Difficulty: l.Difficulty, Stars: l.Stars, Seed: l.Seed,
				RegionsJSON: string(regions), SolutionJSON: string(solution), ContentHash: hash, Position: next,
			}, now); err != nil {
				return rep, err
			}
			rep.Added++
			continue
		case err != nil:
			return rep, err
		}
		if existing.ContentHash != hash {
			return rep, fmt.Errorf("level %s differs from the stored board (size/difficulty %d/%d -> %d/%d); "+
				"published levels are immutable, give the changed board a new id instead",
				l.ID, existing.Size, existing.Difficulty, l.Size, l.Difficulty)
		}
		if existing.Position == 0 {
			next++
			if err := repos.Levels.Publish(ctx, l.ID, next, now); err != nil {
				return rep, err
			}
			rep.Published++
			continue
		}
		rep.Unchanged++
	}

	all, err := repos.Levels.All(ctx)
	if err != nil {
		return rep, err
	}
	pairs := make([][2]string, 0, len(all))
	for _, l := range all {
		pairs = append(pairs, [2]string{l.ID, l.ContentHash})
	}
	rep.SetHash = SetHash(pairs)
	if rep.Total, err = repos.Levels.CountPublished(ctx); err != nil {
		return rep, err
	}
	if err := repos.Levels.InsertLevelSet(ctx, rep.SetHash, rep.Total, now); err != nil {
		return rep, err
	}
	return rep, nil
}

// Sync imports a level file in its own transaction. Boot calls it with the
// embedded file; a refusal stops the server from starting.
func Sync(ctx context.Context, st store.Store, data []byte, now int64) (Report, error) {
	f, err := Parse(data)
	if err != nil {
		return Report{}, err
	}
	var rep Report
	err = st.InTx(ctx, func(ctx context.Context, repos store.Repos) error {
		var err error
		rep, err = Import(ctx, repos, f, now)
		return err
	})
	return rep, err
}
