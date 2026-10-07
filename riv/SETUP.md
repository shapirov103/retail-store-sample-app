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

## Bring in the DevOps Agent

| # | Step | Notes |
| --- | --- | --- |
| 7 | Create the agent space in us-east-1 | Follow the [CLI onboarding guide](https://docs.aws.amazon.com/devopsagent/latest/userguide/getting-started-with-aws-devops-agent-cli-onboarding-guide.html): two IAM roles, create the space, associate the account, enable the web app. Web app sign-in is either IAM Identity Center or admin access (IAM, 30-minute sessions). |
| 8 | Associate the GitHub repo | Lets the agent read the code. Needed for the fix-PR flow in demo 3. |

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

Update this table as steps complete.

| Step | Status |
| --- | --- |
| 1 Push | not done |
| 2 Create stack | not done |
| 3 GitHub variables | not done |
| 4 First pipeline run | not done |
| 5 to 6 Verify | not done |
| 7 to 8 DevOps Agent | not done |
