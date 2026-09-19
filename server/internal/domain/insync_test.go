package domain

import (
	"bytes"
	"os"
	"path/filepath"
	"testing"
)

// The league config is owned by the client (queens/shared/league.json, loaded at
// res://) and embedded here. A rule change is a behaviour change: it goes
// through code review and re-runs the golden fixtures on both sides.
func TestLeagueFileInSync(t *testing.T) {
	src := filepath.Join("..", "..", "..", "queens", "shared", "league.json")
	want, err := os.ReadFile(src)
	if err != nil {
		t.Fatalf("read %s: %v", src, err)
	}
	strip := func(b []byte) []byte { return bytes.ReplaceAll(b, []byte("\r"), nil) }
	if !bytes.Equal(strip(want), strip(LeagueConfigBytes())) {
		t.Fatalf("server/internal/domain/league.json is stale.\nRun: go generate ./... (from server/)")
	}
}
