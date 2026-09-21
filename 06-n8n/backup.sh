#!/bin/bash
# N8N Backup Script
# Exports workflows and credentials, includes encryption key if present,
# creates a timestamped archive, and prunes old backups.

set -euo pipefail

CONTAINER_NAME="n8n"
BACKUP_DIR="/opt/n8n/backups"
DATA_DIR="/opt/n8n/data"
ENCRYPTION_KEY_FILE="/opt/n8n/.encryption_key"
RETENTION_DAYS=14

TIMESTAMP=$(date +%Y%m%d_%H%M%S)
BACKUP_ARCHIVE="${BACKUP_DIR}/n8n_export_${TIMESTAMP}.tar.gz"

echo "========================================"
echo "Starting n8n Backup"
echo "Container      : ${CONTAINER_NAME}"
echo "Backup dir     : ${BACKUP_DIR}"
echo "Data dir       : ${DATA_DIR}"
echo "Archive        : ${BACKUP_ARCHIVE}"
echo "Retention days : ${RETENTION_DAYS}"
echo "========================================"

mkdir -p "${BACKUP_DIR}"
mkdir -p "${DATA_DIR}"

if ! docker ps --format '{{.Names}}' | grep -qx "${CONTAINER_NAME}"; then
  echo "Error: container '${CONTAINER_NAME}' is not running."
  exit 1
fi

echo "[1/6] Cleaning old export files..."
rm -f "${DATA_DIR}/workflows.json" "${DATA_DIR}/credentials.json"

echo "[2/6] Exporting workflows..."
docker exec -i "${CONTAINER_NAME}" n8n export:workflow --all --output=/home/node/.n8n/workflows.json

if [ ! -f "${DATA_DIR}/workflows.json" ]; then
  echo "Error: workflows.json was not created in ${DATA_DIR}"
  exit 1
fi

echo "[3/6] Exporting credentials..."
if docker exec -i "${CONTAINER_NAME}" n8n export:credentials --all --output=/home/node/.n8n/credentials.json; then
  echo "Credentials exported successfully."
else
  echo "No credentials found or export failed. Creating empty credentials.json"
  echo "[]" > "${DATA_DIR}/credentials.json"
fi

if [ ! -f "${DATA_DIR}/credentials.json" ]; then
  echo "[]" > "${DATA_DIR}/credentials.json"
fi

echo "[4/6] Building archive..."
TEMP_DIR=$(mktemp -d)

cp "${DATA_DIR}/workflows.json" "${TEMP_DIR}/"
cp "${DATA_DIR}/credentials.json" "${TEMP_DIR}/"

if [ -f "${ENCRYPTION_KEY_FILE}" ]; then
  cp "${ENCRYPTION_KEY_FILE}" "${TEMP_DIR}/"
  echo "Included encryption key."
else
  echo "Warning: encryption key not found at ${ENCRYPTION_KEY_FILE}"
fi

tar -czf "${BACKUP_ARCHIVE}" -C "${TEMP_DIR}" .

echo "[5/6] Cleaning temporary files..."
rm -rf "${TEMP_DIR}"
rm -f "${DATA_DIR}/workflows.json" "${DATA_DIR}/credentials.json"

echo "[6/6] Pruning backups older than ${RETENTION_DAYS} days..."
find "${BACKUP_DIR}" -type f -name "n8n_export_*.tar.gz" -mtime +${RETENTION_DAYS} -delete

if [ -f "${BACKUP_ARCHIVE}" ]; then
  echo "========================================"
  echo "Backup completed successfully"
  echo "Saved to: ${BACKUP_ARCHIVE}"
  ls -lh "${BACKUP_ARCHIVE}"
  echo "========================================"
else
  echo "Error: backup archive was not created."
  exit 1
fi
