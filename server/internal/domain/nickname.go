package domain

import (
	"bufio"
	_ "embed"
	"errors"
	"strings"
	"unicode"

	"golang.org/x/text/unicode/norm"
)

// A nickname is the one piece of user-authored text with a blast radius: it is
// rendered to every other player in the group. The pipeline is
//
//	trim -> NFKC -> reject control/format/private-use runes -> length 2..16 runes
//	     -> casefold + strip non-letters -> denylist substring match
//
// NFKC first, so the length check and the denylist both see the same canonical
// form and a lookalike cannot smuggle a longer or a forbidden string past them.
//
//go:embed nickname_denylist.txt
var denylistRaw string

var denylist = buildDenylist(denylistRaw)

var (
	ErrNicknameLength  = errors.New("nickname length")
	ErrNicknameInvalid = errors.New("nickname invalid")
)

func buildDenylist(raw string) []string {
	var out []string
	sc := bufio.NewScanner(strings.NewReader(raw))
	for sc.Scan() {
		line := strings.TrimSpace(sc.Text())
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		out = append(out, foldForMatch(line))
	}
	return out
}

// foldForMatch lower-cases and throws away everything that is not a letter or a
// digit, so "f.u.c.k", "F U C K" and "fuck" collapse to the same string.
func foldForMatch(s string) string {
	var b strings.Builder
	for _, r := range strings.ToLower(norm.NFKC.String(s)) {
		if unicode.IsLetter(r) || unicode.IsDigit(r) {
			b.WriteRune(r)
		}
	}
	return b.String()
}

// NormalizeNickname returns the form to store, or an error the API maps to
// ERR_NICKNAME_LENGTH / ERR_NICKNAME_INVALID.
func NormalizeNickname(raw string) (string, error) {
	s := norm.NFKC.String(strings.TrimSpace(raw))
	for _, r := range s {
		// Control, format (bidi overrides, zero-width joiners), surrogate and
		// private-use runes are all ways to make a name render as something it
		// is not.
		if unicode.IsControl(r) || unicode.Is(unicode.Cf, r) || unicode.Is(unicode.Co, r) || unicode.Is(unicode.Cs, r) {
			return "", ErrNicknameInvalid
		}
	}
	n := len([]rune(s))
	if n < NicknameMinLen || n > NicknameMaxLen {
		return "", ErrNicknameLength
	}
	folded := foldForMatch(s)
	if folded == "" {
		return "", ErrNicknameInvalid
	}
	for _, bad := range denylist {
		if bad != "" && strings.Contains(folded, bad) {
			return "", ErrNicknameInvalid
		}
	}
	return s, nil
}
