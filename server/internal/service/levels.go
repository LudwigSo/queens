package service

import (
	"context"
	"encoding/json"
	"fmt"

	"github.com/ludwigsonnenberg/queens-server/internal/domain"
)

// Level sync. A client compares its own level count with LevelCount at
// launch; on a difference it asks for LevelIDs, diffs them against what it
// holds and downloads the rest with LevelsByID. Published levels are
// append-only and immutable, which is what makes "same count, same set" true.

// MaxLevelsPerRequest bounds GET /v1/levels.
const MaxLevelsPerRequest = 50

// LevelView is one downloadable board. Field names match queens/levels/queens.json
// so the client parses a download with the code that reads its bundled file.
//
// It carries the solution. Every other endpoint keeps it out (TestSolutionNeverLeaks):
// the client needs it to mark a wrong queen and to give hints, and the same
// solutions ship inside the APK for every bundled level anyway.
type LevelView struct {
	ID         string  `json:"id"`
	Position   int     `json:"position" doc:"Order in the game: 1, 2, ... Append-only."`
	Size       int     `json:"size"`
	Regions    [][]int `json:"regions" doc:"Row-major region id per cell."`
	Solution   []int   `json:"solution" doc:"Queen column per row."`
	Difficulty int     `json:"difficulty"`
	Stars      int     `json:"stars"`
	Seed       int     `json:"seed"`
}

// LevelCount is the number of published levels, read from the database rather
// than the in-memory index so an import shows up immediately.
func (s *Service) LevelCount(ctx context.Context) (int, error) {
	if err := s.refreshLevels(ctx); err != nil {
		return 0, err
	}
	return s.St.Repos().Levels.CountPublished(ctx)
}

// LevelIDs lists every published level id in game order.
func (s *Service) LevelIDs(ctx context.Context) ([]string, error) {
	levels, err := s.St.Repos().Levels.Published(ctx)
	if err != nil {
		return nil, err
	}
	ids := make([]string, len(levels))
	for i, l := range levels {
		ids[i] = l.ID
	}
	return ids, nil
}

// LevelsByID returns the published boards among ids, in game order. Unknown ids
// are skipped rather than failing the batch: the client logs what is missing.
func (s *Service) LevelsByID(ctx context.Context, ids []string) ([]LevelView, error) {
	if len(ids) > MaxLevelsPerRequest {
		return nil, domain.Errf(422, domain.CodeBadRequest, fmt.Sprintf("at most %d ids", MaxLevelsPerRequest))
	}
	levels, err := s.St.Repos().Levels.GetMany(ctx, ids)
	if err != nil {
		return nil, err
	}
	out := make([]LevelView, 0, len(levels))
	for _, l := range levels {
		v := LevelView{ID: l.ID, Position: l.Position, Size: l.Size, Difficulty: l.Difficulty, Stars: l.Stars, Seed: l.Seed}
		if err := json.Unmarshal([]byte(l.RegionsJSON), &v.Regions); err != nil {
			return nil, fmt.Errorf("level %s regions: %w", l.ID, err)
		}
		if err := json.Unmarshal([]byte(l.SolutionJSON), &v.Solution); err != nil {
			return nil, fmt.Errorf("level %s solution: %w", l.ID, err)
		}
		out = append(out, v)
	}
	return out, nil
}

// LevelState is a player's state on one level: the server-side twin of the
// `levels` entry in the client's save.json, with the same keys.
type LevelState struct {
	LastStartedAt   int64   `json:"last_started_at"`
	Plays           int     `json:"plays"`
	Completions     int     `json:"completions"`
	LastCompletedAt int64   `json:"last_completed_at"`
	BestTime        float64 `json:"best_time" doc:"Fastest completed run in seconds; 0 = none."`
	BestScore       int     `json:"best_score"`
	BestScoreTime   float64 `json:"best_score_time"`
	BestWrong       int     `json:"best_wrong"`
	BestResultID    string  `json:"best_result_id" doc:"\"\" = no completed run."`
	BestAt          int64   `json:"best_at"`
}

// MyLevelStates returns the player's state on every level they ever started.
func (s *Service) MyLevelStates(ctx context.Context, playerID string) (map[string]LevelState, error) {
	rows, err := s.St.Repos().Levels.ListPlayerLevels(ctx, playerID)
	if err != nil {
		return nil, err
	}
	out := make(map[string]LevelState, len(rows))
	for _, pl := range rows {
		out[pl.LevelID] = LevelState{
			LastStartedAt: pl.LastStartedAt, Plays: pl.Plays, Completions: pl.Completions,
			LastCompletedAt: pl.LastCompletedAt, BestTime: pl.BestTime, BestScore: pl.BestScore,
			BestScoreTime: pl.BestScoreTime, BestWrong: pl.BestWrong, BestResultID: pl.BestResultID, BestAt: pl.BestAt,
		}
	}
	return out, nil
}
