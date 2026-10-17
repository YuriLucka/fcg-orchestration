#!/usr/bin/env bash
# Sobe a FCG no AKS. Uso: ./infra/azure-setup.sh   (a partir de fcg-orchestration, com .env preenchido)
# Pré-requisitos: az login --tenant <tenant>; docker; kubectl; envsubst; repos irmãos clonados em ../
# Idempotente: rodar de novo reconstrói as imagens, recria os Secrets e reaplica os manifests.
set -euo pipefail
export MSYS_NO_PATHCONV=1

RG=rg-fcg
LOCATION=eastus
AKS=aks-fcg
ACR=acrfiapyuri
NS=fcg
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REPOS="$(cd "$ROOT/.." && pwd)"
TAG="setup-$(date +%Y%m%d%H%M)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

set -a; source "$ROOT/.env"; set +a
: "${MSSQL_SA_PASSWORD:?}" "${JWT_SECRET:?}" "${RABBIT_USER:?}" "${RABBIT_PASS:?}" "${ES_URL:?}"

echo "== Infra"
az acr update -n "$ACR" --sku Basic -o none
az group create -n "$RG" -l "$LOCATION" -o none
if ! az aks show -g "$RG" -n "$AKS" -o none 2>/dev/null; then
  az aks create -g "$RG" -n "$AKS" -l "$LOCATION" \
    --tier free --node-count 1 --node-vm-size Standard_D4as_v5 \
    --max-pods 50 --node-osdisk-size 64 \
    --auto-upgrade-channel none --node-os-upgrade-channel None \
    --attach-acr "$ACR" --generate-ssh-keys -o none
fi
az aks get-credentials -g "$RG" -n "$AKS" --overwrite-existing

echo "== Imagens ($TAG)"
az acr login -n "$ACR"
for api in users catalog payments; do
  img="$ACR.azurecr.io/$api-api:$TAG"
  docker build -t "$img" "$REPOS/fcg-$api-api"
  docker push "$img"
done

echo "== Secrets"
kubectl apply -f "$ROOT/k8s/namespace.yaml"
apply_secret() { kubectl -n "$NS" create secret generic "$@" --dry-run=client -o yaml | kubectl apply -f -; }
apply_secret users-db-secret   --from-literal=MSSQL_SA_PASSWORD="$MSSQL_SA_PASSWORD"
apply_secret catalog-db-secret --from-literal=MSSQL_SA_PASSWORD="$MSSQL_SA_PASSWORD"
apply_secret rabbitmq-secret   --from-literal=RABBIT_USER="$RABBIT_USER" --from-literal=RABBIT_PASS="$RABBIT_PASS"
apply_secret payments-secret   --from-literal=RabbitMq__User="$RABBIT_USER" --from-literal=RabbitMq__Pass="$RABBIT_PASS"
apply_secret users-secret \
  --from-literal=ConnectionStrings__DefaultConnection="Server=users-db;Database=users;User Id=sa;Password=$MSSQL_SA_PASSWORD;TrustServerCertificate=true" \
  --from-literal=JwtSettings__SecretKey="$JWT_SECRET" \
  --from-literal=RabbitMq__User="$RABBIT_USER" --from-literal=RabbitMq__Pass="$RABBIT_PASS"
apply_secret catalog-secret \
  --from-literal=ConnectionStrings__DefaultConnection="Server=catalog-db;Database=catalog;User Id=sa;Password=$MSSQL_SA_PASSWORD;TrustServerCertificate=true" \
  --from-literal=JwtSettings__SecretKey="$JWT_SECRET" \
  --from-literal=RabbitMq__User="$RABBIT_USER" --from-literal=RabbitMq__Pass="$RABBIT_PASS" \
  --from-literal=MongoSettings__ConnectionString="mongodb://mongodb:27017" \
  --from-literal=RedisSettings__ConnectionString="redis:6379" \
  --from-literal=Elasticsearch__Url="$ES_URL" \
  --from-literal=Elasticsearch__ApiKey="${ES_APIKEY:-}"
# No compose as APIs respondem em :8080; no cluster os Services expõem a porta 80.
envsubst '${JWT_SECRET}' < "$ROOT/kong/kong.yml" \
  | sed -e 's#http://users-api:8080#http://users-api#' -e 's#http://catalog-api:8080#http://catalog-api#' > "$TMP/kong.yml"
apply_secret kong-config --from-file=kong.yml="$TMP/kong.yml"

echo "== Manifests"
for f in users-db.yaml catalog-db.yaml mongodb.yaml redis.yaml rabbitmq.yaml kong/deployment.yaml kong/service.yaml \
         payments-api/configmap.yaml payments-api/service.yaml; do
  kubectl apply -f "$ROOT/k8s/$f"
done
sed "s/IMAGE_TAG/$TAG/" "$ROOT/k8s/payments-api/deployment.yaml" | kubectl apply -f -
for api in users catalog; do
  dir="$REPOS/fcg-$api-api/k8s"
  kubectl apply -f "$dir/configmap.yaml" -f "$dir/service.yaml"
  sed "s/IMAGE_TAG/$TAG/" "$dir/deployment.yaml" | kubectl apply -f -
done
# Secrets/kong-config podem ter mudado: reinicia quem lê na subida.
kubectl -n "$NS" rollout restart deployment/kong deployment/users-api deployment/catalog-api deployment/payments-api

echo "== Aguardando"
for d in users-db catalog-db mongodb redis rabbitmq users-api catalog-api payments-api kong; do
  kubectl -n "$NS" rollout status deployment/$d --timeout=600s
done
echo "IP público do Kong (pode levar 1-2 min para aparecer):"
for i in $(seq 1 30); do
  ip=$(kubectl -n "$NS" get svc kong -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
  [ -n "$ip" ] && { echo "$ip"; break; }
  sleep 5
done
