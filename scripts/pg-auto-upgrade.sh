#!/usr/bin/env bash
set -euo pipefail

OLD_VER="$(cat "${PGDATA}/PG_VERSION")"
NEW_VER="${PG_MAJOR}"

if [ "$OLD_VER" = "$NEW_VER" ]; then
    exit 0
fi

if [ "$OLD_VER" -gt "$NEW_VER" ]; then
    echo "pg-auto-upgrade: refusing to downgrade PGDATA from PG${OLD_VER} to PG${NEW_VER}" >&2
    exit 1
fi

OLD_BIN="/usr/lib/postgresql/${OLD_VER}/bin"
NEW_BIN="/usr/lib/postgresql/${NEW_VER}/bin"

if [ ! -x "$OLD_BIN/pg_upgrade" ]; then
    echo "pg-auto-upgrade: PG${OLD_VER} binaries are not installed in this image; cannot upgrade." >&2
    echo "pg-auto-upgrade: rebuild with LEGACY_PG_VERSIONS including ${OLD_VER}." >&2
    exit 1
fi

echo "pg-auto-upgrade: migrating PGDATA from PG${OLD_VER} to PG${NEW_VER}"

# Stage both clusters as subdirectories of PGDATA itself. This keeps them
# on the same filesystem (required for pg_upgrade --link) regardless of
# whether the user mounted the volume at PGDATA or its parent.
TS="$(date -u +%Y%m%dT%H%M%SZ)"
SUBDIR_OLD="${PGDATA}/.upgrade-old-${TS}"
SUBDIR_NEW="${PGDATA}/.upgrade-new-${TS}"

mkdir -p "$SUBDIR_OLD" "$SUBDIR_NEW"
chmod 700 "$SUBDIR_OLD" "$SUBDIR_NEW"

# Roll back only failures that happen before pg_upgrade --link has run.
ROLLBACK_SAFE=1
on_failure() {
    if [ "$ROLLBACK_SAFE" != "1" ]; then
        return
    fi
    echo "pg-auto-upgrade: failed before pg_upgrade ran; restoring PGDATA contents" >&2
    rm -rf "$SUBDIR_NEW" 2>/dev/null || true
    if [ -d "$SUBDIR_OLD" ]; then
        find "$SUBDIR_OLD" -mindepth 1 -maxdepth 1 \
            -exec mv -t "$PGDATA" {} + 2>/dev/null || true
        rmdir "$SUBDIR_OLD" 2>/dev/null || true
    fi
}
trap on_failure ERR

# Move existing cluster contents into SUBDIR_OLD (skip the upgrade subdirs themselves).
find "$PGDATA" -mindepth 1 -maxdepth 1 \
    ! -path "$SUBDIR_OLD" ! -path "$SUBDIR_NEW" \
    -exec mv -t "$SUBDIR_OLD" {} +

# Match the new cluster's data-checksum setting to the old cluster's;
# pg_upgrade refuses if they differ.
OLD_CHECKSUM_VER="$("$OLD_BIN/pg_controldata" "$SUBDIR_OLD" \
    | awk -F': *' '/Data page checksum version/{print $2}')"
if [ "${OLD_CHECKSUM_VER:-0}" -gt 0 ]; then
    CHECKSUM_ARG="--data-checksums"
else
    CHECKSUM_ARG="--no-data-checksums"
fi

"$NEW_BIN/initdb" \
    --username="${POSTGRES_USER:-postgres}" \
    "$CHECKSUM_ARG" \
    -c max_connections=1000 \
    -D "$SUBDIR_NEW"

cd /tmp
ROLLBACK_SAFE=0
"$NEW_BIN/pg_upgrade" \
    --old-bindir="$OLD_BIN" \
    --new-bindir="$NEW_BIN" \
    --old-datadir="$SUBDIR_OLD" \
    --new-datadir="$SUBDIR_NEW" \
    --link

# Promote the new cluster's files into PGDATA up front, so that even if
# a later step fails the volume contains a startable cluster.
find "$SUBDIR_NEW" -mindepth 1 -maxdepth 1 -exec mv -t "$PGDATA" {} +
rmdir "$SUBDIR_NEW"

# Refresh collation versions: the OS glibc may differ from when the old
# cluster was created (e.g. bullseye -> trixie), which silently breaks
# b-tree ordering. REINDEX rebuilds indexes against current collation
# rules; REFRESH updates the catalog's recorded version.
refresh_collations() {
    local pg_temp_port=50432
    local pg_temp_log=/tmp/pg_post_upgrade.log

    "$NEW_BIN/pg_ctl" -D "$PGDATA" \
        -o "-c listen_addresses='' -c unix_socket_directories=/tmp -p $pg_temp_port" \
        -l "$pg_temp_log" -w start

    local psql=("$NEW_BIN/psql" -h /tmp -p "$pg_temp_port" \
        -U "${POSTGRES_USER:-postgres}" -X -At -v ON_ERROR_STOP=1)

    local dbs
    dbs="$("${psql[@]}" -d postgres -c "
        SELECT datname FROM pg_database
        WHERE datallowconn AND datname <> 'template0'
          AND datcollversion IS DISTINCT FROM pg_database_collation_actual_version(oid)
    ")" || dbs=""

    local db
    while read -r db; do
        [ -n "$db" ] || continue
        echo "pg-auto-upgrade: REINDEX + REFRESH for database $db"
        "${psql[@]}" -d "$db" -c "REINDEX DATABASE \"$db\""
        "${psql[@]}" -d "$db" -c "ALTER DATABASE \"$db\" REFRESH COLLATION VERSION"
        "${psql[@]}" -d "$db" <<'SQL'
DO $$
DECLARE r record;
BEGIN
  FOR r IN SELECT n.nspname, c.collname
           FROM pg_collation c JOIN pg_namespace n ON c.collnamespace = n.oid
           WHERE c.collversion IS NOT NULL
             AND c.collversion <> pg_collation_actual_version(c.oid)
  LOOP
    EXECUTE format('ALTER COLLATION %I.%I REFRESH VERSION', r.nspname, r.collname);
  END LOOP;
END
$$;
SQL
    done <<< "$dbs"

    "$NEW_BIN/pg_ctl" -D "$PGDATA" -w stop
}

if ! refresh_collations; then
    echo "pg-auto-upgrade: collation refresh failed; the cluster is upgraded but" >&2
    echo "pg-auto-upgrade: you should manually REINDEX and REFRESH affected databases." >&2
    "$NEW_BIN/pg_ctl" -D "$PGDATA" -w stop 2>/dev/null || true
fi

# Carry user-defined config and ALTER SYSTEM settings forward.
for f in postgresql.conf postgresql.auto.conf pg_hba.conf pg_ident.conf; do
    if [ -f "$SUBDIR_OLD/$f" ]; then
        cp "$SUBDIR_OLD/$f" "$PGDATA/$f"
    fi
done

# Re-apply image defaults that should survive an upgrade.
sed -ri "s/^#?max_connections\s*=.*/max_connections = 1000/" "$PGDATA/postgresql.conf"

echo "pg-auto-upgrade: PG${OLD_VER} -> PG${NEW_VER} complete"
echo "pg-auto-upgrade: pre-upgrade files kept at $SUBDIR_OLD — delete after verifying the new cluster"
