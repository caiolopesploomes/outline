# Outline + OCI (S3 Compatibility) — No ACL Patch

OCI's S3 Compatibility **does not support ACL** (`x-amz-acl` / POST `acl` field). If Outline includes ACL, uploads fail with `NotImplemented` / `acl field is not supported`.

This bundle gives you a minimal patch and copy‑paste snippets to remove ACL usage in Outline.

## What’s inside

- `patches/outline-oci-no-acl.patch` – a unified diff showing changes to:
  - `server/utils/s3.ts`: remove `acl` from presigned POST and `PutObject`
  - `server/routes/files.ts`: no functional change, reference for context
- `snippets/presign-no-acl.ts` – function you can drop‑in if paths differ
- `snippets/put-object-no-acl.ts` – server‑side upload without ACL
- `examples/.env.oci` – template of env vars for OCI (keep `AWS_S3_ACL=private` to satisfy validation; it will be ignored by the patched code)
- `examples/docker-compose.override.yml` – how to run a custom image

> **Note:** File paths in the patch may differ by Outline version. If `git apply` fails, use the snippets and the GREP below to locate the right places.

## Apply the patch

From your Outline repo root:

```bash
git checkout -b feat/oci-no-acl
git apply patches/outline-oci-no-acl.patch || echo "Patch failed, will do manual edit."
```

If it fails, locate code with:

```bash
rg -n "createPresignedPost\(|PutObjectCommand\(|ACL:\s*process.env.AWS_S3_ACL" server
```

and update to match the snippets.

## Build & Run (Docker)

```bash
docker build -t outline-custom:oci .
docker compose -f docker-compose.yml -f examples/docker-compose.override.yml up -d
```

## Build & Run (bare)

```bash
NODE_ENV=production yarn build
yarn start
```

## Env template (OCI)

See `examples/.env.oci`. Key points:

- Use the **namespace** in `AWS_S3_UPLOAD_BUCKET_URL`:
  `https://<NAMESPACE>.compat.objectstorage.sa-vinhedo-1.oraclecloud.com`
- Keep `AWS_S3_ACL=private` to satisfy Outline’s validation, but with this patch the value is **ignored** (no ACL sent).
- Prefer `AWS_S3_FORCE_PATH_STYLE=false` for OCI direct endpoint.

## Verify

1. Create a doc, upload an image/attachment.
2. In your Object Storage bucket, you'll see the object without ACL headers.
3. No 501/`NotImplemented` errors from OCI.

## Rollback

```bash
git restore --source=HEAD~1 -SW .
```

## Why this works

- Browser uploads use **presigned POST**: we removed `Fields.acl` and the matching policy condition.
- Server uploads use **PutObject**: we removed the `ACL` parameter.

OCI controls access via policies only; ACLs are not supported.
