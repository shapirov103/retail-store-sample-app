#!/usr/bin/env bash
# Demo helpers for re:Invent CON340. Run from anywhere inside the repo.
# Reads names from `terraform output` in terraform/ecs/riv. See RIV.md.
#
#   riv/demo.sh preflight       check everything a demo run depends on (read-only, no ECS Exec)
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

cmd_preflight() {
  load_env
  cd "$REPO_ROOT"
  local fails=0 warns=0
  ok() { printf '  PASS  %s\n' "$*"; }
  warn() { printf '  WARN  %s\n' "$*"; warns=$((warns + 1)); }
  bad() { printf '  FAIL  %s\n' "$*"; fails=$((fails + 1)); }

  echo "Account $(aws sts get-caller-identity --query Account --output text), region $REGION, cluster $CLUSTER"

  echo "ECS services"
  local svc running desired rollout
  while read -r svc running desired rollout; do
    if [[ "$running" == "$desired" && "$rollout" == "COMPLETED" ]]; then
      ok "$svc $running/$desired, rollout $rollout"
    else
      bad "$svc $running/$desired, rollout $rollout"
    fi
  done < <(aws ecs describe-services --region "$REGION" --cluster "$CLUSTER" \
    --services ui catalog carts loadgen \
    --query 'services[].[serviceName,runningCount,desiredCount,deployments[0].rolloutState]' --output text)

  echo "Catalog deployment settings (the break-deploy demo expects max 100, min 0, breaker on, rollback off)"
  local maxp minp cb rb
  read -r maxp minp cb rb < <(aws ecs describe-services --region "$REGION" --cluster "$CLUSTER" --services catalog \
    --query 'services[0].deploymentConfiguration.[maximumPercent,minimumHealthyPercent,deploymentCircuitBreaker.enable,deploymentCircuitBreaker.rollback]' --output text)
  cb="$(printf '%s' "$cb" | tr '[:upper:]' '[:lower:]')"
  rb="$(printf '%s' "$rb" | tr '[:upper:]' '[:lower:]')"
  if [[ "$maxp" == "100" && "$minp" == "0" && "$cb" == "true" && "$rb" == "false" ]]; then
    ok "max $maxp, min $minp, circuit breaker $cb, rollback $rb"
  else
    warn "max $maxp, min $minp, circuit breaker $cb, rollback $rb (differs from the demo setup)"
  fi

  echo "Store ($APP_URL)"
  local path result code secs
  for path in /home /catalog /cart; do
    result="$(curl -s -o /dev/null -w '%{http_code} %{time_total}' -H 'Accept: text/html' "$APP_URL$path" || echo '000 0')"
    code="${result% *}"
    secs="${result#* }"
    if [[ "$code" != "200" ]]; then
      bad "$path returned $code"
    elif awk -v t="$secs" 'BEGIN { exit !(t > 2.0) }'; then
      warn "$path returned 200 but took ${secs}s (latency fault left on?)"
    else
      ok "$path returned 200 in ${secs}s"
    fi
  done

  echo "Load generator"
  local task started mins_left
  task="$(aws ecs list-tasks --region "$REGION" --cluster "$CLUSTER" --service-name loadgen --query 'taskArns[0]' --output text)"
  if [[ "$task" == "None" || -z "$task" ]]; then
    bad "no loadgen task running"
  else
    started="$(aws ecs describe-tasks --region "$REGION" --cluster "$CLUSTER" --tasks "$task" --query 'tasks[0].startedAt' --output text)"
    mins_left="$(python3 -c "import sys,datetime as d; s=d.datetime.fromisoformat(sys.argv[1]); print(int(60-(d.datetime.now(d.timezone.utc)-s).total_seconds()/60))" "$started")"
    if (( mins_left < 10 )); then
      warn "each load run lasts 60 minutes; this one ends in about ${mins_left} min, then traffic pauses briefly while ECS restarts it"
    else
      ok "running, current run ends in about ${mins_left} min"
    fi
  fi

  echo "Git"
  local repo ahead behind
  repo="$(git remote get-url origin | sed -E 's#.*github.com[:/]##; s#\.git$##')"
  git fetch -q origin
  read -r behind ahead < <(git rev-list --left-right --count origin/main...HEAD)
  if [[ "$(git rev-parse --abbrev-ref HEAD)" == "main" ]]; then ok "on main"; else bad "not on main"; fi
  if [[ "$ahead" == "0" && "$behind" == "0" ]]; then
    ok "in sync with origin/main"
  else
    bad "ahead $ahead, behind $behind vs origin/main"
  fi
  if git diff --quiet && git diff --cached --quiet; then ok "tracked files clean"; else bad "uncommitted changes"; fi
  if grep -q 'env:"PORT,default=8080"' "$CONFIG_GO"; then
    ok "catalog default port is 8080 (ready for break-deploy)"
  else
    bad "catalog default port is not 8080 (a break commit is still in place; run fix-deploy)"
  fi
  local last
  last="$(gh run list --repo "$repo" --workflow deploy-catalog.yml --limit 1 --json status,conclusion --jq '.[0] | "\(.status) \(.conclusion)"' 2>/dev/null || echo 'unknown')"
  if [[ "$last" == "completed success" ]]; then ok "last deploy-catalog run: success"; else warn "last deploy-catalog run: $last"; fi

  echo
  echo "$fails failed, $warns warnings"
  [[ "$fails" == "0" ]]
}

case "${1:-}" in
  preflight) cmd_preflight ;;
  status) cmd_status ;;
  chaos-on) shift; cmd_chaos_on "${1:-}" ;;
  chaos-off) cmd_chaos_off ;;
  break-deploy) cmd_break_deploy ;;
  fix-deploy) cmd_fix_deploy ;;
  *) sed -n '2,14p' "$0"; exit 1 ;;
esac
