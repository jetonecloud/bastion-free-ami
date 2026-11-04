-- Athena over the S3 session log archive.
--
-- Use this when your retention outlives what CloudWatch Logs is
-- economical for. Session Manager writes one object per session, named
-- <session-id>.dstrm, containing the session's terminal output.
--
-- SCOPE, because it is easy to misread: these objects exist for SHELL
-- sessions only. Port-forwarding sessions produce no archive object at
-- all, so a query here undercounts access. For "who connected", use
-- cloudtrail-who-connected.sql instead.

-- ---------------------------------------------------------------
-- 1. Table definition
-- ---------------------------------------------------------------
-- Replace the bucket, prefix, and key prefix to match the
-- session-logging module's s3_bucket_name and s3_key_prefix outputs.

CREATE DATABASE IF NOT EXISTS bastion_free_ami;

CREATE EXTERNAL TABLE IF NOT EXISTS bastion_free_ami.session_logs (
  -- Session Manager writes plain terminal output, not structured
  -- records, so the whole line is the only field available.
  line string
)
ROW FORMAT DELIMITED
  FIELDS TERMINATED BY '\n'
STORED AS TEXTFILE
LOCATION 's3://REPLACE-ME-session-logs-111122223333/sessions/'
TBLPROPERTIES ('has_encrypted_data' = 'true');

-- The object key carries the session ID, which carries the principal
-- (session IDs are <aws:userid>-<random>). "$path" is an Athena
-- pseudo-column holding the full S3 URI of the source object, which is
-- how the principal is recovered without any structure in the file.

-- ---------------------------------------------------------------
-- 2. Sessions present in the archive, with their principal
-- ---------------------------------------------------------------
SELECT
  regexp_extract("$path", '([^/]+)\.dstrm$', 1)   AS session_id,
  regexp_extract(
    regexp_extract("$path", '([^/]+)\.dstrm$', 1),
    '^([^-]+)',
    1
  )                                              AS principal_id,
  COUNT(*)                                       AS output_lines
FROM bastion_free_ami.session_logs
GROUP BY 1, 2
ORDER BY output_lines DESC
LIMIT 200;

-- ---------------------------------------------------------------
-- 3. Search archived session content
-- ---------------------------------------------------------------
-- Replace SEARCH_TERM. Results may contain credentials typed at a
-- prompt; handle accordingly.

SELECT
  regexp_extract("$path", '([^/]+)\.dstrm$', 1) AS session_id,
  line
FROM bastion_free_ami.session_logs
WHERE line LIKE '%SEARCH_TERM%'
LIMIT 200;

-- ---------------------------------------------------------------
-- 4. Privilege escalation attempts in archived sessions
-- ---------------------------------------------------------------
SELECT
  regexp_extract("$path", '([^/]+)\.dstrm$', 1) AS session_id,
  COUNT(*)                                      AS matches,
  array_agg(DISTINCT line)                      AS sample_lines
FROM bastion_free_ami.session_logs
WHERE regexp_like(line, '(?i)(sudo|su -|pkexec|doas|systemctl unmask)')
GROUP BY 1
ORDER BY matches DESC
LIMIT 100;
