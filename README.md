# aws-ecs-copilot-deploy
GitHub Action to deploy your copilot application to ECS


## Inputs

### `environments`

**Required** Environments to deploy.

### `workloads`

**Required** Workloads to deploy.

### `bucket`

Bucket to upload CloudFormation template. Default generated name: `ecs-{AppName}`.

### `deploy-method`

Set the deploy method (`manual` | `automatic`). Default `manual`.


## Example usage
```yaml
- name: Deploy service
  uses: fuji97/aws-ecs-copilot-deploy@v1
  with:
    environments: prod
    workloads: backend frontend
    bucket: my-s3-bucket
    deploy-method: manual
```