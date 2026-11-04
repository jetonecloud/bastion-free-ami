# Migrating from a bastion

A staged migration that never leaves you without a way in. The ordering
is the point: **the bastion stays up and working until the new path has
been proven for every team and every access path**, and port 22 closes
last.

Expect this to take two to six weeks of calendar time for a team of
ten. Most of that is step 1 and step 3, and most of the risk is in
step 1 being done badly.

```
1. Inventory ──▶ 2. Deploy alongside ──▶ 3. Move and test each path
                                                      │
        6. Observation period ◀── 5. Close inbound ◀───┘
                    │
                    ▼
        7. Decommission and revoke keys
```

---

## 1. Inventory what uses the bastion

**Do not skip this, and do not do it from memory.** Every failed
bastion migration failed here: somebody's cron job, a vendor's IP
allowlist, or a CI deploy step turned out to depend on the bastion, and
nobody found out until it broke in production at 02:00.

### Find the humans

```sh
# Who has logged in, from the bastion's own records
sudo last -F -w | head -50
sudo lastlog

# Which keys are actually installed, and whose are they?
sudo find /home /root -name 'authorized_keys' -exec sh -c \
  'echo "== $1"; ssh-keygen -lf "$1"' _ {} \;

# Successful authentications over the retained period
sudo journalctl -u sshd --since '90 days ago' \
  | grep -E 'Accepted (publickey|password)' \
  | awk '{print $9, $11}' | sort | uniq -c | sort -rn
```

Any key whose owner you cannot name is itself a finding. Write it down
now; you will revoke it in step 7.

### Find the machines

This is the part people miss. Search for things that reference the
bastion by name or address:

```sh
# In your own repositories
rg -i 'bastion|jump(host|-host)|ProxyJump|ProxyCommand|ssh -J' \
   --glob '!**/node_modules/**'

# SSH client configs on the bastion and on laptops
grep -rn 'ProxyJump\|ProxyCommand' ~/.ssh/config /etc/ssh/ssh_config.d/ 2>/dev/null

# CI configuration
rg -i 'bastion|ssh-agent|SSH_PRIVATE_KEY|ProxyJump' \
   .github/ .gitlab-ci.yml Jenkinsfile 2>/dev/null

# Scheduled work ON the bastion -- a classic hiding place
sudo crontab -l; sudo ls -la /etc/cron.*/ /etc/systemd/system/*.timer
for u in $(cut -f1 -d: /etc/passwd); do sudo crontab -l -u "$u" 2>/dev/null; done
```

### Find the network dependencies

```sh
# What is actually connecting to the bastion right now?
sudo ss -tnp state established '( sport = :22 )'

# Who is allowed to? Each CIDR is a dependency to chase down --
# an office, a VPN, a vendor, or somebody's home IP from 2019.
aws ec2 describe-security-groups --group-ids <bastion-sg> \
  --query 'SecurityGroups[].IpPermissions' --output json

# Over a longer window, if you have VPC flow logs
aws logs start-query --log-group-name /aws/vpc/flowlogs \
  --start-time "$(date -d '30 days ago' +%s)" --end-time "$(date +%s)" \
  --query-string 'fields srcAddr, dstPort | filter dstPort = 22 and dstAddr like /10\./ | stats count(*) by srcAddr | sort by count(*) desc'
```

### Write it down

Produce a table and get it reviewed by each team lead. Do not proceed
until every row has an owner:

| # | Consumer | Type | Access path | Owner | Target state | Moved? | Tested? |
|---|---|---|---|---|---|---|---|
| 1 | Platform team (6 people) | Human | Shell + prod Postgres | @alice | `platform` role, shell + `bfa-pf-prod-db` | | |
| 2 | Analytics (4 people) | Human | Warehouse + Redis | @bob | `analytics` role, forwarding only, no shell | | |
| 3 | `nightly-db-backup` cron | Machine | Runs **on** the bastion | @carol | ECS scheduled task in-VPC | | |
| 4 | GitHub Actions `deploy-migrations` | Machine | `ssh -J bastion` then `psql` | @dave | OIDC role + in-VPC runner | | |
| 5 | AcmeMonitoring vendor | Third party | Static IP allowlisted on 22 | @erin | Vendor's PrivateLink offering | | |
| 6 | `authorized_keys` entry `ops-laptop-2019` | Unknown | — | @alice | **Revoke** | | |

### A warning about machine consumers

Human access maps cleanly onto this kit. **Machine access often does
not**, and the honest answer is frequently "this should not go through
an access node at all":

- A cron job running *on* the bastion needs somewhere else to run — a
  scheduled ECS task, a Lambda in the VPC, or Systems Manager
  Automation. Not an access node. Access nodes are for humans and are
  replaced without warning.
- A CI job tunnelling to a database wants an in-VPC runner (see
  [`github-runner-ami`](https://github.com/jetonecloud/github-runner-ami))
  with an OIDC role, not a port-forward through a shared node.
- A vendor with an allowlisted IP needs PrivateLink, a VPC peering, or
  a purpose-built endpoint — not a seat on your access path.

Deciding these *now* is what keeps step 5 from stalling for a month.

---

## 2. Deploy this kit alongside the bastion

Nothing is removed in this step. Both paths work.

```sh
# Build and publish the AMI (CI does this on main; or locally)
cd packer
packer init .
packer build -var-file=x86_64.pkrvars.hcl -var-file=local.pkrvars.hcl .

# Deploy into the SAME VPC as the bastion, so routes and security
# groups behave identically and you are testing one variable.
cd ../terraform/examples/multi-team
cp terraform.tfvars.example terraform.tfvars
$EDITOR terraform.tfvars
terraform init && terraform plan
terraform apply
```

Then confirm the posture before anyone relies on it:

```sh
scripts/verify --tag BastionFreeAccess=shared \
               --log-group "$(terraform output -raw session_log_group)"
```

Expect the port-22 and inbound-rule checks to **fail at this stage** —
your bastion is still up and in scope if it shares a security group.
That is correct. The run is a baseline, and you will re-run it after
step 5 to show the change.

Also check the IAM wiring did what you think:

```sh
terraform output access_iam_warnings      # expect []
terraform output team_document_arns       # what each team can really reach
```

---

## 3. Move and test each access path, one team at a time

Work the inventory table. One team per change window; do not move
everyone at once, because a surprise found with one team is an
inconvenience and the same surprise found with five is an outage.

For each row:

1. **Grant the new access** — add the team to `module.access_iam`.
2. **Have the real user do their real work** through the new path.
   Not a smoke test you wrote: their actual Monday-morning task. This
   is where TLS hostname problems, cluster-mode caches, and
   `kubectl` certificate mismatches surface, and
   `docs/access-paths.md` has the fix for each.
3. **Record the exact command that worked** in the team's runbook.
   `scripts/connect --dry-run` prints it for you.
4. **Tick "Tested?"** in the table, with a date and the person's name.
5. **Leave the bastion path in place.**

### Per-path acceptance criteria

| Path | Done when |
|---|---|
| Shell | A user opens a session, lands as `ssm-user`, `sudo -n true` fails, and the transcript appears in the log group |
| RDS / Aurora | A user connects with `sslmode=verify-full` succeeding — not `require` — and runs a real query |
| ElastiCache | A user runs real commands; for cluster mode, the shard approach in `docs/access-paths.md` is written into the runbook |
| Internal HTTP | `curl --resolve` returns the expected response with certificate verification on |
| Private EKS | `kubectl get nodes` works without `insecure-skip-tls-verify` |
| Elevated access | The elevation role is assumable with MFA, lands as a sudo-capable user, and the `AssumeRole` appears in CloudTrail |
| Each machine consumer | Running in its new home with the bastion path already removed |

Do not accept "it mostly works". A path that needs
`insecure-skip-tls-verify` or `sslmode=require` to work is not migrated;
it is a security regression wearing a migration's clothes.

---

## 4. Confirm logs and alerts

Before you remove anything, prove the new path produces the evidence
you are about to depend on.

```sh
# Shell session transcripts are arriving
aws logs describe-log-streams \
  --log-group-name "$(terraform output -raw session_log_group)" \
  --order-by LastEventTime --descending --max-items 5

# Retention and encryption are actually set
aws logs describe-log-groups \
  --log-group-name-prefix "$(terraform output -raw session_log_group)" \
  --query 'logGroups[].{name:logGroupName,retention:retentionInDays,kms:kmsKeyId}'

# CloudTrail has the session records -- the authoritative source
aws cloudtrail lookup-events \
  --lookup-attributes AttributeKey=EventName,AttributeValue=StartSession \
  --max-items 10 --query 'Events[].{time:EventTime,user:Username}'
```

Then run the audit queries in `docs/queries/` and check the answers
match what you and your colleagues actually did today. If a session you
know happened is missing, find out why **now** — not during an incident.

### Set up the alerts you will rely on afterwards

Once the bastion is gone, the access path is a single point of failure
for your ability to operate. Alert on it:

- **No healthy access node.** Alarm on the ASG's
  `GroupInServiceInstances` falling below 1.
- **Disk pressure on the node** — `create_audit_disk_alarm = true`.
  The AMI does not halt on a full audit partition by design
  (`docs/design.md`), so this alarm is the compensating control.
- **Unusual session activity** — schedule
  `docs/queries/cloudtrail-unusual-access.sql` as a weekly review.
- **Session logging stopped.** A metric filter on the log group with
  `treat_missing_data = breaching`; silence here means either nobody
  worked today or logging broke.

### State the logging change explicitly

Your bastion's `sshd` logs and shell history gave you one kind of
record; this gives you a different one. Tell whoever depends on it:

- **Better**: every session attributed to an IAM principal, no shared
  accounts, authorisation decisions logged, immediate revocation.
- **Worse**: **tunnel traffic contents are not captured.** Your old
  bastion, if people ran `psql` on it, captured those commands in shell
  history. Port forwarding does not. If you need statement-level
  visibility, turn on the datastore's own audit logging now, in this
  step, before you lose the old path.

That last point is the one that catches teams out at their next audit.
Handle it here.

---

## 5. Remove inbound rules and public IPs — port 22 last

Only when every row of the inventory is ticked "Moved" and "Tested".

The order matters, and it is chosen so that each step is reversible in
under a minute and the most load-bearing thing changes last.

### 5a. Shrink the allowlist to one source

```sh
# Snapshot the current rules FIRST -- this is your rollback artefact.
aws ec2 describe-security-groups --group-ids <bastion-sg> \
  > rollback/bastion-sg-$(date +%F).json

# Remove every source except the one you will use to roll back from.
aws ec2 revoke-security-group-ingress --group-id <bastion-sg> \
  --protocol tcp --port 22 --cidr <vendor-or-stale-cidr>
```

Wait 48 hours. Watch for anything breaking. This step alone usually
flushes out one or two forgotten consumers.

### 5b. Remove the public IP

```sh
# Elastic IP: disassociate, but DO NOT RELEASE it yet. Releasing means
# you cannot get the same address back, and some vendor somewhere has
# it in an allowlist.
aws ec2 disassociate-address --association-id <assoc-id>
```

The bastion is now unreachable from the internet but still running and
still reachable from inside the VPC — so you can get to it through an
access node if you need to. Wait another 48 hours.

### 5c. Close port 22

```sh
aws ec2 revoke-security-group-ingress --group-id <bastion-sg> \
  --protocol tcp --port 22 --cidr <last-remaining-cidr>
```

### 5d. Prove it

```sh
scripts/verify --tag BastionFreeAccess=shared \
               --log-group "$(terraform output -raw session_log_group)" \
               --s3-bucket "$(terraform output -raw session_log_bucket)"
```

Every check should now pass. Keep this output: it is the before/after
evidence for your next review, paired with the baseline from step 2.

---

## 6. Keep a rollback path for a defined observation period

**Set the period before you start, write it down, and put a date on the
calendar.** Without a stated end, "we'll decommission it soon" becomes
a stopped bastion instance that is still in your account two years
later, still carrying its keys, and still in audit scope.

**Recommended: 30 days of normal operation**, extended to cover at
least one of each recurring event — a month-end close, a release, an
on-call rotation handover, and ideally one real incident. If your
quarter-end involves people doing unusual things with the database,
make sure the period spans it.

During the observation period:

| Keep | Why |
|---|---|
| The bastion instance, **stopped** | Startable in ~60 seconds; costs only EBS storage |
| Its security group, with **no inbound rules** | The rules are in `rollback/`, re-addable in one command |
| Its Elastic IP, **disassociated but allocated** | Re-associable; releasing loses the address permanently |
| The `authorized_keys` files, intact | Rolling back needs them. Revoke in step 7, not before |
| `rollback/bastion-sg-*.json` | The exact rules to restore |

### The rollback procedure, written out

Rehearse this once during the observation period. A rollback plan
nobody has executed is a hypothesis.

```sh
# 1. Start the bastion
aws ec2 start-instances --instance-ids <bastion-id>

# 2. Re-associate its address
aws ec2 associate-address --instance-id <bastion-id> \
  --allocation-id <eip-alloc-id>

# 3. Restore inbound access from your current location only
aws ec2 authorize-security-group-ingress --group-id <bastion-sg> \
  --protocol tcp --port 22 --cidr "$(curl -s https://checkip.amazonaws.com)/32"

# 4. Confirm
ssh -o ConnectTimeout=10 user@<bastion-ip> 'echo rollback-ok'
```

Target: under five minutes, by anyone on call, from this document alone.

### Deciding not to roll back

Rolling back is for "the new path cannot do something we need". It is
**not** for "someone found the new way unfamiliar". Decide which you
are looking at before you start the bastion, and record the reason — a
rollback with a written cause gets fixed, and one without becomes
permanent.

---

## 7. Decommission and revoke

Only after the observation period has elapsed with no rollback.

```sh
# 1. Revoke the keys FIRST, while you can still see what they were.
#    The point of the whole exercise: these keys must stop working
#    anywhere, not just on a host you are about to delete.
sudo cp -a /home/*/.ssh/authorized_keys /root/.ssh/authorized_keys \
  /tmp/revoked-keys-inventory/
ssh-keygen -lf /tmp/revoked-keys-inventory/authorized_keys

# Check every key you found against every other host.
# A key that opened the bastion very likely opens something else.
```

Then, in order:

```sh
# 2. Remove the EC2 key pair from AWS so it cannot be attached again
aws ec2 delete-key-pair --key-name <bastion-key>

# 3. Final snapshot, if your retention policy wants one
aws ec2 create-image --instance-id <bastion-id> \
  --name "bastion-final-$(date +%F)" --description "Pre-decommission archive"

# 4. Terminate
aws ec2 terminate-instances --instance-ids <bastion-id>

# 5. Release the address -- the last irreversible step
aws ec2 release-address --allocation-id <eip-alloc-id>

# 6. Delete the security group
aws ec2 delete-security-group --group-id <bastion-sg>
```

Then close the loop:

- Remove bastion references from every repository, SSH config, CI
  pipeline, and runbook found in step 1. Leaving them means somebody
  tries the old way during the next incident.
- Rotate any database password that was ever typed on the bastion. It
  is in that shell history, and that history is in the final snapshot.
- Tell your auditor the access path changed, with the before/after
  `scripts/verify` output and the logging-scope change from step 4.
- Delete the revoked-keys inventory from `/tmp`.

---

## Pre-cutover checklist

Everything must be ticked before step 5. Print it, or paste it into the
change ticket.

### Inventory
- [ ] Every human bastion user identified and assigned to a team role
- [ ] Every `authorized_keys` entry traced to a named owner, or marked for revocation
- [ ] Every scheduled job on the bastion found (`crontab`, systemd timers, all users)
- [ ] Every CI job using the bastion found and given a new home
- [ ] Every third-party/vendor dependency found and given a new home
- [ ] Every inbound CIDR on the bastion's security group traced to an owner
- [ ] The inventory table reviewed and signed off by each team lead

### The new path works
- [ ] AMI built, Goss suites passed, Trivy gate passed
- [ ] `tests/smoke-test.sh` passed against the published AMI
- [ ] Access nodes deployed, multi-AZ, and `scripts/verify` shows a healthy node
- [ ] `terraform output access_iam_warnings` is empty
- [ ] Every team has assumed its role and done real work through it
- [ ] Every access path in the inventory tested by its actual user, with the working command recorded
- [ ] No path requires `insecure-skip-tls-verify`, `sslmode=require`, or an equivalent downgrade
- [ ] The elevation path tested, and the list of people who have it reviewed

### Evidence and monitoring
- [ ] Shell session transcripts arriving in the log group
- [ ] Retention set and KMS encryption confirmed
- [ ] `StartSession` events visible in CloudTrail
- [ ] Audit queries run, and their output matches known activity
- [ ] Datastore-level audit logging enabled where statement visibility is required
- [ ] Alarm on no healthy access node
- [ ] Alarm on access node disk pressure
- [ ] The logging-scope change communicated to whoever depends on it

### Rollback readiness
- [ ] Observation period length agreed, written down, and in the calendar
- [ ] `rollback/bastion-sg-*.json` captured
- [ ] Rollback procedure **rehearsed**, not just written
- [ ] Elastic IP allocation ID recorded
- [ ] On-call briefed, with links to this document and the lockout runbook
- [ ] A named owner for the decommission date

---

## Lockout recovery runbook

Nobody can reach the VPC. Work down the list; each step is independent
of the ones above it and **none of them needs SSH or a bastion**.

> If the bastion still exists and you are inside the observation
> period, the rollback in step 6 is the fastest route. Use it, then
> diagnose at leisure. There is no prize for debugging while your team
> is blocked.

### 0. Confirm it is actually a lockout

```sh
scripts/verify --tag BastionFreeAccess=shared
aws sts get-caller-identity
```

If `get-caller-identity` fails, this is a credentials problem, not a
lockout: `aws sso login`, check `AWS_PROFILE`, check your MFA device.

### 1. No healthy node — the common case

Usually the ASG is at zero, from a schedule or a failed refresh.

```sh
aws autoscaling describe-auto-scaling-groups \
  --auto-scaling-group-names <asg-name> \
  --query 'AutoScalingGroups[].{desired:DesiredCapacity,min:MinSize,inservice:length(Instances)}'

# Scale up. Needs only autoscaling:SetDesiredCapacity -- no SSH.
aws autoscaling set-desired-capacity \
  --auto-scaling-group-name <asg-name> --desired-capacity 1 --honor-cooldown
```

The exact command for your deployment is
`terraform output emergency_scale_up_command`. Put it in your incident
runbook now, not during the incident.

Wait two to three minutes for boot and SSM registration, then
`scripts/connect list`.

### 2. A node is running but not registered with Session Manager

`describe-instance-information` shows nothing, or `ConnectionLost`.

```sh
aws ssm describe-instance-information \
  --filters "Key=tag:BastionFreeAccess,Values=shared" \
  --query 'InstanceInformationList[].{id:InstanceId,ping:PingStatus,agent:AgentVersion}'
```

Causes, in the order they actually occur:

| Cause | Check | Fix |
|---|---|---|
| Endpoints missing or misconfigured (no-NAT VPC) | `aws ec2 describe-vpc-endpoints --filters Name=vpc-id,Values=<vpc>` | `ssm` and `ssmmessages` must exist, be `available`, have an ENI in the node's AZ, and allow 443 from the node |
| NAT gateway failed | `aws ec2 describe-nat-gateways` | Restore it, or add VPC endpoints as a permanent fix |
| Instance role wrong or detached | `aws ec2 describe-instances --instance-ids <id> --query 'Reservations[].Instances[].IamInstanceProfile'` | Reattach the profile from the `access-node` module |
| Private DNS off on the endpoints | `--query 'VpcEndpoints[].PrivateDnsEnabled'` | Must be `true`, or the agent resolves the public endpoint and never arrives |
| Endpoint security group blocks the node | `describe-security-groups` on the endpoint SG | Must allow 443 from the node's security group |
| A bad AMI | `aws autoscaling describe-instance-refreshes` | See step 4 |

Check the boot output without a shell — console output needs no network
path to the instance at all:

```sh
aws ec2 get-console-output --instance-id <id> --output text | tail -60
```

### 3. Nodes are healthy but you get AccessDenied

An IAM problem, not an infrastructure one.

```sh
# What are you, right now?
aws sts get-caller-identity

# Does your policy actually permit this?
aws iam simulate-principal-policy \
  --policy-source-arn "$(aws sts get-caller-identity --query Arn --output text)" \
  --action-names ssm:StartSession \
  --resource-arns "arn:aws:ec2:<region>:<account>:instance/<node-id>"
```

Common causes:

- **MFA missing.** The team roles require it. Re-assume with
  `--serial-number` and `--token-code`.
- **Wrong document.** With `SessionDocumentAccessCheck` enforced you
  must name a document you are permitted to use. Get the list from
  `terraform output team_document_arns`.
- **Tag mismatch.** A node missing the access tag is unreachable. Check
  `aws ec2 describe-instances --query 'Reservations[].Instances[].Tags'`.
  Launch-template tag changes only affect *new* instances — start an
  instance refresh.
- **The node is in the wrong pool.** `payments` cannot reach `shared`
  nodes, by design.

### 4. A bad AMI rolled out and cycled every node

```sh
aws autoscaling describe-instance-refreshes \
  --auto-scaling-group-name <asg-name> --max-records 1

# Cancel an in-flight refresh
aws autoscaling cancel-instance-refresh --auto-scaling-group-name <asg-name>

# Roll back to the previous launch template version
aws autoscaling update-auto-scaling-group \
  --auto-scaling-group-name <asg-name> \
  --launch-template "LaunchTemplateId=<lt-id>,Version=<previous>"

aws autoscaling start-instance-refresh --auto-scaling-group-name <asg-name>
```

The module sets `auto_rollback = true`, so this should have happened by
itself. If it did not, the new nodes were probably passing EC2 health
checks while failing to register with SSM — healthy to the ASG, useless
to you.

### 5. Last resort: a one-off node outside the ASG

When the ASG itself is broken — a bad launch template, a deleted
security group, an exhausted subnet.

```sh
# Launch a single node from a KNOWN-GOOD AMI, with the same profile.
# Note: still no public IP, still no inbound rules, still no key pair.
aws ec2 run-instances \
  --image-id <last-known-good-ami> \
  --instance-type t3.small \
  --subnet-id <private-subnet> \
  --security-group-ids <egress-only-sg> \
  --iam-instance-profile "Name=<instance-profile>" \
  --no-associate-public-ip-address \
  --metadata-options 'HttpTokens=required,HttpEndpoint=enabled,HttpPutResponseHopLimit=1' \
  --tag-specifications 'ResourceType=instance,Tags=[{Key=BastionFreeAccess,Value=shared},{Key=Name,Value=break-glass}]'
```

The access tag is what makes it reachable under your existing IAM
policy. Terminate it once the ASG is fixed, and record why it existed —
an untracked break-glass instance is how the next bastion gets born.

### 6. If none of that works

The failure is in the AWS control plane or your identity provider, and
no change in this repository will help.

- Check the [AWS Health Dashboard](https://health.aws.amazon.com/) for
  Systems Manager and EC2 in your region.
- Open a support case. Session Manager unavailability is a production
  issue.
- If your identity provider is down, break-glass IAM credentials (kept
  offline, MFA-protected, alarmed on use) are the designed answer. If
  you do not have those, create them — before you need them. This is
  the one credential that should not depend on anything else working.

### Prevention, briefly

| Measure | Why |
|---|---|
| `min_size >= 1` and multi-AZ subnets | An AZ outage costs capacity, not access |
| `max_size > desired_capacity` | Lets a 100%-healthy instance refresh actually proceed |
| Leave the scale-to-zero schedule off | It is also a schedule for locking yourself out |
| Alarm on `GroupInServiceInstances < 1` | Find out before a human does |
| VPC endpoints rather than NAT | Removes a shared single point of failure |
| Break-glass IAM credentials, offline and alarmed | For when the identity provider is the problem |
| Rehearse this runbook once a quarter | A runbook nobody has run is a hypothesis |
