package api_test

import (
	"bytes"
	"context"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/google/uuid"
	"github.com/ludwigsonnenberg/queens-server/internal/api"
	"github.com/ludwigsonnenberg/queens-server/internal/config"
	"github.com/ludwigsonnenberg/queens-server/internal/domain"
	"github.com/ludwigsonnenberg/queens-server/internal/service"
	"github.com/ludwigsonnenberg/queens-server/internal/testutil"
)

type client struct {
	t     *testing.T
	srv   *httptest.Server
	clock *domain.FixedClock
	svc   *service.Service
	token string
}

func newClient(t *testing.T) *client {
	t.Helper()
	st := testutil.NewStore(t)
	clock := testutil.NewClock()
	cfg := &config.Config{
		Env: "dev", TokenPepper: "test-pepper",
		CooldownSeconds: domain.CooldownDefault, SessionTTL: domain.SessionFreshness,
		RequestTimeout: 10 * time.Second, MaxBodyBytes: 32 << 10,
	}
	ctx := context.Background()
	levels, err := st.Repos().Levels.All(ctx)
	if err != nil {
		t.Fatal(err)
	}
	set, err := st.Repos().Levels.CurrentLevelSet(ctx)
	if err != nil {
		t.Fatal(err)
	}
	svc := service.New(st, cfg, clock, domain.DefaultLeagueConfig(), domain.LeagueConfigHash(), set.Hash, levels)
	s := api.New(svc, cfg)
	srv := httptest.NewServer(s.Router)
	t.Cleanup(srv.Close)
	return &client{t: t, srv: srv, clock: clock, svc: svc}
}

func (c *client) do(method, path string, body any) (*http.Response, []byte) {
	c.t.Helper()
	var r io.Reader
	if body != nil {
		b, err := json.Marshal(body)
		if err != nil {
			c.t.Fatal(err)
		}
		r = bytes.NewReader(b)
	}
	req, err := http.NewRequest(method, c.srv.URL+path, r)
	if err != nil {
		c.t.Fatal(err)
	}
	if body != nil {
		req.Header.Set("Content-Type", "application/json")
	}
	if c.token != "" {
		req.Header.Set("Authorization", "Bearer "+c.token)
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		c.t.Fatal(err)
	}
	defer resp.Body.Close()
	data, _ := io.ReadAll(resp.Body)
	return resp, data
}

func (c *client) register(nickname string) map[string]any {
	c.t.Helper()
	resp, body := c.do(http.MethodPost, "/v1/players", map[string]any{
		"player_id": uuid.NewString(), "nickname": nickname, "client_version": "test",
	})
	if resp.StatusCode != http.StatusCreated {
		c.t.Fatalf("register: %d %s", resp.StatusCode, body)
	}
	out := decode(c.t, body)
	c.token = out["token"].(string)
	return out
}

func decode(t *testing.T, body []byte) map[string]any {
	t.Helper()
	var m map[string]any
	if err := json.Unmarshal(body, &m); err != nil {
		t.Fatalf("decode %s: %v", body, err)
	}
	return m
}

func TestHealthAndReady(t *testing.T) {
	c := newClient(t)
	for _, p := range []string{"/healthz", "/readyz"} {
		resp, body := c.do(http.MethodGet, p, nil)
		if resp.StatusCode != 200 {
			t.Errorf("%s = %d %s", p, resp.StatusCode, body)
		}
	}
}

// Every response carries the server clock, so the client can keep an offset:
// Backend.now_utc() is synchronous and cannot await a round trip.
func TestServerTimeHeaderOnEveryResponse(t *testing.T) {
	c := newClient(t)
	for _, tc := range []struct{ method, path string }{
		{http.MethodGet, "/v1/time"},
		{http.MethodGet, "/v1/me"},   // 401
		{http.MethodGet, "/nope"},    // 404
		{http.MethodGet, "/healthz"}, // plain chi handler
	} {
		resp, _ := c.do(tc.method, tc.path, nil)
		if resp.Header.Get("X-Server-Time") == "" {
			t.Errorf("%s %s has no X-Server-Time (status %d)", tc.method, tc.path, resp.StatusCode)
		}
	}
}

func TestProblemShape(t *testing.T) {
	c := newClient(t)
	resp, body := c.do(http.MethodGet, "/v1/me", nil)
	if resp.StatusCode != 401 {
		t.Fatalf("expected 401, got %d %s", resp.StatusCode, body)
	}
	if ct := resp.Header.Get("Content-Type"); ct != "application/problem+json" {
		t.Errorf("content type = %q, want application/problem+json", ct)
	}
	p := decode(t, body)
	if p["code"] != domain.CodeUnauthorized {
		t.Errorf("code = %v, want %s", p["code"], domain.CodeUnauthorized)
	}
	if _, ok := p["params"].([]any); !ok {
		t.Errorf("params must always be present as a list, got %#v", p["params"])
	}
	if p["status"].(float64) != 401 {
		t.Errorf("status = %v", p["status"])
	}
}

// A validation failure from Huma itself must carry a code too, so the client has
// exactly one way to render an error.
func TestValidationErrorsCarryACode(t *testing.T) {
	c := newClient(t)
	resp, body := c.do(http.MethodPost, "/v1/players", map[string]any{
		"player_id": "not-a-uuid", "nickname": "Ann",
	})
	if resp.StatusCode != 422 && resp.StatusCode != 400 {
		t.Fatalf("expected a validation failure, got %d %s", resp.StatusCode, body)
	}
	p := decode(t, body)
	if p["code"] == nil || p["code"] == "" {
		t.Errorf("a validation problem must carry a code: %s", body)
	}
}

func TestRegisterThenMe(t *testing.T) {
	c := newClient(t)
	out := c.register("Ann")
	prof := out["profile"].(map[string]any)
	for _, k := range []string{"player_id", "nickname", "friend_code", "tier", "tier_points", "created_at", "stats"} {
		if _, ok := prof[k]; !ok {
			t.Errorf("profile is missing %q; the client indexes it by name", k)
		}
	}
	stats := prof["stats"].(map[string]any)
	for _, k := range []string{"games", "flawless", "best_score", "rounds_played"} {
		if _, ok := stats[k]; !ok {
			t.Errorf("stats is missing %q", k)
		}
	}

	resp, body := c.do(http.MethodGet, "/v1/me", nil)
	if resp.StatusCode != 200 {
		t.Fatalf("GET /v1/me = %d %s", resp.StatusCode, body)
	}
	me := decode(t, body)
	if me["player_id"] != prof["player_id"] {
		t.Error("/v1/me must return the same player")
	}
}

func TestIDTakenIs409(t *testing.T) {
	c := newClient(t)
	id := uuid.NewString()
	first, _ := c.do(http.MethodPost, "/v1/players", map[string]any{"player_id": id, "nickname": "Ann"})
	if first.StatusCode != 201 {
		t.Fatalf("first register = %d", first.StatusCode)
	}
	c.token = ""
	resp, body := c.do(http.MethodPost, "/v1/players", map[string]any{"player_id": id, "nickname": "Mallory"})
	if resp.StatusCode != 409 {
		t.Fatalf("expected 409, got %d %s", resp.StatusCode, body)
	}
	if decode(t, body)["code"] != domain.CodeIDTaken {
		t.Errorf("code = %v", decode(t, body)["code"])
	}
}

// The whole play loop over HTTP, checking the exact key names the GDScript
// client indexes by string.
func TestPlayLoopOverHTTP(t *testing.T) {
	c := newClient(t)
	c.register("Ann")

	levels, err := c.svc.St.Repos().Levels.All(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	lv := levels[0]

	resp, body := c.do(http.MethodPost, "/v1/games", map[string]any{"level_id": lv.ID})
	if resp.StatusCode != 201 {
		t.Fatalf("start = %d %s", resp.StatusCode, body)
	}
	start := decode(t, body)
	for _, k := range []string{"round_index", "group_id", "joined", "session", "server_time"} {
		if _, ok := start[k]; !ok {
			t.Errorf("start_game response is missing %q", k)
		}
	}
	sess := start["session"].(map[string]any)
	token := sess["token"].(string)
	level := sess["level"].(map[string]any)
	if level["size"].(float64) != float64(lv.Size) {
		t.Errorf("session level size = %v", level["size"])
	}

	c.clock.Add(90)
	bd := domain.Breakdown(float64(lv.Difficulty), lv.Size, lv.Par(), 90, 0, 0, true)
	me := decode(t, mustBody(c.do(http.MethodGet, "/v1/me", nil)))
	result := map[string]any{
		"schema": 2, "result_id": uuid.NewString(), "player_id": me["player_id"],
		"level_id": lv.ID, "size": lv.Size, "difficulty": lv.Difficulty, "stars": lv.Stars,
		"par_seconds": lv.Par(), "started_at": sess["issued_at"], "finished_at": c.clock.Now(),
		"elapsed_seconds": 90, "completed": true, "queens_placed": lv.Size, "wrong_placements": 0,
		"queens_removed": 1, "clear_count": 0, "hint_count": 0, "taps": lv.Size * 3,
		"week_index": domain.WeekIndex(c.clock.Now()), "score": bd.Score,
		"client_version": "test", "session_token": token,
	}
	resp, body = c.do(http.MethodPost, "/v1/results", result)
	if resp.StatusCode != 201 {
		t.Fatalf("submit = %d %s", resp.StatusCode, body)
	}
	sub := decode(t, body)
	for _, k := range []string{"breakdown", "round_score", "group_rank", "group_size", "zone",
		"tier", "round_index", "tier_points", "promo_score", "promoted_to"} {
		if _, ok := sub[k]; !ok {
			t.Errorf("submit response is missing %q", k)
		}
	}
	brk := sub["breakdown"].(map[string]any)
	for _, k := range []string{"score", "base", "par_seconds", "accuracy_factor", "speed_factor", "hint_factor", "flawless"} {
		if _, ok := brk[k]; !ok {
			t.Errorf("breakdown is missing %q", k)
		}
	}
	if int(brk["score"].(float64)) != bd.Score {
		t.Errorf("score = %v, want %d", brk["score"], bd.Score)
	}

	// A replay returns 200 and the same bytes.
	resp2, body2 := c.do(http.MethodPost, "/v1/results", result)
	if resp2.StatusCode != 200 {
		t.Errorf("replay status = %d, want 200", resp2.StatusCode)
	}
	if !bytes.Equal(bytes.TrimSpace(body), bytes.TrimSpace(body2)) {
		t.Errorf("replay body differs:\n%s\n%s", body, body2)
	}

	// Standing.
	resp, body = c.do(http.MethodGet, "/v1/league/standing", nil)
	if resp.StatusCode != 200 {
		t.Fatalf("standing = %d %s", resp.StatusCode, body)
	}
	st := decode(t, body)
	for _, k := range []string{"tier", "round_index", "round_days", "round_ends_at", "joined",
		"group", "my_rank", "my_round_score", "my_games", "zone", "my_tier_points", "rules"} {
		if _, ok := st[k]; !ok {
			t.Errorf("standing is missing %q", k)
		}
	}
	rules := st["rules"].(map[string]any)
	for _, k := range []string{"up_pct", "down_pct", "up_count", "up_mode", "promo_score",
		"up_to", "best_n", "round_mode", "round_days", "global", "floor"} {
		if _, ok := rules[k]; !ok {
			t.Errorf("rules is missing %q", k)
		}
	}
	// Presentation stays on the client.
	if _, ok := st["tier_name"]; ok {
		t.Error("the server must not send tier_name")
	}
	if _, ok := st["rules_text"]; ok {
		t.Error("the server must not send rules_text")
	}
	if rules["up_to"] != "silver" {
		t.Errorf("up_to must be a tier id, got %v", rules["up_to"])
	}
	group := st["group"].(map[string]any)
	members := group["members"].([]any)
	m0 := members[0].(map[string]any)
	if _, ok := m0["is_bot"]; ok {
		t.Error("is_bot is gone: the server has no bots")
	}
	for _, k := range []string{"player_id", "nickname", "round_score", "games", "last_submit_at",
		"is_me", "is_friend", "rank", "zone"} {
		if _, ok := m0[k]; !ok {
			t.Errorf("member is missing %q", k)
		}
	}

	// Leaderboard.
	resp, body = c.do(http.MethodGet, "/v1/levels/"+lv.ID+"/leaderboard?scope=global&limit=10", nil)
	if resp.StatusCode != 200 {
		t.Fatalf("leaderboard = %d %s", resp.StatusCode, body)
	}
	lb := decode(t, body)
	for _, k := range []string{"entries", "my_entry", "my_rank", "total_players", "par_seconds"} {
		if _, ok := lb[k]; !ok {
			t.Errorf("leaderboard is missing %q", k)
		}
	}
	if cc := resp.Header.Get("Cache-Control"); cc != "private, max-age=30" {
		t.Errorf("Cache-Control = %q", cc)
	}
	e0 := lb["entries"].([]any)[0].(map[string]any)
	for _, k := range []string{"rank", "player_id", "nickname", "score", "time_seconds",
		"wrong_placements", "achieved_at", "is_me", "is_friend"} {
		if _, ok := e0[k]; !ok {
			t.Errorf("leaderboard entry is missing %q", k)
		}
	}
}

// Nothing pending is 204 with no body, which HttpBackend re-wraps as ok({}).
func TestSummaryIsNoContentWhenNothingPending(t *testing.T) {
	c := newClient(t)
	c.register("Ann")
	resp, body := c.do(http.MethodGet, "/v1/league/summary", nil)
	if resp.StatusCode != 204 {
		t.Fatalf("expected 204, got %d %s", resp.StatusCode, body)
	}
	if len(bytes.TrimSpace(body)) != 0 {
		t.Errorf("204 must have no body, got %q", body)
	}
	// Ack never errors, whatever index it names.
	resp, _ = c.do(http.MethodPost, "/v1/league/summary/ack", map[string]any{"round_index": 12345})
	if resp.StatusCode != 204 {
		t.Errorf("ack = %d, want 204", resp.StatusCode)
	}
}

func TestLevelMetaETagAnd304(t *testing.T) {
	c := newClient(t)
	c.register("Ann")
	resp, body := c.do(http.MethodGet, "/v1/levels/meta", nil)
	if resp.StatusCode != 200 {
		t.Fatalf("meta = %d %s", resp.StatusCode, body)
	}
	etag := resp.Header.Get("ETag")
	if etag == "" {
		t.Fatal("no ETag")
	}
	meta := decode(t, body)
	if _, ok := meta["levels"]; !ok {
		t.Error("meta is missing levels")
	}

	req, _ := http.NewRequest(http.MethodGet, c.srv.URL+"/v1/levels/meta", nil)
	req.Header.Set("Authorization", "Bearer "+c.token)
	req.Header.Set("If-None-Match", etag)
	resp2, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp2.Body.Close()
	if resp2.StatusCode != http.StatusNotModified {
		t.Errorf("If-None-Match = %d, want 304", resp2.StatusCode)
	}
}

func TestFriendsOverHTTP(t *testing.T) {
	c := newClient(t)
	c.register("Ann")
	annToken := c.token

	c.token = ""
	other := c.register("Bob")
	code := other["profile"].(map[string]any)["friend_code"].(string)

	c.token = annToken
	resp, body := c.do(http.MethodPost, "/v1/friends", map[string]any{"code": code})
	if resp.StatusCode != 201 {
		t.Fatalf("add friend = %d %s", resp.StatusCode, body)
	}
	fr := decode(t, body)
	for _, k := range []string{"player_id", "nickname", "tier", "round_score", "friend_since", "friend_code"} {
		if _, ok := fr[k]; !ok {
			t.Errorf("friend entry is missing %q", k)
		}
	}

	resp, body = c.do(http.MethodGet, "/v1/friends", nil)
	if resp.StatusCode != 200 {
		t.Fatalf("list = %d %s", resp.StatusCode, body)
	}
	if n := len(decode(t, body)["friends"].([]any)); n != 1 {
		t.Errorf("expected one friend, got %d", n)
	}

	resp, _ = c.do(http.MethodDelete, "/v1/friends/"+fr["player_id"].(string), nil)
	if resp.StatusCode != 204 {
		t.Errorf("remove = %d, want 204", resp.StatusCode)
	}
	resp, body = c.do(http.MethodDelete, "/v1/friends/"+fr["player_id"].(string), nil)
	if resp.StatusCode != 404 || decode(t, body)["code"] != domain.CodeFriendUnknown {
		t.Errorf("second remove = %d %s", resp.StatusCode, body)
	}
}

func TestDeleteAccountOverHTTP(t *testing.T) {
	c := newClient(t)
	c.register("Ann")
	resp, _ := c.do(http.MethodDelete, "/v1/me", nil)
	if resp.StatusCode != 204 {
		t.Fatalf("delete = %d", resp.StatusCode)
	}
	resp, _ = c.do(http.MethodGet, "/v1/me", nil)
	if resp.StatusCode != 401 {
		t.Errorf("after deletion the token must not resolve, got %d", resp.StatusCode)
	}
}

func TestBootstrap(t *testing.T) {
	c := newClient(t)
	c.register("Ann")
	resp, body := c.do(http.MethodGet, "/v1/bootstrap", nil)
	if resp.StatusCode != 200 {
		t.Fatalf("bootstrap = %d %s", resp.StatusCode, body)
	}
	b := decode(t, body)
	for _, k := range []string{"server_time", "profile", "league_config", "config_hash",
		"level_set_hash", "cooldown_seconds", "level_meta", "standing", "friend_limit"} {
		if _, ok := b[k]; !ok {
			t.Errorf("bootstrap is missing %q", k)
		}
	}
	if _, ok := b["pending_summary"]; ok {
		t.Error("pending_summary must be absent, not null, when there is none")
	}
	cfg := b["league_config"].(map[string]any)
	if cfg["round_best_n"].(float64) != 15 {
		t.Errorf("league config looks wrong: %v", cfg["round_best_n"])
	}
	if len(b["level_meta"].(map[string]any)) != c.svc.LevelCount() {
		t.Error("level_meta must cover every level")
	}
}

// The solution is stored but must never leave the server.
func TestSolutionNeverLeaks(t *testing.T) {
	c := newClient(t)
	c.register("Ann")
	levels, _ := c.svc.St.Repos().Levels.All(context.Background())
	for _, path := range []string{"/v1/bootstrap", "/v1/levels/meta",
		"/v1/levels/" + levels[0].ID + "/leaderboard"} {
		_, body := c.do(http.MethodGet, path, nil)
		if bytes.Contains(body, []byte("solution")) || bytes.Contains(body, []byte("regions")) {
			t.Errorf("%s leaks board data: %s", path, body)
		}
	}
}

func mustBody(resp *http.Response, body []byte) []byte { return body }
