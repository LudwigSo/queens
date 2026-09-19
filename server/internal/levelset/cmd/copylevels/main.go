// Command copylevels refreshes the embedded copies of the two files the client
// owns. Run it with `go generate ./...` after editing queens/levels/queens.json
// or queens/shared/league.json; TestLevelFileInSync and TestLeagueFileInSync are
// what force you to.
package main

import (
	"fmt"
	"os"
	"path/filepath"
)

func main() {
	pairs := [][2]string{
		{filepath.Join("..", "queens", "levels", "queens.json"), filepath.Join("internal", "levelset", "queens.json")},
		{filepath.Join("..", "queens", "shared", "league.json"), filepath.Join("internal", "domain", "league.json")},
	}
	for _, p := range pairs {
		data, err := os.ReadFile(p[0])
		if err != nil {
			fmt.Fprintln(os.Stderr, "read:", err)
			os.Exit(1)
		}
		if err := os.WriteFile(p[1], data, 0o644); err != nil {
			fmt.Fprintln(os.Stderr, "write:", err)
			os.Exit(1)
		}
		fmt.Printf("copied %s -> %s (%d bytes)\n", p[0], p[1], len(data))
	}
}
