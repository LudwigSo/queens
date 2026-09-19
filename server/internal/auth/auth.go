// Package auth mints and verifies the two opaque secrets the server issues: the
// bearer token that identifies a player, and the session token that proves a
// game was started through POST /games.
package auth

import (
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/base64"
	"encoding/hex"
	"fmt"
	"strings"
)

// NewToken returns the value handed to the client once and the hash stored in
// auth_tokens.
//
// The token is opaque random, not a JWT. Revocation is then a DELETE (a JWT
// needs a denylist, which is the same lookup minus the simplicity); the
// interesting claims -- tier, tier_points, shadow_excluded -- change every round,
// so a JWT carrying them is stale within minutes; and there is no alg confusion,
// no rotation ceremony and no library CVE to track.
func NewToken() (token, hash string, err error) {
	buf := make([]byte, 32)
	if _, err := rand.Read(buf); err != nil {
		return "", "", err
	}
	token = base64.RawURLEncoding.EncodeToString(buf)
	return token, HashToken(token), nil
}

// HashToken is plain SHA-256, not bcrypt: 256 bits of CSPRNG output has nothing
// to brute-force, so a slow KDF would cost latency on every request and buy
// nothing.
func HashToken(token string) string {
	sum := sha256.Sum256([]byte(token))
	return hex.EncodeToString(sum[:])
}

// NewSessionID is the database key of a game session.
func NewSessionID() (string, error) {
	buf := make([]byte, 16)
	if _, err := rand.Read(buf); err != nil {
		return "", err
	}
	return base64.RawURLEncoding.EncodeToString(buf), nil
}

// SessionToken is "<id>.<hmac16>". The HMAC lets the server reject garbage
// before it touches the database; on SQLite, where reads and writes share a
// lock, that is a real denial-of-service difference.
func SessionToken(pepper, id string) string {
	mac := hmac.New(sha256.New, []byte(pepper))
	mac.Write([]byte(id))
	sig := mac.Sum(nil)[:16]
	return id + "." + base64.RawURLEncoding.EncodeToString(sig)
}

// VerifySessionToken returns the session id carried by a well-formed token.
func VerifySessionToken(pepper, token string) (string, error) {
	id, sig, ok := strings.Cut(token, ".")
	if !ok || id == "" || sig == "" {
		return "", fmt.Errorf("malformed session token")
	}
	want := SessionToken(pepper, id)
	if subtle.ConstantTimeCompare([]byte(token), []byte(want)) != 1 {
		return "", fmt.Errorf("bad session signature")
	}
	return id, nil
}

// friendCodeAlphabet omits the characters that are easy to misread aloud or in
// print (0/O, 1/I, 8/B).
const friendCodeAlphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567"

// NewFriendCode draws a code from a cryptographic source. 32^6 is about 1.07
// billion codes, so enumeration is bounded by the rate limit, not by the space.
func NewFriendCode() (string, error) {
	buf := make([]byte, 6)
	if _, err := rand.Read(buf); err != nil {
		return "", err
	}
	out := make([]byte, 6)
	for i, b := range buf {
		out[i] = friendCodeAlphabet[int(b)%len(friendCodeAlphabet)]
	}
	return "QN-" + string(out), nil
}
