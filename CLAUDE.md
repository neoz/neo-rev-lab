# CLAUDE.md

## idasql must run inside the Docker container

`idasql` is not installed on the host. It runs inside the reverse-lab Docker
container, with databases under `/workspace/` (bind-mounted from `./workspace/`
on the host).

Before using idasql, discover the running container and invoke idasql through
`docker exec`:

```bash
CONTAINER=$(docker ps --filter ancestor=neo-rev-lab --format '{{.Names}}' | head -1)
MSYS_NO_PATHCONV=1 docker exec "$CONTAINER" \
  /opt/ida-pro-9.3/idasql -s /workspace/<db>.i64 -q "SELECT * FROM welcome;"
```

For iterative analysis, start a long-lived HTTP server once and query it
repeatedly (avoids per-query docker-exec overhead):

```bash
MSYS_NO_PATHCONV=1 docker exec -d "$CONTAINER" \
  /opt/ida-pro-9.3/idasql -s /workspace/<db>.i64 --http 8081

docker exec "$CONTAINER" curl -s http://127.0.0.1:8081/query \
  -d "SELECT * FROM welcome;"
```

Notes:
- `MSYS_NO_PATHCONV=1` is required under Git Bash — otherwise Unix-style paths
  (`/workspace/...`, `/opt/...`) get rewritten to Windows paths before reaching
  `docker.exe` and the exec fails.
- Use `--write` on the idasql command line when mutations must persist to the
  `.i64` on exit.
- Only one `--http` server per database at a time; kill stale servers before
  reopening the same database.
