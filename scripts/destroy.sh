az account set --subscription "$SUBSCRIPTION_ID"
az group delete -n veeam-lab-rg --yes --no-wait
az group delete -n veeam-vbma-mrg --yes --no-wait
