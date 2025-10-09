RED = \033[0;31m
NC = \033[0m # No Color
GREEN = \033[0;32m

define log_section
	@printf "\n${GREEN}--> $(1)${NC}\n\n"
endef

# Get uv dependencies synced (one-time)
sync-libs:
	uv sync --locked

# Generate random pdfs
create-pdfs:
	rm -rf ./pdfs
	uv run ./create_pdfs.py

# Get inventory listing for pdfs folder
full-inventory:
	cd pdfs && find . -name "*.pdf" -exec sh -c 'pdfinfo "$$1" | awk "/^Pages:/ {print \$$2, \"pages  -  \", \"$$1\"}"' _ {} \;


# Create APIM resources with Terraform
create-resources:
	$(call log_section, Create net-new resources with Terraform...)
	# cd terraform && rm -rf .terraform
	# cd terraform && rm -rf .terraform.lock.hcl
	cd terraform && rm -rf main.tfplan
	cd terraform && rm -rf terraform.tfstate
	cd terraform && rm -rf terraform.tfstate.backup
	cd terraform && terraform init -upgrade
	cd terraform && terraform plan -out main.tfplan
	cd terraform && terraform apply main.tfplan

# Incremental changes to Terraform config
incremental-update:
	$(call log_section, Incremental update with Terraform...)
	# cd terraform && terraform init -upgrade
	cd terraform && terraform plan -out main.tfplan
	cd terraform && terraform apply main.tfplan

# Get .env file
write-outputs:
	$(call log_section, Capture env variables...)
	rm -rf .env
	./terraform/capture-outputs.sh

# Generate random pdfs
validate-search-index:
	uv run ./page_distribution.py


# COMMIT LOCAL BRANCH CHANGES
branch=$(shell git symbolic-ref --short HEAD)
now=$(shell date '+%F_%H:%M:%S' )

get-branch:
	@echo $(branch)

git-push:
	@read -p "Enter commit message: " msg && git add . && git commit -m "$$msg" && git push -u origin $(branch)


# Force remote to align with the local branch
force-remote:
	git push origin main --force

git-pull:
	git pull origin $(branch)
