-- Who connected, to which target, when, and for how long.
--
-- THE authoritative query. CloudTrail records every session type,
-- including port forwarding, which the session log group does not.
-- Use this one for audit responses.
--
-- Assumes a CloudTrail Athena table created by the CloudTrail console's
-- "Create Athena table" action, or equivalent. Replace
-- cloudtrail_logs with your table name and adjust the partition
-- predicate to match your partitioning scheme.

WITH starts AS (
  SELECT
    eventtime                                                        AS started_at,
    useridentity.arn                                                 AS principal_arn,
    COALESCE(
      useridentity.sessioncontext.sessionissuer.username,
      useridentity.username,
      useridentity.principalid
    )                                                                AS principal,
    useridentity.type                                                AS principal_type,
    sourceipaddress                                                  AS source_ip,
    json_extract_scalar(requestparameters, '$.target')               AS target_instance,
    COALESCE(
      json_extract_scalar(requestparameters, '$.documentName'),
      'SSM-SessionManagerRunShell (default)'
    )                                                                AS session_document,
    json_extract_scalar(requestparameters, '$.reason')               AS reason,
    json_extract_scalar(responseelements, '$.sessionId')              AS session_id,
    errorcode                                                        AS error_code
  FROM cloudtrail_logs
  WHERE eventsource = 'ssm.amazonaws.com'
    AND eventname   = 'StartSession'
    -- Adjust to your partitioning.
    AND eventtime >= '2026-01-01T00:00:00Z'
),

ends AS (
  SELECT
    json_extract_scalar(requestparameters, '$.sessionId') AS session_id,
    MIN(eventtime)                                        AS ended_at
  FROM cloudtrail_logs
  WHERE eventsource = 'ssm.amazonaws.com'
    AND eventname   = 'TerminateSession'
    AND eventtime >= '2026-01-01T00:00:00Z'
  GROUP BY 1
)

SELECT
  s.started_at,
  e.ended_at,
  -- NULL duration means the session was not explicitly terminated:
  -- it timed out on idleSessionTimeout, hit maxSessionDuration, or the
  -- client disconnected. Not an error, and quite common.
  CASE
    WHEN e.ended_at IS NULL THEN NULL
    ELSE date_diff(
      'second',
      from_iso8601_timestamp(s.started_at),
      from_iso8601_timestamp(e.ended_at)
    )
  END                                            AS duration_seconds,
  s.principal,
  s.principal_type,
  s.principal_arn,
  s.target_instance,
  s.session_document,
  -- Everything except the shell document is a tunnel, and tunnel
  -- CONTENT is not captured anywhere. Flagged so a reader does not
  -- assume the session log group covers these.
  CASE
    WHEN s.session_document LIKE '%PortForwarding%' THEN 'tunnel (content NOT logged)'
    WHEN s.session_document LIKE '%SSHSession%'     THEN 'ssh tunnel (content NOT logged)'
    ELSE 'shell (content logged)'
  END                                            AS content_logging,
  s.source_ip,
  s.reason,
  s.session_id,
  s.error_code
FROM starts s
LEFT JOIN ends e ON e.session_id = s.session_id
ORDER BY s.started_at DESC
LIMIT 500;
