#!/bin/bash
# N8N Restore Script
# Restores workflows and credentials from an n8n backup archive.

set -euo pipefail

CONTAINER_NAME="n8n"
BASE_DIR="/opt/n8n"
DATA_DIR="${BASE_DIR}/data"
BACKUP_DIR="${BASE_DIR}/backups"
ENCRYPTION_KEY_FILE="${BASE_DIR}/.encryption_key"
COMPOSE_FILE="${BASE_DIR}/docker-compose.yml"

if [ -z "${1:-}" ]; then
    echo "Usage: $0 <path_to_backup_archive.tar.gz>"
    echo "Example: $0 /opt/n8n/backups/n8n_export_20260815_220000.tar.gz"
    exit 1
fi

BACKUP_ARCHIVE="$1"

if [ ! -f "${BACKUP_ARCHIVE}" ]; then
    echo "Error: Backup archive not found at ${BACKUP_ARCHIVE}"
    exit 1
fi

mkdir -p "${DATA_DIR}"

echo "========================================"
echo "Starting n8n Restore"
echo "Container      : ${CONTAINER_NAME}"
echo "Archive        : ${BACKUP_ARCHIVE}"
echo "Data dir       : ${DATA_DIR}"
echo "========================================"

if ! docker ps -a --format '{{.Names}}' | grep -qx "${CONTAINER_NAME}"; then
    echo "Error: container '${CONTAINER_NAME}' does not exist."
    exit 1
fi

echo "[1/7] Extracting backup archive..."
TEMP_DIR=$(mktemp -d)
tar -xzf "${BACKUP_ARCHIVE}" -C "${TEMP_DIR}"

echo "[2/7] Checking archive contents..."
ls -lah "${TEMP_DIR}"

echo "[3/7] Checking encryption key..."
if [ -f "${TEMP_DIR}/.encryption_key" ]; then
    CURRENT_KEY=""
    [ -f "${ENCRYPTION_KEY_FILE}" ] && CURRENT_KEY=$(cat "${ENCRYPTION_KEY_FILE}")
    BACKUP_KEY=$(cat "${TEMP_DIR}/.encryption_key")

    if [ "${CURRENT_KEY}" != "${BACKUP_KEY}" ]; then
        echo "======================================================================"
        echo "WARNING: Backup encryption key differs from current configuration."
        echo "Credentials may not decrypt correctly unless n8n uses the same key."
        echo "======================================================================"
        read -r -p "Overwrite ${ENCRYPTION_KEY_FILE} and update docker-compose.yml? (y/N): " OVERWRITE_KEY

        if [[ "${OVERWRITE_KEY}" =~ ^[Yy]$ ]]; then
            printf "%s" "${BACKUP_KEY}" > "${ENCRYPTION_KEY_FILE}"
            chmod 600 "${ENCRYPTION_KEY_FILE}"
            echo "Encryption key file updated."

            if [ -f "${COMPOSE_FILE}" ]; then
                if grep -q 'N8N_ENCRYPTION_KEY=' "${COMPOSE_FILE}"; then
                    sed -i "s|N8N_ENCRYPTION_KEY=.*|N8N_ENCRYPTION_KEY=${BACKUP_KEY}|g" "${COMPOSE_FILE}"
                    echo "Updated N8N_ENCRYPTION_KEY in ${COMPOSE_FILE}"
                else
                    echo "Warning: N8N_ENCRYPTION_KEY not found in ${COMPOSE_FILE}"
                fi
            fi

            echo "Restarting n8n container..."
            cd "${BASE_DIR}"
            docker compose up -d
            sleep 10
        else
            echo "Keeping current encryption key. Credentials restore may fail to decrypt."
        fi
    else
        echo "Encryption key matches current configuration."
    fi
else
    echo "No .encryption_key found in backup. Using current configuration."
fi

echo "[4/7] Verifying container is running..."
if ! docker ps --format '{{.Names}}' | grep -qx "${CONTAINER_NAME}"; then
    echo "Starting container..."
    cd "${BASE_DIR}"
    docker compose up -d
    sleep 10
fi

echo "[5/7] Restoring workflows..."
if [ -f "${TEMP_DIR}/workflows.json" ]; then
    cp "${TEMP_DIR}/workflows.json" "${DATA_DIR}/workflows.json"
    docker exec -i "${CONTAINER_NAME}" n8n import:workflow --input=/home/node/.n8n/workflows.json
    rm -f "${DATA_DIR}/workflows.json"
    echo "Workflows restored."
else
    echo "No workflows.json found in backup. Skipping."
fi

echo "[6/7] Restoring credentials..."
if [ -f "${TEMP_DIR}/credentials.json" ]; then
    if [ -s "${TEMP_DIR}/credentials.json" ] && [ "$(tr -d '[:space:]' < "${TEMP_DIR}/credentials.json")" != "[]" ]; then
        cp "${TEMP_DIR}/credentials.json" "${DATA_DIR}/credentials.json"
        docker exec -i "${CONTAINER_NAME}" n8n import:credentials --input=/home/node/.n8n/credentials.json
        rm -f "${DATA_DIR}/credentials.json"
        echo "Credentials restored."
    else
        echo "credentials.json is empty or contains []. Skipping credentials import."
    fi
else
    echo "No credentials.json found in backup. Skipping."
fi

echo "[7/7] Cleaning up..."
rm -rf "${TEMP_DIR}"

echo "========================================"
echo "Restore complete."
echo "========================================"
