./scripts/deploy.sh   # creates rg, deploys bicep, deploys managedapp

./scripts/destroy.sh  # deletes managedapp + managed rg + rg-veeam-lab

export SUBSCRIPTION_ID="..."

export LOCATION="westeurope"

export RG_NAME="veeam-lab-rg"

export PREFIX="veeam-lab"

export ADMIN_USERNAME="veeamadmin"

export ADMIN_PASSWORD="StrongPassword123"

export ALLOWED_RDP_SOURCE="0.0.0.0/0"

export DEPLOY_VBMA="true"
