# CON340 demo playbook

How to run the demo with `riv/demo.sh`: Part 1 injects a fault, Part 2 ships a bad commit. Setup and
background are in [SETUP.md](./SETUP.md) and [../RIV.md](../RIV.md). Times below are from real runs in
October 2026 unless marked "expected".

## The two parts

| | Part 1: fault injection | Part 2: bad commit |
| --- | --- | --- |
| Command | `riv/demo.sh chaos-on` | `riv/demo.sh break-deploy` |
| What it does | Tells the running catalog task to return HTTP 500 on `/catalog/*` (ECS Exec into the ui container, then `curl -X POST http://catalog/chaos/status/500`) | Commits `default=8080` to `default=8000` in `src/catalog/config/config.go` and pushes to `main`; the pipeline deploys it |
| Time to symptom | Seconds | About 3.5 min until catalog goes down; ECS should mark the deployment FAILED roughly 12 to 15 min after the push (estimate, see the timeline) |
| Users see | `/home` and `/catalog` return 500, `/cart` works | Same, once the old catalog task stops |
| ECS and load balancer | All green, nothing red | Catalog 0 of 1 tasks, failed health checks, deployment IN_PROGRESS then FAILED |
| Pipeline | Green (no deploy) | Red (Actions job times out waiting) |
| What the agent has to find | That a human switched on a fault via ECS Exec (CloudTrail records the exact command) | That the new image listens on 8000 while the health check calls 8080 (needs the GitHub repo) |
| Undo | `riv/demo.sh chaos-off` | `riv/demo.sh fix-deploy` (about 6 min) |

Run one at a time. Chaos plus a deploy in the same window confused the agent in an earlier take.

## Before every run

```bash
export AWS_PROFILE="<demo-account-profile>" AWS_DEFAULT_REGION=us-east-1
cd <repo>
riv/demo.sh preflight        # every line should say PASS
```

`preflight` is read-only and uses no ECS Exec, so it leaves nothing in CloudTrail. It checks the four ECS
services, catalog's deployment settings (max 100, min 0, circuit breaker on, rollback off), the three store
pages and their latency, git state (clean, on `main`, in sync, catalog port still 8080), the last pipeline
run, and how long the load generator's current hour has left.

Also:
- Sign in to the DevOps Agent web app right before you start. IAM sign-in sessions last 30 minutes.
- Start screen recording before the fault, not after.
- If preflight warns that the load generator ends within 10 minutes, wait or accept a short traffic gap.
  Each load run lasts 60 minutes, then ECS restarts it.

## Part 1: fault injection

1. `riv/demo.sh chaos-on`. Expect `{"message":"Error status code set to 500"}` and the command exits after
   about a second. That is normal: the fault lives in the catalog task's memory.
2. Reload the store. `/home` and `/catalog` return 500, `/cart` works. ECS shows every service healthy.
   Wait a minute or two so the load generator's traffic puts errors in the logs and traces.
3. In the DevOps Agent web app, start an investigation. Describe the symptom, not the cause. Suggested text,
   not a tested prompt: "The retail store home and catalog pages are returning HTTP 500 errors, but the ECS
   services and load balancer look healthy. Find the cause."
4. Expect about 15 minutes (interim output was still arriving at 11 minutes). Do not run this live; use the
   finished investigation named "500 errors on ECS retail store application" or a recording.
5. `riv/demo.sh chaos-off`, then `riv/demo.sh preflight`.

What the agent found last time: catalog returning empty 500s, the UI propagating them, no deployment or
config change, and the ECS Exec calls in CloudTrail with the command text, attributed to a human. It
initially dismissed those events as its own access, then corrected itself. It also proposed disabling ECS
Exec and recycling catalog.

## Part 2: bad commit

Order of events (expected unless noted):

| Time after push | Event |
| --- | --- |
| 0 | `riv/demo.sh break-deploy` pushes the commit. The "Deploy catalog" Actions run starts. |
| about 2.5 min | Image built and pushed to ECR; the new task definition is registered and the catalog service is updated (observed: image pushed at +2m32s, service updated at +2m35s). |
| about 3.5 min | New task starts. With min healthy 0 the old task stops first, so the store returns 500. |
| about 6 min | First failed health check (observed +5m41s: the task started at +3m20s and failed 2m21s later). |
| 12 to 15 min | Third failed task, when the circuit breaker should mark the deployment FAILED and stop retrying. **Estimate only.** |
| about 13 min | Actions job fails by timeout (observed 12m26s total in the first run). |

Observed failed-task counts in the first run, which had no circuit breaker: 1 at +6 min, 4 at +17 min, 5 at
+24 min, 7 at +30 min. ECS spaces out retries, and one gap between a failure and the next task start was
about 9 minutes, so the time to a third failure varies. Do not promise an exact time on stage. Start
`break-deploy` early enough, and check `aws ecs describe-services` for `rolloutState` before relying on FAILED.

1. `riv/demo.sh break-deploy`.
2. Show the red Action run, then the ECS console (below), then the failing store.
3. When `/catalog` returns 500, start an investigation. Suggested text, untested: "The Deploy catalog pipeline
   failed and the catalog service in riv-retail-cluster has no running tasks. Find the root cause and propose
   a fix."
4. `riv/demo.sh fix-deploy` to recover (about 6 min: revert pushed, pipeline redeploys). Then `preflight`.

What to show in the ECS console (from general ECS knowledge; check against your console): cluster
`riv-retail-cluster`, service `catalog`. The Deployments tab (revision in progress, failed task count), the
Events tab (`failed container health checks`), and the stopped tasks' stopped reason. The GitHub error is only
"Waiter has timed out", which says nothing about why. Without a circuit breaker the console shows nothing red
at all, just "0 of 1 tasks".

What the agent should find: the new revision differs from the old only in the image; the failing change is
the port default in `config.go` in the latest catalog commit. Without GitHub connected it could not see the
code and blamed the OpenSearch-disabled startup path, which is wrong. It also stated "confirmed" without
evidence. Check its claims against ECS and CloudTrail before relying on them.

## The "prevent" step

Turn on circuit breaker rollback so ECS restores the last COMPLETED revision by itself:

```bash
aws ecs update-service --cluster riv-retail-cluster --service catalog \
  --deployment-configuration 'maximumPercent=100,minimumHealthyPercent=0,deploymentCircuitBreaker={enable=true,rollback=true}'
```

Use `update-service`, not `terraform apply`: the provider waits for the service to become stable and hangs
while a deployment is failing. Afterwards set `deployment_circuit_breaker_rollback = true` in
`terraform/ecs/riv/services.tf` and commit it so the code matches the live service (`terraform plan` should
then say "No changes"). Set it back to `false` before the next take of Part 2. Rollback needs an earlier
COMPLETED deployment, which exists. Rollback itself has not been run yet.

## Reset checklist

| Situation | Do |
| --- | --- |
| After Part 1 | `riv/demo.sh chaos-off` |
| After Part 2 | `riv/demo.sh fix-deploy`, wait for the run to finish |
| Any time | `riv/demo.sh preflight`; all PASS means ready |
| Chaos left on after a catalog redeploy | Nothing to do: a replaced task starts clean |

No reset is needed on the DevOps Agent side. There is no way to delete past investigations from the CLI, and
deleting the agent space would lose the topology, which took hours to learn.

## Gotchas

- `terraform output` reads local state, so `demo.sh` only works on the machine that ran `terraform apply`.
- In zsh, write `${VAR}:` inside ARNs. A bare `$VAR:a` is a path modifier and silently corrupts the value.
- `gh run watch` hung for 15 minutes on a run that had already finished. Use `gh run view <id>` instead.
- Image tags are immutable. The workflow adds the run number and attempt to the tag so re-runs work.
- The circuit breaker did not act on a deployment that was already failing when it was enabled (inferred).
  Enable it before the break.
- The agent role can read ECS but cannot change it (no `UpdateService` or `ExecuteCommand`).
- Usage is metered in hours (`aws devops-agent get-account-usage --region us-east-1`). No price per hour found.
- The GitHub OIDC trust needs the exact subject prefix for this repo; see SETUP.md.

## Not yet observed or built

- Part 2 with the circuit breaker on has not been run end to end: not yet seen the deployment turn FAILED,
  how the console shows it, or how the Actions job reacts.
- The agent with GitHub connected has not yet investigated a bad commit.
- Circuit breaker rollback has not been run.
- Demo 2 (a custom agent that enforces a guardrail and acts) is not built. Open question: whether a custom
  agent can take write actions on its own; the agent's default role is read-only.
- Demo 3 (mitigation plan handed to Kiro, which opens a PR) is not built. The PR title must start with a
  conventional prefix such as `fix(catalog):` or the repo's PR title check fails.
- The learned Pipeline topology view has not generated yet (the generation job is slow).
- Demo 2 and 3 plans and a recording plan are still to be decided.
