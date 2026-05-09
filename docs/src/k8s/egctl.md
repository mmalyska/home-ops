# Debugging Envoy Gateway with egctl

`egctl` is the Envoy Gateway CLI. Install: `brew install egctl`.

## Gateway and route status

```sh
egctl x status gateway -A
egctl x status httproute -A
egctl x status httproute -A --verbose   # full condition history
egctl x status httproute -A --quiet     # latest condition only
```

## xDS config (what Envoy actually has programmed)

```sh
egctl config envoy-proxy route -A       # all routes
egctl config envoy-proxy cluster -A     # all backends
egctl config envoy-proxy listener -A    # all listeners
```

## Envoy admin dashboard

```sh
# Port-forwards to localhost:19000
egctl x dashboard envoy-proxy -n envoy-gateway <pod-name>
```

## Translate a manifest to xDS or IR

```sh
egctl x translate --from gateway-api --to xds -f my-httproute.yaml
egctl x translate --from gateway-api --to ir  -f my-httproute.yaml
```

## Gateway instances in this cluster

| Instance | Namespace | Access |
|----------|-----------|--------|
| `envoy-external` | `envoy-gateway` | Internet-facing via Cloudflare Tunnel |
| `envoy-internal` | `envoy-gateway` | Internal network only |
