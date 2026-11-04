-- Access worth a second look: out of hours, new principals, denied
-- attempts, and unusual source addresses.
--
-- Intended as a weekly review query rather than an alert. Tune the
-- hour window and the "new principal" lookback to your team.

WITH sessions AS (
  SELECT
    from_iso8601_timestamp(eventtime)                   AS started_at,
    COALESCE(
      useridentity.sessioncontext.sessionissuer.username,
      useridentity.username,
      useridentity.principalid
    )                                                   AS principal,
    sourceipaddress                                     AS source_ip,
    json_extract_scalar(requestparameters, '$.target')  AS target_instance,
    json_extract_scalar(requestparameters, '$.documentName') AS session_document,
    json_extract_scalar(requestparameters, '$.reason')  AS reason,
    errorcode,
    -- Was MFA present on the credentials used?
    useridentity.sessioncontext.attributes.mfaauthenticated AS mfa_authenticated
  FROM cloudtrail_logs
  WHERE eventsource = 'ssm.amazonaws.com'
    AND eventname   = 'StartSession'
    AND eventtime >= '2026-01-01T00:00:00Z'
),

first_seen AS (
  SELECT principal, MIN(started_at) AS first_session
  FROM sessions
  GROUP BY principal
)

SELECT
  s.started_at,
  s.principal,
  s.target_instance,
  s.session_document,
  s.source_ip,
  s.reason,
  s.errorcode,
  s.mfa_authenticated,
  -- Flags, concatenated so one row shows everything notable about it.
  array_join(
    filter(
      ARRAY[
        CASE WHEN s.errorcode IS NOT NULL
             THEN 'DENIED' END,
        CASE WHEN hour(s.started_at) < 7 OR hour(s.started_at) >= 20
             THEN 'OUT_OF_HOURS' END,
        CASE WHEN day_of_week(s.started_at) IN (6, 7)
             THEN 'WEEKEND' END,
        CASE WHEN f.first_session >= s.started_at - INTERVAL '7' DAY
             THEN 'NEW_PRINCIPAL' END,
        CASE WHEN s.mfa_authenticated IS NULL OR s.mfa_authenticated = 'false'
             THEN 'NO_MFA' END,
        CASE WHEN s.reason IS NULL OR s.reason = ''
             THEN 'NO_REASON_GIVEN' END,
        CASE WHEN s.session_document LIKE '%PortForwardingSessionToRemoteHost%'
             THEN 'GENERIC_FORWARDING_DOC' END
      ],
      x -> x IS NOT NULL
    ),
    ', '
  ) AS flags
FROM sessions s
JOIN first_seen f ON f.principal = s.principal
WHERE s.errorcode IS NOT NULL
   OR hour(s.started_at) < 7
   OR hour(s.started_at) >= 20
   OR day_of_week(s.started_at) IN (6, 7)
   OR f.first_session >= s.started_at - INTERVAL '7' DAY
   OR s.mfa_authenticated IS NULL
   OR s.mfa_authenticated = 'false'
   OR s.session_document LIKE '%PortForwardingSessionToRemoteHost%'
ORDER BY s.started_at DESC
LIMIT 500;
