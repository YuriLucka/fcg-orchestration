# Roteiro do vídeo — Tech Challenge Fase 4 (até 25 min)

Grupo 4 · 4 blocos, um por integrante. Tempos são alvo; o total precisa ficar abaixo de 25:00.

## Preparação (antes de gravar)

- Cluster ligado: `az aks start -g rg-fcg -n aks-fcg` (se estiver parado) e `kubectl get pods -n fcg` todos `Running`.
- `IP=$(kubectl -n fcg get svc kong -o jsonpath='{.status.loadBalancer.ingress[0].ip}')`
- Token: `TOKEN=$(curl -s -X POST http://$IP/api/Auth/login -H "content-type: application/json" -d '{"email":"admin@fcg.com","password":"Admin@123"}' | sed -E 's/.*"accessToken":"([^"]+)".*/\1/')`
- Abas abertas: Portal Azure (`rg-fcg`, AKS, ACR), Azure DevOps (`dev.azure.com/yurilucka/FCG`: Repos, Pipelines `fcg-users-api`, Environments `fcg-producao`), VS Code com os repositórios, terminal.
- Elastic Cloud ativo (trial) e `catalog-api` reiniciado depois de configurar `ES_URL`/`ES_APIKEY`.
- Escolher a mudança do live deploy (ex.: texto da descrição do Swagger/`ProducesResponseType` ou mensagem de erro de login) e deixar o arquivo aberto, sem salvar.

## Bloco 1 — Carlos (00:00–05:00): problema e infraestrutura na nuvem

1. Apresentação do grupo e do problema da Fase 4: produção gerenciada, entrega automatizada, performance/latência.
2. Arquitetura (diagrama do README, seção "Fase 4 — Azure"): Internet → Load Balancer → Kong → APIs → SQL/Mongo/Redis/RabbitMQ no AKS; CatalogAPI → Elastic Cloud; Azure Pipelines → ACR → AKS (repos no Azure Repos, espelhados no GitHub público).
3. Portal Azure:
   - Resource group `rg-fcg` → AKS `aks-fcg` → **Workloads** (pods do namespace `fcg`).
   - ACR `acrfiapyuri` → Repositórios → tags `sha-*` (versionamento das imagens).
   - IP público do Load Balancer (Service `kong`).
4. Terminal: `kubectl get pods -n fcg` e `kubectl get svc kong -n fcg` (EXTERNAL-IP).
5. `curl -s -o /dev/null -w "%{http_code}\n" http://$IP/api/Game` → `401` (o gateway exige JWT).

## Bloco 2 — Pedro (05:00–11:00): segredos e CI/CD com live deploy

1. Zero credenciais: abrir `k8s/` (sem `secret.yaml`, sem senha), `appsettings.json` sem `SecretKey`, `.env.example`, `kong/kong.yml` com `${JWT_SECRET}`. Mostrar `kubectl get secrets -n fcg` (os Secrets existem no cluster, criados pelo `infra/azure-setup.sh` a partir do `.env`) e, no GitHub, que o único secret da pipeline é `AZURE_CREDENTIALS`.
2. Explicar `azure-pipelines.yml` (Azure DevOps): test → build com tag do commit → push ACR → `kubectl apply` → `rollout status`; `maxSurge: 1` / `maxUnavailable: 0` e `preStop` no `k8s/deployment.yaml`.
3. **Live deploy:**
   - Em um terminal: `while true; do curl -s -o /dev/null -w "%{http_code} " -X POST http://$IP/api/Auth/login -H "content-type: application/json" -d '{}'; sleep 0.5; done`
   - Fazer a mudança visível no `fcg-users-api`, `git commit` e `git push` na `main`.
   - Mostrar a pipeline no Azure DevOps: stage de testes (aba Tests), imagem no ACR, stage de Deploy no environment `fcg-producao` com rollout.
   - Mostrar o loop sem `502/503/000` durante o rollout e `kubectl rollout history deployment/users-api -n fcg` com a nova revisão; conferir a mudança pelo IP.

## Bloco 3 — Yuri (11:00–18:00): busca avançada e cache

1. Busca (Elasticsearch gerenciado, Elastic Cloud):
   - `curl -s -H "Authorization: Bearer $TOKEN" "http://$IP/api/Game/search?q=witchr"` → The Witcher 3 (erro de digitação).
   - `q=hollow%20nigth` → Hollow Knight; `q=shadows%20knight` → Hollow Knight e Sekiro: Shadows Die Twice, mostrando a ordem por relevância (título pesa 3x).
   - Criar um jogo (`POST /api/Game` como admin) e buscá-lo com uma letra trocada; editar e buscar o novo título.
   - Explicar: indexação no create/update/delete do `GameService`, reenvio completo na subida, busca não toca no SQL, `503` se o ES cair.
   - Mostrar o deployment no Elastic Cloud (região Azure East US) e o índice `games`.
2. Cache (Redis):
   - Limpar a chave e medir de dentro do cluster (pela internet a latência de rede esconde o ganho):
     `kubectl exec -n fcg deploy/redis -- redis-cli DEL catalog:games:all`
     `kubectl run curl-cache -n fcg --rm -i --restart=Never --image=curlimages/curl:8.10.1 --command -- sh -c "for i in 1 2 3; do curl -s -o /dev/null -w '%{time_total}s\n' -H 'Authorization: Bearer $TOKEN' http://catalog-api/api/Game; done"`
     → 1ª chamada (SQL, ~6 ms) bem mais lenta que as seguintes (Redis, ~2 ms). No Git Bash, prefixar com `MSYS_NO_PATHCONV=1`.
   - `kubectl exec -n fcg deploy/redis -- redis-cli KEYS 'catalog:*'` e `TTL` da chave `catalog:games:all`.
   - Explicar cache-aside com TTL de 5 min e invalidação no create/update/delete.

## Bloco 4 — Rafael (18:00–24:00): NoSQL e encerramento

1. MongoDB (avaliações):
   - `POST /api/Review` com nota e comentário; `GET /api/Review/game/{gameId}`.
   - `kubectl exec -n fcg deploy/mongodb -- mongosh fcg_catalog --eval 'db.reviews.find().limit(3)'`.
   - Explicar por que avaliações são documento (schema flexível, alto volume, sem relação forte com o SQL) e o driver oficial `MongoDB.Driver`.
2. O que ficou fora da nuvem nesta fase e por quê (Prometheus/Grafana/Loki e a Function seguem como na Fase 3; não pedidos na Fase 4; custo do trial).
3. Recapitulação dos requisitos da Fase 4 atendidos e encerramento.
