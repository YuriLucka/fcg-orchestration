# FIAP Cloud Games — Guia de Orquestração (Fase 2)

Este diretório contém os artefatos de orquestração da solução de microsserviços FCG:

- `docker-compose.yml` — stack completa para desenvolvimento/demonstração local.
- `k8s/` — manifestos Kubernetes (namespace, RabbitMQ, bancos de dados).

Cada serviço também possui seu próprio diretório `k8s/` com Deployment, Service, ConfigMap e Secret.

---

## Visão Geral da Arquitetura

```
                          ┌────────────────────┐
                          │   users-api :5001  │
                          │  (SQL Server users)│
                          └─────────┬──────────┘
                UserCreatedEvent    │
                ───────────────────>│ RabbitMQ
                                    │<──────────────────────────────────────┐
                          ┌─────────▼──────────┐          PaymentProcessedEvent
                          │  catalog-api :5002 │                            │
                          │ (SQL Server catalog)│      ┌────────────────────┴────┐
                          └─────────┬──────────┘      │  payments-api :5003     │
                 OrderPlacedEvent   │                  │  (stateless, sem DB)    │
                ───────────────────>│ RabbitMQ         └─────────────────────────┘
                          ┌─────────▼──────────────────────────┐
                          │       notifications-api :5004       │
                          │       (stateless, sem DB)           │
                          └─────────────────────────────────────┘
```

### Fluxo de Cadastro de Usuário

```
Cliente → POST /api/user (users-api)
        → users-api publica UserCreatedEvent
        → notifications-api consome e loga "Boas-vindas para <email>"
```

### Fluxo de Compra de Jogo

```
Cliente → POST /api/auth/login (users-api) → recebe JWT
        → POST /api/purchases (catalog-api, bearer JWT)
        → catalog-api publica OrderPlacedEvent
        → payments-api consome OrderPlacedEvent
          → Price > 0 → Approved
        → payments-api publica PaymentProcessedEvent(Approved)
        → catalog-api consome PaymentProcessedEvent → adiciona jogo à biblioteca do usuário
        → notifications-api consome PaymentProcessedEvent → loga confirmação de compra
```

---

## Como rodar com Docker Compose

**Pré-requisitos:** Docker Desktop (ou Docker Engine + Compose v2).

```bash
# A partir da raiz do repositório
docker compose -f orchestration/docker-compose.yml up --build
```

Aguarde todos os containers ficarem `healthy`/`running`. Acesse:

| Serviço              | URL                              |
|----------------------|----------------------------------|
| users-api (Swagger)  | http://localhost:5001            |
| catalog-api (Swagger)| http://localhost:5002            |
| payments-api         | http://localhost:5003/health     |
| notifications-api    | http://localhost:5004/health     |
| RabbitMQ Management  | http://localhost:15672 (guest/guest) |

Para parar e remover:

```bash
docker compose -f orchestration/docker-compose.yml down -v
```

---

## Como fazer deploy no Kubernetes

**Pré-requisitos:** `kubectl` configurado, cluster local (Kind ou Docker Desktop Kubernetes).

### 1. Construir as imagens

```bash
# A partir da raiz do repositório
docker build -f services/users-api/Dockerfile        -t fcg/users-api:latest .
docker build -f services/catalog-api/Dockerfile      -t fcg/catalog-api:latest .
docker build -f services/payments-api/Dockerfile     -t fcg/payments-api:latest .
docker build -f services/notifications-api/Dockerfile -t fcg/notifications-api:latest .
```

### 2. Carregar imagens no cluster (apenas Kind)

```bash
kind load docker-image fcg/users-api:latest
kind load docker-image fcg/catalog-api:latest
kind load docker-image fcg/payments-api:latest
kind load docker-image fcg/notifications-api:latest
```

> Com Docker Desktop Kubernetes, as imagens do daemon local já estão disponíveis — pule este passo.

### 3. Aplicar os manifestos

```bash
# Infraestrutura (namespace, RabbitMQ, bancos)
kubectl apply -f orchestration/k8s/

# Serviços de aplicação
kubectl apply -f services/users-api/k8s/
kubectl apply -f services/catalog-api/k8s/
kubectl apply -f services/payments-api/k8s/
kubectl apply -f services/notifications-api/k8s/
```

### 4. Verificar os pods

```bash
kubectl get pods -n fcg
# Todos devem aparecer como Running
```

### 5. Acessar os serviços (port-forward)

```bash
kubectl port-forward svc/users-api        -n fcg 5001:80
kubectl port-forward svc/catalog-api      -n fcg 5002:80
kubectl port-forward svc/payments-api     -n fcg 5003:80
kubectl port-forward svc/notifications-api -n fcg 5004:80
```

---

## Tabela de Portas

| Serviço             | Porta Docker | Porta K8s (port-forward) | Porta interna (container) |
|---------------------|-------------|--------------------------|---------------------------|
| users-api           | 5001        | 5001                     | 8080                      |
| catalog-api         | 5002        | 5002                     | 8080                      |
| payments-api        | 5003        | 5003                     | 8080                      |
| notifications-api   | 5004        | 5004                     | 8080                      |
| RabbitMQ (AMQP)     | 5672        | —                        | 5672                      |
| RabbitMQ (Mgmt UI)  | 15672       | —                        | 15672                     |
| users-db (SQL)      | 1401        | —                        | 1433                      |
| catalog-db (SQL)    | 1402        | —                        | 1433                      |

## Variáveis de Ambiente Principais

| Variável                                | Serviços           | Descrição                              |
|-----------------------------------------|--------------------|----------------------------------------|
| `ConnectionStrings__DefaultConnection` | users-api, catalog-api | Connection string SQL Server       |
| `JwtSettings__SecretKey`               | users-api, catalog-api | Chave secreta JWT (≥32 chars)      |
| `JwtSettings__Issuer`                  | users-api, catalog-api | Issuer do token JWT                |
| `JwtSettings__Audience`               | users-api, catalog-api | Audience do token JWT              |
| `RabbitMq__Host`                       | todos os serviços  | Host do RabbitMQ                       |
| `RabbitMq__User`                       | todos os serviços  | Usuário do RabbitMQ (padrão: guest)    |
| `RabbitMq__Pass`                       | todos os serviços  | Senha do RabbitMQ (padrão: guest)      |

---

## Links

- **Documentacao (Event Storming):** https://miro.com/app/board/uXjVHfBBYHk=/
- **users-api repo:** `<users-api repo>` *(preencher após split)*
- **catalog-api repo:** `<catalog-api repo>` *(preencher após split)*
- **payments-api repo:** `<payments-api repo>` *(preencher após split)*
- **notifications-api repo:** `<notifications-api repo>` *(preencher após split)*
- **orchestration repo:** `<orchestration repo>` *(preencher após split)*
