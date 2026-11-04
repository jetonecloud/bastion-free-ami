# IAM policies

Two separate roles are involved. **Do not conflate them** — the first
is powerful, the second is deliberately tiny.

| Role | Used by | Defined in |
|---|---|---|
| **Pipeline / OIDC role** | GitHub Actions, to build and publish the AMI | [`iam-policy.json`](iam-policy.json) |
| **Access node instance role** | The EC2 instances themselves | `terraform/modules/access-node/iam.tf` |

---

## 1. The pipeline role

`vars.AWS_ROLE_ARN` in `.github/workflows/pipeline.yml`. Apply
[`iam-policy.json`](iam-policy.json), replacing `ACCOUNT_ID` and
`REGION`. The file is valid, appliable JSON with no placeholder keys to
strip.

### What each statement is for

| Sid | Why it is needed |
|---|---|
| `DescribeForBuildPlanning` | Packer resolves the source AMI, subnet, and instance type before launching. All read-only. `Resource: "*"` is unavoidable — every action is a Describe/List operation that enumerates across the account and accepts no resource ARN. |
| `ManageTheEphemeralBuildInstance` | Launch, tag, and terminate the short-lived build instance. Bounded by `aws:RequestedRegion`. |
| `ManageTheEphemeralBuildKeyPairAndSecurityGroup` | Packer mints a throwaway ed25519 key pair per build and discards it on exit. When `security_group_ids` is empty it also creates a temporary group scoped to its own public IP. Both are deleted when the build ends. |
| `CreateAndTagTheAmi` | Register the image and its encrypted snapshot, and copy it to `ami_regions`. |
| `ReadThePublicAl2023Parameter` | **Only needed in `al2023-base` mode.** The default mode resolves the source AMI with a `source_ami_filter` and does not call SSM. Drop this statement if you only build in the default mode. |
| `PublishThisProjectsAmiPointer` | Write `/bastion-free-ami/<region>/latest` and the per-architecture parameters. Scoped to this project's own namespace. |
| `EncryptTheRootVolumeAndSnapshot` | Root volume and snapshot encryption, which is not optional in this template. |

### Narrowing it further

- **`key/*` in the KMS statement** is needed only when relying on the
  account's default EBS key, whose ID is not known in advance. If you
  pin `kms_key_id` in the Packer vars, replace `key/*` with that exact
  key ARN.
- **The EC2 statements** can be narrowed with a condition on the build
  VPC if you run builds in a dedicated one:
  ```json
  "Condition": {
    "StringEquals": { "ec2:Vpc": "arn:aws:ec2:REGION:ACCOUNT_ID:vpc/vpc-BUILD" }
  }
  ```
  Note this does not apply to `ec2:RunInstances` for every resource
  type, so test it before relying on it.
- **`iam:PassRole` is deliberately absent.** The build instance needs no
  AWS API access from inside, so no instance profile is attached to it.
  If you add one, grant `iam:PassRole` scoped by name prefix *and* by
  `iam:PassedToService: ec2.amazonaws.com`, so it cannot be used to
  pass an arbitrary role to EC2.

### OIDC trust policy

Scope the `sub` condition to this repository. A trust policy with
`repo:ORG/REPO:*` lets **any branch or pull request** in the repo
assume the role; prefer restricting it to the branch and tag refs the
pipeline actually runs on.

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Federated": "arn:aws:iam::ACCOUNT_ID:oidc-provider/token.actions.githubusercontent.com"
      },
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Condition": {
        "StringEquals": {
          "token.actions.githubusercontent.com:aud": "sts.amazonaws.com"
        },
        "StringLike": {
          "token.actions.githubusercontent.com:sub": [
            "repo:jetonecloud/bastion-free-ami:ref:refs/heads/main",
            "repo:jetonecloud/bastion-free-ami:ref:refs/tags/v*"
          ]
        }
      }
    }
  ]
}
```

This pairs with the workflow design: `pipeline.yml` has no
`pull_request` trigger, so even a permissive `sub` would not let a fork
build — but defence in depth is cheap here, and a future edit to the
triggers would otherwise become a publish path.

---

## 2. The access node instance role

Created by `terraform/modules/access-node`. Shown here so you can see
how small it is, because **everything this role can do, anyone with a
shell on the access node can do** — and the point of the node is that
many people can.

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "SessionManagerChannel",
      "Effect": "Allow",
      "Action": [
        "ssm:UpdateInstanceInformation",
        "ssmmessages:CreateControlChannel",
        "ssmmessages:CreateDataChannel",
        "ssmmessages:OpenControlChannel",
        "ssmmessages:OpenDataChannel"
      ],
      "Resource": "*"
    },
    {
      "Sid": "SessionLogsToCloudWatch",
      "Effect": "Allow",
      "Action": ["logs:CreateLogStream", "logs:PutLogEvents", "logs:DescribeLogStreams"],
      "Resource": [
        "arn:aws:logs:REGION:ACCOUNT_ID:log-group:/aws/ssm/bfa/sessions",
        "arn:aws:logs:REGION:ACCOUNT_ID:log-group:/aws/ssm/bfa/sessions:*"
      ]
    },
    {
      "Sid": "SessionDataEncryption",
      "Effect": "Allow",
      "Action": ["kms:Decrypt", "kms:GenerateDataKey"],
      "Resource": "arn:aws:kms:REGION:ACCOUNT_ID:key/KEY_ID"
    }
  ]
}
```

### Why not `AmazonSSMManagedInstanceCore`

That AWS managed policy is the usual answer, and this module
deliberately does not attach it. It grants Run Command document access,
Parameter Store reads, and broad S3 access that an access node does not
need — and that every person with a session would inherit. The five
`ssmmessages`/`ssm` actions above are what AWS documents as the minimum
for Session Manager, and they are all this role gets.

### The unavoidable wildcards

Three places, each commented in the source:

- **`ssmmessages:*` actions** operate on the agent's own control and
  data channel, which has no ARN to name. AWS's own documented minimal
  instance policy uses `"*"` here.
- **`ssm:UpdateInstanceInformation`** writes the calling instance's own
  registration record.
- **`logs:DescribeLogGroups`** (granted separately) is a list operation
  over the account's log groups with no condition key to narrow it. SSM
  Agent calls it to confirm the configured group exists. It leaks log
  group names and nothing else.

Everything else is scoped to one log group, one bucket prefix, and one
KMS key — tighter than AWS's example policy, which uses `"*"` for
`logs:*`, `s3:GetEncryptionConfiguration`, and `kms:GenerateDataKey`.

---

## 3. Team access roles

Created by `terraform/modules/access-iam`. See
[that module's README](../terraform/modules/access-iam/README.md) —
particularly the section on IAM having no condition key for
port-forwarding parameters, which is the reason per-target session
documents exist.
