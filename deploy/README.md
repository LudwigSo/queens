# Deploying Queens

The release pipeline lives in `.github/workflows/release.yml`. Develop on
`main`; when you want to ship, merge `main` into `release` and push. That one
push does everything:

```
release branch push
  └─ version          next v1.0.N from the existing tags
  └─ server           test → build → deploy to Uberspace → smoke test the URL
       └─ android     test → sign → export APK → publish the GitHub release
```

The order is not cosmetic. An old server answers `ERR_LEVEL_UNKNOWN` for a
level it has not imported, and `levelset.Sync` refuses to boot on a board whose
`size` or `difficulty` changed, so **the server always goes out before the
client that was built against it.** If the deploy fails, no APK is published.

A server-only change does not need a release: run **Deploy server** from the
Actions tab.

| Workflow | Trigger | Does |
| --- | --- | --- |
| `server.yml` | push to `main`, PRs touching the server | Go vet/build/test, OpenAPI drift, parity fixtures, client suite |
| `android.yml` | push to `main` | Builds and signs an APK as a CI artifact. No release. |
| `deploy-server.yml` | manual, or called by Release | Deploys `queensd` to Uberspace |
| `release.yml` | push to `release` | The whole thing, above |

Later additions — a Play Store upload, for one — hang off `release.yml` as
another job with `needs: android`.

## The production host

A shared Uberspace 7 account that already serves `www.ludwigso.de`. The API is
mounted at `https://www.ludwigso.de/queens/api`.

```
~/bin/queensd              -> symlink into the current release
~/bin/queensd-run          sources the env file and execs `queensd serve`
~/releases/<sha>/queensd   one directory per deployed commit, newest 5 kept
~/etc/queensd.env          0600, rewritten by every deploy
~/etc/services.d/queensd.ini
~/queens/queens.db         + -wal/-shm; the directory is 0700
~/queens/backups/          nightly copies (14) and pre-<sha>.db (5)
~/logs/queensd.log         JSON, one line per request, 10 MB x 5
```

The route is registered once, by `bootstrap.sh`:

    uberspace web backend set www.ludwigso.de/queens/api --http --port 8721 --remove-prefix

`--remove-prefix` strips the path before forwarding, so `queensd` keeps its own
`/v1`, `/healthz` and `/readyz` and never learns it is mounted under a prefix.
That is why there is no base-path option in the server, and why adding one
would be the wrong fix.

Consequence worth knowing: `/docs` and `/openapi` do not work through the
prefix, because huma emits an absolute `/openapi.yaml`. Nothing uses them in
production — the Godot client only ever calls `/v1`.

## First-time setup

1. `ssh <user>@<host>.uberspace.de 'bash -s' < deploy/uberspace/bootstrap.sh`
   — creates the layout and registers the web backend.
2. Add the CI public key to `~/.ssh/authorized_keys` on the host.
3. Create the `production` environment in GitHub and fill in:

| Name | Kind | Value |
| --- | --- | --- |
| `UBERSPACE_SSH_HOST` | secret | `<host>.uberspace.de` |
| `UBERSPACE_SSH_USER` | secret | the Uberspace username |
| `UBERSPACE_SSH_KEY` | secret | a deploy-only ed25519 private key |
| `UBERSPACE_SSH_KNOWN_HOSTS` | secret | `ssh-keyscan <host>.uberspace.de` |
| `QUEENS_TOKEN_PEPPER` | secret | `openssl rand -base64 32` |
| `QUEENS_PORT` | variable | `8721` (the default if unset) |
| `QUEENS_BACKEND_PATH` | variable | `www.ludwigso.de/queens/api` (default if unset) |
| `QUEENS_SERVER_URL` | variable | `https://www.ludwigso.de/queens/api` |
| `QUEENS_NO_SESSION_GRACE_UNTIL` | variable | see below |

4. Run **Deploy server** once. The first run creates the database, applies the
   migrations and imports the levels.
5. Verify, then cut a release.

**The pepper is generated once and never rotated.** It signs session tokens. A
new pepper invalidates every outstanding session, and the client clears its
credential on a 401 — so every player silently re-registers as a brand new
account and loses their history.

## QUEENS_NO_SESSION_GRACE_UNTIL

Defaults to `1798761600` (2027-01-01T00:00:00Z), i.e. **off**.

A result submitted without a server-minted session is flagged `no_session` at
weight 8, and a player is shadow-excluded at 15. The second offline game inside
the 30-day half-life therefore quarantines a legitimate player into hidden
boards, silently. This setting suppresses the signal for everything finished
before it.

Offline play is a supported, documented path in the client, so the signal stays
off through launch. It was never a security control in any case: `finished_at`
is client-supplied, so a cheater can backdate under any value.

Before bringing it forward, measure. Over a few weeks:

```bash
grep 'shadow-excluded' ~/logs/queensd.log
set -a; . ~/etc/queensd.env; set +a; ~/bin/queensd admin flags --player <id>
```

If honest offline players are the bulk of it, lower `WNoSession` rather than
the grace. Whatever you pick, **changing the value re-classifies history in
both directions**, because it is compared against client timestamps.

## Operating the host

```bash
supervisorctl status queensd
supervisorctl tail -f queensd              # or: tail -f ~/logs/queensd.log
supervisorctl restart queensd

# Admin commands read the same database, so they need the same environment.
set -a; . ~/etc/queensd.env; set +a
~/bin/queensd version
~/bin/queensd admin players --limit 20
~/bin/queensd admin flags --player <uuid>
```

## Rolling back

`deploy.sh` rolls back on its own if the new build does not reach `/readyz`
within 30 seconds, or does not report the expected commit in its startup line.
If ssh drops mid-deploy and it cannot finish, do it by hand:

```bash
ls -t ~/releases                            # pick the previous sha
ln -sfn ~/releases/<sha>/queensd ~/bin/queensd.tmp
mv -T ~/bin/queensd.tmp ~/bin/queensd
supervisorctl restart queensd && curl -fsS http://127.0.0.1:8721/readyz
```

### Rolling back across a migration

Migrations are forward-only and there are no down-migrations. Worse, **an older
binary does not notice a newer schema**: it skips the versions it already knows
and never errors on one it does not, so it starts happily and may then fail at
runtime on a column it has never heard of. `/readyz` will not catch that — it
only pings the database and touches no application table.

So when a deploy applied migrations, the symlink swap alone is *not* a
rollback. `deploy.sh` says so loudly when that happens. The real procedure:

```bash
supervisorctl stop queensd
mv ~/queens/queens.db ~/queens/queens.db.bad
rm -f ~/queens/queens.db-wal ~/queens/queens.db-shm
cp ~/queens/backups/pre-<sha>.db ~/queens/queens.db
ln -sfn ~/releases/<old-sha>/queensd ~/bin/queensd.tmp
mv -T ~/bin/queensd.tmp ~/bin/queensd
supervisorctl start queensd && curl -fsS http://127.0.0.1:8721/readyz
```

Everything written since that backup is gone. Retention is 14 nightly
`queens-<day>.db` plus the newest 5 `pre-<sha>.db`.

**Keep this rare: new migrations should be additive and defaulted** — a new
table, or a nullable column, or one with a DEFAULT — so that binary N-1 keeps
working against schema N and the cheap rollback stays correct.

### Restore drill

Worth doing once, before you need it. The same steps as above but with a
nightly backup, putting the real database back afterwards.

## Verifying a deploy by hand

```bash
BASE=https://www.ludwigso.de/queens/api
curl -fsS  $BASE/healthz
curl -fsS  $BASE/readyz
curl -fsSi $BASE/v1/time | grep -i x-server-time
curl -sS   $BASE/v1/me          # 401 and ERR_UNAUTHORIZED, not an HTML page
curl -sS -o /dev/null -w '%{http_code}\n' https://www.ludwigso.de/   # the site still works
```

The `/v1/me` check is the one that matters most. If `/queens/api/*` ever falls
through to the webserver instead of reaching `queensd`, the 403 it answers with
is treated as *permanent* by the client, which then **silently discards every
queued offline result**. The deploy workflow asserts this on every run.

End to end against the live server — it registers a player, plays, reads the
boards and the league, and deletes that account again:

```bash
QUEENS_SERVER_URL=https://www.ludwigso.de/queens/api \
  godot --headless --path queens --script tests/e2e_http.gd
```

It does **not** leave production completely clean, though. The `App` autoload
starts before the script does and sees the same `QUEENS_SERVER_URL`, so it
registers your own `user://save.json` as a second player and writes an auth
token into it. The script only deletes the throwaway account it made itself.
So after an e2e run against production:

- one stray player is left behind. Find it with
  `~/bin/queensd admin players --limit 5` and deal with it there.
- your local save now holds a token for the live server. Harmless — a 401
  simply re-registers — but it is no longer an offline save.

Prefer pointing the e2e script at a local `queensd`, and keep the production
check to the curl list above.

You cannot check the forwarded-for handling from the logs: the access log
records method, path, status, bytes, duration and request id, but not the
caller's address. The behaviour is pinned by
`server/internal/api/clientip_test.go` instead -- the right-most
`X-Forwarded-For` element wins, anything that does not parse as an IP falls
back to the peer. If you ever want to see it live you will have to add the
resolved address to `accessLog` first, which is a deliberate omission rather
than an oversight: on a public service that log line is a record of who played
when.

And after any restart, check that no `~/queens/queens.db-wal` is left behind:
that proves the graceful shutdown and the WAL checkpoint got their 30 seconds.

## What is deliberately not automated

- **DNS and the domain.** Already on the account; nothing here touches it.
- **TLS.** Uberspace issues and renews Let's Encrypt certificates itself.
- **`bootstrap.sh`.** It registers a web backend on a live domain and wants a
  human reading the output.
- **Scaling.** `queensd` is single-instance by design: the rate limiters are
  in-process and the SQLite write pool holds exactly one connection.
