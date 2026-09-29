#!/usr/bin/env bash
set -euo pipefail

TARGET_TAG="${1:-${IMAGE_TAG:-}}"
TARGET_IMAGE="${2:-${IMAGE_NAME:-}}"
CONTAINER="${3:-${CONTAINER_NAME:-app}}"
SERVICE="${4:-${SERVICE_NAME:-app}}"
TIMEOUT="${5:-${HEALTHCHECK_TIMEOUT:-300}}"
HEALTHCHECK_PORT="${6:-${HEALTHCHECK_PORT:-8080}}"
HEALTHCHECK_PATH="${7:-${HEALTHCHECK_PATH:-/login}}"

if [ -z "$TARGET_TAG" ]; then
  echo "Usage: ./deploy.sh <image_tag> [image_name] [container_name] [service_name] [timeout_seconds] [healthcheck_port] [healthcheck_path]" >&2
  exit 1
fi

APP_DIR="${APP_DIR:-$(cd "$(dirname "$0")" && pwd)}"
cd "$APP_DIR"

if [ ! -f .env ]; then
  touch .env
fi
chmod 0600 .env

PREV_TAG=$(grep -E '^IMAGE_TAG=' .env 2>/dev/null | cut -d= -f2- || true)
PREV_IMAGE=$(grep -E '^IMAGE_NAME=' .env 2>/dev/null | cut -d= -f2- || true)

# Resolve target image from .env if not supplied via argument or env
if [ -z "$TARGET_IMAGE" ]; then
  TARGET_IMAGE="$PREV_IMAGE"
fi

if [ -z "$TARGET_IMAGE" ]; then
  echo "::error::Target image name is required (pass as argument 2, IMAGE_NAME env, or in .env)" >&2
  exit 1
fi

update_env_var() {
  local key="$1"
  local val="$2"
  if grep -q "^${key}=" .env; then
    sed -i "s|^${key}=.*|${key}=${val}|" .env
  else
    echo "${key}=${val}" >> .env
  fi
}

rollback_and_exit() {
  local reason="$1"
  echo "::error::Deployment failed: ${reason}. Recent logs:" >&2
  docker compose logs --tail=200 "$SERVICE" 2>&1 || true

  if [ -n "$PREV_TAG" ] && [ "$PREV_TAG" != "$TARGET_TAG" ]; then
    echo "Rolling back to previous tag ${PREV_TAG}..." >&2
    update_env_var "IMAGE_TAG" "$PREV_TAG"
    [ -n "$PREV_IMAGE" ] && update_env_var "IMAGE_NAME" "$PREV_IMAGE"
    chmod 0600 .env

    IMAGE_NAME="${PREV_IMAGE:-$TARGET_IMAGE}" IMAGE_TAG="$PREV_TAG" CONTAINER_NAME="$CONTAINER" docker compose up -d --remove-orphans "$SERVICE" 2>&1 || true

    echo "Waiting up to 120s for rollback container readiness..." >&2
    local rollback_deadline=$((SECONDS + 120))
    local rollback_ready=0
    while [ $SECONDS -lt $rollback_deadline ]; do
      local http_code
      http_code=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 3 --max-time 10 "http://127.0.0.1:${HEALTHCHECK_PORT}${HEALTHCHECK_PATH}" 2>/dev/null || true)
      if [ "$http_code" = "200" ]; then
        rollback_ready=1
        break
      fi
      sleep 4
    done

    if [ "$rollback_ready" -eq 1 ]; then
      echo "::warning::Rollback to ${PREV_TAG} succeeded and service is responsive." >&2
    else
      echo "::error::Rollback to ${PREV_TAG} failed to become ready! Logs:" >&2
      docker compose logs --tail=100 "$SERVICE" 2>&1 || true
    fi
  else
    echo "No previous tag to rollback to. Stopping broken container..." >&2
    docker compose stop "$SERVICE" 2>&1 || true
  fi
  exit 1
}

echo "Pulling image ${TARGET_IMAGE}:${TARGET_TAG} for service ${SERVICE}..."
IMAGE_NAME="$TARGET_IMAGE" IMAGE_TAG="$TARGET_TAG" CONTAINER_NAME="$CONTAINER" docker compose pull "$SERVICE"

update_env_var "IMAGE_NAME" "$TARGET_IMAGE"
update_env_var "IMAGE_TAG" "$TARGET_TAG"
chmod 0600 .env

echo "Starting service ${SERVICE} (container ${CONTAINER})..."
if ! IMAGE_NAME="$TARGET_IMAGE" IMAGE_TAG="$TARGET_TAG" CONTAINER_NAME="$CONTAINER" docker compose up -d --remove-orphans "$SERVICE"; then
  rollback_and_exit "docker compose up failed"
fi

echo "Waiting up to ${TIMEOUT}s for container readiness at http://127.0.0.1:${HEALTHCHECK_PORT}${HEALTHCHECK_PATH}..."
DEADLINE=$((SECONDS + TIMEOUT))
READY=0
while [ $SECONDS -lt $DEADLINE ]; do
  HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 3 --max-time 10 "http://127.0.0.1:${HEALTHCHECK_PORT}${HEALTHCHECK_PATH}" 2>/dev/null || true)
  if [ "$HTTP_CODE" = "200" ]; then
    READY=1
    break
  fi
  sleep 4
done

if [ "$READY" -eq 1 ]; then
  echo "${CONTAINER}:${TARGET_TAG} successfully deployed and responsive."

  # Prune obsolete images for this repo except current and previous
  echo "Pruning old release images for ${TARGET_IMAGE}..."
  EXISTING_IMAGES=$(docker images --format '{{.Repository}}:{{.Tag}}' | grep -F "${TARGET_IMAGE}:" || true)
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    t="${line#"${TARGET_IMAGE}:"}"
    if [ "$t" != "$TARGET_TAG" ] && [ "$t" != "$PREV_TAG" ] && [ "$t" != "<none>" ]; then
      echo "Removing obsolete image ${TARGET_IMAGE}:${t}..."
      docker rmi "${TARGET_IMAGE}:${t}" 2>/dev/null || true
    fi
  done <<< "$EXISTING_IMAGES"
  docker image prune -f 2>/dev/null || true
  exit 0
else
  rollback_and_exit "Health check failed after ${TIMEOUT}s"
fi
