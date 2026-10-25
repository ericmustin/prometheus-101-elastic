#!/usr/bin/env bash
# Delete the cluster. The image and your .env stay.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/env.sh
source "${ROOT_DIR}/scripts/lib/env.sh"

# Not `k3d cluster list | grep -q`: under pipefail, grep exiting at the first
# match can SIGPIPE k3d and fail the whole test while the cluster is listed.
if grep -q "^${CLUSTER_NAME} " <<<"$(k3d cluster list 2>/dev/null)"; then
  k3d cluster delete "${CLUSTER_NAME}"
  log_ok "Deleted k3d cluster '${CLUSTER_NAME}'."
else
  log_info "No cluster named '${CLUSTER_NAME}'."
fi

rm -rf "${TMP_DIR}"
log_ok "Cleared .tmp/"
log_info "Data already sent to Elastic is untouched. Remove it there if you want it gone."
