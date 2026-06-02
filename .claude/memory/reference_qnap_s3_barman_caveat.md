---
name: reference-qnap-s3-barman-caveat
description: QNAP QuObjects S3 store requires boto3 checksum workaround for barman-cloud-backup to succeed
metadata:
  type: reference
---

## QNAP QuObjects + barman-cloud: InvalidDigest workaround

**S3 endpoint:** `https://s3.mmalyska.cloud` (QNAP QuObjects)

**Problem:** botocore ≥ 1.34 automatically sends `x-amz-checksum-crc32` headers on multipart uploads. QNAP QuObjects rejects these with `InvalidDigest: The Content-MD5 or checksum value that you specified is not valid`.

**Fix:** Add to every CNPG `ObjectStore` via `instanceSidecarConfiguration.env` in `values.yaml`:

```yaml
instanceSidecarConfiguration:
  env:
    - name: AWS_REQUEST_CHECKSUM_CALCULATION
      value: when_required
    - name: AWS_RESPONSE_CHECKSUM_VALIDATION
      value: when_required
```

Applied to all five CNPG clusters in `pgsql-cnpg` chart v1.3.2.

**How to apply:** The `instanceSidecarConfiguration` key is a top-level sibling of `objectStore:` under `pgsql-cnpg:` in each app's `values.yaml`. The chart template renders it under `spec.instanceSidecarConfiguration` on the `ObjectStore` CR.

**Why:** botocore's flexible checksums (RFC 1321 / SHA-256) were added in 1.34 and are sent by default. Pre-1.34 behaviour (checksums only when the server requires them) is restored by setting `AWS_REQUEST_CHECKSUM_CALCULATION=when_required`.
