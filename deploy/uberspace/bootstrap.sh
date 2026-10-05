#!/usr/bin/env bash
#
# One-time setup on the Uberspace host. Run it by hand over ssh; it is NOT part
# of the pipeline, because it touches a live domain and because the checks in it
# want a human reading the output.
#
#   ssh <user>@<host>.uberspace.de 'bash -s' < deploy/uberspace/bootstrap.sh
#
# Afterwards, add the CI public key to ~/.ssh/authorized_keys and fill in the
# GitHub secrets listed in deploy/README.md.
set -euo pipefail

PORT="${QUEENS_PORT:-8721}"
BACKEND_PATH="${QUEENS_BACKEND_PATH:-www.ludwigso.de/queens/api}"
DOMAIN="${BACKEND_PATH%%/*}"

say() { printf '\n==> %s\n' "$*"; }

say "Creating the directory layout"
mkdir -p ~/bin ~/etc/services.d ~/logs ~/releases ~/queens/backups
# SQLite creates the database 0644 and runBackup creates its directory 0755.
# On a shared host that is every player row and every session, world-readable.
chmod 700 ~/queens ~/queens/backups
ls -ld ~/queens ~/queens/backups

say "The domain must already be on this account"
uberspace web domain list
echo "'$DOMAIN' has to appear above. If it does not: uberspace web domain add $DOMAIN"

say "And it must actually point here"
# Worth doing properly rather than by eye, because the half-broken case is
# invisible from a desktop: an AAAA that points at Uberspace and an A that
# still points at the registrar's parking makes the site work over IPv6 and
# fail for everyone else -- including GitHub runners, which have no IPv6.
me="$(hostname -f)"
host_v4="$(getent ahostsv4 "$me"     | awk '{print $1}' | sort -u)"
host_v6="$(getent ahostsv6 "$me"     | awk '{print $1}' | sort -u)"
dom_v4="$( getent ahostsv4 "$DOMAIN" | awk '{print $1}' | sort -u)"
dom_v6="$( getent ahostsv6 "$DOMAIN" | awk '{print $1}' | sort -u)"

printf '  this host (%s)\n    A    %s\n    AAAA %s\n' "$me" "${host_v4:-none}" "${host_v6:-none}"
printf '  %s\n    A    %s\n    AAAA %s\n' "$DOMAIN" "${dom_v4:-none}" "${dom_v6:-none}"

dns_ok=1
for want in $host_v4; do
  echo "$dom_v4" | grep -qx "$want" || dns_ok=0
done
for want in $host_v6; do
  echo "$dom_v6" | grep -qx "$want" || dns_ok=0
done
# Extra addresses are as bad as missing ones: traffic lands wherever they point.
[ "$(echo "$dom_v4" | grep -c .)" = "$(echo "$host_v4" | grep -c .)" ] || dns_ok=0

if [ "$dns_ok" != 1 ]; then
  cat >&2 <<EOF

!! $DOMAIN does not resolve to this host.
!! Set these at your registrar, replacing whatever is there now:
!!   A     $(echo "$host_v4" | tr '\n' ' ')
!!   AAAA  $(echo "$host_v6" | tr '\n' ' ')
!! Both families matter. An A record left on the registrar's parking address
!! makes the site reachable over IPv6 only, which looks fine from a browser
!! and fails every deploy.
EOF
  exit 1
fi
echo "  ok: both families point at this host"

say "Routing $BACKEND_PATH to port $PORT"
# --remove-prefix is what lets the server keep its own /v1, /healthz and /readyz
# paths: it never learns it is mounted under a prefix.
uberspace web backend set "$BACKEND_PATH" --http --port "$PORT" --remove-prefix
uberspace web backend list

cat <<EOF

==> Remaining manual steps

  1. Add the CI deploy key:
       echo 'ssh-ed25519 AAAA... queens-deploy' >> ~/.ssh/authorized_keys

  2. Record the host keys for the UBERSPACE_SSH_KNOWN_HOSTS secret, from your
     own machine:
       ssh-keyscan $(hostname -f)

  3. Generate the pepper once and store it as the QUEENS_TOKEN_PEPPER secret.
     It is NEVER rotated -- see deploy/README.md:
       openssl rand -base64 32

  4. Run the Release (or Deploy server) workflow. The first deploy creates the
     database, applies the migrations and imports the levels.

  5. After that first deploy, prove WAL works on this filesystem -- SQLite's
     WAL mode is hardcoded and needs real POSIX locks, which an NFS-backed home
     would not give:
       QUEENS_DB=~/queens/probe.db ~/bin/queensd migrate \\
         && ls -l ~/queens/probe.db-wal && rm -f ~/queens/probe.db*
EOF
