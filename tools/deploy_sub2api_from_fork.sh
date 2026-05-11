#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

REMOTE_HOST="${REMOTE_HOST:-sg}"
FORK_REPO="${FORK_REPO:-shiyi-jiaqiu/sub2api}"
IMAGE_REPO="${IMAGE_REPO:-ghcr.io/shiyi-jiaqiu/sub2api}"
IMAGE_TAG="${IMAGE_TAG:-}"
IMAGE_REF="${IMAGE_REPO}:${IMAGE_TAG}"

if ! command -v vpsops >/dev/null 2>&1; then
  echo "vpsops is required" >&2
  exit 1
fi

if ! command -v gh >/dev/null 2>&1; then
  echo "gh is required" >&2
  exit 1
fi

if [[ -z "${IMAGE_TAG}" ]]; then
  IMAGE_TAG="$(gh release view --repo "${FORK_REPO}" --json tagName -q .tagName | sed 's/^v//')"
fi

IMAGE_REF="${IMAGE_REPO}:${IMAGE_TAG}"

echo "remote_host=${REMOTE_HOST}"
echo "fork_repo=${FORK_REPO}"
echo "image_ref=${IMAGE_REF}"

PUSH_IMAGE=0 IMAGE_REPO="${IMAGE_REPO}" IMAGE_TAG="${IMAGE_TAG}" REMOTE_HOST="${REMOTE_HOST}" "${REPO_ROOT}/tools/deploy_sub2api_custom.sh"
