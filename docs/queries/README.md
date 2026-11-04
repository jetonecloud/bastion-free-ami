# Queries

Ready-to-run queries answering the four questions an auditor or an
incident responder actually asks: **who connected, to which target,
when, and for how long.**

## Which source to use

Three sources, and picking the right one matters:

| Source | Covers | Does not cover | Use for |
|---|---|---|---|
| **CloudTrail** | Every session start/end, all session types, with principal, target, document, and source IP | Session content | The authoritative "who connected to what" record. Start here. |
| **CloudWatch Logs** (session log group) | Shell session content: keystrokes and output | Port-forwarding traffic (never captured) | "What did they type in a shell?" |
| **Athena over the S3 archive** | Same as CloudWatch Logs, cheaper at long retention | Same gap | Long-range historical queries |

**CloudTrail is the one that answers the audit question.** The session
log group only has shell sessions, so a query against it alone
undercounts access — a team that only ever port-forwards will appear to
have never connected.

## Files

| File | Source | Question |
|---|---|---|
| `cloudtrail-who-connected.sql` | CloudTrail (Athena) | Who connected, to what, when, for how long — all session types |
| `cloudtrail-unusual-access.sql` | CloudTrail (Athena) | Out-of-hours, new principals, unusual source IPs |
| `cloudtrail-port-forward-targets.sql` | CloudTrail (Athena) | Which forwarding documents were used, by whom |
| `logs-insights-who-connected.txt` | CloudWatch Logs Insights | Shell sessions with duration, from the log stream names |
| `logs-insights-session-content.txt` | CloudWatch Logs Insights | Search shell session content for a string |
| `logs-insights-privileged-activity.txt` | CloudWatch Logs Insights | sudo, su, and privilege attempts inside shell sessions |
| `athena-session-logs.sql` | Athena (S3 archive) | Table definition plus content queries |

## Running a Logs Insights query

```sh
QUERY_ID="$(aws logs start-query \
  --log-group-name /aws/ssm/bfa/sessions \
  --start-time "$(date -d '7 days ago' +%s)" \
  --end-time "$(date +%s)" \
  --query-string "$(cat docs/queries/logs-insights-who-connected.txt)" \
  --query queryId --output text)"

# Poll until Complete.
aws logs get-query-results --query-id "$QUERY_ID"
```

## A note on session log stream names

Session Manager names each CloudWatch log stream after the session ID,
which has the form `<aws:userid>-<random>`. For an assumed role that is
`<role-id>:<session-name>-<random>`, so the principal is recoverable
from the stream name — which is what the Logs Insights queries rely on,
since the log *events* contain only terminal output.

This is also why the CloudTrail queries are the better source: they
carry the principal as a structured field rather than a substring of a
stream name.
