# postgres-backup

Encrypted (GPG AES-256) `pg_dump` backups of PostgreSQL 17 to S3, on a schedule. Single sh script in a Docker image.

```bash
docker build -t pgbackup .
docker run -d --name pgbackup --restart unless-stopped \
  -e POSTGRES_USER=app -e POSTGRES_PASSWORD=... -e POSTGRES_DB=appdb -e POSTGRES_HOST=db \
  -e S3_BUCKET=my-bucket -e S3_ACCESS_KEY_ID=... -e S3_SECRET_ACCESS_KEY=... \
  -e S3_REGION=us-east-1 \
  -e BACKUP_INTERVAL_MINUTES=60 -e BACKUP_ENCRYPTION_PASSWORD=... \
  pgbackup
```

Optional: `POSTGRES_PORT` (5432), `S3_ENDPOINT` (MinIO/R2/etc.), `S3_PREFIX` — folder in the bucket (`postgres-backups` by default, nested like `prod/db1` is fine; created automatically if missing).

## Restore

```bash
docker exec -it pgbackup pgbackup restore            # pick from the list in S3
docker exec -it pgbackup pgbackup list               # just list
docker exec -e RESTORE_YES=1 pgbackup pgbackup restore latest   # non-interactive: N | latest | file name
docker exec pgbackup pgbackup backup                 # backup now
```

Restore runs `pg_restore --clean --if-exists --single-transaction`: existing objects are replaced; on error nothing changes.
**Keep the encryption password safe — without it backups cannot be read.**

`docker-compose.yml` is a ready test stack (Postgres 17 + MinIO + backup).
