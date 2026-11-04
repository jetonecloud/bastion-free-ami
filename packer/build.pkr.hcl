## -----------------------------------------------------------------------
## bastion-free-ami: build pipeline.
##
##   1. Apply the Ansible role(s). In al2023-base mode the pinned
##      hardened-al2023 roles run first; otherwise the source AMI is
##      already hardened and only access_node runs.
##   2. Run the blocking Goss suites. A failure here aborts the build, so
##      a node with a startable sshd can never be published.
##   3. Run Trivy (vuln + secret + misconfig) and save the report.
##   4. Clean the build's own traces, including the ephemeral SSH key.
##
## Ordering note: cleanup.sh runs LAST and is the step that actually stops
## sshd. Goss runs before it and asserts the *persistent* state (masked +
## disabled), because the build is itself connected over SSH -- see
## docs/design.md, "Consequence for the Goss requirement".
## -----------------------------------------------------------------------

build {
  name    = "bastion-free-ami"
  sources = ["source.amazon-ebs.access_node"]

  # Runs on the Packer host, not the build instance.
  provisioner "shell-local" {
    inline = ["mkdir -p ${path.root}/../reports"]
  }

  provisioner "ansible" {
    playbook_file = "${path.root}/../ansible/playbook.yml"
    user          = var.ssh_username
    use_proxy     = false
    extra_arguments = [
      "--extra-vars", "ansible_python_interpreter=/usr/bin/python3",
      "--extra-vars", "apply_upstream_hardening=${var.apply_upstream_hardening}",
    ]
    ansible_env_vars = [
      "ANSIBLE_HOST_KEY_CHECKING=False",
      "ANSIBLE_CONFIG=${path.root}/../ansible/ansible.cfg",
      "ANSIBLE_ROLES_PATH=${path.root}/../ansible/roles:${path.root}/../ansible/.upstream/hardened-al2023/ansible/roles",
    ]
  }

  # ---- Compliance test stage (Goss) ----
  provisioner "file" {
    source      = "${path.root}/../tests/goss/"
    destination = "/tmp/goss"
  }

  provisioner "shell" {
    script          = "${path.root}/scripts/install-goss.sh"
    execute_command = "chmod +x {{ .Path }}; sudo -E {{ .Path }}"
    environment_vars = [
      "GOSS_VERSION=${var.goss_version}",
      "GOSS_ARCH=${local.goss_arch}",
      "GOSS_CHECKSUM=${local.goss_checksum}",
    ]
  }

  provisioner "shell" {
    # A non-zero exit here fails the build outright. This is the gate that
    # makes "sshd is disabled" a property of every published AMI rather
    # than a claim in a README.
    script          = "${path.root}/scripts/run-goss.sh"
    execute_command = "chmod +x {{ .Path }}; sudo -E {{ .Path }}"
  }

  provisioner "file" {
    direction   = "download"
    source      = "/tmp/goss-results.json"
    destination = "${path.root}/../reports/goss-results.json"
  }

  provisioner "file" {
    direction   = "download"
    source      = "/tmp/goss-advisory-results.json"
    destination = "${path.root}/../reports/goss-advisory-results.json"
  }

  # ---- Scan stage (Trivy) ----
  provisioner "shell" {
    script          = "${path.root}/scripts/install-trivy.sh"
    execute_command = "chmod +x {{ .Path }}; sudo -E {{ .Path }}"
    environment_vars = [
      "TRIVY_VERSION=${var.trivy_version}",
      "TRIVY_ARCH=${local.trivy_arch}",
      "TRIVY_CHECKSUM=${local.trivy_checksum}",
    ]
  }

  provisioner "shell" {
    script          = "${path.root}/scripts/run-trivy.sh"
    execute_command = "chmod +x {{ .Path }}; sudo -E {{ .Path }}"
    environment_vars = [
      "TRIVY_SEVERITY=${var.trivy_severity}",
      "TRIVY_FAIL_ON_CRITICAL=${var.trivy_fail_on_critical}",
    ]
  }

  provisioner "file" {
    direction   = "download"
    source      = "/tmp/trivy-report.json"
    destination = "${path.root}/../reports/trivy-report.json"
  }

  # ---- Bake hygiene: must be the final provisioner ----
  provisioner "shell" {
    script          = "${path.root}/scripts/cleanup.sh"
    execute_command = "chmod +x {{ .Path }}; sudo -E {{ .Path }}"
  }

  post-processor "manifest" {
    output     = "${path.root}/../reports/manifest.json"
    strip_path = true
    custom_data = {
      arch             = var.arch
      build_version    = var.build_version
      upstream_applied = var.apply_upstream_hardening ? "true" : "false"
      source_filter    = var.source_ami_name_filter
    }
  }
}
