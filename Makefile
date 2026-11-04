SHELL := /bin/bash

PACKER_DIR  := packer
ANSIBLE_DIR := ansible
TF_DIR      := terraform
VARS_FILE   ?= $(PACKER_DIR)/local.pkrvars.hcl
ARCH        ?= x86_64

# Set TF=tofu to run everything with OpenTofu instead. Both are
# supported and both are tested in CI.
TF ?= terraform

.PHONY: help init fmt fmt-check validate lint test test-scripts build scan docs clean

help:
	@echo "Targets:"
	@echo "  init         - install packer plugins and ansible collections"
	@echo "  fmt          - format packer, terraform, and shell sources (writes)"
	@echo "  fmt-check    - check formatting without writing"
	@echo "  validate     - packer validate + terraform validate (all modules/examples)"
	@echo "  lint         - ansible-lint, yamllint, shellcheck, tflint"
	@echo "  test         - terraform test (mocked; no AWS credentials needed)"
	@echo "  test-scripts - prove scripts/verify is read-only"
	@echo "  scan         - trivy config + secret scan of this repo"
	@echo "  build        - packer build (needs AWS credentials; ARCH=x86_64|arm64)"
	@echo "  docs         - regenerate module docs (needs terraform-docs)"
	@echo "  clean        - remove local build artefacts"
	@echo ""
	@echo "Variables: ARCH=$(ARCH)  TF=$(TF)  VARS_FILE=$(VARS_FILE)"

init:
	cd $(PACKER_DIR) && packer init .
	ansible-galaxy collection install -r $(ANSIBLE_DIR)/requirements.yml

fmt:
	cd $(PACKER_DIR) && packer fmt -recursive .
	$(TF) fmt -recursive $(TF_DIR)
	@command -v shfmt >/dev/null 2>&1 \
	  && shfmt -w -i 2 -ci scripts/connect scripts/verify scripts/*.sh \
	       $(PACKER_DIR)/scripts/*.sh tests/*.sh tests/scripts/*.sh \
	  || echo "shfmt not installed, skipping shell formatting"

fmt-check:
	cd $(PACKER_DIR) && packer fmt -check -recursive .
	$(TF) fmt -check -recursive $(TF_DIR)

validate: init
	cd $(PACKER_DIR) && packer validate -syntax-only -var-file=$(ARCH).pkrvars.hcl .
	@set -e; for d in $(TF_DIR)/modules/*/ $(TF_DIR)/examples/*/; do \
	  echo "== validate $$d"; \
	  $(TF) -chdir="$$d" init -backend=false -no-color >/dev/null; \
	  $(TF) -chdir="$$d" validate -no-color; \
	done

lint:
	ansible-lint $(ANSIBLE_DIR)/playbook.yml
	yamllint .
	shellcheck --severity=warning scripts/connect scripts/verify scripts/*.sh \
	  $(PACKER_DIR)/scripts/*.sh tests/*.sh tests/scripts/*.sh
	@command -v tflint >/dev/null 2>&1 \
	  && tflint --recursive --config="$(PWD)/.tflint.hcl" \
	  || echo "tflint not installed, skipping"

# Runs against mock_provider: no AWS credentials, no cost.
test:
	@set -e; for d in $(TF_DIR)/modules/*/; do \
	  if [ -d "$$d/tests" ]; then \
	    echo "== test $$d"; \
	    $(TF) -chdir="$$d" init -backend=false -no-color >/dev/null; \
	    $(TF) -chdir="$$d" test -no-color; \
	  fi; \
	done

test-scripts:
	bash tests/scripts/test-verify-readonly.sh

scan:
	trivy config --severity HIGH,CRITICAL $(TF_DIR) $(PACKER_DIR) $(ANSIBLE_DIR)
	trivy filesystem --scanners secret --exit-code 1 .

# Costs a few cents in AWS spend and needs credentials.
#   make build ARCH=arm64
build: init
	@test -f $(VARS_FILE) \
	  || (echo "missing $(VARS_FILE) -- cp $(PACKER_DIR)/example.pkrvars.hcl $(VARS_FILE)"; exit 1)
	cd $(PACKER_DIR) && PACKER_LOG=1 packer build \
	  -var-file=$(ARCH).pkrvars.hcl \
	  -var-file=$(notdir $(VARS_FILE)) \
	  .

docs:
	@command -v terraform-docs >/dev/null 2>&1 \
	  || (echo "terraform-docs not installed: https://terraform-docs.io/user-guide/installation/"; exit 1)
	@for d in $(TF_DIR)/modules/*/; do \
	  echo "== docs $$d"; \
	  terraform-docs markdown table --output-file README.md \
	    --output-mode inject --hide-empty "$$d"; \
	done

clean:
	rm -rf $(PACKER_DIR)/packer_cache reports artifacts *.log
	rm -rf $(ANSIBLE_DIR)/.upstream
	find $(TF_DIR) -type d -name '.terraform' -prune -exec rm -rf {} +
	find $(TF_DIR) -type f -name '.terraform.lock.hcl' -delete
