package levelset

import (
	"bytes"
	"os"
	"path/filepath"
	"testing"
)

// The embedded queens.json is a copy, because Go embed cannot reach outside the
// module. This test is the enforcement; `go generate ./...` is the fix.
func TestLevelFileInSync(t *testing.T) {
	src := filepath.Join("..", "..", "..", "queens", "levels", "queens.json")
	want, err := os.ReadFile(src)
	if err != nil {
		t.Fatalf("read %s: %v", src, err)
	}
	if !bytes.Equal(normalize(want), normalize(Embedded())) {
		t.Fatalf("server/internal/levelset/queens.json is stale.\nRun: go generate ./... (from server/)")
	}
}

// normalize strips CR so a CRLF checkout does not fail the comparison.
func normalize(b []byte) []byte { return bytes.ReplaceAll(b, []byte("\r"), nil) }

func TestParseEmbedded(t *testing.T) {
	f, err := Parse(Embedded())
	if err != nil {
		t.Fatal(err)
	}
	if f.Format != 1 || f.Game != "queens" {
		t.Errorf("unexpected header: format %d game %q", f.Format, f.Game)
	}
	if len(f.Levels) != 100 {
		t.Errorf("expected 100 levels, got %d", len(f.Levels))
	}
	for _, l := range f.Levels {
		if l.Size < 6 || l.Size > 10 {
			t.Errorf("level %s has size %d", l.ID, l.Size)
		}
		if l.Difficulty < 1 {
			t.Errorf("level %s has difficulty %d", l.ID, l.Difficulty)
		}
	}
}
