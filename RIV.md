# re:Invent 2026 CON340: demo repo notes

This fork of [aws-containers/retail-store-sample-app](https://github.com/aws-containers/retail-store-sample-app)
is the demo environment for CON340, *Troubleshooting and Recovering Failed Amazon ECS Deployments*
(Containers track, code talk, 60 minutes). Speakers: Mikhail Shapirov and Vikram Venkataraman.

The talk shows AWS DevOps Agent investigating real ECS failures on this app. Upstream docs are in
[README.md](./README.md). This file covers only what is different for the talk.

**Step-by-step setup and demo commands: [riv/SETUP.md](./riv/SETUP.md).**

## Status (2026-10-07)

| Item | State |
| --- | --- |
| Trimmed Terraform stack, `terraform/ecs/riv/` | **Deployed** (68 resources, us-east-1). ui, catalog, carts and loadgen all 1/1, rollout COMPLETED. |
| CD workflow, `.github/workflows/deploy-catalog.yml` | **Green end to end** on a push to `main`: build, push to ECR, new task definition, ECS deploy, wait. About 7 minutes. Catalog now runs the image built by the pipeline. |
| Noisy upstream workflows | `e2e-test.yml` and `release-please.yml` switched to manual trigger only. |
| Demo helper script, `riv/demo.sh` | `status`, `chaos-on` and `chaos-off` **run against AWS and work**. `break-deploy` and `fix-deploy` **not run yet**. |
| UI behavior when catalog fails | **Tested in AWS**: `/home` and `/catalog` return 500, `/cart` returns 200, UI health stays UP. |
| Traces and metrics | X-Ray service map shows ui, carts and catalog. Container Insights metrics present. |
| DevOps Agent space | Not created. |

Problems found and fixed on the first real run:

- **OIDC subject.** This repo uses GitHub's immutable subject claim, so the token subject carries the
  numeric owner and repo IDs. Fixed with `github_subject_prefix` (`terraform/ecs/riv/variables.tf`).
  See `riv/SETUP.md`.
- **Missing `ecs:TagResource`** on the deploy role, needed to register a tagged task definition. Added,
  scoped to the catalog task definition family (`github.tf`).
- **Immutable ECR tags.** Re-running a workflow on the same commit failed at the image push. Tags now
  include the run number and attempt (`deploy-catalog.yml:76`).
- **Harmless sidecar noise.** The CloudWatch agent logs EC2 metadata errors on Fargate and falls back.
  Traces still arrive.

## The three demos

1. **Troubleshoot.** A deploy breaks catalog. DevOps Agent builds the topology, correlates ECS events,
   logs, metrics and traces, and names the root cause. A human validates it.
2. **Self-heal.** A DevOps Agent custom agent watches a guardrail condition and takes a narrow,
   pre-approved corrective action.
3. **Fix and release.** The agent's mitigation plan is handed to a coding agent (Kiro), which opens a
   pull request. A human reviews and merges, and the CD workflow redeploys.

On demo 3: in the DevOps Agent docs, "Release management" (preview, us-east-1 only) means reviewing
and testing changes *before* they ship. The "agent finds the bug, coding agent opens the PR" flow is
documented under Production operations as "agent-ready instructions that can be implemented by another
frontier agent, such as code improvements that can be implemented by Kiro." Present it that way.

## App topology

Three of the five upstream services are deployed. Orders and checkout are not deployed; the UI uses
its built-in mocks for them. This removes both RDS databases, OpenSearch, ElastiCache and Amazon MQ.

```
                 Internet  <-- loadgen (Artillery task, steady traffic through the ALB)
                    |
          ALB  (HTTP :80, health check: UI's own /actuator/health)
                    |
        +-----------v-----------+
        |  ui  (Java, Spring)   |   orders, checkout: in-process mocks
        +-----+-----------+-----+
              |           |         ECS Service Connect, namespace retailstore.local
              |           |         (callers use http://<service>, tasks listen on 8080)
     +--------v---+   +---v----------+
     | catalog    |   | carts (Java) |
     | (Go)       |   +------+-------+
     | in-memory  |          |
     | CI-deployed|   +------v-------+
     +------------+   |  DynamoDB    |
                      +--------------+

  Every app task: app container + cloudwatch-agent sidecar sending OTLP traces to X-Ray
  Cluster: Container Insights "enhanced"; task logs in "<env>-tasks";
  ECS events (deployments, stopped reasons) in "/aws/events/ecs/<env>"
```

| Node | Container health check | Data | Deployed by |
| --- | --- | --- | --- |
| ui | `curl localhost:8080/actuator/health` | none | Terraform |
| catalog | `curl localhost:8080/health` | in-memory | Terraform once, then the CD workflow |
| carts | `curl localhost:8080/actuator/health` | DynamoDB | Terraform |
| loadgen | none | none | Terraform |

All app services use `terraform/ecs/riv/modules/service`: Fargate, 1 vCPU / 2 GB, one task each,
health check every 10s after a 60s start period (`modules/service/ecs.tf:40-42`).

### What happens when catalog breaks

Two ways to break it, both verified against the code and the second one tested locally.

**1. Bad deploy (demo 1 and 3).** `riv/demo.sh break-deploy` commits a plausible one-line change:
catalog's default port goes from 8080 to 8000 (`src/catalog/config/config.go:21`). The health check
still calls 8080 (`modules/service/ecs.tf:40`), so every new catalog task is marked unhealthy and
replaced. The deploy never stabilizes, and the CD job fails after `DEPLOY_WAIT_MINUTES` (default 10,
`deploy-catalog.yml:99`). *Expected from the config; `break-deploy` has not been run in AWS yet.*

**2. Runtime fault (fast, repeatable rehearsal).** `riv/demo.sh chaos-on` makes catalog's API return
500 while its `/health` keeps returning 200. Nothing in ECS or at the ALB turns red.
`riv/demo.sh chaos-off` clears it. The fault lives in process memory, so a replaced task comes back
clean (`src/catalog/middleware/chaos.go:43`).

**What users and dashboards see.** Local test on 2026-10-02 with the published 1.6.3 images under
podman, UI pointed at catalog, after `POST /chaos/status/500` on catalog:

| Check | Result |
| --- | --- |
| catalog `/health` | 200 |
| catalog `/catalog/products` | 500 |
| ui `/actuator/health` (what ECS and the ALB check) | `{"status":"UP"}` |
| ui `/home` and `/catalog` pages | HTTP 500, styled error page |
| ui `/cart` page | 200 |

So the UI **fails, it does not degrade**: catalog-backed pages return 500 while every health check is
green. That is the story for demo 1: "all green, users get errors, and the cause is one hop away."
The UI calls catalog without error handling (`KiotaCatalogService.java:43`). If you want a page that
renders without products instead, that is a small Java change plus a UI image build; not done.

**The bad deploy does not break the store.** The riv Terraform sets no deployment limits, so ECS uses
its defaults (100% minimum healthy, 200% maximum; stated from general ECS knowledge, not tested
here). The old catalog task keeps serving while the new one fails its health check and gets replaced
over and over. Users see a working store. What goes red is the deployment: the CD job, the service
events, and the stopped-task reasons. An earlier version of this file said the store would error in
this case; that was wrong. So the two faults tell different stories:

| Fault | Users | ECS and ALB health | Pipeline | Agent has to find |
| --- | --- | --- | --- | --- |
| `break-deploy` | store works | new tasks keep failing, deployment never completes | red | why the new catalog tasks are unhealthy (port 8000 vs health check on 8080) |
| `chaos-on` | catalog pages return 500 | all green | green | that catalog is the source of UI errors |

## What changed versus upstream

| Path | Change |
| --- | --- |
| `terraform/ecs/riv/` | New root module. Reuses upstream `lib/vpc`, `lib/tags`, `lib/images` unchanged. |
| `terraform/ecs/riv/modules/service/` | Copy of `lib/ecs/service` with: `ci_managed` mode that ignores `task_definition` (`ecs.tf:183`) so Terraform does not roll back pipeline deploys; task ingress limited to the VPC CIDR (upstream allows 0.0.0.0/0); no secrets. |
| `terraform/ecs/riv/services.tf` | catalog in-memory, search off (`:25-26`); UI wired to catalog and carts only, search off (`:75-77`). |
| `terraform/ecs/riv/github.tf` | GitHub OIDC provider and a deploy role usable only from `main` of this repo (`:43`), scoped to the catalog ECR repo and service. |
| `terraform/ecs/riv/loadgen.tf` | Artillery service using the upstream scenario, hitting the ALB at 2 new users/s. |
| `terraform/ecs/riv/cluster.tf` | ECS events to CloudWatch Logs, Container Insights enhanced. |
| `.github/workflows/deploy-catalog.yml` | New CD workflow (below). |
| `.github/workflows/e2e-test.yml`, `release-please.yml` | Manual trigger only. |
| `riv/demo.sh` | Demo helper commands. |
| `.gitignore` | Ignores `terraform/ecs/riv/backend.tf` (optional shared-state config). |

Not configured on purpose: the ECS deployment circuit breaker. Turning it on is the "prevent" step.

## CI/CD

| Workflow | Trigger | Purpose in the demo |
| --- | --- | --- |
| `deploy-catalog.yml` | push to `main` touching `src/catalog/**`, or manual | The on-stage pipeline |
| `pr.yaml` (upstream, unchanged) | pull requests | Checks on Kiro's PR in demo 3: semantic title, lint, build and tests of changed projects |
| `e2e-test.yml`, `release-please.yml` | manual only | Not used |
| `artifacts.yaml`, `publish-build.yml`, `oss.yml` | manual or called | Not used |

`deploy-catalog.yml` steps: Go build and vet (catalog's `test/` package needs MySQL, so tests are
skipped), OIDC login, image build and push tagged with the commit SHA, render a new revision from the
latest registered task definition (`:86`, so only the image changes), update the service and wait for
stability. On failure it prints the last 10 ECS service events.

`pr.yaml` uses `amannn/action-semantic-pull-request`, so Kiro's PR title needs a conventional prefix
such as `fix(catalog): ...` or that check goes red on stage.

## Setup

Prerequisites: AWS CLI v2 with the Session Manager plugin, Terraform >= 1.5, `gh`. Use a dedicated
demo account.

```bash
# 1. Stack (state stays local in terraform/ecs/riv, git-ignored)
cd terraform/ecs/riv
terraform init
terraform apply                      # region defaults to us-east-1 (variables.tf)

# 2. GitHub repository variables for the CD workflow
terraform output -json github_variables \
  | jq -r 'to_entries[] | "\(.key) \(.value)"' \
  | while read -r k v; do gh variable set "$k" --body "$v" --repo shapirov103/retail-store-sample-app; done

# 3. Sanity check
../../../riv/demo.sh status
```

State is local, so only the laptop that ran `apply` can run `terraform output`, and `riv/demo.sh`
reads its names from there. To let the other speaker run the script or manage the stack, share state
through S3 (optional, see `terraform/ecs/riv/backend.tf.example`) or copy the `github_variables`
output values into their shell.

If the account already has a GitHub OIDC provider, apply with `-var create_github_oidc_provider=false`.
The demo account had none on 2026-10-02.

Account and credentials: every command (`terraform`, `aws`, `riv/demo.sh`) must run against the demo
account. Set `AWS_PROFILE` to that account's profile first; the shell default may point elsewhere.

Region: us-east-1, next to the DevOps Agent space. Checked 2026-10-02 in the demo account: VPCs
2 of 5, Elastic IPs 3 of 5, internet gateways 2 of 5, no `riv-retail` resources, no GitHub OIDC provider,
no `retailstore.local` namespace. The stack adds 1 VPC, 1 Elastic IP (NAT gateway) and 1 internet gateway.
An existing VPC also uses `10.0.0.0/16`; that only matters if the VPCs are ever
peered.

DevOps Agent space: create it in **us-east-1** (release management preview is us-east-1 only;
us-east-2 is not in the documented Region list). No AWS Support plan is required. Follow the
[CLI onboarding guide](https://docs.aws.amazon.com/devopsagent/latest/userguide/getting-started-with-aws-devops-agent-cli-onboarding-guide.html),
then associate this GitHub repository so the agent can read the code.

Teardown: `terraform destroy`. The ECR repo is force-deleted with its images.

## Demo runbook

| When | Command | Effect |
| --- | --- | --- |
| Before the talk | `riv/demo.sh status` | All three services 1/1, rollout COMPLETED |
| Start of talk or during the concepts slides | `riv/demo.sh break-deploy` | Pushes the bad port commit; CD job goes red about 10 minutes later |
| Rehearsing demo 1 without a deploy | `riv/demo.sh chaos-on` / `chaos-off` | Instant catalog 500s with green health checks |
| After demo 3 merge, or to reset | `riv/demo.sh fix-deploy` | Reverts the bad commit; CD redeploys the good image |

## Open questions

1. **DevOps Agent pricing** outside a Support plan. Not found yet.
2. **Can a custom agent take write actions on its own?** Demo 2 depends on it. Not verified.
3. **Demo 2 guardrail** is not built. Need to pick the condition and the action once (2) is answered.
4. **Docker Hub pulls.** The load generator pulls `artilleryio/artillery:2.0.22` from Docker Hub through
   one NAT IP. Anonymous pull limits could bite; mirror it to ECR if it does.
5. **First real run.** Nothing here has run in AWS yet. Expect fixes on first `terraform apply` and
   first workflow run.
