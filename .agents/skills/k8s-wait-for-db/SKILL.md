---
name: k8s-wait-for-db
description: >
  Init container pattern that blocks app startup until a database service accepts
  connections. Use when an app crash-loops because it runs DB migrations at
  startup before the database pod is ready.
when_to_use: >
  Trigger phrases: "crash loop on startup", "EHOSTUNREACH database", "migration fails",
  "connection refused on start", "app starts before db", "startup ordering",
  "CNPG restart", "db not ready".
---

# Wait-for-DB Init Container

## Problem

Apps that run DB migrations at startup exit with `EHOSTUNREACH` or `connection refused`
when Kubernetes schedules them before the database is ready (e.g. after a CNPG failover
or maintenance restart). The app crash-loops until the DB comes up.

## Solution

Add a `wait-db` init container that polls the DB service with `nc -z` before the app starts.

### bjw-s app-template style

```yaml
controllers:
  app:
    initContainers:
      wait-db:
        image:
          repository: busybox
          tag: latest
        command:
          - sh
          - -c
          - until nc -z <db-service> <port>; do sleep 2; done
    containers:
      app:
        ...
```

### Plain Kubernetes Deployment

```yaml
spec:
  template:
    spec:
      initContainers:
        - name: wait-db
          image: busybox:latest
          command: ['sh', '-c', 'until nc -z <db-service> <port>; do sleep 2; done']
      containers:
        - name: app
          ...
```

## CNPG Service Names

CloudNative-PG creates predictable service names:

| Service | Purpose |
|---------|---------|
| `<cluster>-cnpg-rw` | Primary (read-write) — use this for apps |
| `<cluster>-cnpg-ro` | Read-only replicas |
| `<cluster>-cnpg-r` | Any instance |

Example for a cluster named `bookorbdb`:
```sh
until nc -z bookorbdb-cnpg-rw 5432; do sleep 2; done
```

## Why Not a Startup Probe?

Startup probes fire **after** the container starts. If the app crashes during `CMD`
execution (before any probe kicks in), Kubernetes restarts it via the default restart
policy. An init container prevents the main container from starting at all until the
condition is met — cleaner and avoids crash-loop backoff delays.
