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

An Uberspace 8 account, `ludwigso`, which also runs job-agent. The API is
mounted on the account's own domain at `https://ludwigso.uber.space/queens`.

```
~/bin/queensd                              -> symlink into the current release
~/releases/<sha>/queensd                   one directory per deployed commit, newest 5 kept
~/etc/queensd.env                          0600, rewritten by every deploy
~/.config/systemd/user/queensd.service     systemd user unit, rewritten by every deploy
~/queens/queens.db                         + -wal/-shm; the directory is 0700
~/queens/backups/                          nightly copies (14) and pre-<sha>.db (5)
journalctl --user -u queensd               JSON, one line per request
```

The route is registered once, by `bootstrap.sh`:

    uberspace web backend add /queens port 8721 --remove-prefix

A bare path is mounted on every domain of the account. `--remove-prefix` strips
it before forwarding, so `queensd` keeps its own `/v1`, `/healthz` and
`/readyz` and never learns it is mounted under a prefix. That is why there is
no base-path option in the server, and why adding one would be the wrong fix.
Uberspace 8 forwards to the port on the host's public address, which is why
`QUEENS_ADDR` is `:8721` and never `127.0.0.1:8721`.

Consequence worth knowing: `/docs` and `/openapi` do not work through the
prefix, because huma emits an absolute `/openapi.yaml`. Nothing uses them in
production — the Godot client only ever calls `/v1`.

## First-time setup

1. `ssh ludwigso@<host>.uberspace.de 'bash -s' < deploy/uberspace/bootstrap.sh`
   — checks the account, creates the layout and registers the web backend.
2. On the host, `uberspace ssh key add "<the CI public key>"`.
3. In the `production` environment in GitHub, fill in:

| Name | Kind | Value |
| --- | --- | --- |
| `UBERSPACE_SSH_HOST` | secret | `<host>.uberspace.de` |
| `UBERSPACE_SSH_USER` | secret | `ludwigso` |
| `UBERSPACE_SSH_KEY` | secret | a deploy-only ed25519 private key |
| `UBERSPACE_SSH_KNOWN_HOSTS` | secret | `ssh-keyscan <host>.uberspace.de` |
| `QUEENS_TOKEN_PEPPER` | secret | `openssl rand -base64 32`, **once** |
| `QUEENS_PORT` | variable | `8721` (the default if unset) |
| `QUEENS_BACKEND_PATH` | variable | `/queens` (the default if unset) |
| `QUEENS_SERVER_URL` | variable | `https://ludwigso.uber.space/queens` (the default if unset) |
| `QUEENS_NO_SESSION_GRACE_UNTIL` | variable | see below |

   `QUEENS_SERVER_URL` is read twice: by the deploy's smoke test, and by
   `android.yml`, which writes it into the APK over `SERVER_URL_RELEASE` in
   `queens/scripts/config.gd`. Leave it unset or keep it equal to that constant.

4. Run **Deploy server** once. The first run creates the database, applies the
   migrations and imports the levels.
5. Verify, then cut a release.

**The pepper is generated once and never rotated.** It signs session tokens. A
new pepper invalidates every outstanding session, and the client clears its
credential on a 401 — so every player silently re-registers as a brand new
account and loses their history. When moving hosts, the database and the pepper
travel together.

## Moving from the Uberspace 7 host

The API used to run on the Uberspace 7 account behind `www.ludwigso.de` at
`https://www.ludwigso.de/queens/api`, under supervisord. Moving it is a one-off:

1. **Set up the new host** as in *First-time setup*. Change only the four
   `UBERSPACE_SSH_*` secrets and delete the variables `QUEENS_BACKEND_PATH` and
   `QUEENS_SERVER_URL` if they still hold the old values. Keep
   `QUEENS_TOKEN_PEPPER` as it is.
2. **Deploy server** onto the empty host. It creates an empty database; the
   smoke test proves the new route.
3. **Copy the database.** Stop the old service first, so that nothing is written
   after the copy:

   ```bash
   # old host
   supervisorctl stop queensd
   set -a; . ~/etc/queensd.env; set +a
   ~/bin/queensd backup -o ~/queens/migrate.db
   ```

   ```bash
   # from your own machine, through it
   scp <old-user>@encke.uberspace.de:queens/migrate.db .
   scp migrate.db ludwigso@<host>.uberspace.de:queens/migrate.db
   ```

   ```bash
   # new host
   systemctl --user stop queensd
   mv ~/queens/migrate.db ~/queens/queens.db
   rm -f ~/queens/queens.db-wal ~/queens/queens.db-shm
   chmod 600 ~/queens/queens.db
   systemctl --user start queensd && curl -fsS http://127.0.0.1:8721/readyz
   set -a; . ~/etc/queensd.env; set +a; ~/bin/queensd admin players --limit 5
   ```

   The start applies any migration the copy lacks and re-imports the levels.
4. **Cut a release.** Only the new APK knows the new URL; testers have to
   install it.
5. **Retire the old service, but leave its web backend in place.** With the
   backend registered and `queensd` stopped, an old APK gets a 502, which it
   retries, and keeps its queued offline results. Remove the backend and the
   request falls through to the webserver, whose 403 the client treats as
   permanent: it **silently discards every queued offline result**. Delete the
   backend only once nobody runs the old APK.

   ```bash
   # old host
   supervisorctl stop queensd
   rm ~/etc/services.d/queensd.ini && supervisorctl reread && supervisorctl update
   ```

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
journalctl --user -u queensd --output cat | grep 'shadow-excluded'
set -a; . ~/etc/queensd.env; set +a; ~/bin/queensd admin flags --player <id>
```

If honest offline players are the bulk of it, lower `WNoSession` rather than
the grace. Whatever you pick, **changing the value re-classifies history in
both directions**, because it is compared against client timestamps.

## Operating the host

```bash
systemctl --user status queensd
journalctl --user -u queensd -f --output cat
systemctl --user restart queensd

# Admin commands read the same database, so they need the same environment.
set -a; . ~/etc/queensd.env; set +a
~/bin/queensd version
~/bin/queensd admin players --limit 20
~/bin/queensd admin flags --player <uuid>
```

If three starts fail within a minute, systemd stops trying and the unit shows
`failed`. Fix the cause, then `systemctl --user reset-failed queensd` before
starting it again; `deploy.sh` does that on its own.

## Adding levels

Levels go into the production database directly; no deploy and no app release.
Clients download the new ones at their next launch (or when they come back
online), and the running server serves them from its next level request on.

```bash
# On your machine: generate new boards after the existing ones.
python tools/gen_boards.py queens/levels/queens.json --append --count 20 --seed 5000
scp queens/levels/queens.json <host>:~/queens/levels-import.json

# On the host: check, then publish.
set -a; . ~/etc/queensd.env; set +a
~/bin/queensd admin levels import --dry-run ~/queens/levels-import.json
~/bin/queensd admin levels import ~/queens/levels-import.json
~/bin/queensd admin levels list | tail
```

The import is additive and idempotent, so importing the whole file is fine: the
levels already published are reported as unchanged. It refuses the whole file
if a published board was edited, naming the id; published levels are
immutable, so give a fixed board a new id. Every board is checked for exactly
one solution before anything is written.

Afterwards commit `queens/levels/queens.json` and refresh the server's embedded
copy (`go run ./internal/levelset/cmd/copylevels` from `server/`), so the next
APK bundles the levels and the next server build seeds them on a fresh
database. Neither is urgent.

## Rolling back

`deploy.sh` rolls back on its own if the new build does not reach `/readyz`
within 30 seconds, or does not report the expected commit in its startup line.
If ssh drops mid-deploy and it cannot finish, do it by hand:

```bash
ls -t ~/releases                            # pick the previous sha
ln -sfn ~/releases/<sha>/queensd ~/bin/queensd.tmp
mv -T ~/bin/queensd.tmp ~/bin/queensd
systemctl --user restart queensd && curl -fsS http://127.0.0.1:8721/readyz
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
systemctl --user stop queensd
mv ~/queens/queens.db ~/queens/queens.db.bad
rm -f ~/queens/queens.db-wal ~/queens/queens.db-shm
cp ~/queens/backups/pre-<sha>.db ~/queens/queens.db
ln -sfn ~/releases/<old-sha>/queensd ~/bin/queensd.tmp
mv -T ~/bin/queensd.tmp ~/bin/queensd
systemctl --user start queensd && curl -fsS http://127.0.0.1:8721/readyz
```

Everything written since that backup is gone. Retention is 14 nightly
`queens-<day>.db` plus the newest 5 `pre-<sha>.db`. Uberspace's own daily
snapshots under `/backup` exist too, but a live SQLite file copied mid-write is
not a backup to rely on; these are.

**Keep this rare: new migrations should be additive and defaulted** — a new
table, or a nullable column, or one with a DEFAULT — so that binary N-1 keeps
working against schema N and the cheap rollback stays correct.

### Restore drill

Worth doing once, before you need it. The same steps as above but with a
nightly backup, putting the real database back afterwards.

## Verifying a deploy by hand

```bash
BASE=https://ludwigso.uber.space/queens
curl -fsS  $BASE/healthz
curl -fsS  $BASE/readyz
curl -fsSi $BASE/v1/time | grep -i x-server-time
curl -sS   $BASE/v1/me          # 401 and ERR_UNAUTHORIZED, not an HTML page
curl -sS -o /dev/null -w '%{http_code}\n' https://ludwigso.uber.space/   # the rest of the account still answers
```

The `/v1/me` check is the one that matters most. If `/queens/*` ever falls
through to the webserver instead of reaching `queensd`, the 403 it answers with
is treated as *permanent* by the client, which then **silently discards every
queued offline result**. The deploy workflow asserts this on every run.

End to end against the live server — it registers a player, plays, reads the
boards and the league, and deletes that account again:

```bash
QUEENS_SERVER_URL=https://ludwigso.uber.space/queens \
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

## When the URL is unreachable

`ludwigso.uber.space` is Uberspace's own name, so its DNS is theirs and not
something to debug here. Work inwards from the host instead:

```bash
curl -fsS http://127.0.0.1:8721/readyz      # on the host: is queensd up?
uberspace web backend list                  # is /queens still routed to 8721?
systemctl --user status queensd
journalctl --user -u queensd -n 50 --output cat
```

Test from outside with `curl -4`, as the runner does: GitHub runners have no
IPv6 outbound, and an IPv6 connection will happily hide an IPv4 fault.

To move the API to a domain of your own later, add it with
`uberspace web domain add`, set **both** the A and the AAAA record that
`uberspace web domain show` prints, and set `QUEENS_BACKEND_PATH` to
`<domain>/` before running `bootstrap.sh`, which then checks both families.
The first release under Uberspace 7 failed exactly there: an `AAAA` pointing at
the host and an `A` still on the registrar's parking address, which works from
any IPv6 browser and fails every deploy.

## What is deliberately not automated

- **The web backend.** `bootstrap.sh` registers it once; the deploy only checks it.
- **TLS.** Uberspace issues and renews Let's Encrypt certificates itself.
- **`bootstrap.sh`.** It registers a web backend on a live account and wants a
  human reading the output.
- **Scaling.** `queensd` is single-instance by design: the rate limiters are
  in-process and the SQLite write pool holds exactly one connection.
