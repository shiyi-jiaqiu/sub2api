#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

REMOTE_HOST="${REMOTE_HOST:-sg}"
REMOTE_PROJECT_DIR="${REMOTE_PROJECT_DIR:-/opt/sub2api-deploy}"
IMAGE_REPO="${IMAGE_REPO:-ghcr.io/shiyi-jiaqiu/sub2api}"
IMAGE_TAG="${IMAGE_TAG:-oauth-subexp-fix-$(date +%Y%m%d)-$(git -C "${REPO_ROOT}" rev-parse --short HEAD)}"
IMAGE_REF="${IMAGE_REPO}:${IMAGE_TAG}"
PLATFORM="${PLATFORM:-linux/amd64}"
PUSH_IMAGE="${PUSH_IMAGE:-1}"
VERIFY_ONLY="${VERIFY_ONLY:-0}"
INTERVAL_DAYS="${INTERVAL_DAYS:-3}"
AUTO_UPDATE_SCRIPT_PATH="${AUTO_UPDATE_SCRIPT_PATH:-/usr/local/sbin/sub2api-auto-update.sh}"

if ! command -v docker >/dev/null 2>&1; then
  echo "docker is required" >&2
  exit 1
fi

if ! command -v gh >/dev/null 2>&1; then
  echo "gh is required" >&2
  exit 1
fi

if ! command -v vpsops >/dev/null 2>&1; then
  echo "vpsops is required" >&2
  exit 1
fi

git -C "${REPO_ROOT}" diff --quiet || {
  echo "working tree is dirty; commit or stash first" >&2
  exit 1
}

gh auth status >/dev/null

echo "image_ref=${IMAGE_REF}"

if [[ "${VERIFY_ONLY}" != "1" ]]; then
  if [[ "${PUSH_IMAGE}" == "1" ]]; then
    if ! docker info >/dev/null 2>&1; then
      echo "docker daemon is unavailable" >&2
      exit 1
    fi

    if ! docker buildx version >/dev/null 2>&1; then
      echo "docker buildx is required" >&2
      exit 1
    fi

    if ! docker manifest inspect "${IMAGE_REF}" >/dev/null 2>&1; then
      echo "building and pushing ${IMAGE_REF}"
      docker buildx build \
        --platform "${PLATFORM}" \
        --build-arg GOPROXY=https://proxy.golang.org,direct \
        --tag "${IMAGE_REF}" \
        --push \
        -f "${REPO_ROOT}/Dockerfile" \
        "${REPO_ROOT}"
    else
      echo "image already exists remotely, skipping build"
    fi
  fi

  echo "updating ${REMOTE_HOST}:${REMOTE_PROJECT_DIR}"
  vpsops "${REMOTE_HOST}" batch \
    --cmd "cd ${REMOTE_PROJECT_DIR} && if grep -q '^SUB2API_IMAGE=' .env; then sed -i 's#^SUB2API_IMAGE=.*#SUB2API_IMAGE=${IMAGE_REF}#' .env; else printf '\nSUB2API_IMAGE=%s\n' '${IMAGE_REF}' >> .env; fi" \
    --cmd "python3 - <<'PY'
from pathlib import Path
path = Path('${REMOTE_PROJECT_DIR}/docker-compose.yml')
text = path.read_text()
old = 'image: weishaw/sub2api:latest'
new = 'image: \${SUB2API_IMAGE:-weishaw/sub2api:latest}'
if old in text:
    path.write_text(text.replace(old, new, 1))
PY" \
    --cmd "cd ${REMOTE_PROJECT_DIR} && docker compose pull sub2api && docker compose up -d --no-deps sub2api"
fi

AUTO_UPDATE_TMP="$(mktemp)"
trap 'rm -f "${AUTO_UPDATE_TMP}"' EXIT
cat >"${AUTO_UPDATE_TMP}" <<EOF
#!/usr/bin/env bash
set -euo pipefail

INTERVAL_DAYS="\${INTERVAL_DAYS:-${INTERVAL_DAYS}}"
STATE_DIR="\${STATE_DIR:-/var/lib/sub2api-auto-update}"
STATE_FILE="\${STATE_DIR}/last_success_epoch"
PROJECT_DIR="\${PROJECT_DIR:-${REMOTE_PROJECT_DIR}}"
IMAGE_REF="\${IMAGE_REF:-${IMAGE_REF}}"

if ! [[ "\${INTERVAL_DAYS}" =~ ^[0-9]+$ ]] || [ "\${INTERVAL_DAYS}" -lt 1 ]; then
  echo "INTERVAL_DAYS must be a positive integer" >&2
  exit 1
fi

now_epoch="\$(date +%s)"
min_interval="\$((INTERVAL_DAYS * 86400))"

if [ -f "\${STATE_FILE}" ]; then
  last_epoch="\$(cat "\${STATE_FILE}" 2>/dev/null || echo 0)"
  if [[ "\${last_epoch}" =~ ^[0-9]+$ ]]; then
    elapsed="\$((now_epoch - last_epoch))"
    if [ "\${elapsed}" -lt "\${min_interval}" ]; then
      echo "skip: only \${elapsed}s elapsed (< \${min_interval}s)"
      exit 0
    fi
  fi
fi

cd "\${PROJECT_DIR}"
if grep -q "^SUB2API_IMAGE=" .env; then
  sed -i "s#^SUB2API_IMAGE=.*#SUB2API_IMAGE=\${IMAGE_REF}#" .env
else
  printf "\nSUB2API_IMAGE=%s\n" "\${IMAGE_REF}" >> .env
fi

docker compose pull sub2api
docker compose up -d --no-deps sub2api

status="\$(docker ps --filter "name=^/sub2api$" --format "{{.Status}}" | head -n 1)"
if [ -z "\${status}" ] || [[ "\${status}" != Up* ]]; then
  echo "sub2api is not running after update" >&2
  exit 1
fi

mkdir -p "\${STATE_DIR}"
printf "%s\n" "\${now_epoch}" > "\${STATE_FILE}"
echo "update_complete=true"
EOF

AUTO_UPDATE_B64="$(base64 -w0 "${AUTO_UPDATE_TMP}")"

echo "installing ${AUTO_UPDATE_SCRIPT_PATH} on ${REMOTE_HOST}"
vpsops "${REMOTE_HOST}" -- "python3 - <<'PY'
import base64
from pathlib import Path

payload = base64.b64decode('${AUTO_UPDATE_B64}')
path = Path('${AUTO_UPDATE_SCRIPT_PATH}')
path.write_bytes(payload)
path.chmod(0o755)
PY
systemctl daemon-reload
systemctl restart sub2api-update.timer"

echo "verifying remote service"
vpsops "${REMOTE_HOST}" batch \
  --cmd "cd ${REMOTE_PROJECT_DIR} && docker compose ps sub2api" \
  --cmd "docker logs sub2api --tail 80 | tail -n 40" \
  --cmd "docker inspect sub2api --format '{{json .Config.Image}} {{json .Image}}'" \
  --cmd "curl -fsS http://127.0.0.1:9080/health || curl -fsS http://127.0.0.1:9080/api/health || true"

echo "done image_ref=${IMAGE_REF}"
