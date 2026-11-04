# Tests for access-iam. Run with:
#
#   cd terraform/modules/access-iam && terraform test
#
# The assertions below focus on the parts of this module that are easy
# to get subtly wrong and hard to notice: the document allowlist, the
# own-sessions-only scoping, and the configurations that quietly defeat
# the allowlist.

mock_provider "aws" {
  mock_data "aws_caller_identity" {
    defaults = {
      account_id = "111122223333"
    }
  }

  mock_data "aws_region" {
    defaults = {
      region = "us-east-1"
    }
  }

  mock_data "aws_partition" {
    defaults = {
      partition = "aws"
    }
  }
}

variables {
  name = "bfa"

  teams = {
    payments = {
      access_tag_value       = "payments"
      trusted_principal_arns = ["arn:aws:iam::111122223333:role/Payments"]
      allow_shell            = true
      forward_targets = {
        db = {
          host = "payments.cluster-abc.us-east-1.rds.amazonaws.com"
          port = 5432
        }
      }
    }
  }
}

# ---------------------------------------------------------------------
# Per-target documents are the allowlist mechanism
# ---------------------------------------------------------------------
run "mints_a_document_per_forward_target" {
  command = plan

  assert {
    condition     = length(aws_ssm_document.forward_target) == 1
    error_message = "Each forward_targets entry must get its own Port session document."
  }

  assert {
    condition     = aws_ssm_document.forward_target["payments:db"].name == "bfa-pf-payments-db"
    error_message = "Document names should be derived from the team and target names."
  }

  assert {
    condition     = aws_ssm_document.forward_target["payments:db"].document_type == "Session"
    error_message = "Forwarding documents must be of type Session."
  }
}

run "target_host_and_port_are_fixed_not_parameters" {
  command = plan

  # This is the crux. If host or portNumber were parameters, the caller
  # could override them and the allowlist would be worthless, because
  # IAM has no condition key for ssm:StartSession parameters.
  assert {
    condition = strcontains(
      aws_ssm_document.forward_target["payments:db"].content,
      "\"host\":\"payments.cluster-abc.us-east-1.rds.amazonaws.com\""
    )
    error_message = "The target host must appear as a fixed property in the document content, not as a caller-supplied parameter."
  }

  assert {
    condition = strcontains(
      aws_ssm_document.forward_target["payments:db"].content,
      "\"portNumber\":\"5432\""
    )
    error_message = "The target port must be a fixed property in the document content."
  }

  # The agent's port plugin needs this to recognise the session as port
  # forwarding at all.
  assert {
    condition = strcontains(
      aws_ssm_document.forward_target["payments:db"].content,
      "\"type\":\"LocalPortForwarding\""
    )
    error_message = "Port documents must declare type LocalPortForwarding, or SSM Agent will not treat the session as port forwarding."
  }

  # localPortNumber is the one caller-supplied value, and is purely
  # local to their machine.
  assert {
    condition = strcontains(
      aws_ssm_document.forward_target["payments:db"].content,
      "localPortNumber"
    )
    error_message = "localPortNumber should remain a parameter so callers can pick their own local port."
  }
}

run "team_policy_lists_only_its_own_documents" {
  command = plan

  assert {
    condition = anytrue([
      for arn in output.team_document_arns["payments"] :
      strcontains(arn, "document/bfa-pf-payments-db")
    ])
    error_message = "The payments team's policy must include its own forwarding document."
  }

  # The generic document is what would make the allowlist meaningless.
  assert {
    condition = !anytrue([
      for arn in output.team_document_arns["payments"] :
      strcontains(arn, "AWS-StartPortForwardingSessionToRemoteHost")
    ])
    error_message = "The generic remote-host forwarding document must not be granted by default: a team holding it can forward anywhere the access node can reach, regardless of any allowlist."
  }
}

# ---------------------------------------------------------------------
# Warnings for configurations that defeat themselves
# ---------------------------------------------------------------------
run "warns_when_unrestricted_forwarding_defeats_the_allowlist" {
  command = plan

  variables {
    teams = {
      payments = {
        access_tag_value              = "payments"
        trusted_principal_arns        = ["arn:aws:iam::111122223333:role/Payments"]
        allow_shell                   = true
        allow_unrestricted_forwarding = true
        forward_targets = {
          db = {
            host = "payments.cluster-abc.us-east-1.rds.amazonaws.com"
            port = 5432
          }
        }
      }
    }
  }

  assert {
    condition     = length(output.warnings) > 0
    error_message = "Defining forward_targets alongside allow_unrestricted_forwarding must produce a warning: the allowlist has no effect in that configuration."
  }

  assert {
    condition     = contains(output.unrestricted_forwarding_teams, "payments")
    error_message = "Teams with unrestricted forwarding must be reported, so a reviewer can see who really has unrestricted access."
  }
}

run "no_warnings_for_a_clean_configuration" {
  command = plan

  variables {
    session_kms_key_arn = "arn:aws:kms:us-east-1:111122223333:key/abcd1234-12ab-34cd-56ef-1234567890ab"
  }

  assert {
    condition     = length(output.warnings) == 0
    error_message = "A configuration with an allowlist, the document access check on, and a KMS key supplied should produce no warnings."
  }
}

run "warns_when_kms_key_is_missing" {
  command = plan

  # Without the grant, a KMS-encrypted session fails to start with an
  # opaque error, so it is worth saying out loud.
  assert {
    condition = anytrue([
      for w in output.warnings : strcontains(w, "kms:GenerateDataKey")
    ])
    error_message = "An empty session_kms_key_arn should warn that KMS-encrypted sessions will fail to start."
  }
}

# ---------------------------------------------------------------------
# Roles and trust
# ---------------------------------------------------------------------
run "role_requires_mfa_by_default" {
  command = plan

  assert {
    condition     = strcontains(aws_iam_role.team["payments"].assume_role_policy, "MultiFactorAuthPresent")
    error_message = "require_mfa defaults to true, so the trust policy should carry the aws:MultiFactorAuthPresent condition."
  }
}

run "rejects_team_with_no_trusted_principals" {
  command = plan

  variables {
    teams = {
      payments = {
        access_tag_value = "payments"
        allow_shell      = true
      }
    }
  }

  expect_failures = [
    terraform_data.preconditions,
  ]
}

run "rejects_team_granted_nothing" {
  command = plan

  variables {
    teams = {
      ghost = {
        access_tag_value       = "payments"
        trusted_principal_arns = ["arn:aws:iam::111122223333:role/Payments"]
        allow_shell            = false
      }
    }
  }

  expect_failures = [
    terraform_data.preconditions,
  ]
}

run "rejects_root_run_as_user" {
  command = plan

  variables {
    teams = {
      payments = {
        access_tag_value       = "payments"
        trusted_principal_arns = ["arn:aws:iam::111122223333:role/Payments"]
        allow_shell            = true
        session_run_as_user    = "root"
      }
    }
  }

  expect_failures = [
    var.teams,
  ]
}

run "rejects_out_of_range_port" {
  command = plan

  variables {
    teams = {
      payments = {
        access_tag_value       = "payments"
        trusted_principal_arns = ["arn:aws:iam::111122223333:role/Payments"]
        forward_targets = {
          db = {
            host = "payments.example.com"
            port = 70000
          }
        }
      }
    }
  }

  expect_failures = [
    var.teams,
  ]
}

# ---------------------------------------------------------------------
# Identity Center path
# ---------------------------------------------------------------------
run "create_roles_false_emits_policies_only" {
  command = plan

  variables {
    create_roles = false
    teams = {
      payments = {
        access_tag_value = "payments"
        allow_shell      = true
      }
    }
  }

  assert {
    condition     = length(aws_iam_role.team) == 0
    error_message = "With create_roles = false the module must create no roles: IAM Identity Center owns its own AWSReservedSSO_* roles."
  }

  assert {
    condition     = length(aws_iam_policy.team) == 1
    error_message = "With create_roles = false the module must still emit the policy, for attaching to a permission set."
  }
}
