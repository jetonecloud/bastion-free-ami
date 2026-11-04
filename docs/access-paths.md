# Access paths

The commands for every path this kit supports, what breaks on each one,
and how to fix it. Each section ends with how to test the path, so you
can verify it during a migration instead of hoping.

Throughout, `$NODE` is an access node instance ID. Get one with:

```sh
scripts/connect list
# or
aws ssm describe-instance-information \
  --filters 'Key=tag:BastionFreeAccess,Values=shared' \
  --query "InstanceInformationList[?PingStatus=='Online'].InstanceId" \
  --output text
```

## Prerequisites, once

```sh
aws --version                  # v2 recommended
session-manager-plugin --version   # 1.2.764.0 or later
```

The Session Manager plugin is the thing everyone forgets. Without it
`aws ssm start-session` fails with an error that does not mention it.
`scripts/connect` checks for it and says so plainly.

## A note that applies to every port-forwarding path below

**Traffic through a port-forwarding tunnel is not logged.** AWS:

> Logging isn't available for Session Manager sessions that connect
> through port forwarding or SSH.

CloudTrail records that the session existed — principal, target
instance, document, start, end, duration, source IP. It does not record
the SQL, the HTTP requests, or the keys you fetched. If you need
statement-level visibility, turn it on at the datastore; each section
below names the relevant setting.

Shell sessions *are* fully logged, keystrokes included. That is its own
hazard — see the credential note under "Shell access".

---

## 1. Shell access to the access node

```sh
scripts/connect shell

# or by hand
aws ssm start-session --target "$NODE"
```

You land as `ssm-user`, which this AMI deliberately strips of sudo. The
session banner reminds you that keystrokes are recorded.

### Don't type secrets at a prompt

Shell sessions capture keystrokes, so a password typed at a prompt ends
up in CloudWatch Logs, readable by anyone with access to the log group.
AWS's recommended pattern:

```sh
stty -echo; read -r PGPASSWORD; stty echo; export PGPASSWORD
```

### Getting elevated access

There is no sudo on `ssm-user`, on purpose. Elevation is a **separate
IAM role** tagged `SSMSessionRunAs=<os-user>`, so sessions started by
that role run as a user that does have sudo (`ec2-user` by default).

```sh
# Assume the elevated role first, then start the session.
aws sts assume-role \
  --role-arn arn:aws:iam::111122223333:role/bfa-platform-xxxx \
  --role-session-name break-glass \
  --serial-number arn:aws:iam::111122223333:mfa/you \
  --token-code 123456
```

This is deliberately not a sudoers rule. Assuming the role is a
distinct, MFA-gated `sts:AssumeRole` event in CloudTrail, so "who had
root on the access node, and when" is answerable from the audit trail
rather than from a `sudoers` file nobody reads. See the `platform` team
in `terraform/examples/multi-team`.

### Test it

```sh
aws ssm start-session --target "$NODE" --reason "migration test"
# then, in the session:
whoami          # expect: ssm-user
sudo -n true    # expect: failure
exit
```

---

## 2. RDS and Aurora

```sh
scripts/connect forward --document bfa-pf-payments-db --local-port 5432

# or with the generic document, if your team has it
aws ssm start-session \
  --target "$NODE" \
  --document-name AWS-StartPortForwardingSessionToRemoteHost \
  --parameters '{"host":["mydb.cluster-abc.eu-west-1.rds.amazonaws.com"],"portNumber":["5432"],"localPortNumber":["5432"]}'
```

Then, in another terminal, connect your own client to `localhost:5432`.

### The TLS hostname problem, and how to actually fix it

This is the part that trips up every team, so here it is in full.

Your client connects to `localhost`. The RDS certificate is issued for
`mydb.cluster-abc.eu-west-1.rds.amazonaws.com`. Full TLS verification
checks the hostname in the certificate against the host you asked for,
they do not match, and the connection is rejected:

```
server certificate for "mydb.cluster-abc.eu-west-1.rds.amazonaws.com"
does not match host name "localhost"
```

**The wrong fix** is `sslmode=require` (PostgreSQL) or
`--ssl-mode=REQUIRED` (MySQL). Those encrypt but do not verify, which
means you have given up server authentication — on the connection you
built an access kit to protect. Do not do this because a Stack Overflow
answer said to.

**The right fix** is to make the name your client asks for match the
certificate. Three ways, best first:

#### Option A — map the real hostname to localhost (recommended)

Add to `/etc/hosts`:

```
127.0.0.1  mydb.cluster-abc.eu-west-1.rds.amazonaws.com
```

Then forward with `localPortNumber` equal to the real port and connect
using the real hostname:

```sh
psql "host=mydb.cluster-abc.eu-west-1.rds.amazonaws.com port=5432 \
      dbname=app user=app sslmode=verify-full \
      sslrootcert=/path/to/global-bundle.pem"
```

Full verification passes, because the name matches the certificate and
the traffic still goes through the tunnel. This is the only option that
keeps `verify-full` with no caveats.

Get the certificate bundle from AWS:

```sh
curl -fsSL -o global-bundle.pem \
  https://truststore.pki.rds.amazonaws.com/global/global-bundle.pem
```

#### Option B — PostgreSQL only: override the verified name

`libpq` 14+ accepts `sslsni` and, more usefully here,
`host`/`hostaddr` separately:

```sh
psql "host=mydb.cluster-abc.eu-west-1.rds.amazonaws.com \
      hostaddr=127.0.0.1 port=5432 dbname=app user=app \
      sslmode=verify-full sslrootcert=global-bundle.pem"
```

`host` is what gets verified and sent as SNI; `hostaddr` is where it
actually connects. No `/etc/hosts` edit required. MySQL's client has no
equivalent.

#### Option C — verify the CA but not the hostname

```sh
psql "host=localhost port=5432 sslmode=verify-ca sslrootcert=global-bundle.pem"
```

`verify-ca` checks the certificate chains to the RDS CA but skips the
hostname check. Weaker than A or B — it would accept any RDS instance's
certificate, not just yours — but far better than `require`. Acceptable
when you cannot edit `/etc/hosts`.

### IAM database authentication

Where it fits, this is the best option available: no database password
exists to leak into a session log, and the token lasts 15 minutes.

```sh
TOKEN="$(aws rds generate-db-auth-token \
  --hostname mydb.cluster-abc.eu-west-1.rds.amazonaws.com \
  --port 5432 --region eu-west-1 --username app_iam_user)"

PGPASSWORD="$TOKEN" psql \
  "host=mydb.cluster-abc.eu-west-1.rds.amazonaws.com hostaddr=127.0.0.1 \
   port=5432 dbname=app user=app_iam_user \
   sslmode=verify-full sslrootcert=global-bundle.pem"
```

Note two things:

- Generate the token for the **real hostname**, not `localhost`. The
  hostname is part of what the token is signed over, so a token
  generated for `localhost` is rejected.
- IAM auth **requires** TLS, which makes getting the hostname
  verification right above mandatory rather than optional.

Caveats worth knowing before you standardise on it: IAM auth has a
connection-rate limit (roughly 20–200 new connections/second depending
on engine and class), it does not work for every engine version, and
the database user must be created with the right grant
(`rds_iam` role in PostgreSQL, `AWSAuthenticationPlugin` in MySQL). It
suits human interactive access well, which is exactly this use case.

### What is and is not logged

The tunnel content is not logged. For statement-level visibility enable
the engine's own audit logging and export it to CloudWatch Logs:

- **PostgreSQL / Aurora PostgreSQL**: `pgaudit` extension, or
  `log_statement = 'ddl'` at minimum.
- **MySQL / Aurora MySQL**: the `MARIADB_AUDIT_PLUGIN`, or Aurora's
  advanced auditing (`server_audit_events`).
- Both: Performance Insights shows query digests but is not an audit log.

Correlate the two by timestamp and source IP: the access node's private
IP appears in the database log, and the Session Manager record says who
had a tunnel open through that node at the time. That join is the whole
audit story for this path, and `docs/audit-evidence.md` spells it out.

### Test it

```sh
# terminal 1
scripts/connect forward --document bfa-pf-payments-db --local-port 5432
# terminal 2
psql "host=<real-hostname> hostaddr=127.0.0.1 port=5432 dbname=postgres \
      user=app sslmode=verify-full sslrootcert=global-bundle.pem" -c 'select 1'
```

---

## 3. ElastiCache

```sh
scripts/connect forward --document bfa-pf-analytics-cache --local-port 6379
```

Then:

```sh
# Redis OSS / Valkey without encryption in transit
redis-cli -h 127.0.0.1 -p 6379 PING

# With encryption in transit (the default for new serverless caches)
redis-cli -h 127.0.0.1 -p 6379 --tls \
  --sni analytics.xyz.ng.0001.use1.cache.amazonaws.com PING
```

### What breaks

- **TLS hostname verification**, same as RDS. `redis-cli` has `--sni`,
  which is the equivalent of the PostgreSQL `host`/`hostaddr` split: it
  sends the real name in the handshake while connecting to localhost.
  Other clients may need the `/etc/hosts` approach.
- **Cluster mode is the real problem.** A cluster-mode-enabled cache
  responds to `CLUSTER SLOTS` with the *internal* node addresses, and
  your client will then try to connect directly to those addresses,
  which your laptop cannot reach. Symptoms: the first command works,
  then everything times out with `MOVED` errors.

  Workarounds, in order of preference:
  1. Forward to the **configuration endpoint** and use a client in
     non-cluster mode for simple diagnostics.
  2. Open one tunnel per shard, on different local ports, and give the
     client the full set as fixed nodes with cluster discovery
     disabled.
  3. Run the diagnostic from a shell session on the access node
     instead — but note the node ships no `redis-cli` by design, and
     adding one is a derived AMI, not a default.

  There is no clean fix. Cluster mode and port forwarding are
  fundamentally in tension, and pretending otherwise wastes an
  afternoon.

### Logging

ElastiCache slow logs and engine logs can be delivered to CloudWatch
Logs. Neither is a per-command audit trail; Redis has no equivalent of
database audit logging. For this path, the honest position is that you
have connection-level evidence and nothing finer.

---

## 4. Internal HTTP services

For an internal ALB, a private API, or a service mesh ingress:

```sh
aws ssm start-session \
  --target "$NODE" \
  --document-name AWS-StartPortForwardingSessionToRemoteHost \
  --parameters '{"host":["internal-alb-123.eu-west-1.elb.amazonaws.com"],"portNumber":["443"],"localPortNumber":["8443"]}'
```

Then:

```sh
curl --resolve internal-alb-123.eu-west-1.elb.amazonaws.com:8443:127.0.0.1 \
     https://internal-alb-123.eu-west-1.elb.amazonaws.com:8443/health
```

`curl --resolve` is the cleanest tool for this: it keeps the real
hostname in the request and the TLS handshake while connecting to
localhost, so both certificate verification and `Host` -based routing
work. This matters more than it looks — an ALB with host-based listener
rules returns 404 for a request with `Host: localhost`.

For a browser, use the `/etc/hosts` approach from the RDS section; a
browser will not accept a certificate mismatch and has no `--resolve`.

### Logging

ALB access logs capture the request. The source IP will be the access
node's private IP, so join on that plus the timestamp to attribute a
request to a person.

---

## 5. Private EKS API endpoints

The fiddliest path, because `kubectl` verifies the API server
certificate and the certificate does not contain `localhost`.

```sh
# 1. Tunnel to the EKS API endpoint.
#    Strip the https:// prefix -- the document wants a hostname.
EKS_ENDPOINT="$(aws eks describe-cluster --name my-cluster \
  --query 'cluster.endpoint' --output text | sed 's#https://##')"

aws ssm start-session \
  --target "$NODE" \
  --document-name AWS-StartPortForwardingSessionToRemoteHost \
  --parameters "{\"host\":[\"${EKS_ENDPOINT}\"],\"portNumber\":[\"443\"],\"localPortNumber\":[\"4443\"]}"
```

### Making kubeconfig work

```sh
aws eks update-kubeconfig --name my-cluster --alias my-cluster-tunnel
```

That writes a kubeconfig pointing at the real endpoint. Two changes are
needed.

**The hostname.** The EKS API server certificate is issued for the
cluster's endpoint hostname, so `server: https://localhost:4443` fails
verification. Add the hostname mapping:

```
127.0.0.1  ABCDEF0123456789.gr7.eu-west-1.eks.amazonaws.com
```

and point kubeconfig at the real name on the tunnel port:

```yaml
clusters:
  - name: my-cluster-tunnel
    cluster:
      server: https://ABCDEF0123456789.gr7.eu-west-1.eks.amazonaws.com:4443
      certificate-authority-data: <unchanged, from update-kubeconfig>
```

Certificate verification now passes, because the name matches and the
CA data is the cluster's own.

**Do not use `insecure-skip-tls-verify: true`.** It is the documented
workaround in a lot of blog posts and it is wrong here: it disables
server authentication on your cluster's control plane, over a tunnel
whose contents are not logged. If you cannot edit `/etc/hosts`, use a
`kubectl` proxy from a shell session on the node instead.

**Authentication still works unchanged.** EKS auth uses a signed STS
token in the `Authorization` header, which does not depend on the URL
you dialled. Your existing `aws eks get-token` exec credential keeps
working.

```sh
kubectl --context my-cluster-tunnel get nodes
```

### A caveat about private-only clusters

If the cluster's endpoint is private-only, `aws eks describe-cluster`
still works (it is a control-plane API call over the public AWS
endpoint), but DNS for the endpoint hostname resolves only inside the
VPC. On your laptop it will not resolve at all — which is fine, because
the `/etc/hosts` entry above overrides resolution anyway. Note that the
access node must be able to resolve it, which it can, being in the VPC.

### Logging

EKS audit logging (`--logging` on the cluster, `audit` type) delivers
full API-level records to CloudWatch Logs, including the IAM identity
behind each request. For this path, EKS audit logs are genuinely better
evidence than anything Session Manager could give you: they record the
actual identity rather than just the tunnel. Turn them on.

---

## 6. SSH-requiring tools

If a tool truly needs SSH — `rsync`, `scp`, an IDE remote plugin — see
`terraform/modules/eice`. It is off by default, and the module README
explains what enabling it costs: the target host needs an inbound rule
on port 22, which is the thing the rest of this kit removes.

It cannot target the access node: `sshd` is masked there and the
security group has no inbound rules. EICE is for *other* hosts.

---

## Quick reference

| Path | Document | What breaks | Fix |
|---|---|---|---|
| Shell | `SSM-SessionManagerRunShell` | — | Don't type secrets; `stty -echo` |
| RDS / Aurora | `...SessionToRemoteHost` | TLS hostname | `/etc/hosts`, or `host`+`hostaddr` |
| IAM DB auth | as above | Token signed for real host | Generate token for the real hostname |
| ElastiCache | `...SessionToRemoteHost` | TLS hostname; cluster mode | `--sni`; one tunnel per shard |
| Internal HTTP | `...SessionToRemoteHost` | TLS + `Host` routing | `curl --resolve` |
| Private EKS | `...SessionToRemoteHost` | API cert hostname | `/etc/hosts` + real name in kubeconfig |
| Real SSH | EICE | Reintroduces inbound 22 | Only if genuinely needed |
