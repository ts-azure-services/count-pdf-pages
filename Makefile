# =============================================================================
# Generate and analyze PDFs in Azure Blob Storage
# Create PDFs, extract page counts and other attributes with Container Apps
# jobs, and report on them. Run `make help` for the menu. Container images are
# built only in Azure ACR.
# =============================================================================

# Bare `make` prints the menu.
.DEFAULT_GOAL := help

# Toolchain and service settings
UV    ?= uv

# ── Sizing a run ─────────────────────────────────────────────────────────────
# Three knobs, set per command:
#   NUM_DOCS             total PDFs `create-pdfs-azure` makes, split evenly over
#                        the generator's replicas (rounded up, so the total can
#                        overshoot by up to one PDF per replica).
#   GENERATOR_REPLICAS   generator replicas. Fixed in the deployed job, so it
#                        only takes effect via `create-resources` or
#                        `incremental-update`; `create-pdfs-azure` reads the
#                        deployed count. Every Terraform apply sets it, so pass
#                        it on each apply or it resets to the default below.
#   ANALYZER_PARTITIONS  analyzer executions, each listing and analyzing an
#                        equal slice of the blobs (at most 4096). Set per run;
#                        no infrastructure change.
#
# The analyzer reads every blob in the pdfs container, not a count, so run
# `clean-pdfs` before generating if a run should only see its own PDFs.
#
# Rough starting points (one replica or partition per 500-12k PDFs; fewer
# replicas for small runs, as each one spends ~30s starting up):
#
#   PDFs      GENERATOR_REPLICAS   ANALYZER_PARTITIONS
#   1k        2                    2
#   10k       5                    5
#   100k      20                   20
#   600k      50                   50   (check the environment's vCPU quota)
#
# Example: a clean 1k run.
#   make incremental-update GENERATOR_REPLICAS=2   # only if the count changes
#   make clean-pdfs
#   make create-pdfs-azure NUM_DOCS=1000
#   make analyze-pdfs-azure ANALYZER_PARTITIONS=2
#   make report-azure
NUM_DOCS ?= 100
GENERATOR_REPLICAS ?= 50
export TF_VAR_generator_parallelism = $(GENERATOR_REPLICAS)
ANALYZER_PARTITIONS ?= 50
# Leave empty to read the registry from Terraform; override with `ACR=myregistry`.
ACR   ?=
IMAGE ?= pdf-tools
# Immutable tag derived from every file the image is built from (the lockfile
# and everything in jobs/ except caches), so a changed dependency or source file
# always yields a new tag and job image. Terraform receives the same value via
# TF_VAR_image_tag.
IMAGE_TAG ?= $(shell cat pyproject.toml uv.lock .dockerignore \
	$$(find jobs -type f ! -path '*/__pycache__/*' ! -name '.DS_Store' | LC_ALL=C sort) \
	| shasum -a 256 | cut -c1-12)
export TF_VAR_image_tag = $(IMAGE_TAG)
TF_PLAN = cd terraform && terraform plan -out main.tfplan

# Colors used by the existing infrastructure progress messages.
RED = \033[0;31m
NC = \033[0m
GREEN = \033[0;32m

define log_section
	@printf "\n${GREEN}--> $(1)${NC}\n\n"
endef

## ── Setup and validation ───────────────────────────────────────────────────
#> `uv run --locked` installs the locked dependencies on demand and fails if the
#> lockfile is stale. Tests need no Azure access.
.PHONY: help lock test
help: ## Show this help
	@awk ' \
		/^## ── / { s = $$0; sub(/^## /, "", s); printf "\n\033[1m%s\033[0m\n", s; next } \
		/^#> / { s = $$0; sub(/^#> /, "", s); printf "    \033[90m%s\033[0m\n", s; next } \
		/^[a-zA-Z0-9_. -]+:.*?##~ / { \
			t = $$0; sub(/:.*/, "", t); \
			d = $$0; sub(/^[^#]*##~ /, "", d); \
			printf "  \033[33m%-24s\033[0m \033[90m%s\033[0m\n", t, d; next } \
		/^[a-zA-Z0-9_. -]+:.*?## / { \
			t = $$0; sub(/:.*/, "", t); \
			d = $$0; sub(/^[^#]*## /, "", d); \
			printf "  \033[36m%-24s\033[0m %s\n", t, d; next } \
	' $(MAKEFILE_LIST)

lock: ##~ Refresh the lockfile after editing dependencies
	$(UV) lock

test: ## Run the analyzer tests without Azure access
	PYTHONPATH=jobs $(UV) run --locked python -m unittest discover -s tests -v

## ── Azure infrastructure ───────────────────────────────────────────────────
#> Requires Terraform and an authenticated Azure CLI. Provisioning also builds
#> the jobs image in ACR.
#> WARNING: `create-resources` deletes local state. Use it only for a fresh
#> deployment; use `incremental-update` for an existing initialized deployment.
#> Storage allows public network access but requires Entra ID and RBAC (shared
#> keys are disabled); IP allow lists don't work for same-region Azure services.
.PHONY: validate-terraform create-resources incremental-update destroy
validate-terraform: ##~ Initialize providers and validate without applying resources
	terraform -chdir=terraform init -backend=false
	terraform -chdir=terraform validate

create-resources: ## Provision a fresh Azure deployment (deletes local state)
	$(call log_section, Create net-new resources with Terraform...)
	# cd terraform && rm -rf .terraform
	# cd terraform && rm -rf .terraform.lock.hcl
	cd terraform && rm -rf main.tfplan
	cd terraform && rm -rf terraform.tfstate
	cd terraform && rm -rf terraform.tfstate.backup
	cd terraform && terraform init -upgrade
	$(TF_PLAN)
	cd terraform && terraform apply main.tfplan

incremental-update: ## Apply changes to an initialized Azure deployment
	$(call log_section, Incremental update with Terraform...)
	# cd terraform && terraform init -upgrade
	$(TF_PLAN)
	cd terraform && terraform apply main.tfplan

destroy: ##~ Delete the Azure resource group and everything in it (no Terraform state needed)
	$(call log_section, Delete Azure resource group...)
	@rg="$${RG:-$$(az group list --tag Project=azure-search-demo --query '[0].name' -o tsv)}"; \
	test -n "$$rg" || { echo "No resource group found; set RG=<name>"; exit 1; }; \
	echo "Deleting resource group $$rg (all resources inside)"; \
	az group delete --name "$$rg" --yes --no-wait

## ── Azure builds ───────────────────────────────────────────────────────────
#> Image builds always run on ACR's Linux workers. `acr-build` requires an
#> existing registry and pushes IMAGE:IMAGE_TAG without deploying.
.PHONY: acr-build
acr-build: ##~ Build and push the Linux/amd64 jobs image in Azure ACR
	@registry="$(ACR)"; \
	if [ -z "$$registry" ]; then \
		registry=$$(terraform -chdir=terraform output -raw container_registry_name) || exit $$?; \
	fi; \
	az acr build \
		--registry "$$registry" \
		--image "$(IMAGE):$(IMAGE_TAG)" \
		--platform linux/amd64 \
		--file jobs/Dockerfile \
		.

## ── PDF generation ─────────────────────────────────────────────────────────
#> PDFs are generated only in Azure: `create-pdfs-azure` runs a Container Apps
#> Job that writes NUM_DOCS PDFs straight to Blob Storage, split across the
#> job's deployed replicas. `clean-pdfs` empties the pdfs container between runs.
.PHONY: clean-pdfs create-pdfs-azure
clean-pdfs: ## Delete every PDF in the pdfs container (asks first; YES=1 skips)
	@account=$$(terraform -chdir=terraform output -raw storage_account_name) && \
	if [ "$(YES)" != 1 ]; then \
		printf "Delete ALL blobs in $$account/pdfs? [y/N] "; read ans; \
		[ "$$ans" = y ] || { echo "Aborted"; exit 1; }; \
	fi && \
	$(UV) run --locked tools/blob_tools.py --account "$$account" clean

create-pdfs-azure: ## Generate NUM_DOCS PDFs directly in Blob Storage with the Azure job
	@job=$$(terraform -chdir=terraform output -raw pdf_generator_job_name) && \
	rg=$$(terraform -chdir=terraform output -raw resource_group_name) && \
	account=$$(terraform -chdir=terraform output -raw storage_account_name) && \
	registry=$$(terraform -chdir=terraform output -raw container_registry_name) && \
	az acr repository show --name "$$registry" --image "$(IMAGE):$(IMAGE_TAG)" -o none 2>/dev/null || \
		{ echo "Image $(IMAGE):$(IMAGE_TAG) is not in $$registry; run 'make acr-build' or 'make incremental-update' first."; exit 1; } && \
	replicas=$$(az containerapp job show --name "$$job" --resource-group "$$rg" \
		--query properties.configuration.manualTriggerConfig.parallelism -o tsv 2>/dev/null) && \
	per=$$(( ($(NUM_DOCS) + $$replicas - 1) / $$replicas )) && \
	echo "Starting $$replicas replicas x $$per docs on $$job" && \
	tools="$(UV) run --locked tools/blob_tools.py --account $$account" && \
	base=$$($$tools count) && start=$$(date +%s) && \
	exec=$$(az containerapp job start --name "$$job" --resource-group "$$rg" \
		--container-name generator \
		--command python create_pdfs.py --cpu 1 --memory 2Gi \
		--image "$$registry.azurecr.io/$(IMAGE):$(IMAGE_TAG)" \
		--env-vars STORAGE_ACCOUNT="$$account" STORAGE_CONTAINER=pdfs NUM_DOCS="$$per" \
		--query name -o tsv) && \
	echo "Execution $$exec ($$base PDFs already in the container)" && \
	while :; do \
		state=$$(az containerapp job execution show --name "$$job" --resource-group "$$rg" \
			--job-execution-name "$$exec" --query properties.status -o tsv 2>/dev/null); \
		$$tools progress --state "$$state" --base $$base --target $$(( replicas * per )) --start $$start; \
		case "$$state" in Succeeded) echo; break;; Failed|Stopped|Degraded) echo; exit 1;; esac; \
		sleep 10; \
	done

## ── Analysis ───────────────────────────────────────────────────────────────
#> Extract page count, size, PDF version, encryption, metadata and read errors
#> into Parquet, then summarize with DuckDB. `analyze-pdfs-azure` splits the
#> blobs over ANALYZER_PARTITIONS job executions that write to the results
#> container; `report-azure` downloads the latest run and summarizes it.
.PHONY: analyze-pdfs-azure report-azure stop-jobs
analyze-pdfs-azure: ## Analyze every PDF in Blob Storage with the Azure job
	@job=$$(terraform -chdir=terraform output -raw pdf_analyzer_job_name) && \
	rg=$$(terraform -chdir=terraform output -raw resource_group_name) && \
	account=$$(terraform -chdir=terraform output -raw storage_account_name) && \
	registry=$$(terraform -chdir=terraform output -raw container_registry_name) && \
	az acr repository show --name "$$registry" --image "$(IMAGE):$(IMAGE_TAG)" -o none 2>/dev/null || \
		{ echo "Image $(IMAGE):$(IMAGE_TAG) is not in $$registry; run 'make acr-build' or 'make incremental-update' first."; exit 1; } && \
	run=$$(date -u +%Y%m%dT%H%M%S) && start=$$(date +%s) && \
	execs="" && \
	for i in $$(seq 0 $$(( $(ANALYZER_PARTITIONS) - 1 ))); do \
		e=$$(az containerapp job start --name "$$job" --resource-group "$$rg" \
			--container-name analyzer \
			--command python analyze_pdfs.py --cpu 1 --memory 2Gi \
			--image "$$registry.azurecr.io/$(IMAGE):$(IMAGE_TAG)" \
			--env-vars STORAGE_ACCOUNT="$$account" PARTITION=$$i PARTITIONS=$(ANALYZER_PARTITIONS) RUN_ID="$$run" \
			--query name -o tsv) || exit 1; \
		execs="$$execs $$e"; \
	done; \
	echo "Run $$run: started $(ANALYZER_PARTITIONS) partitions"; \
	tools="$(UV) run --locked tools/blob_tools.py --account $$account"; \
	total=$$($$tools count); \
	while :; do \
		states=$$(az containerapp job execution list --name "$$job" --resource-group "$$rg" \
			--query "[].[name, properties.status]" -o tsv 2>/dev/null \
			| awk -v want="$$execs" 'BEGIN { n = split(want, w, " "); for (i = 1; i <= n; i++) keep[w[i]] = 1 } \
				$$1 in keep { print $$2 }'); \
		ok=$$(echo "$$states" | grep -c '^Succeeded$$'); \
		bad=$$(echo "$$states" | grep -cE '^(Failed|Stopped|Degraded)$$'); \
		left=$$(( $(ANALYZER_PARTITIONS) - ok - bad )); \
		$$tools progress --state "$$ok/$(ANALYZER_PARTITIONS) parts" --run "$$run" \
			--target $$total --start $$start; \
		[ $$left -eq 0 ] && break; \
		sleep 10; \
	done; \
	echo; \
	[ $$bad -eq 0 ] || { echo "Failed partitions can be re-run alone; see the job's execution history."; exit 1; }

report-azure: ## Download the latest Azure analysis and summarize it
	$(UV) run --locked tools/report.py --account $$(terraform -chdir=terraform output -raw storage_account_name)

stop-jobs: ##~ Stop every running generator and analyzer execution (finished partitions keep their results)
	@rg=$$(terraform -chdir=terraform output -raw resource_group_name) && \
	for job in $$(terraform -chdir=terraform output -raw pdf_generator_job_name) \
	           $$(terraform -chdir=terraform output -raw pdf_analyzer_job_name); do \
		for e in $$(az containerapp job execution list --name "$$job" --resource-group "$$rg" \
				--query "[?properties.status=='Running'].name" -o tsv 2>/dev/null); do \
			az containerapp job stop --name "$$job" --resource-group "$$rg" \
				--job-execution-name "$$e" -o none 2>/dev/null && echo "  stopped $$e" & \
		done; \
	done; \
	wait; echo "Done. Ctrl-C any make progress loop still running; it only watches."
