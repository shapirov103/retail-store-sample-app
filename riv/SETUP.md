# CON340 setup and demo steps

Everything to get from a fresh clone to a running demo, in order. Steps 1 to 6 build and verify the
app and pipeline. Steps 7 and 8 bring in the DevOps Agent. Background and topology are in
[RIV.md](../RIV.md).

Set the AWS profile for the demo account in every shell before anything else. Replace the placeholder
with your own profile name.

```bash
export AWS_PROFILE="<demo-account-profile>" AWS_DEFAULT_REGION=us-east-1
aws sts get-caller-identity        # confirm this is the demo account
```

Prerequisites: AWS CLI v2 with the Session Manager plugin, Terraform 1.5 or newer, `gh` logged in
with repo and workflow scopes, `jq`, `git`.

## Deploy the app

| # | Step | Command | Expected result |
| --- | --- | --- | --- |
| 1 | Push the repo to GitHub | `git push origin HEAD:main` | Fork on `main`. One deploy run starts and skips itself (variables not set yet). |
| 2 | Create the AWS stack | `cd terraform/ecs/riv && terraform init && terraform apply` | About 68 resources: VPC, ECS cluster, ui, catalog, carts, load balancer, DynamoDB, ECR, deploy role, load generator. State stays local. |
| 3 | Give GitHub the deploy settings | see below | Repository variables set from Terraform outputs. |
| 4 | Run the pipeline once on good code | `gh workflow run deploy-catalog.yml --repo <owner>/<repo>` | Job goes green. Catalog now runs an image built in this account. Do not re-run on the same commit (image tags are immutable). |
| 5 | Check the stack | `riv/demo.sh status` | ui, catalog, carts each 1 running. |
| 6 | Open the store | `terraform -chdir=terraform/ecs/riv output -raw application_url` | Store loads. The load generator keeps traffic flowing. |

Step 3 command:

```bash
terraform -chdir=terraform/ecs/riv output -json github_variables \
  | jq -r 'to_entries[] | "\(.key) \(.value)"' \
  | while read -r k v; do gh variable set "$k" --body "$v" --repo <owner>/<repo>; done
```

How GitHub reaches AWS: an OIDC trust, no stored keys. Only workflow runs on the `main` branch of the
repo named in `terraform/ecs/riv/variables.tf` (`github_repository`) can assume the deploy role.
See `terraform/ecs/riv/github.tf`.

If the deploy job fails at "AWS credentials (OIDC)" with "Not authorized to perform
sts:AssumeRoleWithWebIdentity", the repository probably uses GitHub's immutable subject claim, where the
token subject includes numeric owner and repo IDs. Read the exact prefix and pass it to Terraform:

```bash
echo "github_subject_prefix = \"$(gh api repos/<owner>/<repo>/actions/oidc/customization/sub --jq .sub_claim_prefix)\"" \
  > terraform/ecs/riv/local.auto.tfvars    # git-ignored
terraform -chdir=terraform/ecs/riv apply
```

This fork needed it.

## Bring in the DevOps Agent

Done from the CLI, following the
[onboarding guide](https://docs.aws.amazon.com/devopsagent/latest/userguide/getting-started-with-aws-devops-agent-cli-onboarding-guide.html).
Use `us-east-1` (release management preview runs only there). Use braces around shell variables that
are followed by a colon (`${ACCT}:agentspace`); in zsh a bare `$ACCT:a` is a path modifier and silently
corrupts the ARN.

| # | Step | Command | Result |
| --- | --- | --- | --- |
| 7a | Agent space role | `aws iam create-role --role-name DevOpsAgentRole-AgentSpace` with trust for `aidevops.amazonaws.com` (conditions: your account, `arn:aws:aidevops:<region>:<acct>:agentspace/*`), then attach `AIDevOpsAgentAccessPolicy` and an inline policy allowing `iam:CreateServiceLinkedRole` for the Resource Explorer role | Role created |
| 7b | Web app role | Same trust plus `sts:TagSession`, named `DevOpsAgentRole-WebappAdmin`, with `AIDevOpsOperatorAppAccessPolicy` | Role created |
| 7c | Create the space | `aws devops-agent create-agent-space --name con340-riv-retail --region us-east-1` | Returns `agentSpaceId` |
| 7d | Associate the account | `aws devops-agent associate-service --agent-space-id <id> --service-id aws --configuration '{"aws":{"assumableRoleArn":"<AgentSpace role arn>","accountId":"<acct>","accountType":"monitor"}}'` | Association status `valid` |
| 7e | Enable the web app | `aws devops-agent enable-operator-app --agent-space-id <id> --auth-flow iam --operator-app-role-arn <WebappAdmin role arn>` | Returns the web app URL |

Find the space and URL later with `aws devops-agent list-agent-spaces --region us-east-1` and
`aws devops-agent get-operator-app --agent-space-id <id> --region us-east-1`.

Web app sign-in is IAM (admin access). Sessions last 30 minutes, so relaunch it mid-talk or switch to
IAM Identity Center, which this account does not have.

| # | Step | Notes |
| --- | --- | --- |
| 8 | Register GitHub and associate the repo | **Console only.** Register GitHub in the DevOps Agent console (Capabilities > Pipeline), then run `aws devops-agent list-services` to get the GitHub service id and `aws devops-agent associate-service` with a `github` configuration (`repoName`, `repoId`, `owner`, `ownerType`). Needed for the fix-PR flow in demo 3, not for demo 1. |

Usage is metered in hours (investigation, evaluation, system learning, on demand), with no limit set
(`aws devops-agent get-account-usage`). No per-hour price was found. Check the billing console after
the first investigations.

## Run Demo 1

| Scenario | Command | What you see | Undo |
| --- | --- | --- | --- |
| Errors while everything is green | `riv/demo.sh chaos-on` | Catalog pages return 500; ECS and the load balancer stay healthy; pipeline stays green. | `riv/demo.sh chaos-off` |
| Failed deployment | `riv/demo.sh break-deploy` | Store keeps working. New catalog tasks fail their health check; the Actions job turns red after about 10 minutes. | `riv/demo.sh fix-deploy` |

Then start an investigation in the DevOps Agent web app and let it find catalog.

## Tear down

```bash
terraform -chdir=terraform/ecs/riv destroy
```

The ECR repository is force-deleted with its images. The GitHub repository variables are left in place.

## Progress log

Last updated 2026-10-07.

| Step | Status |
| --- | --- |
| 1 Push | Done |
| 2 Create stack | Done (68 resources) |
| 3 GitHub variables | Done |
| 4 First pipeline run | Done, green (needed two fixes, see RIV.md) |
| 5 to 6 Verify | Done: services 1/1, store returns 200, load generator running with 0 failures, traces and Container Insights present |
| Demo 1 `chaos-on` / `chaos-off` | Tested in AWS, works |
| Demo 1 `break-deploy` / `fix-deploy` | Not run yet |
| 7 DevOps Agent space | Done: roles, space, account association `valid`, web app enabled (IAM sign-in) |
| 8 GitHub association | Not done (console registration needed) |
| First investigation | Not started |

Resources that cost money while the stack is up: NAT gateway, load balancer, and five Fargate tasks
(ui, catalog, carts with sidecars, plus the load generator). Run the teardown step when not rehearsing.
