---
name: onlyoffice-stuck-document
description: >
  Diagnose and fix ONLYOFFICE Document Server showing "An error has occurred
  while opening the file" with no failed requests visible in the browser.
  Root cause is usually an orphaned task_result row in the docserver's
  Postgres DB, left over from a conversion interrupted by a pod crash/OOM/restart.
when_to_use: >
  Trigger phrases: "error opening file" (OnlyOffice/Nextcloud editor),
  "Press OK to close the editor", "onlyoffice won't open document",
  "document editor blank/error but no failed network request",
  "onlyoffice worked before but not after a pod restart/OOM".
---

# ONLYOFFICE Stuck Document (orphaned task_result row)

## Symptom

Editor UI loads fine (static assets, websocket connects, all 200s in the browser
network tab/HAR) but shows "An error has occurred while opening the file. Press
'OK' to close the editor." with **no failed HTTP request anywhere** — this is
what makes it confusing, since there's nothing to point at.

## Why default log levels won't show it

ONLYOFFICE's docservice/converter log at `WARN` by default, which only captures
worker startup lines. Normal request handling — including the "open" command
that's actually failing — produces nothing. Don't waste time staring at
`kubectl logs`; you need DEBUG level (see below) or to go straight to the DB.

## Root cause

The docservice persists document conversion state (`task_result` table) and
co-authoring metadata (`doc_changes` table) in Postgres. If a conversion gets
interrupted mid-flight (pod OOM-killed, pod restarted, deployment redeployed
while someone had a doc open), the `task_result` row for that document's `key`
is left with `status=1` ("in progress") and never updated. Every subsequent
open request for that same document key just replays this stale row instead of
running a fresh conversion — the browser gets an empty `documentOpen` payload
and immediately errors out. Because the key is derived from the file's mtime,
the same broken row keeps getting hit until the file changes or the row is
cleared. Since CNPG-backed storage survives pod restarts, this persists even
after the OnlyOffice pod itself has been cycled.

## Fast diagnosis (skip debug logging if you can identify the doc key)

Get the document key from the Nextcloud OCS config endpoint response
(`document.key` field) or from any `/apps/onlyoffice/track?doc=...` JWT payload
(`fileId` maps to the Nextcloud file, but the docserver `key` is what's needed —
easiest to get it live, see below).

```sh
kubectl -n <ns> exec deploy/onlyoffice -- sh -c '
export PGPASSWORD=$DB_PWD
psql -h <db-service>-cnpg-rw -U "$DB_USER" -d app -c \
  "select id, status, created_at, last_open_date from task_result where id='"'"'<key>'"'"';"
'
```

`status=1` with a `created_at` well in the past (predating your current pod's
uptime) confirms the stuck row.

## Confirming live (if key is unknown or you want certainty first)

1. Bump docservice log level to DEBUG (reversible, ~seconds of editor downtime):
   ```sh
   kubectl -n <ns> exec deploy/onlyoffice -- sh -c \
     'sed -i "s/\"level\": \"WARN\"/\"level\": \"DEBUG\"/" /etc/onlyoffice/documentserver/log4js/production.json'
   kubectl -n <ns> exec deploy/onlyoffice -- supervisorctl restart ds:docservice ds:converter
   ```
2. Tail logs (`kubectl -n <ns> logs -f deploy/onlyoffice`) and have the user retry
   opening the document.
3. Look for `Start command: {"c":"open",...}` followed immediately by
   `Response command: {"type":"open","status":"ok","data":{},"openedAt":<ms>}`.
   **The tell**: `openedAt` is identical across separate retries/sessions — a
   real open would produce a fresh timestamp each time. Identical `openedAt`
   means it's replaying cached state, not re-converting.
4. Revert the log level the same way (WARN back), restart the two components again.

## Fix

Delete the stale row so the next open triggers a real conversion:

```sh
kubectl -n <ns> exec deploy/onlyoffice -- sh -c '
export PGPASSWORD=$DB_PWD
psql -h <db-service>-cnpg-rw -U "$DB_USER" -d app -c \
  "DELETE FROM task_result WHERE id='"'"'<key>'"'"';"
'
```

Then have the user retry the open — no pod restart needed, the fix takes effect
immediately since the docservice re-queries the DB per request.

## Notes

- This is a live DB mutation — confirm with the user first per the repo's
  cluster-mutation rule, even though it's clearly garbage state and not user data.
- `doc_changes` for the same key is worth checking too (`select count(*) from
  doc_changes where id='<key>'`) but was empty in the confirmed case — only
  `task_result` was the culprit.
- If this recurs frequently, consider it a symptom of whatever is crashing/
  restarting the OnlyOffice pod mid-conversion (OOM, ArgoCD sync, etc.) — fix
  that root cause too, this DB cleanup is just the symptom fix per incident.
