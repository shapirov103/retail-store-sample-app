#!/usr/bin/env bash
# Demo helpers for re:Invent CON340. Run from anywhere inside the repo.
# Reads names from `terraform output` in terraform/ecs/riv. See RIV.md.
#
#   riv/demo.sh status          service health, deployments, store URL
#   riv/demo.sh chaos-on [code] catalog API returns <code> (default 500); /health stays 200
#   riv/demo.sh chaos-off       clear the catalog fault
#   riv/demo.sh break-deploy    commit the bad catalog port change and push to main
#   riv/demo.sh fix-deploy      revert the last break-deploy commit and push
#
# chaos-* use ECS Exec into the ui task (catalog is only reachable inside the VPC),
# so they need the AWS CLI Session Manager plugin.

set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
TF_DIR="$REPO_ROOT/terraform/ecs/riv"
CONFIG_GO="src/catalog/config/config.go"
BREAK_MSG="chore(catalog): move default listen port to 8000"

tf_out() { terraform -chdir="$TF_DIR" output -raw "$1"; }

load_env() {
  REGION="$(tf_out region)"
  CLUSTER="$(tf_out cluster_name)"
  APP_URL="$(tf_out application_url)"
}

ui_task() {
  aws ecs list-tasks --region "$REGION" --cluster "$CLUSTER" --service-name ui \
    --desired-status RUNNING --query 'taskArns[0]' --output text
}

exec_in_ui() {
  local task
  task="$(ui_task)"
  [[ "$task" == "None" || -z "$task" ]] && { echo "no running ui task" >&2; exit 1; }
  aws ecs execute-command --region "$REGION" --cluster "$CLUSTER" --task "$task" \
    --container ui-service --interactive --command "$1"
}

cmd_status() {
  load_env
  echo "Store: $APP_URL"
  aws ecs describe-services --region "$REGION" --cluster "$CLUSTER" \
    --services ui catalog carts \
    --query 'services[].{service:serviceName,running:runningCount,desired:desiredCount,rollout:deployments[0].rolloutState,taskdef:deployments[0].taskDefinition}' \
    --output table
}

cmd_chaos_on() {
  local code="${1:-500}"
  [[ "$code" =~ ^[1-5][0-9][0-9]$ ]] || { echo "status code must be 100-599" >&2; exit 1; }
  load_env
  exec_in_ui "curl -s -X POST http://catalog/chaos/status/$code"
}

cmd_chaos_off() {
  load_env
  exec_in_ui "curl -s -X DELETE http://catalog/chaos/status"
}

cmd_break_deploy() {
  cd "$REPO_ROOT"
  if ! git diff --quiet || ! git diff --cached --quiet; then
    echo "working tree not clean" >&2
    exit 1
  fi
  grep -q 'env:"PORT,default=8080"' "$CONFIG_GO" || { echo "expected default=8080 in $CONFIG_GO" >&2; exit 1; }
  sed -i.bak 's/env:"PORT,default=8080"/env:"PORT,default=8000"/' "$CONFIG_GO" && rm -f "$CONFIG_GO.bak"
  git add "$CONFIG_GO"
  git commit -m "$BREAK_MSG"
  git push origin HEAD:main
  echo "Pushed. Watch: Actions > Deploy catalog"
}

cmd_fix_deploy() {
  cd "$REPO_ROOT"
  local sha
  sha="$(git log --format=%H --grep="^${BREAK_MSG}\$" -n 1)"
  [[ -n "$sha" ]] || { echo "no break-deploy commit found" >&2; exit 1; }
  git revert --no-edit "$sha"
  git push origin HEAD:main
}

case "${1:-}" in
  status) cmd_status ;;
  chaos-on) shift; cmd_chaos_on "${1:-}" ;;
  chaos-off) cmd_chaos_off ;;
  break-deploy) cmd_break_deploy ;;
  fix-deploy) cmd_fix_deploy ;;
  *) sed -n '2,13p' "$0"; exit 1 ;;
esac
