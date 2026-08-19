# FIAP Cloud Games — Guia de Orquestração (Fase 3)

Este repositório é o **guia central** da entrega: reúne toda a orquestração da
solução de microsserviços FCG (Fase 1 monólito → Fase 2 microsserviços → Fase 3
gateway, observabilidade, persistência poliglota e serverless) e documenta como
subir a stack completa do zero.

- `docker-compose.yml` — stack completa para desenvolvimento/demonstração local.
- `k8s/` — manifestos Kubernetes (namespace, gateway, observabilidade, bancos de
  dados, filas e os 3 serviços .NET). Cada serviço também possui seu próprio
  `k8s/` com Deployment, Service, ConfigMap e Secret, replicado aqui para deploy
  a partir de um único lugar.
- `kong/` — configuração declarativa do API Gateway (compose).
- `prometheus/`, `grafana/` — configuração e dashboard da observabilidade.
- `rabbitmq/` — topologia de filas/exchanges pré-declarada (definitions.json).

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
- **Redis** cacheia a listagem de jogos (`GET /api/Game`) por 30 segundos —
  reduz o round-trip ao SQL Server em toda consulta popular de catálogo.

Ambos usam drivers oficiais (`MongoDB.Driver` e `StackExchange.Redis`) no
`fcg-catalog-api`. GUIs de conveniência para inspeção durante a demonstração:
**mongo-express** (`:8081`) e **redis-commander** (`:8082`).

---

## API Gateway

Kong roda em modo **DB-less** (config 100% declarativa, sem banco próprio),
com a configuração versionada neste repositório:

- Docker Compose: `kong/kong.yml`
- Kubernetes: `k8s/kong/configmap.yaml` (tipo `Secret`, já que embute o segredo do JWT)

### Tabela de rotas

| Rota                | Serviço destino | Autenticação                                  |
|---------------------|-----------------|------------------------------------------------|
| `/api/Auth`         | users-api       | Público                                         |
| `/api/User`         | users-api       | `POST` público (cadastro); demais métodos exigem JWT |
| `/api/Game`         | catalog-api     | JWT obrigatório                                 |
| `/api/purchases`    | catalog-api     | JWT obrigatório — **atenção:** minúsculo e plural, foge do padrão PascalCase singular das demais rotas |
| `/api/Review`       | catalog-api     | JWT obrigatório                                 |

Gateway em `http://localhost:8000` (proxy). A Admin API (`8001`) não é mais
publicada no host — fica acessível só de dentro da rede do container
(`127.0.0.1:8001`), para evitar reconfiguração não autenticada do gateway.

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

- Consome as mesmas filas que a stack já declara via
  `rabbitmq/definitions.json` (compose) / `k8s/rabbitmq.yaml` (k8s) — não é
  necessário nenhum outro serviço para a function existir, a topologia de
  filas/exchanges já está pronta quando o RabbitMQ sobe.
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
docker compose up --build
```

Aguarde todos os containers ficarem `healthy`/`running` (os bancos SQL Server
demoram mais — até ~1 min no primeiro start). Acesse:

| Serviço                          | URL                                         |
|-----------------------------------|----------------------------------------------|
| API Gateway (Kong)                | http://localhost:8000/api/...                |
| Prometheus                        | http://localhost:9090                        |
| Grafana                           | http://localhost:3000 (login `admin`/`admin`, ou acesso anônimo habilitado) |
| Loki                              | via Grafana → Explore (datasource já provisionado; não é acessado direto) |
| mongo-express                     | http://localhost:8081                        |
| redis-commander                   | http://localhost:8082                        |
| RabbitMQ Management                | http://localhost:15672 (`guest`/`guest`)     |

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

**Pré-requisitos:** `kubectl` configurado, cluster local (Kind ou Docker
Desktop Kubernetes).

### 1. Construir as imagens

Com os repositórios de serviços .NET clonados lado a lado (ver pré-requisito
acima — não inclui o `fcg-notifications-function`, que não sobe em container),
rode a partir do `fcg-orchestration`:

```bash
docker build -t fcg/users-api:latest    ../fcg-users-api
docker build -t fcg/catalog-api:latest  ../fcg-catalog-api
docker build -t fcg/payments-api:latest ../fcg-payments-api
```

### 2. Carregar imagens no cluster (apenas Kind)

```bash
kind load docker-image fcg/users-api:latest
kind load docker-image fcg/catalog-api:latest
kind load docker-image fcg/payments-api:latest
```

> Com Docker Desktop Kubernetes, as imagens do daemon local já estão disponíveis — pule este passo.

### 3. Aplicar os manifestos

Todos os manifestos (namespace, gateway, observabilidade, bancos de dados,
filas e os 3 serviços) estão neste repositório, sob `k8s/`. Aplique o
namespace primeiro e depois o restante de forma recursiva:

```bash
# A partir da raiz do repositório fcg-orchestration
kubectl apply -f k8s/namespace.yaml
kubectl apply -R -f k8s/
```

`kubectl apply -R -f k8s/` já aplica Kong, Prometheus, Grafana, Loki, MongoDB e
Redis automaticamente, por estarem dentro de `k8s/`. O RabbitMQ
(`k8s/rabbitmq.yaml`) sobe com a topologia de filas
(`welcome-email`/`purchase-confirmation`) pré-declarada via ConfigMap — não
depende de nenhum container de notificação para existir; a
`fcg-notifications-function`, rodando local, consome essas filas diretamente
do RabbitMQ exposto pelo cluster.

> Os manifestos de cada serviço também existem no `/k8s` do repositório
> individual correspondente (Deployment, Service, ConfigMap e Secret). Para o
> deploy completo, use a pasta `k8s/` deste repositório de orquestração.

### 4. Verificar os pods

```bash
kubectl get pods -n fcg
# Todos devem aparecer como Running
```

### 5. Acessar os serviços (port-forward)

```bash
kubectl port-forward svc/kong       -n fcg 8000:8000
kubectl port-forward svc/grafana    -n fcg 3000:3000
kubectl port-forward svc/prometheus -n fcg 9090:9090
```

Todo acesso externo aos serviços de negócio (`users-api`, `catalog-api`) passa
pelo `kong`, igual ao compose — não faça port-forward direto para eles.

---

## Tabela de Portas

| Serviço              | Porta Docker | Porta K8s (port-forward) | Porta interna (container) |
|-----------------------|-------------|---------------------------|-----------------------------|
| Kong (proxy)          | 8000        | 8000                      | 8000                        |
| Kong (admin API)      | não publicada (127.0.0.1 no container) | — | 8001            |
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

\* Não publicadas no host — acesso somente via Kong (`http://localhost:8000/api/...`).
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
| `JwtSettings__SecretKey`                | users-api, catalog-api   | Chave secreta JWT (≥32 chars)              |
| `JwtSettings__Issuer`                   | users-api, catalog-api   | Issuer do token JWT                        |
| `JwtSettings__Audience`                 | users-api, catalog-api   | Audience do token JWT                      |
| `RabbitMq__Host`                        | todos os serviços         | Host do RabbitMQ                           |
| `RabbitMq__User`                        | todos os serviços         | Usuário do RabbitMQ (padrão: guest)        |
| `RabbitMq__Pass`                         | todos os serviços         | Senha do RabbitMQ (padrão: guest)          |

---

### Configs espelhadas entre compose e k8s

Alguns arquivos de configuração existem em duplicidade — uma versão consumida
pelo Docker Compose e outra, equivalente, inline nos manifestos do
Kubernetes. Hoje estão sincronizados manualmente (não há geração automática a
partir de uma fonte única), então **ao editar um lado, atualize o outro**:

| Compose                              | Kubernetes                          |
|---------------------------------------|--------------------------------------|
| `kong/kong.yml`                       | `k8s/kong/configmap.yaml` (Secret)   |
| `prometheus/prometheus.yml`           | `k8s/prometheus/configmap.yaml`      |
| `rabbitmq/definitions.json`           | chave `definitions.json` em `k8s/rabbitmq.yaml` |
| `grafana/dashboards/fcg-overview.json`| chave `fcg-overview.json` (minificada) em `k8s/grafana/configmap.yaml` |

Cada um dos 4 arquivos do lado k8s tem um comentário `# ATENÇÃO: espelha ...`
no topo, lembrando do par correspondente.

---

## Links

- **Documentação (Event Storming):** https://miro.com/app/board/uXjVHfBBYHk=/
- **users-api repo:** https://github.com/YuriLucka/fcg-users-api
- **catalog-api repo:** https://github.com/YuriLucka/fcg-catalog-api
- **payments-api repo:** https://github.com/YuriLucka/fcg-payments-api
- **notifications-api repo (descontinuado — ver fcg-notifications-function):** https://github.com/YuriLucka/fcg-notifications-api
- **notifications-function repo (migração serverless, substitui notifications-api):** https://github.com/YuriLucka/fcg-notifications-function
- **orchestration repo:** https://github.com/YuriLucka/fcg-orchestration
