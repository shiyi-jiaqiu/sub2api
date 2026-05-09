#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

REMOTE_HOST="${REMOTE_HOST:-sg}"
REMOTE_SOURCE_DIR="${REMOTE_SOURCE_DIR:-/opt/sub2api-src}"
REMOTE_DEPLOY_DIR="${REMOTE_DEPLOY_DIR:-/opt/sub2api-deploy}"
FORK_URL="${FORK_URL:-https://github.com/shiyi-jiaqiu/sub2api.git}"
BRANCH="${BRANCH:-ops/oauth-subscription-expiry-fix}"
IMAGE_REPO="${IMAGE_REPO:-sub2api-local}"
IMAGE_TAG="${IMAGE_TAG:-oauth-subexp-fix-$(git -C "${REPO_ROOT}" rev-parse --short HEAD)}"
IMAGE_REF="${IMAGE_REPO}:${IMAGE_TAG}"

if ! command -v vpsops >/dev/null 2>&1; then
  echo "vpsops is required" >&2
  exit 1
fi

git -C "${REPO_ROOT}" diff --quiet || {
  echo "working tree is dirty; commit or stash first" >&2
  exit 1
}

echo "remote_host=${REMOTE_HOST}"
echo "fork_url=${FORK_URL}"
echo "branch=${BRANCH}"
echo "image_ref=${IMAGE_REF}"

vpsops "${REMOTE_HOST}" batch \
  --cmd "if [ ! -d '${REMOTE_SOURCE_DIR}/.git' ]; then git clone '${FORK_URL}' '${REMOTE_SOURCE_DIR}'; fi" \
  --cmd "cd '${REMOTE_SOURCE_DIR}' && git remote set-url origin '${FORK_URL}' && git fetch origin '${BRANCH}' && git checkout -B '${BRANCH}' 'origin/${BRANCH}'" \
  --cmd "cd '${REMOTE_SOURCE_DIR}' && docker build -t '${IMAGE_REF}' -f Dockerfile ." \
  --cmd "cd '${REMOTE_DEPLOY_DIR}' && grep -q '^SUB2API_IMAGE=' .env && sed -i 's#^SUB2API_IMAGE=.*#SUB2API_IMAGE=${IMAGE_REF}#' .env || printf '\nSUB2API_IMAGE=${IMAGE_REF}\n' >> .env" \
  --cmd "python3 - <<'PY'
from pathlib import Path
path = Path('${REMOTE_DEPLOY_DIR}/docker-compose.yml')
text = path.read_text()
old = 'image: weishaw/sub2api:latest'
new = 'image: ${SUB2API_IMAGE:-weishaw/sub2api:latest}'
if old in text:
    path.write_text(text.replace(old, new, 1))
PY" \
  --cmd "cd '${REMOTE_DEPLOY_DIR}' && docker compose up -d --no-deps sub2api"

vpsops "${REMOTE_HOST}" -- "cat >/usr/local/sbin/sub2api-auto-update.sh <<'SH'
#!/usr/bin/env bash
set -euo pipefail

INTERVAL_DAYS=\"\${INTERVAL_DAYS:-3}\"
STATE_DIR=\"\${STATE_DIR:-/var/lib/sub2api-auto-update}\"
STATE_FILE=\"\${STATE_DIR}/last_success_epoch\"
PROJECT_DIR=\"\${PROJECT_DIR:-${REMOTE_DEPLOY_DIR}}\"
SOURCE_DIR=\"\${SOURCE_DIR:-${REMOTE_SOURCE_DIR}}\"
FORK_URL=\"\${FORK_URL:-${FORK_URL}}\"
BRANCH=\"\${BRANCH:-${BRANCH}}\"
IMAGE_REF=\"\${IMAGE_REF:-${IMAGE_REF}}\"

if ! [[ \"\${INTERVAL_DAYS}\" =~ ^[0-9]+$ ]] || [ \"\${INTERVAL_DAYS}\" -lt 1 ]; then
  echo \"INTERVAL_DAYS must be a positive integer\" >&2
  exit 1
fi

now_epoch=\"\$(date +%s)\"
min_interval=\"\$((INTERVAL_DAYS * 86400))\"

if [ -f \"\${STATE_FILE}\" ]; then
  last_epoch=\"\$(cat \"\${STATE_FILE}\" 2>/dev/null || echo 0)\"
  if [[ \"\${last_epoch}\" =~ ^[0-9]+$ ]]; then
    elapsed=\"\$((now_epoch - last_epoch))\"
    if [ \"\${elapsed}\" -lt \"\${min_interval}\" ]; then
      echo \"skip: only \${elapsed}s elapsed (< \${min_interval}s)\"
      exit 0
    fi
  fi
fi

if [ ! -d \"\${SOURCE_DIR}/.git\" ]; then
  git clone \"\${FORK_URL}\" \"\${SOURCE_DIR}\"
fi

cd \"\${SOURCE_DIR}\"
git remote set-url origin \"\${FORK_URL}\"
git fetch origin \"\${BRANCH}\"
git checkout -B \"\${BRANCH}\" \"origin/\${BRANCH}\"

docker build -t \"\${IMAGE_REF}\" -f Dockerfile .

cd \"\${PROJECT_DIR}\"
grep -q '^SUB2API_IMAGE=' .env && sed -i \"s#^SUB2API_IMAGE=.*#SUB2API_IMAGE=\${IMAGE_REF}#\" .env || printf '\nSUB2API_IMAGE=%s\n' \"\${IMAGE_REF}\" >> .env
docker compose up -d --no-deps sub2api

status=\"\$(docker ps --filter name=^/sub2api$ --format '{{.Status}}' | head -n 1)\"
if [ -z \"\${status}\" ] || [[ \"\${status}\" != Up* ]]; then
  echo \"sub2api is not running after update\" >&2
  exit 1
fi

mkdir -p \"\${STATE_DIR}\"
printf '%s\n' \"\${now_epoch}\" > \"\${STATE_FILE}\"
echo \"update_complete=true\"
SH
chmod +x /usr/local/sbin/sub2api-auto-update.sh
systemctl daemon-reload
systemctl restart sub2api-update.timer"

vpsops "${REMOTE_HOST}" batch \
  --cmd "cd '${REMOTE_DEPLOY_DIR}' && docker compose ps sub2api" \
  --cmd "docker inspect sub2api --format '{{json .Config.Image}} {{json .Image}}'" \
  --cmd "docker logs sub2api --tail 80 | tail -n 40" \
  --cmd "curl -fsS http://127.0.0.1:9080/api/health || curl -fsS http://127.0.0.1:9080/health || true"

echo "done image_ref=${IMAGE_REF}"
