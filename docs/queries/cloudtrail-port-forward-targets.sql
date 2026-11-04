-- Which forwarding targets were reached, and by whom.
--
-- This is the query that makes per-target session documents pay off.
-- Because each allowed host/port pair has its OWN document, the
-- document name in CloudTrail tells you the destination -- even though
-- the tunnel's traffic is not captured.
--
-- With the generic AWS-StartPortForwardingSessionToRemoteHost document
-- the host is in requestparameters instead. That is recorded too, but
-- it is caller-supplied rather than policy-enforced: the caller chose
-- it and could have chosen anything the node can reach. The
-- destination_source column distinguishes the two cases, which is the
-- difference between evidence and an assertion.

SELECT
  COALESCE(
    json_extract_scalar(requestparameters, '$.documentName'),
    'SSM-SessionManagerRunShell (default)'
  )                                                   AS session_document,

  -- For per-target documents the destination is fixed in the document
  -- and NOT present in the request, by design.
  json_extract_scalar(requestparameters, '$.parameters.host[0]')       AS requested_host,
  json_extract_scalar(requestparameters, '$.parameters.portNumber[0]') AS requested_port,

  CASE
    WHEN json_extract_scalar(requestparameters, '$.documentName')
         LIKE '%StartPortForwardingSessionToRemoteHost'
      THEN 'caller-supplied (NOT policy-enforced)'
    WHEN json_extract_scalar(requestparameters, '$.documentName')
         LIKE '%-pf-%'
      THEN 'fixed in document (policy-enforced allowlist)'
    ELSE 'n/a (not a forwarding session)'
  END                                                 AS destination_source,

  COALESCE(
    useridentity.sessioncontext.sessionissuer.username,
    useridentity.username,
    useridentity.principalid
  )                                                   AS principal,

  COUNT(*)                                            AS session_count,
  COUNT(DISTINCT json_extract_scalar(requestparameters, '$.target')) AS distinct_nodes,
  MIN(eventtime)                                      AS first_session,
  MAX(eventtime)                                      AS last_session

FROM cloudtrail_logs
WHERE eventsource = 'ssm.amazonaws.com'
  AND eventname   = 'StartSession'
  AND errorcode IS NULL
  AND eventtime >= '2026-01-01T00:00:00Z'
GROUP BY 1, 2, 3, 4, 5
ORDER BY session_count DESC
LIMIT 500;
