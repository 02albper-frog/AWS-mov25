#!/bin/bash
# V46: Tar en backup av databasen och uppladdade filer direkt, i stället för att vänta
# på nattens schemalagda backup.
# Användning: ./backup-now.sh [miljö]
set -euo pipefail
cd "$(dirname "$0")"
source ./lib.sh "${1:-prod}"

on_web "sudo /usr/local/bin/novatrix-backup.sh"
echo ""
echo "Backuper i s3://$BackupBucketName:"
aws s3 ls "s3://$BackupBucketName/db/" --region "$Region" | tail -n 3
aws s3 ls "s3://$BackupBucketName/uploads/" --region "$Region" | tail -n 3
