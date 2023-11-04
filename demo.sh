#!/bin/bash

. third_party/demo-magic/demo-magic.sh

clear
DEMO_PROMPT="${CYAN}➜  ${COLOR_RESET}"

echo "Generating a new key pair"
wait
pei "openssl genrsa -out sa.key 2048"
pei "openssl rsa -in sa.key -pubout -out sa.pub"
wait

clear

echo "Set up Storage Account for hosting Issuer URL"
pei "az group create --name kubecon-na-2023 --location southcentralus --output none --only-show-errors"
pei "az storage account create --resource-group kubecon-na-2023 --name oidcissuer008 --output none --only-show-errors"
pei "az storage container create --account-name oidcissuer008 --name demo --public-access container --output none --only-show-errors"
wait

clear

echo "Upload discovery document to Storage Account"

cat <<EOF > openid-configuration.json
{
  "issuer": "https://oidcissuer008.blob.core.windows.net/demo/",
  "jwks_uri": "https://oidcissuer008.blob.core.windows.net/demo/openid/v1/jwks",
  "response_types_supported": [
    "id_token"
  ],
  "subject_types_supported": [
    "public"
  ],
  "id_token_signing_alg_values_supported": [
    "RS256"
  ]
}
EOF

bat openid-configuration.json

pe "az storage blob upload --account-name oidcissuer008 --container-name demo --file openid-configuration.json --name .well-known/openid-configuration --output none --only-show-errors"
wait

clear

echo "Verify discovery document is publicly accessible"
wait
pe "curl -s https://oidcissuer008.blob.core.windows.net/demo/.well-known/openid-configuration | jq"
wait

clear

echo "Upload JWKS to Storage Account"
wait
echo "Generate the JWKS document using azwi tool"

pe "azwi jwks --public-keys sa.pub --output-file jwks.json"
bat jwks.json
wait
pei "az storage blob upload --account-name oidcissuer008 --container-name demo --file jwks.json --name openid/v1/jwks --output none --only-show-errors"
wait

clear

echo "Verify JWKS document is publicly accessible"
wait
pe "curl -s https://oidcissuer008.blob.core.windows.net/demo/openid/v1/jwks | jq"
wait

clear

echo "Create a kind cluster"
cat <<EOF > kind-config.yml
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
- role: control-plane
  extraMounts:
    - hostPath: sa.pub
      containerPath: /etc/kubernetes/pki/sa.pub
    - hostPath: sa.key
      containerPath: /etc/kubernetes/pki/sa.key
  kubeadmConfigPatches:
  - |
    kind: InitConfiguration
    nodeRegistration:
    taints:
    - key: "kubeadmNode"
      value: "master"
      effect: "NoSchedule"
  - |
    kind: ClusterConfiguration
    apiServer:
      extraArgs:
        service-account-issuer: https://oidcissuer008.blob.core.windows.net/demo/
        service-account-key-file: /etc/kubernetes/pki/sa.pub
        service-account-signing-key-file: /etc/kubernetes/pki/sa.key
    controllerManager:
      extraArgs:
        service-account-private-key-file: /etc/kubernetes/pki/sa.key
- role: worker
EOF

bat kind-config.yml
wait
pei "kind create cluster --image kindest/node:v1.28.0 --config kind-config.yml --name workload-identity-demo"
wait

clear

echo "Create a managed identity in Azure and assign it permissions to access secret from Key Vault"
pe "az identity create --name kubecon-na-2023 --resource-group kubecon-na-2023 --output none --only-show-errors"
pei "az keyvault set-policy --name kindkv --object-id $(az identity show --name kubecon-na-2023 --resource-group kubecon-na-2023 --query principalId -otsv) --secret-permissions get --output none --only-show-errors"
wait

clear

echo "Configure trust for workload identity federation"
pe "az identity federated-credential create --name kubernetes-federated-identity --identity-name kubecon-na-2023 --resource-group kubecon-na-2023 --issuer 'https://oidcissuer008.blob.core.windows.net/demo/' --subject 'system:serviceaccount:kubecon-demo:workload-identity'"
wait
clear

echo "Install the Azure Workload Identity mutating webhook"
pe "helm install wi workload-identity-webhook --set azureTenantID=72f988bf-86f1-41af-91ab-2d7cd011db47 --create-namespace --namespace azure-workload-identity-system --repo https://azure.github.io/azure-workload-identity/charts --wait"
wait
clear

echo "Lets deploy a sample application that uses the identity"
pe "kubectl create namespace kubecon-demo"
wait
pei "kubectl create serviceaccount workload-identity -n kubecon-demo"
wait
pei "kubectl annotate serviceaccount workload-identity -n kubecon-demo azure.workload.identity/client-id=$(az identity show --name kubecon-na-2023 --resource-group kubecon-na-2023 --query clientId -otsv)"
wait

cat <<EOF > pod.yml
apiVersion: v1
kind: Pod
metadata:
  name: kubecon-demo
  namespace: kubecon-demo
  labels:
    azure.workload.identity/use: "true"
spec:
  serviceAccountName: workload-identity
  containers:
    - image: aramase/msal-go:kubecon-v1
      name: oidc
      env:
      - name: KEYVAULT_URL
        value: "https://kindkv.vault.azure.net/"
      - name: SECRET_NAME
        value: kubecon-secret
EOF

bat pod.yml

pe "kubectl apply -f pod.yml"
kubectl wait --for=condition=Ready pod/kubecon-demo -n kubecon-demo --timeout=60s
wait
clear

echo "Lets look at the pod volumes"
pe "kubectl get pod kubecon-demo -n kubecon-demo -o jsonpath={.spec.volumes} | jq"
wait
clear

echo "Lets look at the service account token mounted in the pod"
pei "kubectl exec kubecon-demo -n kubecon-demo -- cat /var/run/secrets/azure/tokens/azure-identity-token | step crypto jwt inspect --insecure"
wait
clear

echo "Finally lets look at the logs to see the secret value"
pei "kubectl logs kubecon-demo -n kubecon-demo"
