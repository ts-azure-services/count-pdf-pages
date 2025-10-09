 #!/bin/bash

# Get Terraform outputs
search_service=$(cd terraform && terraform output -raw search_service_endpoint)
search_index=$(cd terraform && terraform output -raw search_service_index)
search_key=$(cd terraform && terraform output -raw search_service_key)

# Write to .env file
cat <<EOF > .env
# Azure Search details
SEARCH_SERVICE=$search_service
SEARCH_INDEX=$search_index
SEARCH_KEY=$search_key
EOF
