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
    --cmd "cd ${REMOTE_PROJECT_DIR} && grep -q '^SUB2API_IMAGE=' .env && sed -i 's#^SUB2API_IMAGE=.*#SUB2API_IMAGE=${IMAGE_REF}#' .env || printf '\nSUB2API_IMAGE=${IMAGE_REF}\n' >> .env" \
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

echo "patching sub2api auto-update to follow compose image"
vpsops "${REMOTE_HOST}" -- "python3 - <<'PY'
from pathlib import Path
path = Path('/usr/local/sbin/sub2api-auto-update.sh')
text = path.read_text()
old = \"\"\"before_digest=\"$(docker image inspect weishaw/sub2api:latest --format '{{index .RepoDigests 0}}' 2>/dev/null || true)\"
echo \"before_digest=${before_digest}\"

docker compose pull sub2api
docker compose up -d --no-deps sub2api postgres redis

after_digest=\"$(docker image inspect weishaw/sub2api:latest --format '{{index .RepoDigests 0}}' 2>/dev/null || true)\"
\"\"\"
new = \"\"\"image_ref=\"\$(docker compose config | awk '/image:/ {print \$2; exit}')\"
if [ -z \"\${image_ref}\" ]; then
  echo \"failed to resolve image from compose config\" >&2
  exit 1
fi

before_digest=\"\$(docker image inspect \"\${image_ref}\" --format '{{index .RepoDigests 0}}' 2>/dev/null || true)\"
echo \"image_ref=\${image_ref}\"
echo \"before_digest=\${before_digest}\"

docker compose pull sub2api
docker compose up -d --no-deps sub2api postgres redis

after_digest=\"\$(docker image inspect \"\${image_ref}\" --format '{{index .RepoDigests 0}}' 2>/dev/null || true)\"
\"\"\"
if old not in text and 'image_ref=\"\\$(docker compose config | awk \\'/image:/ {print \\$2; exit}\\')\"' not in text:
    raise SystemExit('expected auto-update script shape not found')
if old in text:
    text = text.replace(old, new, 1)
    path.write_text(text)
PY
chmod +x /usr/local/sbin/sub2api-auto-update.sh
systemctl daemon-reload
systemctl restart sub2api-update.timer || true"

echo "verifying remote service"
vpsops "${REMOTE_HOST}" batch \
  --cmd "cd ${REMOTE_PROJECT_DIR} && docker compose ps sub2api" \
  --cmd "docker logs sub2api --tail 80 | tail -n 40" \
  --cmd "docker inspect sub2api --format '{{json .Config.Image}} {{json .Image}}'" \
  --cmd "curl -fsS http://127.0.0.1:9080/api/health || curl -fsS http://127.0.0.1:9080/health || true"

echo "done image_ref=${IMAGE_REF}"
