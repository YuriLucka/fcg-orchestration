# FCG Fase 4 — Design (Azure)

Data: 2026-10-16 · Grupo 4 · Enunciado: "TC NETT - Fase 4"

## Objetivo

Entregar exatamente o que a Fase 4 pede: aplicação rodando em Kubernetes gerenciado na Azure (AKS + ACR, exposta por Load Balancer), busca avançada com Elasticsearch gerenciado no CatalogAPI, pipeline CI/CD (GitHub Actions) para UsersAPI e CatalogAPI com rolling update, e zero credenciais em código-fonte/YAML. MongoDB e Redis já existem (Fase 3) e só passam a rodar no cluster.

Entrega = vídeo de até 25 min + repositórios públicos + relatório. O professor não testa o ambiente; o cluster precisa funcionar durante a gravação.

## Fora do escopo (decidido)

- Prometheus, Grafana, Loki, Azurite e a Azure Function de notificações **não sobem na nuvem**. Continuam como entregues na Fase 3 (compose local). Declarado no README e no vídeo. Sem a Function, as filas `welcome-email` e `purchase-confirmation` acumulam mensagens; nenhum fluxo depende delas.
- Persistência: bancos seguem com `emptyDir` (dados recriados pelo seed a cada restart).
- Security scan (desejável), Key Vault, bancos gerenciados, Ingress Controller, Terraform.

## Restrições da conta

- Azure Free Trial: crédito ~US$190, expira ~2026-11-08, spending limit ligado.
- Quota eastus: 4 vCPU no total. Série B indisponível para AKS. `Standard_D4as_v5` liberado.
- 3 IPs públicos (usamos 2).
- Elastic Cloud: trial direto em cloud.elastic.co (14 dias; Marketplace da Azure não aceita crédito do trial).

## 1. Infra Azure

**Recursos**
- ACR existente `acrfiapyuri` (eastus), rebaixado para SKU Basic.
- Resource group `rg-fcg` (eastus) com AKS `aks-fcg`:
  `--tier free --node-count 1 --node-vm-size Standard_D4as_v5 --max-pods 50 --node-osdisk-size 64 --auto-upgrade-channel none --node-os-upgrade-channel None --attach-acr acrfiapyuri`
- Sem Container Insights/monitoring addon.

**Script versionado** `infra/azure-setup.sh` (bash, idempotente onde possível): cria RG/AKS, liga ao ACR, faz build+push das 3 imagens com tag `sha-<commit>`, cria os Secrets a partir de `.env` local (gitignored), aplica os manifests e imprime o IP público do Kong. `infra/azure-teardown.sh` apaga o RG.

**Manifests**
- Fonte única por componente:
  - `fcg-users-api/k8s/` e `fcg-catalog-api/k8s/`: Deployment, Service, ConfigMap da própria API (aplicados pela pipeline).
  - `fcg-orchestration/k8s/`: namespace, users-db, catalog-db, mongodb, redis, rabbitmq, kong, payments-api (+ manifests locais de observabilidade).
  - Remover `fcg-orchestration/k8s/users-api` e `k8s/catalog-api` (duplicatas). Probes dos repos passam a `initialDelaySeconds: 45`, `failureThreshold: 8`.
- `infra/azure-setup.sh` aplica uma lista explícita do que sobe na nuvem (kustomize não carrega arquivos fora da própria pasta); o ambiente local oficial passa a ser o `docker compose`.
- Imagens: `acrfiapyuri.azurecr.io/<api>:<tag>`.
- Kong: Service `type: LoadBalancer`, porta 80 → 8000; `KONG_ADMIN_LISTEN=off`.
- Requests/limits em todos os workloads:

  | Workload | req mem / cpu | lim mem |
  |---|---|---|
  | SQL Server (x2) | 2Gi / 250m | 2560Mi (+ `MSSQL_MEMORY_LIMIT_MB=1800`) |
  | MongoDB | 256Mi / 100m | 768Mi |
  | Redis | 32Mi / 25m | 128Mi |
  | RabbitMQ | 256Mi / 100m | 512Mi |
  | APIs (x3) | 192Mi / 100m | 512Mi |
  | Kong | 256Mi / 100m | 512Mi |

- APIs: `strategy: RollingUpdate` com `maxSurge: 1`, `maxUnavailable: 0`.
- Migrations no startup: tentativas de 10 → 30 (SQL novo pode demorar mais de 50 s).

## 2. Zero credenciais

Regra: nenhum valor de senha, chave ou string de conexão em arquivo versionado de código ou YAML. Valores vêm de `.env` local (compose e setup) ou GitHub Secrets (pipeline) e chegam aos pods como Kubernetes Secrets criados por `kubectl create secret ... --dry-run=client -o yaml | kubectl apply -f -`. Valores na nuvem são novos (os antigos estão no histórico público do git).

| Onde | Mudança |
|---|---|
| `k8s/secret.yaml` (orchestration x3, users/catalog/payments) | apagar |
| `k8s/users-db.yaml`, `k8s/catalog-db.yaml` | remover bloco Secret embutido; referenciar Secret criado no setup |
| `kong/kong.yml`, `k8s/kong/configmap.yaml` | `kong.yml` com placeholder `${JWT_SECRET}`; Secret `kong-config` gerado via `envsubst` (compose: entrypoint renderiza o arquivo); apagar `k8s/kong/configmap.yaml` |
| `rabbitmq/definitions.json`, `k8s/rabbitmq.yaml` | tirar `users`/hash; definitions renderizado no setup a partir de `RABBIT_USER/PASS` e montado de Secret |
| Grafana (compose, `k8s/grafana`) | senha via variável / `secretKeyRef` |
| `appsettings.json` (users, catalog, payments) | remover SecretKey, connection strings e usuário/senha RabbitMQ |
| `building-blocks/Fcg.Messaging/MassTransitExtensions.cs` (3 repos) | remover `?? "guest"`; exigir configuração |
| `Program.cs`/`JwtTokenService.cs` (users, catalog) | validar SecretKey com `string.IsNullOrWhiteSpace` |
| `k8s/catalog-api/configmap.yaml` (Mongo/Redis) | connection strings vão para o Secret |
| `docker-compose.yml` | todos os valores como `${VAR}`; `.env.example` versionado; passar `RabbitMq__User/Pass` explicitamente |
| READMEs/docs | placeholders no lugar de valores reais |

`.env.example` lista: `MSSQL_SA_PASSWORD`, `JWT_SECRET`, `RABBIT_USER`, `RABBIT_PASS`, `RABBIT_ERLANG_COOKIE`, `GRAFANA_ADMIN_PASSWORD`, `ES_URL`, `ES_APIKEY`.

## 3. Elasticsearch (fcg-catalog-api)

- Pacote `Elastic.Clients.Elasticsearch` 9.x. Local: container `elasticsearch:9.x` single-node (`xpack.security.enabled=false`) no compose. Nuvem: Elastic Cloud Hosted (Azure eastus), endpoint + API key.
- `IGameSearchService` (Application/Interfaces): `IndexAsync(Game)`, `RemoveAsync(Guid)`, `SearchAsync(string q)`, `EnsureIndexAsync(IEnumerable<Game>)`.
- `ElasticGameSearchService` + `ElasticsearchSettings` (Infrastructure/Search); `ElasticsearchClient` singleton registrado em `AddInfrastructure`.
- Índice `games`: `_id` = Game.Id; `title` text (+ keyword), `description` text, `price`, `isActive`.
- `GameService`: após create/update chama `TryIndexAsync`; após delete `TryRemoveIndexAsync`. Mesmo padrão do cache: try/catch + `LogWarning`, CRUD nunca falha por causa do ES.
- `GET /api/Game/search?q=` com `[Authorize]`: `multi_match` em `title^3` e `description`, `fuzziness: AUTO`, ordem por `_score`. Consulta só o ES; ES indisponível → 503.
- Startup: após `SeedAsync`, se o índice não existe, cria e indexa todos os jogos via bulk. Com timeout e try/catch; nunca bloqueia o boot.
- Config: `Elasticsearch__Url`, `Elasticsearch__ApiKey` (Secret), `Elasticsearch__IndexName` (ConfigMap).
- Rota passa pelo Kong sem mudança (prefixo `/api/Game`, JWT).

## 4. CI/CD (fcg-users-api, fcg-catalog-api)

Arquivo `.github/workflows/ci-cd.yml`:
- `pull_request` → job `test`; `push` em `main` → `test` + `deploy`. `concurrency` por repo.
- `test`: `actions/setup-dotnet@v4` (8.0.x) e `dotnet test tests/<X>.Tests/<X>.Tests.csproj` (o `.slnx` exige SDK 9).
- `deploy`:
  1. `azure/login@v2` com `AZURE_CREDENTIALS` (service principal com Contributor no `rg-fcg` + AcrPush no ACR).
  2. `az acr login`; `docker build` + `docker push` com tag `sha-<7 chars>`.
  3. `azure/aks-set-context@v4`.
  4. (removido na revisão final: os Secrets da aplicação são criados só pelo `infra/azure-setup.sh` a partir do `.env`, fonte única — evita divergência entre `.env` e GitHub Secrets.)
  5. `sed` da imagem em `k8s/deployment.yaml` + `kubectl apply -f k8s/` → manifest de `main` + imagem do commit = produção.
  6. `kubectl rollout status --timeout=300s`.
- GitHub Secret: só `AZURE_CREDENTIALS`.

## 5. Testes

- Unitários existentes (users 36, catalog 33) continuam passando; ajustar construtor de `GameServiceTests`.
- Novos: `GameService` chama o indexador em create/update/delete; falha do indexador não quebra o CRUD.
- Verificação local: `docker compose up` com `.env`, busca fuzzy contra ES local, fluxo de compra.
- Verificação na nuvem: pods Running, chamadas via IP do Kong, pipeline verde com rollout sem downtime (requisições em loop durante o deploy).

## 6. Ordem

1. Parte 2 (credenciais) + Parte 3 (ES) localmente.
2. Cluster AKS + setup + deploy inicial.
3. Pipelines.
4. Elastic Cloud trial (perto da gravação, antes de ~2026-10-30).
5. Ensaio e gravação até ~2026-11-05. `az aks stop` entre sessões (parado ainda custa ~US$1,5/dia).

## 7. Entregáveis

- README do orchestration: seção Fase 4 (arquitetura na nuvem, setup, variáveis/GitHub Secrets, o que ficou fora da nuvem e por quê); seção Kubernetes local mantida separada. READMEs de users/catalog com as novas variáveis.
- Roteiro do vídeo (≤25 min, 4 pessoas): Portal (AKS workloads, ACR com tags sha, IP público) + `kubectl get pods`; YAML sem segredos + GitHub Secrets; live deploy com mudança visível e Actions verde; busca fuzzy com erro de digitação e ordem por relevância; cache (1ª vs 2ª chamada com `curl -w`, chave no Redis); explicação do MongoDB (reviews).
- Relatório de entrega no modelo da Fase 3.
