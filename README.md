# FIAP Cloud Games — Guia de Orquestração (Fase 4)

Este repositório é o **guia central** da entrega: reúne toda a orquestração da
solução de microsserviços FCG (Fase 1 monólito → Fase 2 microsserviços → Fase 3
gateway, observabilidade, persistência poliglota e serverless → Fase 4 nuvem
gerenciada, CI/CD, busca avançada e gestão de segredos) e documenta como subir a
stack completa do zero.

- `infra/` — scripts `az` que criam o AKS na Azure e fazem o deploy (Fase 4).
- `k8s/` — manifestos Kubernetes da infraestrutura (namespace, bancos, filas,
  Kong, payments-api e observabilidade). Os manifestos de `users-api` e
  `catalog-api` ficam no `k8s/` de cada repositório, que é o que a pipeline de
  CI/CD aplica.
- `docker-compose.yml` — stack completa para desenvolvimento/demonstração local.
- `.env.example` — lista de variáveis sensíveis (copiar para `.env`, nunca versionado).
- `kong/` — configuração declarativa do API Gateway (template: o segredo do JWT
  é injetado na hora do deploy).
- `prometheus/`, `grafana/` — configuração e dashboard da observabilidade.
- `rabbitmq/` — topologia de filas/exchanges (definitions.json, sem usuários).

---

## Fase 4 — Azure (AKS + ACR + Elastic Cloud + GitHub Actions)

```
Internet
   |
   v
Azure Load Balancer (IP público) --> Kong (Service LoadBalancer, porta 80)
                                        |
                       +----------------+----------------+
                       v                                 v
                  users-api                         catalog-api ----> Elastic Cloud (busca /api/Game/search)
                       |                            |    |    \
                  SQL Server users        SQL Server  MongoDB  Redis
                       \                    catalog      |
                        +-----> RabbitMQ <---------------+
                                    ^
                                    |
                               payments-api
                    (tudo acima roda no AKS, namespace fcg)

GitHub Actions (users-api, catalog-api): test -> docker build -> push ACR -> kubectl apply (rolling update)
```

| Recurso | Nome | Observação |
|---|---|---|
| Resource group | `rg-fcg` (eastus) | apagar com `./infra/azure-teardown.sh` |
| Kubernetes gerenciado | AKS `aks-fcg` | tier Free, 1 nó `Standard_D4as_v4`, sem auto-upgrade |
| Registry privado | ACR `acrfiapyuri` | SKU Basic, ligado ao AKS (`--attach-acr`) |
| Exposição | Service `kong` tipo `LoadBalancer` | único IP público |
| Busca | Elastic Cloud (Hosted, Azure East US) | endpoint + API key |

### Subir na Azure

```bash
cp .env.example .env            # preencher com valores novos; ES_URL/ES_APIKEY = endpoint e API key do Elastic Cloud
az login --tenant <tenant-id>
./infra/azure-setup.sh          # cria RG/AKS, build+push das 3 imagens (tag sha-<commit>), Secrets, manifests; imprime o IP do Kong
```

O script recusa rodar com o `ES_URL` local (`http://elasticsearch:9200`). Para
subir antes de ter o Elastic Cloud: `ALLOW_NO_ES=1 ./infra/azure-setup.sh`
(a busca responde `503` até o `.env` ser atualizado e o script rodar de novo).
O `.env` é a fonte única dos valores sensíveis: rodar o script de novo recria
os Kubernetes Secrets e reinicia os pods que já existiam.

Para economizar crédito entre sessões: `az aks stop -g rg-fcg -n aks-fcg` /
`az aks start -g rg-fcg -n aks-fcg` (esperar 15-30 min entre os dois). Para
apagar tudo: `./infra/azure-teardown.sh`.

### CI/CD

`fcg-users-api` e `fcg-catalog-api` têm `.github/workflows/ci-cd.yml`:

- `pull_request` → `dotnet test`.
- `push` em `main` → `dotnet test` → `docker build` com tag `sha-<commit>` →
  push no ACR → `kubectl apply -f k8s/` com a imagem do commit →
  `kubectl rollout status`. O código em `main` é o que está em
  produção (manifest versionado + imagem do commit).
- Rolling update sem downtime: `maxSurge: 1`, `maxUnavailable: 0`, readiness
  probe (o pod novo só recebe tráfego quando está pronto) e `preStop` de 10 s
  (o pod antigo sai do balanceamento antes de parar).

Único GitHub Secret (nos dois repositórios): `AZURE_CREDENTIALS` — JSON do
service principal com `Contributor` no `rg-fcg` e `AcrPush` no ACR. As
credenciais da aplicação não passam pela pipeline: ficam nos Kubernetes Secrets
criados pelo `infra/azure-setup.sh` a partir do `.env`, e os pods novos os
leem na subida.

### Zero credenciais no código

Nenhuma senha, chave ou string de conexão está versionada (código ou YAML).
Os valores vêm do `.env` local (compose e `infra/azure-setup.sh`) e chegam aos
pods como Kubernetes Secrets criados com
`kubectl create secret ... --dry-run=client -o yaml | kubectl apply -f -`.
As APIs falham na subida se `JwtSettings:SecretKey` ou `RabbitMq:User/Pass`
não forem informados. O segredo do JWT do Kong é injetado no `kong/kong.yml`
por `envsubst`.

### Busca avançada (Elasticsearch)

`GET /api/Game/search?q=<termo>` (JWT) no `catalog-api`: `multi_match` em
título (peso 3) e descrição, `fuzziness: AUTO` (tolera erro de digitação),
ordenado por relevância. A busca consulta só o Elasticsearch, nunca o SQL.
O índice `games` é atualizado em todo create/update/delete de jogo e
reenviado por completo na subida da API. Se o Elasticsearch estiver fora, a
busca responde `503` e o CRUD continua funcionando.

### O que ficou fora da nuvem nesta fase

O enunciado da Fase 4 não pede, então **Prometheus, Grafana, Loki, Azurite e a
`fcg-notifications-function` continuam como entregues na Fase 3** (rodando no
compose local). No AKS não há consumidor das filas `welcome-email` e
`purchase-confirmation`: as mensagens acumulam sem afetar nenhum fluxo. Os
bancos usam `emptyDir`; o seed recria jogos e usuários a cada subida.

---

## Visão Geral da Arquitetura

```
                                         Cliente
                                            v
                               +------------------------+
                               | Kong API Gateway :8000  |<-- unico ponto de entrada, valida JWT
                               +------------|-----------+
                   -------------------------|--------------------------
                   v                                                  v
        +--------------------+                            +----------------------+
        | users-api           |                           | catalog-api           | +--> MongoDB (reviews)
        | (SQL Server users)  |                           | (SQL Server catalog)  | +--> Redis   (cache jogos)
        +----------|---------+                            +-----------|----------+
                     UserCreatedEvent     OrderPlaced / PaymentProcessed
                   ------------------    v    -------------------------
                      +-------------------------------------+
                      | RabbitMQ                             |
                      | (filas com topologia pre-declarada)  |
                      +------------------|------------------+
                   ----------------------|-----------------------------
                   |                                                  |
           consome / publica                        welcome-email / purchase-confirmation
                   |                                                  |
        +---------------------+                 +-------------------------------------------+
        | payments-api         |                | fcg-notifications-function                 |
        | (stateless, sem DB)  |                | (fora do compose, roda local: func start)  |
        +---------------------+                 +-------------------------------------------+

        Prometheus --scrape--> users-api / catalog-api --> Grafana (dashboard)
        Loki <--logs (function)-- fcg-notifications-function --> Grafana (Explore)
```

> **Migração serverless (notifications-api → Azure Function):** o consumo de
> `UserCreatedEvent`/`PaymentProcessedEvent` foi migrado do antigo container
> `notifications-api` (24/7) para uma Azure Function isolated worker acionada
> diretamente pelas filas RabbitMQ (`welcome-email`, `purchase-confirmation`).
> O container `notifications-api` **não existe mais** neste `docker-compose.yml`.
> Código da function em repositório próprio — veja **Links** abaixo. O serviço
> `azurite` permanece no compose apenas como storage local exigido pelo host de
> Functions (a function precisa dele para rodar, mesmo fora do compose).

> **Gateway:** Kong roteia apenas para `users-api` e `catalog-api` — são os
> únicos serviços expostos por HTTP a clientes externos. `payments-api` é
> stateless e reage apenas a eventos do RabbitMQ (`OrderPlacedEvent` →
> `PaymentProcessedEvent`); não tem rota no Kong.

### Fluxo de Cadastro de Usuário

```
Cliente → POST http://localhost:8000/api/User (via Kong → users-api, sem JWT)
        → users-api publica UserCreatedEvent
        → fcg-notifications-function consome (fila welcome-email) e loga "Boas-vindas para <email>"
```

### Fluxo de Compra de Jogo

```
Cliente → POST http://localhost:8000/api/Auth/login (via Kong → users-api) → recebe JWT
        → POST http://localhost:8000/api/purchases (via Kong → catalog-api, bearer JWT)
        → catalog-api publica OrderPlacedEvent
        → payments-api consome OrderPlacedEvent
          → Price > 0 → Approved
        → payments-api publica PaymentProcessedEvent(Approved)
        → catalog-api consome PaymentProcessedEvent → adiciona jogo à biblioteca do usuário
        → fcg-notifications-function consome (fila purchase-confirmation) → loga confirmação de compra
```

---

## Stack de Observabilidade escolhida

**Opção A: Prometheus (métricas) + Grafana (dashboard) + Loki (logs centralizados).**

- **Prometheus** faz *scrape* das métricas HTTP expostas por `users-api` e
  `catalog-api` (latência, contagem por status code, taxa de erro).
- **Grafana** consome o Prometheus como datasource e exibe o dashboard
  provisionado automaticamente (`grafana/dashboards/fcg-overview.json`), com os
  painéis: *Taxa de requisições por segundo*, *Taxa de erro (4xx + 5xx)*,
  *Latência p95*, *Requisições por status code* e *Total de requisições*.
- **Loki** centraliza os logs da `fcg-notifications-function` (Task 13) — como
  a function roda local via `func start` (fora do compose/k8s), ela não aparece
  no Prometheus; seus logs são a única telemetria disponível dela, e o Loki
  permite consultá-los junto do resto no mesmo Grafana, via **Explore**
  (Grafana já vem com o datasource Loki provisionado em
  `grafana/provisioning/datasources/datasource.yml`).

**Por que essa opção:** é a stack de observabilidade de aplicação recomendada
pelo próprio enunciado do Tech Challenge, é 100% self-hosted (sem custo) e já
roda tanto via Docker Compose quanto em Kubernetes através dos manifests deste
repositório (`k8s/prometheus/`, `k8s/grafana/` e `k8s/loki.yaml`).

> **Loki no deploy k8s (limitação conhecida):** `k8s/loki.yaml` sobe o Loki
> dentro do cluster, mas a única fonte de log configurada para enviar dados a
> ele é a `fcg-notifications-function`, que roda **local** na máquina do dev
> (não é um workload do cluster). Num deploy k8s "puro", sem a function
> apontando para o Loki do cluster (via port-forward, ex.:
> `kubectl port-forward svc/loki -n fcg 3100:3100`, configurando a function
> local para publicar logs nesse endpoint), o Loki fica de pé mas **sem
> nenhum log real** — o datasource aparece vazio no Grafana Explore. Isso é
> esperado dado que a function roda local de propósito (sem custo de cloud),
> não é um bug.

---

## Persistência Poliglota

- **MongoDB** guarda as avaliações de jogos (`fcg-catalog-api`, coleção
  `reviews`) — cenário de dado não-relacional e de schema flexível (nota,
  comentário, autor), sem necessidade de relacionamento forte com as tabelas
  SQL do catálogo.
- **Redis** cacheia a listagem de jogos (`GET /api/Game`) por 5 minutos —
  reduz o round-trip ao SQL Server em toda consulta popular de catálogo.

Ambos usam drivers oficiais (`MongoDB.Driver` e `StackExchange.Redis`) no
`fcg-catalog-api`. GUIs de conveniência para inspeção durante a demonstração:
**mongo-express** (`:8081`) e **redis-commander** (`:8082`).

---

## API Gateway

Kong roda em modo **DB-less** (config 100% declarativa, sem banco próprio),
com a configuração versionada neste repositório:

- `kong/kong.yml` (fonte única). O campo `secret` do consumer JWT é o
  placeholder `${JWT_SECRET}`: no compose o serviço `kong-config` renderiza o
  arquivo com `envsubst`; no AKS o `infra/azure-setup.sh` faz o mesmo e cria o
  Secret `kong-config`.

### Tabela de rotas

| Rota                | Serviço destino | Autenticação                                  |
|---------------------|-----------------|------------------------------------------------|
| `/api/Auth`         | users-api       | Público                                         |
| `/api/User`         | users-api       | `POST` público (cadastro); demais métodos exigem JWT |
| `/api/Game`         | catalog-api     | JWT obrigatório                                 |
| `/api/purchases`    | catalog-api     | JWT obrigatório — **atenção:** minúsculo e plural, foge do padrão PascalCase singular das demais rotas |
| `/api/Review`       | catalog-api     | JWT obrigatório                                 |

Gateway em `http://localhost:8000` (compose) ou `http://<IP público>` (AKS).
A Admin API não é publicada: no compose escuta só em `127.0.0.1:8001` dentro do
container; no AKS está desligada (`KONG_ADMIN_LISTEN=off`).

---

## Serverless: fcg-notifications-function

O antigo container `notifications-api` (24/7) foi substituído por uma **Azure
Function isolated worker**, acionada diretamente pelas filas RabbitMQ
(`welcome-email`, `purchase-confirmation`) — sem custo de execução contínua,
alinhado ao modelo serverless.

- Repositório próprio: https://github.com/YuriLucka/fcg-notifications-function
- Roda **local**, fora deste `docker-compose.yml`, via **Azure Functions Core
  Tools** (`func start`) — junto do restante da stack:

```bash
# Em um terminal separado, a partir do repositório fcg-notifications-function
func start
```

- Consome as filas declaradas em `rabbitmq/definitions.json`, importado pelo
  serviço `rabbitmq-init` do compose assim que o RabbitMQ fica saudável.
- Precisa do Azurite (`azurite`, portas `10000`-`10002`) rodando — é o storage
  local exigido pelo host de Functions.

---

## Pré-requisito: clonar os repositórios lado a lado

O `docker-compose.yml` referencia cada serviço por caminho relativo
(`../fcg-users-api`, etc.). Clone os **4 repositórios de serviços .NET** no
mesmo diretório pai deste repositório, **mais** o `fcg-notifications-function`
(roda à parte, local, não faz parte do compose):

```bash
git clone https://github.com/YuriLucka/fcg-users-api.git
git clone https://github.com/YuriLucka/fcg-catalog-api.git
git clone https://github.com/YuriLucka/fcg-payments-api.git
git clone https://github.com/YuriLucka/fcg-orchestration.git
git clone https://github.com/YuriLucka/fcg-notifications-function.git
```

Estrutura esperada:

```
.
├── fcg-users-api/
├── fcg-catalog-api/
├── fcg-payments-api/
├── fcg-orchestration/            ← rode os comandos do compose/k8s a partir daqui
└── fcg-notifications-function/   ← roda à parte, via `func start`
```

---

## Como rodar com Docker Compose

**Pré-requisitos:** Docker Desktop (ou Docker Engine + Compose v2).

```bash
# A partir da raiz do repositório fcg-orchestration
cp .env.example .env     # preencher os valores (o .env não é versionado)
docker compose up --build
```

Aguarde todos os containers ficarem `healthy`/`running` (os bancos SQL Server
demoram mais — até ~1 min no primeiro start). Acesse:

| Serviço                          | URL                                         |
|-----------------------------------|----------------------------------------------|
| API Gateway (Kong)                | http://localhost:8000/api/...                |
| Prometheus                        | http://localhost:9090                        |
| Grafana                           | http://localhost:3000 (login `admin` / `GRAFANA_ADMIN_PASSWORD` do `.env`, ou acesso anônimo habilitado) |
| Loki                              | via Grafana → Explore (datasource já provisionado; não é acessado direto) |
| mongo-express                     | http://localhost:8081                        |
| redis-commander                   | http://localhost:8082                        |
| RabbitMQ Management                | http://localhost:15672 (`RABBIT_USER`/`RABBIT_PASS` do `.env`) |
| Elasticsearch                      | http://localhost:9200 (sem autenticação, só local) |

> **Atenção:** `users-api` e `catalog-api` **não publicam mais porta no host**
> (desde a introdução do Kong). Todo acesso externo passa por
> `http://localhost:8000/api/...`. Não tente acessar `:5001`/`:5002`
> diretamente — vai dar "connection refused".

Exemplo de chamada via gateway (login com usuário seed):

```bash
curl -X POST http://localhost:8000/api/Auth/login \
  -H "Content-Type: application/json" \
  -d '{"email":"admin@fcg.com","password":"Admin@123"}'
```

Usuários seed disponíveis: admin `admin@fcg.com` / `Admin@123`; usuários comuns
`yuri@fcg.com`, `rafael@fcg.com`, `pedro@fcg.com`, `gustavo@fcg.com`,
`carlos@fcg.com`, todos com senha `Fiap@123`.

Para parar e remover:

```bash
docker compose down -v
```

---

## Como fazer deploy no Kubernetes

O deploy Kubernetes oficial desta fase é o **AKS** — ver
[Fase 4 — Azure](#fase-4--azure-aks--acr--elastic-cloud--github-actions).
Os manifestos de `k8s/` apontam para imagens do ACR
(`acrfiapyuri.azurecr.io/...:IMAGE_TAG`) e dependem dos Secrets criados pelo
`infra/azure-setup.sh`. Para desenvolvimento local use o Docker Compose.

```bash
kubectl get pods -n fcg                       # todos Running
kubectl get svc kong -n fcg                   # EXTERNAL-IP = IP público do gateway
kubectl rollout history deployment/users-api -n fcg
```

---

## Tabela de Portas

| Serviço              | Porta Docker | AKS                       | Porta interna (container) |
|-----------------------|-------------|---------------------------|-----------------------------|
| Kong (proxy)          | 8000        | 80 (IP público do LB)     | 8000                        |
| Kong (admin API)      | não publicada (127.0.0.1 no container) | desligada | 8001            |
| Elasticsearch         | 9200 (127.0.0.1) | Elastic Cloud (externo) | 9200                     |
| users-api             | —* (via Kong)| —* (via Kong)             | 8080                        |
| catalog-api           | —* (via Kong)| —* (via Kong)             | 8080                        |
| payments-api          | —† (sem rota HTTP)| —† (sem rota HTTP)       | 8080                        |
| Prometheus            | 9090        | 9090                      | 9090                        |
| Grafana               | 3000        | 3000                      | 3000                        |
| Loki                  | 3100        | —                         | 3100                        |
| MongoDB               | 27017       | —                         | 27017                       |
| mongo-express         | 8081        | —                         | 8081                        |
| Redis                 | 6379        | —                         | 6379                        |
| redis-commander       | 8082        | —                         | 8081                        |
| RabbitMQ (AMQP)       | 5672        | —                         | 5672                        |
| RabbitMQ (Mgmt UI)    | 15672       | —                         | 15672                       |
| Azurite (Blob/Queue/Table) | 10000-10002 | —                    | 10000-10002                 |
| users-db (SQL)        | 1401        | —                         | 1433                        |
| catalog-db (SQL)      | 1402        | —                         | 1433                        |

\* Não publicadas no host — acesso somente via Kong. Prometheus, Grafana e Loki não sobem no AKS (ver "O que ficou fora da nuvem").
† `payments-api` não publica porta no host nem tem rota no Kong — é 100%
orientado a eventos (consome/produz apenas via RabbitMQ), sem nenhum fluxo
HTTP que precise ser acessado externamente.

## Variáveis de Ambiente Principais

| Variável                                | Serviços               | Descrição                              |
|-------------------------------------------|--------------------------|-------------------------------------------|
| `ConnectionStrings__DefaultConnection`   | users-api, catalog-api   | Connection string SQL Server              |
| `MongoSettings__ConnectionString`       | catalog-api              | Connection string MongoDB                 |
| `MongoSettings__Database`               | catalog-api              | Nome do database MongoDB (`fcg_catalog`)  |
| `RedisSettings__ConnectionString`       | catalog-api              | Endpoint do Redis (cache de `GET /api/Game`) |
| `JwtSettings__SecretKey`                | users-api, catalog-api   | Chave secreta JWT (≥32 chars) — `JWT_SECRET` do `.env` |
| `JwtSettings__Issuer`                   | users-api, catalog-api   | Issuer do token JWT                        |
| `JwtSettings__Audience`                 | users-api, catalog-api   | Audience do token JWT                      |
| `RabbitMq__Host`                        | todos os serviços         | Host do RabbitMQ                           |
| `RabbitMq__User`                        | todos os serviços         | Usuário do RabbitMQ (obrigatório)          |
| `RabbitMq__Pass`                         | todos os serviços         | Senha do RabbitMQ (obrigatório)            |
| `Elasticsearch__Url`                    | catalog-api              | Endpoint do Elasticsearch / Elastic Cloud  |
| `Elasticsearch__ApiKey`                 | catalog-api              | API key do Elastic Cloud (vazio no local)  |
| `Elasticsearch__IndexName`              | catalog-api              | Índice dos jogos (`games`)                 |

Valores sensíveis: `.env` → variáveis do compose (local) ou Kubernetes Secrets (AKS, via `infra/azure-setup.sh`).

---

### Configs espelhadas entre compose e k8s

| Compose                              | Kubernetes                          |
|---------------------------------------|--------------------------------------|
| `kong/kong.yml`                       | o mesmo arquivo, renderizado no Secret `kong-config` pelo `infra/azure-setup.sh` |
| `prometheus/prometheus.yml`           | `k8s/prometheus/configmap.yaml`      |
| `grafana/dashboards/fcg-overview.json`| chave `fcg-overview.json` (minificada) em `k8s/grafana/configmap.yaml` |

`rabbitmq/definitions.json` só existe no compose (topologia usada pela
function local); no AKS o RabbitMQ sobe com usuário do Secret
`rabbitmq-secret` e o MassTransit declara a própria topologia.

---

## Links

- **Documentação (Event Storming):** https://miro.com/app/board/uXjVHfBBYHk=/
- **users-api repo:** https://github.com/YuriLucka/fcg-users-api
- **catalog-api repo:** https://github.com/YuriLucka/fcg-catalog-api
- **payments-api repo:** https://github.com/YuriLucka/fcg-payments-api
- **notifications-api repo (descontinuado — ver fcg-notifications-function):** https://github.com/YuriLucka/fcg-notifications-api
- **notifications-function repo (migração serverless, substitui notifications-api):** https://github.com/YuriLucka/fcg-notifications-function
- **orchestration repo:** https://github.com/YuriLucka/fcg-orchestration
