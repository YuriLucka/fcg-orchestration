# Fase 3 Tech Challenge — Gateway, Serverless, Observabilidade, NoSQL, Cache — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Evoluir a arquitetura FCG (4 microsserviços + orchestration da Fase 2) para atender aos 5 requisitos obrigatórios da Fase 3: API Gateway, migração serverless da NotificationsAPI, observabilidade, persistência poliglota (NoSQL) e cache distribuído — usando só ferramentas gratuitas/self-hosted, sem conta cloud paga.

**Architecture:** Kong (DB-less, declarative) na frente de UsersAPI/CatalogAPI validando JWT e roteando. Prometheus+Grafana raspando `/metrics` de UsersAPI/CatalogAPI. MongoDB guardando avaliações de jogos (feature nova em CatalogAPI). Redis cacheando a listagem de jogos do CatalogAPI. NotificationsAPI decomissionado como container e substituído por uma Azure Function isolated-worker (`fcg-notifications-function`, repo novo) com trigger nativo de RabbitMQ, rodando local via Azure Functions Core Tools.

**Tech Stack:** .NET 8, Kong 3.7 (DB-less), Prometheus + Grafana, MongoDB.Driver 2.28, StackExchange.Redis (via `Microsoft.Extensions.Caching.StackExchangeRedis`), prometheus-net.AspNetCore, Azure Functions Worker (isolated) + `Microsoft.Azure.Functions.Worker.Extensions.Rabbitmq`, xUnit + Moq (padrão já usado no projeto).

**Spec:** Tech Challenge Fase 3 (enunciado colado na conversa em 2026-08-14) — sem arquivo local, texto integral na sessão que originou este plano.

## Global Constraints

- Gateway deve ser o único ponto de entrada externo, validar JWT, e rotear só para UsersAPI e CatalogAPI.
- Config do gateway (rotas/políticas) deve ficar versionada no repo `fcg-orchestration`.
- NotificationsAPI deixa de rodar como container 24/7 — vira function acionada direto pela fila.
- Código da function + IaC ficam em repositório próprio (novo), linkado no README da orchestration.
- Observabilidade Opção A (Prometheus/Grafana): instrumentar UsersAPI e CatalogAPI, dashboard com latência, contagem por status code, taxa de erro. Deploy via manifests k8s.
- NoSQL obrigatório (MongoDB) + Cache obrigatório (Redis) — usar drivers oficiais.
- README do `fcg-orchestration` é o guia central: stack escolhida + como subir tudo.
- Sem custo: tudo self-hosted via Docker/k8s, function roda local (sem deploy real obrigatório).
- Todas as mudanças em C# seguem TDD: teste falha → implementação mínima → teste passa → commit. Idioma dos testes/mensagens: português, igual ao resto do código (`DomainException`, nomes de teste tipo `MetodoX_DeveY_QuandoZ`).

---

## Mapa de repositórios afetados

| Repo | O que muda |
|---|---|
| `fcg-orchestration` | docker-compose + k8s: Kong, Prometheus, Grafana, MongoDB, Redis; remove notifications-api; README novo |
| `fcg-catalog-api` | Feature de avaliações (Mongo), cache Redis no catálogo, métricas Prometheus |
| `fcg-users-api` | Métricas Prometheus |
| `fcg-notifications-function` (**novo repo**) | Azure Function isolated worker, trigger RabbitMQ, IaC Bicep |
| `fcg-notifications-api` | Nenhuma mudança de código — só para de ser orquestrado |

Todos os repos já estão clonados em `C:\Users\Yuri\source\repos\YuriLucka\`.

---

### Task 1: Infra MongoDB (orchestration)

**Files:**
- Modify: `fcg-orchestration/docker-compose.yml`
- Create: `fcg-orchestration/k8s/mongodb.yaml`
- Modify: `fcg-orchestration/k8s/catalog-api/configmap.yaml`
- Modify: `fcg-catalog-api/k8s/configmap.yaml` (cópia espelhada, mesmo padrão dos outros configs duplicados no repo)
- Modify: `fcg-catalog-api/src/Catalog.API/appsettings.json`
- Modify: `fcg-catalog-api/src/Catalog.API/appsettings.Development.json`

**Interfaces:**
- Produces: variável de config `MongoSettings:ConnectionString` e `MongoSettings:Database`, lida pela Task 2.

- [ ] **Step 1: Adicionar serviço `mongo` ao docker-compose**

Em `fcg-orchestration/docker-compose.yml`, adicionar (após o bloco `catalog-db`):

```yaml
  mongo:
    image: mongo:7
    ports: ["27017:27017"]
    healthcheck:
      test: ["CMD", "mongosh", "--eval", "db.adminCommand('ping')"]
      interval: 10s
      timeout: 5s
      retries: 10
```

E no bloco `catalog-api`, adicionar `mongo: { condition: service_healthy }` em `depends_on` e as env vars:

```yaml
      MongoSettings__ConnectionString: "mongodb://mongo:27017"
      MongoSettings__Database: "fcg_catalog"
```

- [ ] **Step 2: Criar manifest k8s do MongoDB**

Criar `fcg-orchestration/k8s/mongodb.yaml`:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: mongodb
  namespace: fcg
spec:
  replicas: 1
  selector:
    matchLabels:
      app: mongodb
  template:
    metadata:
      labels:
        app: mongodb
    spec:
      containers:
        - name: mongodb
          image: mongo:7
          imagePullPolicy: IfNotPresent
          ports:
            - containerPort: 27017
          volumeMounts:
            - name: data
              mountPath: /data/db
      volumes:
        - name: data
          emptyDir: {}
---
apiVersion: v1
kind: Service
metadata:
  name: mongodb
  namespace: fcg
spec:
  selector:
    app: mongodb
  ports:
    - port: 27017
      targetPort: 27017
```

- [ ] **Step 3: Adicionar as chaves de config do Mongo no configmap do catalog-api (k8s)**

Em `fcg-orchestration/k8s/catalog-api/configmap.yaml` e (mirror) `fcg-catalog-api/k8s/configmap.yaml`, adicionar sob `data:`:

```yaml
  MongoSettings__ConnectionString: "mongodb://mongodb:27017"
  MongoSettings__Database: "fcg_catalog"
```

- [ ] **Step 4: Config local (appsettings)**

Em `fcg-catalog-api/src/Catalog.API/appsettings.json`, adicionar seção nova:

```json
  "MongoSettings": {
    "ConnectionString": "mongodb://localhost:27017",
    "Database": "fcg_catalog"
  },
```

(logo depois de `"ConnectionStrings"`, antes de `"JwtSettings"`).

- [ ] **Step 5: Verificar**

```bash
cd fcg-orchestration
docker compose up -d mongo
docker compose exec mongo mongosh --eval "db.adminCommand('ping')"
```
Esperado: `{ ok: 1 }`.

- [ ] **Step 6: Commit**

```bash
git -C fcg-orchestration add docker-compose.yml k8s/mongodb.yaml k8s/catalog-api/configmap.yaml
git -C fcg-orchestration commit -m "feat: adiciona infra MongoDB (compose + k8s)"
git -C fcg-catalog-api add k8s/configmap.yaml src/Catalog.API/appsettings.json
git -C fcg-catalog-api commit -m "feat: adiciona config MongoSettings"
```

---

### Task 2: Entidade Review + repositório Mongo (fcg-catalog-api)

**Files:**
- Create: `fcg-catalog-api/src/Catalog.Domain/Entities/Review.cs`
- Create: `fcg-catalog-api/src/Catalog.Domain/Interfaces/IReviewRepository.cs`
- Create: `fcg-catalog-api/src/Catalog.Infrastructure/Mongo/MongoSettings.cs`
- Create: `fcg-catalog-api/src/Catalog.Infrastructure/Mongo/MongoReviewRepository.cs`
- Modify: `fcg-catalog-api/src/Catalog.Infrastructure/InfrastructureExtensions.cs`
- Modify: `fcg-catalog-api/src/Catalog.Infrastructure/Catalog.Infrastructure.csproj`
- Test: `fcg-catalog-api/tests/Catalog.Tests/Domain/ReviewEntityTests.cs`

**Interfaces:**
- Consumes: nada de outra task.
- Produces: `Review` (entidade), `IReviewRepository.AddAsync(Review)`, `IReviewRepository.GetByGameIdAsync(Guid gameId)` — usados pela Task 3.

- [ ] **Step 1: Teste da entidade (falha)**

Criar `fcg-catalog-api/tests/Catalog.Tests/Domain/ReviewEntityTests.cs`:

```csharp
using Catalog.Domain.Entities;
using Catalog.Domain.Exceptions;

namespace Catalog.Tests.Domain
{
    public class ReviewEntityTests
    {
        [Fact]
        public void Construtor_DeveCriarReview_QuandoDadosValidos()
        {
            var gameId = Guid.NewGuid();
            var userId = Guid.NewGuid();

            var review = new Review(gameId, userId, 5, "Excelente jogo");

            Assert.Equal(gameId, review.GameId);
            Assert.Equal(userId, review.UserId);
            Assert.Equal(5, review.Rating);
            Assert.Equal("Excelente jogo", review.Comment);
        }

        [Theory]
        [InlineData(0)]
        [InlineData(6)]
        public void Construtor_DeveLancarExcecao_QuandoRatingForaDoIntervalo(int rating)
        {
            Assert.Throws<DomainException>(() =>
                new Review(Guid.NewGuid(), Guid.NewGuid(), rating, "comentário"));
        }
    }
}
```

- [ ] **Step 2: Rodar e confirmar falha**

```bash
cd fcg-catalog-api
dotnet test tests/Catalog.Tests/Catalog.Tests.csproj --filter ReviewEntityTests
```
Esperado: FAIL — `Review` não existe.

- [ ] **Step 3: Implementar `Review`**

Criar `fcg-catalog-api/src/Catalog.Domain/Entities/Review.cs`:

```csharp
using Catalog.Domain.Exceptions;

namespace Catalog.Domain.Entities
{
    public class Review
    {
        public string Id { get; private set; } = string.Empty;
        public Guid GameId { get; private set; }
        public Guid UserId { get; private set; }
        public int Rating { get; private set; }
        public string? Comment { get; private set; }
        public DateTime CreatedAt { get; private set; }

        protected Review() { }

        public Review(Guid gameId, Guid userId, int rating, string? comment = null)
        {
            if (rating is < 1 or > 5)
                throw new DomainException("Rating deve estar entre 1 e 5.");

            GameId = gameId;
            UserId = userId;
            Rating = rating;
            Comment = comment;
            CreatedAt = DateTime.UtcNow;
        }
    }
}
```

- [ ] **Step 4: Rodar e confirmar sucesso**

```bash
dotnet test tests/Catalog.Tests/Catalog.Tests.csproj --filter ReviewEntityTests
```
Esperado: PASS (3 testes).

- [ ] **Step 5: Interface do repositório**

Criar `fcg-catalog-api/src/Catalog.Domain/Interfaces/IReviewRepository.cs`:

```csharp
using Catalog.Domain.Entities;

namespace Catalog.Domain.Interfaces
{
    public interface IReviewRepository
    {
        Task AddAsync(Review review);
        Task<IEnumerable<Review>> GetByGameIdAsync(Guid gameId);
    }
}
```

- [ ] **Step 6: Adicionar pacote MongoDB.Driver**

Em `fcg-catalog-api/src/Catalog.Infrastructure/Catalog.Infrastructure.csproj`, dentro do `<ItemGroup>` de pacotes (criar um se não existir):

```xml
  <ItemGroup>
    <PackageReference Include="MongoDB.Driver" Version="2.28.0" />
  </ItemGroup>
```

- [ ] **Step 7: MongoSettings + repositório Mongo**

Criar `fcg-catalog-api/src/Catalog.Infrastructure/Mongo/MongoSettings.cs`:

```csharp
namespace Catalog.Infrastructure.Mongo
{
    public class MongoSettings
    {
        public string ConnectionString { get; set; } = string.Empty;
        public string Database { get; set; } = string.Empty;
    }
}
```

Criar `fcg-catalog-api/src/Catalog.Infrastructure/Mongo/MongoReviewRepository.cs`:

```csharp
using Catalog.Domain.Entities;
using Catalog.Domain.Interfaces;
using MongoDB.Bson;
using MongoDB.Bson.Serialization.Attributes;
using MongoDB.Driver;

namespace Catalog.Infrastructure.Mongo
{
    [BsonIgnoreExtraElements]
    public class ReviewDocument
    {
        [BsonId]
        [BsonRepresentation(BsonType.ObjectId)]
        public string Id { get; set; } = ObjectId.GenerateNewId().ToString();
        [BsonRepresentation(BsonType.String)]
        public Guid GameId { get; set; }
        [BsonRepresentation(BsonType.String)]
        public Guid UserId { get; set; }
        public int Rating { get; set; }
        public string? Comment { get; set; }
        public DateTime CreatedAt { get; set; }
    }

    public class MongoReviewRepository : IReviewRepository
    {
        private readonly IMongoCollection<ReviewDocument> _collection;

        public MongoReviewRepository(IMongoDatabase database)
        {
            _collection = database.GetCollection<ReviewDocument>("reviews");
        }

        public Task AddAsync(Review review)
        {
            var doc = new ReviewDocument
            {
                GameId = review.GameId,
                UserId = review.UserId,
                Rating = review.Rating,
                Comment = review.Comment,
                CreatedAt = review.CreatedAt
            };
            return _collection.InsertOneAsync(doc);
        }

        public async Task<IEnumerable<Review>> GetByGameIdAsync(Guid gameId)
        {
            var docs = await _collection.Find(d => d.GameId == gameId).ToListAsync();
            return docs.Select(ToEntity);
        }

        private static Review ToEntity(ReviewDocument doc)
        {
            var review = new Review(doc.GameId, doc.UserId, doc.Rating, doc.Comment);
            typeof(Review).GetProperty(nameof(Review.Id))!.SetValue(review, doc.Id);
            typeof(Review).GetProperty(nameof(Review.CreatedAt))!.SetValue(review, doc.CreatedAt);
            return review;
        }
    }
}
```

> Nota: `ToEntity` usa reflection pra restaurar `Id`/`CreatedAt` porque `Review` não tem construtor "de leitura" — é o mesmo trade-off que EF Core resolve com o construtor `protected`. Se preferir mais limpo, adicione um segundo construtor interno em `Review` recebendo todos os campos; mantive reflection aqui pra não abrir um construtor público que quebraria a invariante de validação.

> **Bug evitado, com correção de versão (achado do implementador da Task 2, confirmado em teste real contra Mongo):** `[BsonRepresentation(BsonType.String)]` em `GameId`/`UserId` continua certo e forward-compatible, mas o texto original aqui estava impreciso — na driver 2.28.0 (a versão fixada nesta task), a ausência do atributo NÃO lança `NotSupportedException`; cai no modo legado V2 (`GuidRepresentationMode.V2`), só emite aviso de depreciação `CS0618`. O `NotSupportedException` é comportamento do driver **3.x** (onde V3/string explícito virou padrão), não de qualquer 2.19+. Testado negativamente: implementador removeu o atributo, rodou contra Mongo real, não quebrou — só warning. Mantendo o atributo mesmo assim: evita o warning agora e evita quebra numa eventual migração futura pra driver 3.x.

- [ ] **Step 8: Registrar no DI**

Em `fcg-catalog-api/src/Catalog.Infrastructure/InfrastructureExtensions.cs`, adicionar imports (`Catalog.Infrastructure.Mongo`, `MongoDB.Driver`) e, dentro de `AddInfrastructure`, antes do `return services;`:

```csharp
            services.Configure<MongoSettings>(configuration.GetSection("MongoSettings"));
            services.AddSingleton<IMongoClient>(sp =>
            {
                var settings = configuration.GetSection("MongoSettings").Get<MongoSettings>()!;
                return new MongoClient(settings.ConnectionString);
            });
            services.AddScoped(sp =>
            {
                var settings = configuration.GetSection("MongoSettings").Get<MongoSettings>()!;
                return sp.GetRequiredService<IMongoClient>().GetDatabase(settings.Database);
            });
            services.AddScoped<IReviewRepository, MongoReviewRepository>();
```

- [ ] **Step 9: Build e rodar todos os testes**

```bash
dotnet build fcg-catalog-api/Catalog.slnx
dotnet test fcg-catalog-api/tests/Catalog.Tests/Catalog.Tests.csproj
```
Esperado: build ok, todos os testes (novos + existentes) PASS.

- [ ] **Step 10: Commit**

```bash
git -C fcg-catalog-api add src/Catalog.Domain/Entities/Review.cs src/Catalog.Domain/Interfaces/IReviewRepository.cs \
  src/Catalog.Infrastructure/Mongo/ src/Catalog.Infrastructure/InfrastructureExtensions.cs \
  src/Catalog.Infrastructure/Catalog.Infrastructure.csproj tests/Catalog.Tests/Domain/ReviewEntityTests.cs
git -C fcg-catalog-api commit -m "feat: entidade Review e repositório MongoDB"
```

---

### Task 3: Application + API de avaliações (fcg-catalog-api)

**Files:**
- Create: `fcg-catalog-api/src/Catalog.Application/DTOs/CreateReviewDto.cs`
- Create: `fcg-catalog-api/src/Catalog.Application/DTOs/ReviewDto.cs`
- Create: `fcg-catalog-api/src/Catalog.Application/Interfaces/IReviewService.cs`
- Create: `fcg-catalog-api/src/Catalog.Application/Services/ReviewService.cs`
- Create: `fcg-catalog-api/src/Catalog.API/Controllers/ReviewController.cs`
- Modify: `fcg-catalog-api/src/Catalog.API/Program.cs`
- Test: `fcg-catalog-api/tests/Catalog.Tests/Application/ReviewServiceTests.cs`

**Interfaces:**
- Consumes: `Review`, `IReviewRepository` (Task 2).
- Produces: rota `POST api/Review`, `GET api/Review/game/{gameId}` — usadas pela Task 9 (Kong routes).

- [ ] **Step 1: Teste do service (falha)**

Criar `fcg-catalog-api/tests/Catalog.Tests/Application/ReviewServiceTests.cs`:

```csharp
using Catalog.Application.DTOs;
using Catalog.Application.Services;
using Catalog.Domain.Entities;
using Catalog.Domain.Interfaces;
using Moq;

namespace Catalog.Tests.Application
{
    public class ReviewServiceTests
    {
        private readonly Mock<IReviewRepository> _repoMock;
        private readonly ReviewService _service;

        public ReviewServiceTests()
        {
            _repoMock = new Mock<IReviewRepository>();
            _service = new ReviewService(_repoMock.Object);
        }

        [Fact]
        public async Task CreateAsync_DeveSalvarReview_QuandoDadosValidos()
        {
            var gameId = Guid.NewGuid();
            var userId = Guid.NewGuid();
            var dto = new CreateReviewDto(gameId, 4, "Muito bom");

            _repoMock.Setup(r => r.AddAsync(It.IsAny<Review>())).Returns(Task.CompletedTask);

            var result = await _service.CreateAsync(dto, userId);

            Assert.Equal(gameId, result.GameId);
            Assert.Equal(userId, result.UserId);
            Assert.Equal(4, result.Rating);
            _repoMock.Verify(r => r.AddAsync(It.IsAny<Review>()), Times.Once);
        }

        [Fact]
        public async Task GetByGameIdAsync_DeveRetornarLista()
        {
            var gameId = Guid.NewGuid();
            var reviews = new List<Review> { new(gameId, Guid.NewGuid(), 5, "Top") };
            _repoMock.Setup(r => r.GetByGameIdAsync(gameId)).ReturnsAsync(reviews);

            var result = await _service.GetByGameIdAsync(gameId);

            Assert.Single(result);
        }
    }
}
```

- [ ] **Step 2: Rodar e confirmar falha**

```bash
dotnet test fcg-catalog-api/tests/Catalog.Tests/Catalog.Tests.csproj --filter ReviewServiceTests
```
Esperado: FAIL — tipos não existem.

- [ ] **Step 3: DTOs**

Criar `fcg-catalog-api/src/Catalog.Application/DTOs/CreateReviewDto.cs`:

```csharp
namespace Catalog.Application.DTOs
{
    public record CreateReviewDto(Guid GameId, int Rating, string? Comment);
}
```

Criar `fcg-catalog-api/src/Catalog.Application/DTOs/ReviewDto.cs`:

```csharp
namespace Catalog.Application.DTOs
{
    public record ReviewDto(string Id, Guid GameId, Guid UserId, int Rating, string? Comment, DateTime CreatedAt);
}
```

- [ ] **Step 4: Interface + Service**

Criar `fcg-catalog-api/src/Catalog.Application/Interfaces/IReviewService.cs`:

```csharp
using Catalog.Application.DTOs;

namespace Catalog.Application.Interfaces
{
    public interface IReviewService
    {
        Task<ReviewDto> CreateAsync(CreateReviewDto dto, Guid userId);
        Task<IEnumerable<ReviewDto>> GetByGameIdAsync(Guid gameId);
    }
}
```

Criar `fcg-catalog-api/src/Catalog.Application/Services/ReviewService.cs`:

```csharp
using Catalog.Application.DTOs;
using Catalog.Application.Interfaces;
using Catalog.Domain.Entities;
using Catalog.Domain.Interfaces;

namespace Catalog.Application.Services
{
    public class ReviewService : IReviewService
    {
        private readonly IReviewRepository _reviewRepository;

        public ReviewService(IReviewRepository reviewRepository)
        {
            _reviewRepository = reviewRepository;
        }

        public async Task<ReviewDto> CreateAsync(CreateReviewDto dto, Guid userId)
        {
            var review = new Review(dto.GameId, userId, dto.Rating, dto.Comment);
            await _reviewRepository.AddAsync(review);
            return MapToDto(review);
        }

        public async Task<IEnumerable<ReviewDto>> GetByGameIdAsync(Guid gameId)
        {
            var reviews = await _reviewRepository.GetByGameIdAsync(gameId);
            return reviews.Select(MapToDto);
        }

        private static ReviewDto MapToDto(Review r) =>
            new(r.Id, r.GameId, r.UserId, r.Rating, r.Comment, r.CreatedAt);
    }
}
```

- [ ] **Step 5: Rodar e confirmar sucesso**

```bash
dotnet test fcg-catalog-api/tests/Catalog.Tests/Catalog.Tests.csproj --filter ReviewServiceTests
```
Esperado: PASS (2 testes).

- [ ] **Step 6: Controller**

Criar `fcg-catalog-api/src/Catalog.API/Controllers/ReviewController.cs`:

```csharp
using System.Security.Claims;
using Catalog.Application.DTOs;
using Catalog.Application.Interfaces;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;

namespace Catalog.API.Controllers
{
    [ApiController]
    [Route("api/[controller]")]
    public class ReviewController : ControllerBase
    {
        private readonly IReviewService _reviewService;

        public ReviewController(IReviewService reviewService)
        {
            _reviewService = reviewService;
        }

        /// <summary>
        /// Registra uma avaliação para um jogo, em nome do usuário autenticado.
        /// </summary>
        [HttpPost]
        [Authorize]
        [ProducesResponseType(typeof(ReviewDto), StatusCodes.Status201Created)]
        public async Task<IActionResult> Create([FromBody] CreateReviewDto dto)
        {
            var userId = Guid.Parse(User.FindFirstValue(ClaimTypes.NameIdentifier)!);
            var review = await _reviewService.CreateAsync(dto, userId);
            return CreatedAtAction(nameof(GetByGame), new { gameId = review.GameId }, review);
        }

        /// <summary>
        /// Lista as avaliações de um jogo.
        /// </summary>
        [HttpGet("game/{gameId:guid}")]
        [Authorize]
        [ProducesResponseType(typeof(IEnumerable<ReviewDto>), StatusCodes.Status200OK)]
        public async Task<IActionResult> GetByGame(Guid gameId)
        {
            var reviews = await _reviewService.GetByGameIdAsync(gameId);
            return Ok(reviews);
        }
    }
}
```

> **Achado ao auditar contra o código real:** minha primeira versão desse controller usava `JwtRegisteredClaimNames.Sub` pra pegar o Id do usuário — não funcionaria. O `AddJwtBearer` do `Program.cs` não desliga o `MapInboundClaims` padrão do .NET, então o claim `sub` do token chega remapeado pra `ClaimTypes.NameIdentifier` antes do controller ver qualquer coisa. Confirmei isso lendo `fcg-catalog-api/src/Catalog.API/Controllers/PurchaseController.cs:21`, que já faz exatamente `User.FindFirstValue(ClaimTypes.NameIdentifier)` em produção — copiei o padrão comprovado em vez de reinventar.

- [ ] **Step 7: Registrar service no DI**

Em `fcg-catalog-api/src/Catalog.API/Program.cs`, ao lado de `builder.Services.AddScoped<IGameService, GameService>();`, adicionar:

```csharp
builder.Services.AddScoped<IReviewService, ReviewService>();
```

(e `using Catalog.Application.Services;` já existe no arquivo).

- [ ] **Step 8: Build completo e todos os testes**

```bash
dotnet build fcg-catalog-api/Catalog.slnx
dotnet test fcg-catalog-api/tests/Catalog.Tests/Catalog.Tests.csproj
```
Esperado: PASS geral.

- [ ] **Step 9: Atualizar o README.md do repositório**

Achado auditando o histórico: nas Fases 1 e 2, o critério "cada repositório deve ter README explicando finalidade e variáveis de ambiente" apareceu no feedback do professor e contribuiu pra nota 90/100 nas duas — `fcg-catalog-api/README.md` já segue esse padrão (tabelas de Eventos, Variáveis de Ambiente, Endpoints). Ele precisa ganhar as entradas novas desta e da Task 2, senão fica desatualizado assim que o Mongo/Review existirem.

Em `fcg-catalog-api/README.md`, na tabela **## Variáveis de Ambiente**, adicionar as linhas (depois de `RabbitMq__Pass`):

```markdown
| `MongoSettings__ConnectionString`      | Sim         | `mongodb://localhost:27017`                       | Connection string do MongoDB (avaliações) |
| `MongoSettings__Database`              | Sim         | `fcg_catalog`                                     | Nome do database Mongo             |
```

Na tabela **## Endpoints**, adicionar (depois da linha de `POST /api/purchases`):

```markdown
| `POST`   | `/api/Review`               | Bearer (user)  | Registra avaliação de um jogo                |
| `GET`    | `/api/Review/game/{gameId}` | Bearer (user)  | Lista avaliações de um jogo                  |
```

E em **## Eventos**, nenhuma mudança — Review não publica/consome evento, só grava no Mongo.

- [ ] **Step 10: Commit**

```bash
git -C fcg-catalog-api add src/Catalog.Application/DTOs/CreateReviewDto.cs src/Catalog.Application/DTOs/ReviewDto.cs \
  src/Catalog.Application/Interfaces/IReviewService.cs src/Catalog.Application/Services/ReviewService.cs \
  src/Catalog.API/Controllers/ReviewController.cs src/Catalog.API/Program.cs \
  tests/Catalog.Tests/Application/ReviewServiceTests.cs README.md
git -C fcg-catalog-api commit -m "feat: endpoint de avaliacoes de jogos (api/Review)"
```

---

### Task 4: Infra Redis (orchestration)

**Files:**
- Modify: `fcg-orchestration/docker-compose.yml`
- Create: `fcg-orchestration/k8s/redis.yaml`
- Modify: `fcg-orchestration/k8s/catalog-api/configmap.yaml`
- Modify: `fcg-catalog-api/k8s/configmap.yaml`
- Modify: `fcg-catalog-api/src/Catalog.API/appsettings.json`

- [ ] **Step 1: Serviço `redis` no docker-compose**

Em `fcg-orchestration/docker-compose.yml`, adicionar:

```yaml
  redis:
    image: redis:7-alpine
    ports: ["6379:6379"]
    healthcheck:
      test: ["CMD", "redis-cli", "ping"]
      interval: 10s
      timeout: 5s
      retries: 10
```

No bloco `catalog-api`: `depends_on: redis: { condition: service_healthy }` e env:

```yaml
      RedisSettings__ConnectionString: "redis:6379"
```

- [ ] **Step 2: Manifest k8s do Redis**

Criar `fcg-orchestration/k8s/redis.yaml`:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: redis
  namespace: fcg
spec:
  replicas: 1
  selector:
    matchLabels:
      app: redis
  template:
    metadata:
      labels:
        app: redis
    spec:
      containers:
        - name: redis
          image: redis:7-alpine
          imagePullPolicy: IfNotPresent
          ports:
            - containerPort: 6379
---
apiVersion: v1
kind: Service
metadata:
  name: redis
  namespace: fcg
spec:
  selector:
    app: redis
  ports:
    - port: 6379
      targetPort: 6379
```

- [ ] **Step 3: Config no configmap k8s do catalog-api**

Em `fcg-orchestration/k8s/catalog-api/configmap.yaml` e `fcg-catalog-api/k8s/configmap.yaml`, adicionar:

```yaml
  RedisSettings__ConnectionString: "redis:6379"
```

- [ ] **Step 4: Config local**

Em `fcg-catalog-api/src/Catalog.API/appsettings.json`, adicionar seção:

```json
  "RedisSettings": {
    "ConnectionString": "localhost:6379"
  },
```

- [ ] **Step 5: Verificar**

```bash
cd fcg-orchestration
docker compose up -d redis
docker compose exec redis redis-cli ping
```
Esperado: `PONG`.

- [ ] **Step 6: Commit**

```bash
git -C fcg-orchestration add docker-compose.yml k8s/redis.yaml k8s/catalog-api/configmap.yaml
git -C fcg-orchestration commit -m "feat: adiciona infra Redis (compose + k8s)"
git -C fcg-catalog-api add k8s/configmap.yaml src/Catalog.API/appsettings.json
git -C fcg-catalog-api commit -m "feat: adiciona config RedisSettings"
```

---

### Task 5: Cache Redis na listagem de jogos (fcg-catalog-api)

**Files:**
- Modify: `fcg-catalog-api/src/Catalog.Application/Services/GameService.cs`
- Modify: `fcg-catalog-api/src/Catalog.API/Catalog.API.csproj`
- Modify: `fcg-catalog-api/src/Catalog.API/Program.cs`
- Test: `fcg-catalog-api/tests/Catalog.Tests/Application/GameServiceTests.cs` (adicionar casos)

**Interfaces:**
- Consumes: `IDistributedCache` (ASP.NET Core abstraction, registrado via Redis).
- Produces: nada consumido por outra task.

- [ ] **Step 1: Testes de cache (falha)**

Em `fcg-catalog-api/tests/Catalog.Tests/Application/GameServiceTests.cs`, adicionar (no topo, `using Microsoft.Extensions.Caching.Distributed;` e `using Moq;` já existe):

```csharp
        [Fact]
        public async Task GetAllAsync_DeveConsultarRepositorio_QuandoCacheVazio()
        {
            var cacheMock = new Mock<IDistributedCache>();
            cacheMock.Setup(c => c.GetAsync("catalog:games:all", default)).ReturnsAsync((byte[]?)null);
            var repoMock = new Mock<IGameRepository>();
            repoMock.Setup(r => r.GetAllAsync()).ReturnsAsync(new List<Game> { new("CS2", 59.90m) });
            var service = new GameService(repoMock.Object, cacheMock.Object);

            var result = await service.GetAllAsync();

            Assert.Single(result);
            repoMock.Verify(r => r.GetAllAsync(), Times.Once);
            cacheMock.Verify(c => c.SetAsync("catalog:games:all", It.IsAny<byte[]>(), It.IsAny<DistributedCacheEntryOptions>(), default), Times.Once);
        }

        [Fact]
        public async Task CreateAsync_DeveInvalidarCache_QuandoJogoCriado()
        {
            var cacheMock = new Mock<IDistributedCache>();
            var repoMock = new Mock<IGameRepository>();
            repoMock.Setup(r => r.AddAsync(It.IsAny<Game>())).Returns(Task.CompletedTask);
            var service = new GameService(repoMock.Object, cacheMock.Object);

            await service.CreateAsync(new CreateGameDto("Novo Jogo", 10m, null));

            cacheMock.Verify(c => c.RemoveAsync("catalog:games:all", default), Times.Once);
        }
```

E ajustar o construtor no `GameServiceTests()` existente para passar um `Mock<IDistributedCache>` — trocar:

```csharp
            _gameService = new GameService(_gameRepoMock.Object);
```
por:
```csharp
            _cacheMock = new Mock<IDistributedCache>();
            _cacheMock.Setup(c => c.GetAsync(It.IsAny<string>(), default)).ReturnsAsync((byte[]?)null);
            _gameService = new GameService(_gameRepoMock.Object, _cacheMock.Object);
```
e declarar `private readonly Mock<IDistributedCache> _cacheMock;` junto de `_gameRepoMock`.

- [ ] **Step 2: Rodar e confirmar falha**

```bash
dotnet test fcg-catalog-api/tests/Catalog.Tests/Catalog.Tests.csproj --filter GameServiceTests
```
Esperado: FAIL — `GameService` não tem construtor com 2 parâmetros.

- [ ] **Step 3: Implementar cache no GameService**

Reescrever `fcg-catalog-api/src/Catalog.Application/Services/GameService.cs`:

```csharp
using System.Text.Json;
using Catalog.Application.DTOs;
using Catalog.Application.Interfaces;
using Catalog.Domain.Entities;
using Catalog.Domain.Exceptions;
using Catalog.Domain.Interfaces;
using Microsoft.Extensions.Caching.Distributed;

namespace Catalog.Application.Services
{
    public class GameService : IGameService
    {
        private const string AllGamesCacheKey = "catalog:games:all";
        private static readonly DistributedCacheEntryOptions CacheOptions = new()
        {
            AbsoluteExpirationRelativeToNow = TimeSpan.FromSeconds(30)
        };

        private readonly IGameRepository _gameRepository;
        private readonly IDistributedCache _cache;

        public GameService(IGameRepository gameRepository, IDistributedCache cache)
        {
            _gameRepository = gameRepository;
            _cache = cache;
        }

        public async Task<GameDto> GetByIdAsync(Guid id)
        {
            var game = await _gameRepository.GetByIdAsync(id)
                ?? throw new DomainException($"Jogo com Id '{id}' não encontrado.");

            return MapToDto(game);
        }

        public async Task<IEnumerable<GameDto>> GetAllAsync()
        {
            var cached = await _cache.GetAsync(AllGamesCacheKey);
            if (cached is not null)
                return JsonSerializer.Deserialize<List<GameDto>>(cached)!;

            var games = await _gameRepository.GetAllAsync();
            var dtos = games.Select(MapToDto).ToList();

            await _cache.SetAsync(AllGamesCacheKey, JsonSerializer.SerializeToUtf8Bytes(dtos), CacheOptions);
            return dtos;
        }

        public async Task<GameDto> CreateAsync(CreateGameDto dto)
        {
            var game = new Game(dto.Title, dto.Price, dto.Description);
            await _gameRepository.AddAsync(game);
            await _cache.RemoveAsync(AllGamesCacheKey);
            return MapToDto(game);
        }

        public async Task<GameDto> UpdateAsync(Guid id, UpdateGameDto dto)
        {
            var game = await _gameRepository.GetByIdAsync(id)
                ?? throw new DomainException($"Jogo com Id '{id}' não encontrado.");

            game.Update(dto.Title, dto.Price, dto.Description);
            await _gameRepository.UpdateAsync(game);
            await _cache.RemoveAsync(AllGamesCacheKey);

            return MapToDto(game);
        }

        public async Task DeleteAsync(Guid id)
        {
            var game = await _gameRepository.GetByIdAsync(id)
                ?? throw new DomainException($"Jogo com Id '{id}' não encontrado.");

            await _gameRepository.DeleteAsync(game.Id);
            await _cache.RemoveAsync(AllGamesCacheKey);
        }

        private static GameDto MapToDto(Game game) => new(
            game.Id,
            game.Title,
            game.Description,
            game.Price,
            game.IsActive,
            game.CreatedAt
        );
    }
}
```

- [ ] **Step 4: Registrar Redis no Program.cs**

Adicionar pacote em `fcg-catalog-api/src/Catalog.API/Catalog.API.csproj`:

```xml
    <PackageReference Include="Microsoft.Extensions.Caching.StackExchangeRedis" Version="8.0.0" />
```

Em `fcg-catalog-api/src/Catalog.API/Program.cs`, adicionar antes de `builder.Services.AddScoped<IGameService, GameService>();`:

```csharp
builder.Services.AddStackExchangeRedisCache(options =>
{
    options.Configuration = builder.Configuration["RedisSettings:ConnectionString"];
});
```

- [ ] **Step 5: Rodar e confirmar sucesso**

```bash
dotnet build fcg-catalog-api/Catalog.slnx
dotnet test fcg-catalog-api/tests/Catalog.Tests/Catalog.Tests.csproj
```
Esperado: PASS geral (inclui os 2 testes novos + `GetByIdAsync`/`UpdateAsync`/`CreateAsync` antigos ajustados).

- [ ] **Step 6: Atualizar o README.md do repositório**

Em `fcg-catalog-api/README.md`, tabela **## Variáveis de Ambiente**, adicionar (depois das linhas de Mongo, adicionadas na Task 3):

```markdown
| `RedisSettings__ConnectionString`      | Sim         | `localhost:6379`                                  | Connection string do Redis (cache) |
```

- [ ] **Step 7: Commit**

```bash
git -C fcg-catalog-api add src/Catalog.Application/Services/GameService.cs src/Catalog.API/Catalog.API.csproj \
  src/Catalog.API/Program.cs tests/Catalog.Tests/Application/GameServiceTests.cs README.md
git -C fcg-catalog-api commit -m "feat: cache Redis na listagem de jogos"
```

---

### Task 6: Instrumentação Prometheus (UsersAPI + CatalogAPI)

**Files:**
- Modify: `fcg-catalog-api/src/Catalog.API/Catalog.API.csproj`
- Modify: `fcg-catalog-api/src/Catalog.API/Program.cs`
- Modify: `fcg-users-api/src/Users.API/Users.API.csproj`
- Modify: `fcg-users-api/src/Users.API/Program.cs`

- [ ] **Step 1: Pacote em ambos os `.csproj`**

Adicionar em `Catalog.API.csproj` e `Users.API.csproj`:

```xml
    <PackageReference Include="prometheus-net.AspNetCore" Version="8.2.1" />
```

- [ ] **Step 2: Middleware no Program.cs do CatalogAPI**

Em `fcg-catalog-api/src/Catalog.API/Program.cs`, logo após `var app = builder.Build();` e antes de `app.UseMiddleware<ErrorHandlingMiddleware>();`, adicionar:

```csharp
app.UseHttpMetrics();
```

E depois de `app.MapControllers();`, adicionar:

```csharp
app.MapMetrics();
```

- [ ] **Step 3: Mesmo middleware no Program.cs do UsersAPI**

Repetir exatamente o mesmo padrão em `fcg-users-api/src/Users.API/Program.cs` (`app.UseHttpMetrics();` antes do `ErrorHandlingMiddleware`, `app.MapMetrics();` depois de `MapControllers()`).

- [ ] **Step 4: Verificar localmente**

```bash
cd fcg-catalog-api/src/Catalog.API && dotnet run &
sleep 5
curl http://localhost:5xxx/metrics | grep http_requests_received_total
```
Esperado: linhas `# TYPE http_requests_received_total counter` e `# TYPE http_request_duration_seconds histogram` no output (a porta exata vem do `launchSettings.json`).

- [ ] **Step 5: Atualizar o README.md dos dois repositórios**

Em `fcg-catalog-api/README.md` e `fcg-users-api/README.md`, adicionar uma seção nova (depois de `## Endpoints`, antes de `### Exemplos de uso`):

```markdown
## Observabilidade

| Rota       | Descrição                                              |
|------------|----------------------------------------------------------|
| `/metrics` | Métricas Prometheus (contagem de requisições, latência, status code) — raspado pelo Prometheus da orchestration |
```

- [ ] **Step 6: Commit**

```bash
git -C fcg-catalog-api add src/Catalog.API/Catalog.API.csproj src/Catalog.API/Program.cs README.md
git -C fcg-catalog-api commit -m "feat: expõe métricas Prometheus em /metrics"
git -C fcg-users-api add src/Users.API/Users.API.csproj src/Users.API/Program.cs README.md
git -C fcg-users-api commit -m "feat: expõe métricas Prometheus em /metrics"
```

---

### Task 7: Infra Prometheus (orchestration)

**Files:**
- Create: `fcg-orchestration/prometheus/prometheus.yml`
- Modify: `fcg-orchestration/docker-compose.yml`
- Create: `fcg-orchestration/k8s/prometheus/configmap.yaml`
- Create: `fcg-orchestration/k8s/prometheus/deployment.yaml`
- Create: `fcg-orchestration/k8s/prometheus/service.yaml`

- [ ] **Step 1: Config de scrape (docker-compose)**

Criar `fcg-orchestration/prometheus/prometheus.yml`:

```yaml
global:
  scrape_interval: 5s

scrape_configs:
  - job_name: users-api
    static_configs:
      - targets: ["users-api:8080"]
  - job_name: catalog-api
    static_configs:
      - targets: ["catalog-api:8080"]
```

- [ ] **Step 2: Serviço no docker-compose**

Em `fcg-orchestration/docker-compose.yml`, adicionar:

```yaml
  prometheus:
    image: prom/prometheus:v2.55.0
    ports: ["9090:9090"]
    volumes:
      - ./prometheus/prometheus.yml:/etc/prometheus/prometheus.yml:ro
    depends_on: [users-api, catalog-api]
```

- [ ] **Step 3: ConfigMap k8s (targets via Service, porta 80)**

Criar `fcg-orchestration/k8s/prometheus/configmap.yaml`:

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: prometheus-config
  namespace: fcg
data:
  prometheus.yml: |
    global:
      scrape_interval: 5s
    scrape_configs:
      - job_name: users-api
        static_configs:
          - targets: ["users-api:80"]
      - job_name: catalog-api
        static_configs:
          - targets: ["catalog-api:80"]
```

- [ ] **Step 4: Deployment + Service k8s**

Criar `fcg-orchestration/k8s/prometheus/deployment.yaml`:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: prometheus
  namespace: fcg
spec:
  replicas: 1
  selector:
    matchLabels:
      app: prometheus
  template:
    metadata:
      labels:
        app: prometheus
    spec:
      containers:
        - name: prometheus
          image: prom/prometheus:v2.55.0
          imagePullPolicy: IfNotPresent
          ports:
            - containerPort: 9090
          volumeMounts:
            - name: config
              mountPath: /etc/prometheus
      volumes:
        - name: config
          configMap:
            name: prometheus-config
```

Criar `fcg-orchestration/k8s/prometheus/service.yaml`:

```yaml
apiVersion: v1
kind: Service
metadata:
  name: prometheus
  namespace: fcg
spec:
  selector:
    app: prometheus
  ports:
    - port: 9090
      targetPort: 9090
```

- [ ] **Step 5: Verificar**

```bash
cd fcg-orchestration
docker compose up -d --build users-api catalog-api prometheus
sleep 15
curl -s http://localhost:9090/api/v1/targets | grep '"health":"up"'
```
Esperado: pelo menos 2 targets `up` (users-api, catalog-api).

- [ ] **Step 6: Commit**

```bash
git -C fcg-orchestration add prometheus/ docker-compose.yml k8s/prometheus/
git -C fcg-orchestration commit -m "feat: adiciona Prometheus (compose + k8s)"
```

---

### Task 8: Infra Grafana + dashboard (orchestration)

**Files:**
- Create: `fcg-orchestration/grafana/provisioning/datasources/datasource.yml`
- Create: `fcg-orchestration/grafana/provisioning/dashboards/dashboard.yml`
- Create: `fcg-orchestration/grafana/dashboards/fcg-overview.json`
- Modify: `fcg-orchestration/docker-compose.yml`
- Create: `fcg-orchestration/k8s/grafana/configmap.yaml`
- Create: `fcg-orchestration/k8s/grafana/deployment.yaml`
- Create: `fcg-orchestration/k8s/grafana/service.yaml`

- [ ] **Step 1: Provisionamento do datasource**

Criar `fcg-orchestration/grafana/provisioning/datasources/datasource.yml`:

```yaml
apiVersion: 1
datasources:
  - name: Prometheus
    type: prometheus
    access: proxy
    url: http://prometheus:9090
    isDefault: true
```

- [ ] **Step 2: Provisionamento do dashboard**

Criar `fcg-orchestration/grafana/provisioning/dashboards/dashboard.yml`:

```yaml
apiVersion: 1
providers:
  - name: FCG
    folder: FCG
    type: file
    options:
      path: /etc/grafana/provisioning/dashboards/json
```

- [ ] **Step 3: Dashboard JSON**

Criar `fcg-orchestration/grafana/dashboards/fcg-overview.json`:

```json
{
  "title": "FCG - Overview",
  "uid": "fcg-overview",
  "timezone": "browser",
  "schemaVersion": 39,
  "version": 1,
  "refresh": "5s",
  "panels": [
    {
      "id": 1,
      "title": "Taxa de requisições por segundo",
      "type": "timeseries",
      "gridPos": { "h": 8, "w": 12, "x": 0, "y": 0 },
      "targets": [
        {
          "expr": "sum(rate(http_requests_received_total[1m])) by (job)",
          "legendFormat": "{{job}}"
        }
      ]
    },
    {
      "id": 2,
      "title": "Taxa de erro (4xx + 5xx)",
      "type": "timeseries",
      "gridPos": { "h": 8, "w": 12, "x": 12, "y": 0 },
      "targets": [
        {
          "expr": "sum(rate(http_requests_received_total{code=~\"[45]..\"}[1m])) by (job)",
          "legendFormat": "{{job}}"
        }
      ]
    },
    {
      "id": 3,
      "title": "Latência p95",
      "type": "timeseries",
      "gridPos": { "h": 8, "w": 12, "x": 0, "y": 8 },
      "targets": [
        {
          "expr": "histogram_quantile(0.95, sum(rate(http_request_duration_seconds_bucket[5m])) by (le, job))",
          "legendFormat": "{{job}}"
        }
      ]
    },
    {
      "id": 4,
      "title": "Requisições por status code",
      "type": "timeseries",
      "gridPos": { "h": 8, "w": 12, "x": 12, "y": 8 },
      "targets": [
        {
          "expr": "sum(rate(http_requests_received_total[1m])) by (code)",
          "legendFormat": "{{code}}"
        }
      ]
    },
    {
      "id": 5,
      "title": "Total de requisições (desde o início)",
      "type": "stat",
      "gridPos": { "h": 4, "w": 24, "x": 0, "y": 16 },
      "targets": [
        {
          "expr": "sum(http_requests_received_total) by (job)",
          "legendFormat": "{{job}}"
        }
      ]
    }
  ]
}
```

- [ ] **Step 4: Serviço no docker-compose**

Em `fcg-orchestration/docker-compose.yml`, adicionar:

```yaml
  grafana:
    image: grafana/grafana:11.2.0
    ports: ["3000:3000"]
    environment:
      GF_SECURITY_ADMIN_PASSWORD: admin
      GF_AUTH_ANONYMOUS_ENABLED: "true"
      GF_AUTH_ANONYMOUS_ORG_ROLE: Viewer
    volumes:
      - ./grafana/provisioning:/etc/grafana/provisioning
      - ./grafana/dashboards:/etc/grafana/provisioning/dashboards/json
    depends_on: [prometheus]
```

- [ ] **Step 5: ConfigMap + Deployment + Service k8s**

Criar `fcg-orchestration/k8s/grafana/configmap.yaml` (embute os 3 arquivos como chaves):

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: grafana-provisioning
  namespace: fcg
data:
  datasource.yml: |
    apiVersion: 1
    datasources:
      - name: Prometheus
        type: prometheus
        access: proxy
        url: http://prometheus:9090
        isDefault: true
  dashboard-provider.yml: |
    apiVersion: 1
    providers:
      - name: FCG
        folder: FCG
        type: file
        options:
          path: /etc/grafana/provisioning/dashboards/json
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: grafana-dashboard
  namespace: fcg
data:
  fcg-overview.json: |
    {"title":"FCG - Overview","uid":"fcg-overview","timezone":"browser","schemaVersion":39,"version":1,"refresh":"5s","panels":[{"id":1,"title":"Taxa de requisições por segundo","type":"timeseries","gridPos":{"h":8,"w":12,"x":0,"y":0},"targets":[{"expr":"sum(rate(http_requests_received_total[1m])) by (job)","legendFormat":"{{job}}"}]},{"id":2,"title":"Taxa de erro (4xx + 5xx)","type":"timeseries","gridPos":{"h":8,"w":12,"x":12,"y":0},"targets":[{"expr":"sum(rate(http_requests_received_total{code=~\"[45]..\"}[1m])) by (job)","legendFormat":"{{job}}"}]},{"id":3,"title":"Latência p95","type":"timeseries","gridPos":{"h":8,"w":12,"x":0,"y":8},"targets":[{"expr":"histogram_quantile(0.95, sum(rate(http_request_duration_seconds_bucket[5m])) by (le, job))","legendFormat":"{{job}}"}]},{"id":4,"title":"Requisições por status code","type":"timeseries","gridPos":{"h":8,"w":12,"x":12,"y":8},"targets":[{"expr":"sum(rate(http_requests_received_total[1m])) by (code)","legendFormat":"{{code}}"}]},{"id":5,"title":"Total de requisições (desde o início)","type":"stat","gridPos":{"h":4,"w":24,"x":0,"y":16},"targets":[{"expr":"sum(http_requests_received_total) by (job)","legendFormat":"{{job}}"}]}]}
```

Criar `fcg-orchestration/k8s/grafana/deployment.yaml`:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: grafana
  namespace: fcg
spec:
  replicas: 1
  selector:
    matchLabels:
      app: grafana
  template:
    metadata:
      labels:
        app: grafana
    spec:
      containers:
        - name: grafana
          image: grafana/grafana:11.2.0
          imagePullPolicy: IfNotPresent
          ports:
            - containerPort: 3000
          env:
            - name: GF_SECURITY_ADMIN_PASSWORD
              value: "admin"
            - name: GF_AUTH_ANONYMOUS_ENABLED
              value: "true"
            - name: GF_AUTH_ANONYMOUS_ORG_ROLE
              value: "Viewer"
          volumeMounts:
            - name: provisioning-datasources
              mountPath: /etc/grafana/provisioning/datasources
            - name: provisioning-dashboards
              mountPath: /etc/grafana/provisioning/dashboards
            - name: dashboard-json
              mountPath: /etc/grafana/provisioning/dashboards/json
      volumes:
        - name: provisioning-datasources
          configMap:
            name: grafana-provisioning
            items:
              - key: datasource.yml
                path: datasource.yml
        - name: provisioning-dashboards
          configMap:
            name: grafana-provisioning
            items:
              - key: dashboard-provider.yml
                path: dashboard-provider.yml
        - name: dashboard-json
          configMap:
            name: grafana-dashboard
```

Criar `fcg-orchestration/k8s/grafana/service.yaml`:

```yaml
apiVersion: v1
kind: Service
metadata:
  name: grafana
  namespace: fcg
spec:
  selector:
    app: grafana
  ports:
    - port: 3000
      targetPort: 3000
```

- [ ] **Step 6: Verificar**

```bash
cd fcg-orchestration
docker compose up -d grafana
sleep 10
curl -s -o /dev/null -w "%{http_code}" http://localhost:3000/api/health
```
Esperado: `200`. Depois abrir `http://localhost:3000` no navegador (anônimo, Viewer) e confirmar que o dashboard "FCG - Overview" aparece na pasta "FCG".

- [ ] **Step 7: Commit**

```bash
git -C fcg-orchestration add grafana/ docker-compose.yml k8s/grafana/
git -C fcg-orchestration commit -m "feat: adiciona Grafana com dashboard provisionado"
```

---

### Task 9: Kong declarativo (docker-compose)

**Files:**
- Create: `fcg-orchestration/kong/kong.yml`
- Modify: `fcg-orchestration/docker-compose.yml`

**Interfaces:**
- Consumes: rotas `api/Auth`, `api/User` (users-api), `api/Game`, `api/purchases`, `api/Review` (catalog-api) — todas já existentes ou criadas na Task 3. **`api/purchases` é minúsculo e plural de propósito** — `PurchaseController` tem `[Route("api/purchases")]` explícito (não usa o token `[controller]` como os outros), confirmado lendo `fcg-catalog-api/src/Catalog.API/Controllers/PurchaseController.cs:9`.
- Consumes: `JwtSettings:Issuer` = `"FiapCloudGames"` e `JwtSettings:SecretKey` = `"fcg-fase2-shared-secret-key-please-change-32+chars"` (já usados por UsersAPI/CatalogAPI, ver `docker-compose.yml` atual) — o Kong precisa da MESMA chave para validar tokens emitidos pela UsersAPI.

- [ ] **Step 1: Config declarativa do Kong**

Criar `fcg-orchestration/kong/kong.yml`:

```yaml
_format_version: "3.0"

services:
  - name: users-api
    url: http://users-api:8080
    routes:
      - name: auth-route
        paths: ["/api/Auth"]
        strip_path: false
      - name: user-register-route
        paths: ["/api/User"]
        methods: ["POST"]
        strip_path: false
      - name: user-protected-route
        paths: ["/api/User"]
        methods: ["GET", "PUT", "DELETE", "PATCH"]
        strip_path: false
        plugins:
          - name: jwt

  - name: catalog-api
    url: http://catalog-api:8080
    routes:
      - name: catalog-route
        paths: ["/api/Game", "/api/purchases", "/api/Review"]
        strip_path: false
        plugins:
          - name: jwt

consumers:
  - username: fcg-app
    jwt_secrets:
      - key: "FiapCloudGames"
        algorithm: HS256
        secret: "fcg-fase2-shared-secret-key-please-change-32+chars"
```

> **`strip_path: false` é obrigatório em toda rota** (achado real do implementador da Task 9, descoberto com o Kong rodando): o default do Kong é `strip_path: true`, que remove o prefixo casado antes de encaminhar pro backend — `/api/Auth/login` chegaria no users-api como `/login` e tomaria 404 do próprio ASP.NET. Sem essa linha o gateway não funciona pra nenhuma rota. Como aqui os paths do Kong são exatamente os paths reais dos controllers (não há reescrita de prefixo), o certo é sempre `false`.

> `/api/Auth` fica sem plugin JWT de propósito — é onde o cliente faz login e ainda não tem token. As demais rotas exigem `Authorization: Bearer <token>` validado pelo Kong antes mesmo de chegar no serviço.

> **Atenção à caixa de letras:** os controllers geram rotas com a casing exata do nome da classe (`AuthController` → `/api/Auth`, não `/api/auth`) — **exceto `PurchaseController`, que tem `[Route("api/purchases")]` explícito**: minúsculo e plural, quebra o padrão dos outros de propósito (confirmado no código-fonte, não é suposição). O matching de paths do Kong é sensível a maiúsculas/minúsculas — use sempre `/api/Auth`, `/api/User`, `/api/Game`, `/api/purchases`, `/api/Review`. Isso vale pra gravação do vídeo também: é fácil digitar "Purchase" com maiúscula por analogia aos outros e tomar 404 no Kong.

> **Credenciais de teste já seedadas** em `fcg-users-api/src/Users.Infrastructure/Data/AppDbContext.cs` (`SeedUsersAsync`): admin `admin@fcg.com` / `Admin@123` (role Admin), e usuários comuns `yuri@fcg.com`, `rafael@fcg.com`, `pedro@fcg.com`, `gustavo@fcg.com`, `carlos@fcg.com`, todos com senha `Fiap@123`. Usados nos `curl` de verificação abaixo.

- [ ] **Step 2: Fechar o acesso direto a users-api/catalog-api — Kong vira o único ponto de entrada externo**

O enunciado exige que o gateway "receba todas as requisições externas". Do jeito que o `docker-compose.yml` está hoje (Task 2 da Fase 2), `users-api` e `catalog-api` publicam `5001:8080`/`5002:8080` pro host — um cliente externo consegue pular o Kong inteiro batendo direto nessas portas. Remover essas duas linhas `ports:` em `fcg-orchestration/docker-compose.yml`:

```yaml
  users-api:
    build:
      context: ../fcg-users-api
      dockerfile: Dockerfile
    depends_on:
      rabbitmq: { condition: service_healthy }
      users-db: { condition: service_healthy }
    environment:
      # ...(sem mudança nas env vars)
    # ports: ["5001:8080"]   ← REMOVER esta linha

  catalog-api:
    build:
      context: ../fcg-catalog-api
      dockerfile: Dockerfile
    depends_on:
      # ...
    environment:
      # ...(sem mudança nas env vars)
    # ports: ["5002:8080"]   ← REMOVER esta linha
```

O container continua ouvindo em `8080` — só não fica mais publicado no host. Prometheus e Kong acessam pela rede interna do compose (`users-api:8080`, `catalog-api:8080`), que não depende de `ports:`. Depois disso, o único jeito de bater nesses dois serviços de fora é via Kong, porta `8000`.

> **Trade-off:** durante o dia a dia de dev você perde o acesso direto a `localhost:5001`/`5002` (Swagger incluso). Pra debugar um serviço isoladamente sem o gateway, use `docker compose exec catalog-api curl localhost:8080/...` ou reative a porta temporariamente — não é permanente, é só o estado final que precisa satisfazer "ponto de entrada único".

- [ ] **Step 3: Corrigir a seção "Como rodar via Docker" nos READMEs individuais**

Achado auditando os READMEs existentes: `fcg-users-api/README.md` e `fcg-catalog-api/README.md` já têm uma seção `## Como rodar via Docker` que termina com "O serviço ficará disponível em **http://localhost:5001**" (ou `5002`). Depois do Step 2 acima, essa frase vira mentira — a porta não é mais publicada. Corrigir os dois:

Em `fcg-users-api/README.md`, trocar:
```markdown
O serviço ficará disponível em **http://localhost:5001**.
```
por:
```markdown
A partir da Fase 3, o serviço não é mais acessível direto — todo tráfego externo passa pelo Kong (`fcg-orchestration`), em **http://localhost:8000/api/User** e **http://localhost:8000/api/Auth**. Ver o README do `fcg-orchestration` para detalhes do gateway.
```

Em `fcg-catalog-api/README.md`, trocar:
```markdown
O serviço ficará disponível em **http://localhost:5002**.
```
por:
```markdown
A partir da Fase 3, o serviço não é mais acessível direto — todo tráfego externo passa pelo Kong (`fcg-orchestration`), em **http://localhost:8000/api/Game**, **http://localhost:8000/api/purchases** e **http://localhost:8000/api/Review**. Ver o README do `fcg-orchestration` para detalhes do gateway.
```

Commit junto com o Step 9 (commit final desta task) — não precisa de commit isolado.

- [ ] **Step 4: Serviço Kong no docker-compose**

Em `fcg-orchestration/docker-compose.yml`, adicionar:

```yaml
  kong:
    image: kong:3.7
    environment:
      KONG_DATABASE: "off"
      KONG_DECLARATIVE_CONFIG: /kong/declarative/kong.yml
      KONG_PROXY_LISTEN: "0.0.0.0:8000"
      KONG_ADMIN_LISTEN: "0.0.0.0:8001"
    volumes:
      - ./kong/kong.yml:/kong/declarative/kong.yml:ro
    ports: ["8000:8000", "8001:8001"]
    depends_on: [users-api, catalog-api]
```

- [ ] **Step 5: Verificar — login público**

```bash
cd fcg-orchestration
docker compose up -d --build users-api catalog-api kong
sleep 10
curl -s -X POST http://localhost:8000/api/Auth/login -H "Content-Type: application/json" \
  -d '{"email":"admin@fcg.com","password":"Admin@123"}'
```
Esperado: `200` com um `accessToken` no corpo (rota pública, sem JWT plugin).

- [ ] **Step 6: Verificar — rota protegida sem token**

```bash
curl -s -o /dev/null -w "%{http_code}" http://localhost:8000/api/Game
```
Esperado: `401` (Kong bloqueia antes de chegar no catalog-api).

- [ ] **Step 7: Verificar — rota protegida com token**

```bash
TOKEN=$(curl -s -X POST http://localhost:8000/api/Auth/login -H "Content-Type: application/json" \
  -d '{"email":"admin@fcg.com","password":"Admin@123"}' | jq -r .accessToken)
curl -s -o /dev/null -w "%{http_code}" http://localhost:8000/api/Game -H "Authorization: Bearer $TOKEN"
```
Esperado: `200`.

- [ ] **Step 8: Verificar — acesso direto bloqueado (porta antiga fechada)**

```bash
curl -s -o /dev/null -w "%{http_code}" http://localhost:5002/api/Game 2>&1 || echo "conexão recusada (esperado)"
```
Esperado: falha de conexão — `5002` não está mais publicado, só existe o caminho via `8000`.

- [ ] **Step 9: Commit**

```bash
git -C fcg-orchestration add kong/kong.yml docker-compose.yml
git -C fcg-orchestration commit -m "feat: adiciona Kong (DB-less) como API Gateway e fecha acesso direto aos servicos"
git -C fcg-users-api add README.md
git -C fcg-users-api commit -m "docs: atualiza instrucoes de acesso apos fechamento do gateway"
git -C fcg-catalog-api add README.md
git -C fcg-catalog-api commit -m "docs: atualiza instrucoes de acesso apos fechamento do gateway"
```

---

### Task 10: Kong em k8s

**Files:**
- Create: `fcg-orchestration/k8s/kong/configmap.yaml`
- Create: `fcg-orchestration/k8s/kong/deployment.yaml`
- Create: `fcg-orchestration/k8s/kong/service.yaml`

- [ ] **Step 1: ConfigMap com kong.yml (portas de Service = 80)**

Criar `fcg-orchestration/k8s/kong/configmap.yaml`:

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: kong-config
  namespace: fcg
data:
  kong.yml: |
    _format_version: "3.0"
    services:
      - name: users-api
        url: http://users-api
        routes:
          - name: auth-route
            paths: ["/api/Auth"]
            strip_path: false
          - name: user-register-route
            paths: ["/api/User"]
            methods: ["POST"]
            strip_path: false
          - name: user-protected-route
            paths: ["/api/User"]
            methods: ["GET", "PUT", "DELETE", "PATCH"]
            strip_path: false
            plugins:
              - name: jwt
      - name: catalog-api
        url: http://catalog-api
        routes:
          - name: catalog-route
            paths: ["/api/Game", "/api/purchases", "/api/Review"]
            strip_path: false
            plugins:
              - name: jwt
    consumers:
      - username: fcg-app
        jwt_secrets:
          - key: "FiapCloudGames"
            algorithm: HS256
            secret: "fcg-fase2-shared-secret-key-please-change-32+chars"
```

- [ ] **Step 2: Deployment + Service**

Criar `fcg-orchestration/k8s/kong/deployment.yaml`:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: kong
  namespace: fcg
spec:
  replicas: 1
  selector:
    matchLabels:
      app: kong
  template:
    metadata:
      labels:
        app: kong
    spec:
      containers:
        - name: kong
          image: kong:3.7
          imagePullPolicy: IfNotPresent
          env:
            - name: KONG_DATABASE
              value: "off"
            - name: KONG_DECLARATIVE_CONFIG
              value: /kong/declarative/kong.yml
            - name: KONG_PROXY_LISTEN
              value: "0.0.0.0:8000"
            - name: KONG_ADMIN_LISTEN
              value: "0.0.0.0:8001"
          ports:
            - containerPort: 8000
            - containerPort: 8001
          volumeMounts:
            - name: config
              mountPath: /kong/declarative
      volumes:
        - name: config
          configMap:
            name: kong-config
```

Criar `fcg-orchestration/k8s/kong/service.yaml`:

```yaml
apiVersion: v1
kind: Service
metadata:
  name: kong
  namespace: fcg
spec:
  selector:
    app: kong
  ports:
    - name: proxy
      port: 8000
      targetPort: 8000
    - name: admin
      port: 8001
      targetPort: 8001
```

- [ ] **Step 3: Verificar**

```bash
kubectl apply -R -f fcg-orchestration/k8s/
kubectl -n fcg port-forward svc/kong 8000:8000 &
sleep 5
curl -s -o /dev/null -w "%{http_code}" http://localhost:8000/api/Game
```
Esperado: `401` (sem token) — mesma verificação da Task 9, agora via k8s.

- [ ] **Step 4: Commit**

```bash
git -C fcg-orchestration add k8s/kong/
git -C fcg-orchestration commit -m "feat: adiciona Kong em k8s"
```

---

### Task 11: Scaffold do repo `fcg-notifications-function`

**Files:**
- Create (novo repo): `fcg-notifications-function/Notifications.Function.csproj`
- Create: `fcg-notifications-function/Program.cs`
- Create: `fcg-notifications-function/host.json`
- Create: `fcg-notifications-function/local.settings.json.example`
- Create: `fcg-notifications-function/.gitignore`
- Create: `fcg-notifications-function/Messaging/MassTransitEnvelope.cs`
- Create: `fcg-notifications-function/Functions/WelcomeEmailFunction.cs`
- Create: `fcg-notifications-function/Functions/PurchaseConfirmationFunction.cs`
- Modify: `fcg-orchestration/docker-compose.yml` (adicionar `azurite`)

**Interfaces:**
- Consumes: filas RabbitMQ `welcome-email` e `purchase-confirmation` — mesmos nomes gerados pelo `SetKebabCaseEndpointNameFormatter()` do MassTransit em `fcg-notifications-api` (confirmado em `fcg-notifications-api/building-blocks/Fcg.Messaging/MassTransitExtensions.cs`), então UsersAPI/CatalogAPI **não precisam mudar** — continuam publicando do mesmo jeito.

- [ ] **Step 1: Criar o repositório no GitHub**

```bash
cd "C:\Users\Yuri\source\repos\YuriLucka"
gh repo create YuriLucka/fcg-notifications-function --public --clone
```

- [ ] **Step 2: Azurite no docker-compose (storage exigido pelo host de Functions)**

Em `fcg-orchestration/docker-compose.yml`, adicionar:

```yaml
  azurite:
    image: mcr.microsoft.com/azure-storage/azurite:latest
    ports: ["10000:10000", "10001:10001", "10002:10002"]
```

- [ ] **Step 3: Projeto da Function (isolated worker)**

Criar `fcg-notifications-function/Notifications.Function.csproj`:

```xml
<Project Sdk="Microsoft.NET.Sdk">

  <PropertyGroup>
    <TargetFramework>net8.0</TargetFramework>
    <AzureFunctionsVersion>v4</AzureFunctionsVersion>
    <OutputType>Exe</OutputType>
    <ImplicitUsings>enable</ImplicitUsings>
    <Nullable>enable</Nullable>
    <RootNamespace>Notifications.Function</RootNamespace>
  </PropertyGroup>

  <ItemGroup>
    <PackageReference Include="Microsoft.Azure.Functions.Worker" Version="1.23.0" />
    <PackageReference Include="Microsoft.Azure.Functions.Worker.Sdk" Version="1.17.4" OutputItemType="Analyzer" />
    <PackageReference Include="Microsoft.Azure.Functions.Worker.Extensions.Rabbitmq" Version="1.0.1" />
  </ItemGroup>

  <ItemGroup>
    <None Update="host.json">
      <CopyToOutputDirectory>PreserveNewest</CopyToOutputDirectory>
    </None>
    <None Update="local.settings.json">
      <CopyToOutputDirectory>PreserveNewest</CopyToOutputDirectory>
      <CopyToPublishDirectory>Never</CopyToPublishDirectory>
    </None>
  </ItemGroup>

</Project>
```

Criar `fcg-notifications-function/Program.cs`:

```csharp
using Microsoft.Extensions.Hosting;

var host = new HostBuilder()
    .ConfigureFunctionsWorkerDefaults()
    .Build();

host.Run();
```

Criar `fcg-notifications-function/host.json`:

```json
{
  "version": "2.0"
}
```

Criar `fcg-notifications-function/local.settings.json.example` (versionado — copiar para `local.settings.json` localmente, que fica no `.gitignore`):

```json
{
  "IsEncrypted": false,
  "Values": {
    "AzureWebJobsStorage": "UseDevelopmentStorage=true",
    "FUNCTIONS_WORKER_RUNTIME": "dotnet-isolated",
    "RabbitMQConnection": "amqp://guest:guest@localhost:5672"
  }
}
```

Criar `fcg-notifications-function/.gitignore`:

```
bin/
obj/
local.settings.json
```

- [ ] **Step 4: Helper de parsing do envelope MassTransit**

Criar `fcg-notifications-function/Messaging/MassTransitEnvelope.cs`:

```csharp
using System.Text.Json;

namespace Notifications.Function.Messaging;

public record UserCreatedEvent(string Name, string Email);
public record PaymentProcessedEvent(Guid GameId, Guid UserId, bool Approved);

public static class MassTransitEnvelope
{
    public static UserCreatedEvent ParseUserCreated(string rawMessage)
    {
        using var doc = JsonDocument.Parse(rawMessage);
        var msg = doc.RootElement.GetProperty("message");
        return new UserCreatedEvent(
            msg.GetProperty("name").GetString()!,
            msg.GetProperty("email").GetString()!);
    }

    public static PaymentProcessedEvent ParsePaymentProcessed(string rawMessage)
    {
        using var doc = JsonDocument.Parse(rawMessage);
        var msg = doc.RootElement.GetProperty("message");
        var statusProp = msg.GetProperty("status");

        var approved = statusProp.ValueKind == JsonValueKind.String
            ? string.Equals(statusProp.GetString(), "Approved", StringComparison.OrdinalIgnoreCase)
            : statusProp.GetInt32() == 0;

        return new PaymentProcessedEvent(
            msg.GetProperty("gameId").GetGuid(),
            msg.GetProperty("userId").GetGuid(),
            approved);
    }
}
```

> **Nota importante:** o parsing acima assume que o MassTransit serializa o envelope com `message` em camelCase e `status` como string (`"Approved"`/`"Rejected"`) — é o padrão do `SystemTextJsonMessageSerializer` do MassTransit 8. **Antes de considerar isso pronto**, publique um evento real (registre um usuário via `POST /api/User` com o compose rodando), abra `http://localhost:15672` (RabbitMQ Management, guest/guest), vá em `Queues → welcome-email → Get messages`, e confirme que o JSON bate com o que o parser espera. Se os nomes de campo vierem diferentes, ajuste os `GetProperty(...)` acima.

- [ ] **Step 5: As duas functions**

Criar `fcg-notifications-function/Functions/WelcomeEmailFunction.cs`:

```csharp
using Microsoft.Azure.Functions.Worker;
using Microsoft.Extensions.Logging;
using Notifications.Function.Messaging;

namespace Notifications.Function.Functions;

public class WelcomeEmailFunction
{
    private readonly ILogger<WelcomeEmailFunction> _log;

    public WelcomeEmailFunction(ILogger<WelcomeEmailFunction> log) => _log = log;

    [Function("WelcomeEmailFunction")]
    public void Run(
        [RabbitMQTrigger("welcome-email", ConnectionStringSetting = "RabbitMQConnection")] string message)
    {
        var evt = MassTransitEnvelope.ParseUserCreated(message);
        _log.LogInformation("[EMAIL] Boas-vindas enviado para {Email} ({Name})", evt.Email, evt.Name);
    }
}
```

Criar `fcg-notifications-function/Functions/PurchaseConfirmationFunction.cs`:

```csharp
using Microsoft.Azure.Functions.Worker;
using Microsoft.Extensions.Logging;
using Notifications.Function.Messaging;

namespace Notifications.Function.Functions;

public class PurchaseConfirmationFunction
{
    private readonly ILogger<PurchaseConfirmationFunction> _log;

    public PurchaseConfirmationFunction(ILogger<PurchaseConfirmationFunction> log) => _log = log;

    [Function("PurchaseConfirmationFunction")]
    public void Run(
        [RabbitMQTrigger("purchase-confirmation", ConnectionStringSetting = "RabbitMQConnection")] string message)
    {
        var evt = MassTransitEnvelope.ParsePaymentProcessed(message);
        if (!evt.Approved) return;

        _log.LogInformation("[EMAIL] Confirmacao de compra: jogo {GameId} para usuario {UserId}",
            evt.GameId, evt.UserId);
    }
}
```

- [ ] **Step 6: Rodar local e verificar o trigger disparando**

```bash
cd fcg-orchestration
docker compose up -d rabbitmq users-db catalog-db users-api catalog-api azurite

cd ../fcg-notifications-function
cp local.settings.json.example local.settings.json
func start
```

Em outro terminal, criar um usuário via UsersAPI (dispara `UserCreatedEvent`):

```bash
curl -s -X POST http://localhost:5001/api/User -H "Content-Type: application/json" \
  -d '{"name":"Teste","email":"teste@fcg.com","password":"Senha123!"}'
```

Esperado: no terminal do `func start`, aparece um log `Executing 'Functions.WelcomeEmailFunction'` seguido de `[EMAIL] Boas-vindas enviado para teste@fcg.com (Teste)`.

- [ ] **Step 7: Commit**

```bash
cd fcg-notifications-function
git add .
git commit -m "feat: Azure Function isolated worker consumindo RabbitMQ (substitui NotificationsAPI)"
git push
```

---

### Task 12: Testes unitários da Function + IaC Bicep

**Files:**
- Create: `fcg-notifications-function/Notifications.Function.Tests/Notifications.Function.Tests.csproj`
- Create: `fcg-notifications-function/Notifications.Function.Tests/MassTransitEnvelopeTests.cs`
- Create: `fcg-notifications-function/infra/main.bicep`
- Create: `fcg-notifications-function/README.md`

- [ ] **Step 1: Teste do parser (falha)**

Criar `fcg-notifications-function/Notifications.Function.Tests/Notifications.Function.Tests.csproj`:

```xml
<Project Sdk="Microsoft.NET.Sdk">

  <PropertyGroup>
    <TargetFramework>net8.0</TargetFramework>
    <ImplicitUsings>enable</ImplicitUsings>
    <Nullable>enable</Nullable>
    <IsPackable>false</IsPackable>
    <IsTestProject>true</IsTestProject>
  </PropertyGroup>

  <ItemGroup>
    <PackageReference Include="coverlet.collector" Version="6.0.0" />
    <PackageReference Include="Microsoft.NET.Test.Sdk" Version="17.8.0" />
    <PackageReference Include="xunit" Version="2.9.3" />
    <PackageReference Include="xunit.runner.visualstudio" Version="2.5.3" />
  </ItemGroup>

  <ItemGroup>
    <ProjectReference Include="..\Notifications.Function.csproj" />
  </ItemGroup>

  <ItemGroup>
    <Using Include="Xunit" />
  </ItemGroup>

</Project>
```

Criar `fcg-notifications-function/Notifications.Function.Tests/MassTransitEnvelopeTests.cs`:

```csharp
using Notifications.Function.Messaging;

namespace Notifications.Function.Tests;

public class MassTransitEnvelopeTests
{
    [Fact]
    public void ParseUserCreated_DeveExtrairNomeEEmail()
    {
        var raw = """
        { "message": { "userId": "11111111-1111-1111-1111-111111111111", "name": "Ana", "email": "ana@fcg.com" } }
        """;

        var result = MassTransitEnvelope.ParseUserCreated(raw);

        Assert.Equal("Ana", result.Name);
        Assert.Equal("ana@fcg.com", result.Email);
    }

    [Fact]
    public void ParsePaymentProcessed_DeveMarcarAprovado_QuandoStatusApproved()
    {
        var gameId = Guid.NewGuid();
        var userId = Guid.NewGuid();
        var raw = $$"""
        { "message": { "orderId": "22222222-2222-2222-2222-222222222222", "userId": "{{userId}}", "gameId": "{{gameId}}", "status": "Approved" } }
        """;

        var result = MassTransitEnvelope.ParsePaymentProcessed(raw);

        Assert.True(result.Approved);
        Assert.Equal(gameId, result.GameId);
        Assert.Equal(userId, result.UserId);
    }

    [Fact]
    public void ParsePaymentProcessed_DeveMarcarReprovado_QuandoStatusRejected()
    {
        var raw = $$"""
        { "message": { "orderId": "22222222-2222-2222-2222-222222222222", "userId": "{{Guid.NewGuid()}}", "gameId": "{{Guid.NewGuid()}}", "status": "Rejected" } }
        """;

        var result = MassTransitEnvelope.ParsePaymentProcessed(raw);

        Assert.False(result.Approved);
    }
}
```

- [ ] **Step 2: Rodar e confirmar (deve já passar, pois `MassTransitEnvelope` foi implementado na Task 11)**

```bash
cd fcg-notifications-function
dotnet test Notifications.Function.Tests/Notifications.Function.Tests.csproj
```
Esperado: PASS (3 testes). Se falhar, ajustar `MassTransitEnvelope.cs` conforme os nomes de campo — esse é o ponto de checagem previsto no Step 4 da Task 11.

- [ ] **Step 3: IaC Bicep (deliverable, deploy real é opcional)**

Criar `fcg-notifications-function/infra/main.bicep`:

```bicep
param location string = resourceGroup().location
param appName string = 'fcg-notifications-fn'

resource storage 'Microsoft.Storage/storageAccounts@2023-01-01' = {
  name: '${appName}stor'
  location: location
  sku: { name: 'Standard_LRS' }
  kind: 'StorageV2'
}

resource plan 'Microsoft.Web/serverfarms@2023-01-01' = {
  name: '${appName}-plan'
  location: location
  sku: { name: 'Y1', tier: 'Dynamic' }
}

resource functionApp 'Microsoft.Web/sites@2023-01-01' = {
  name: appName
  location: location
  kind: 'functionapp'
  properties: {
    serverFarmId: plan.id
    siteConfig: {
      appSettings: [
        { name: 'FUNCTIONS_WORKER_RUNTIME', value: 'dotnet-isolated' }
        { name: 'FUNCTIONS_EXTENSION_VERSION', value: '~4' }
        {
          name: 'AzureWebJobsStorage'
          value: 'DefaultEndpointsProtocol=https;AccountName=${storage.name};EndpointSuffix=core.windows.net'
        }
        { name: 'RabbitMQConnection', value: '' }
      ]
    }
  }
}
```

> `RabbitMQConnection` fica vazio de propósito — só é preenchido se de fato optarem por publicar (exigiria expor o RabbitMQ do compose/k8s pra internet, fora do escopo do "grátis/local" desta entrega). O Bicep existe pra satisfazer o requisito de "infraestrutura como código", documentado no README abaixo como deploy opcional.

- [ ] **Step 4: README do repo novo**

Criar `fcg-notifications-function/README.md`:

```markdown
# fcg-notifications-function

Substitui o container `notifications-api` (Fase 2) por uma Azure Function isolated-worker
(.NET 8) acionada diretamente pelas filas RabbitMQ `welcome-email` e `purchase-confirmation` —
sem processo rodando 24/7.

## Rodar localmente (grátis, sem conta Azure)

Pré-requisitos: [Azure Functions Core Tools v4](https://learn.microsoft.com/azure/azure-functions/functions-run-local),
`fcg-orchestration` rodando (`docker compose up -d rabbitmq users-db catalog-db users-api catalog-api azurite`).

```bash
cp local.settings.json.example local.settings.json
func start
```

Dispare um evento criando um usuário via UsersAPI (`POST http://localhost:5001/api/User`) ou
completando uma compra via CatalogAPI — os logs da function aparecem no terminal do `func start`.

## Deploy real (opcional)

`infra/main.bicep` provisiona um Function App Consumption Plan no Azure. Não é necessário para
rodar/demonstrar o projeto — a function local já satisfaz o requisito de "acionada diretamente
pela fila". Deploy real exigiria expor o RabbitMQ do `fcg-orchestration` publicamente.

```bash
az deployment group create --resource-group <rg> --template-file infra/main.bicep
```
```

- [ ] **Step 5: Commit**

```bash
cd fcg-notifications-function
git add .
git commit -m "test: cobre parsing do envelope MassTransit; adiciona IaC Bicep e README"
git push
```

---

### Task 13: Loki + logs centralizados da Function

O enunciado pede, fora do bloco específico da Opção A/B, que o vídeo "demonstre a Função Serverless sendo acionada e exiba **seus logs na plataforma centralizada**". A Opção A (Prometheus/Grafana) só cobre métricas — sem essa task, o único lugar pra ver log da function seria o terminal do `func start`, que não é uma "plataforma centralizada". Loki resolve isso ficando na mesma stack (Grafana já vai estar rodando, só ganha mais uma fonte de dado).

**Files:**
- Modify: `fcg-orchestration/docker-compose.yml`
- Create: `fcg-orchestration/k8s/loki.yaml`
- Modify: `fcg-orchestration/grafana/provisioning/datasources/datasource.yml`
- Modify: `fcg-orchestration/k8s/grafana/configmap.yaml`
- Modify: `fcg-notifications-function/Notifications.Function.csproj`
- Modify: `fcg-notifications-function/Program.cs`

**Interfaces:**
- Consumes: Grafana já provisionado (Task 8).
- Produces: logs da function pesquisáveis no Grafana Explore com o label `app="fcg-notifications-function"` — é o que a Task 16 (ensaio) e o vídeo vão mostrar.

- [ ] **Step 1: Serviço Loki no docker-compose**

Em `fcg-orchestration/docker-compose.yml`, adicionar:

```yaml
  loki:
    image: grafana/loki:2.9.8
    ports: ["3100:3100"]
    command: -config.file=/etc/loki/local-config.yaml
```

- [ ] **Step 2: Manifest k8s do Loki**

Criar `fcg-orchestration/k8s/loki.yaml`:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: loki
  namespace: fcg
spec:
  replicas: 1
  selector:
    matchLabels:
      app: loki
  template:
    metadata:
      labels:
        app: loki
    spec:
      containers:
        - name: loki
          image: grafana/loki:2.9.8
          imagePullPolicy: IfNotPresent
          args: ["-config.file=/etc/loki/local-config.yaml"]
          ports:
            - containerPort: 3100
---
apiVersion: v1
kind: Service
metadata:
  name: loki
  namespace: fcg
spec:
  selector:
    app: loki
  ports:
    - port: 3100
      targetPort: 3100
```

> A function em si continua rodando local (Task 11), fora do k8s — este manifest existe só pra manter o Loki disponível também quando o resto da stack sobe via k8s em vez de compose. Se for demonstrar tudo via k8s, use `kubectl port-forward svc/loki 3100:3100` pra function local enxergar.

- [ ] **Step 3: Datasource Loki no Grafana**

Em `fcg-orchestration/grafana/provisioning/datasources/datasource.yml`, adicionar uma segunda entrada (arquivo vira uma lista com 2 datasources):

```yaml
apiVersion: 1
datasources:
  - name: Prometheus
    type: prometheus
    access: proxy
    url: http://prometheus:9090
    isDefault: true
  - name: Loki
    type: loki
    access: proxy
    url: http://loki:3100
```

Espelhar a mesma mudança em `fcg-orchestration/k8s/grafana/configmap.yaml`, na chave `datasource.yml` do ConfigMap `grafana-provisioning` (mesmo conteúdo YAML acima).

- [ ] **Step 4: Pacotes Serilog na Function**

Em `fcg-notifications-function/Notifications.Function.csproj`, adicionar ao `<ItemGroup>` de pacotes:

```xml
    <PackageReference Include="Serilog.Extensions.Hosting" Version="8.0.0" />
    <PackageReference Include="Serilog.Sinks.Console" Version="6.0.0" />
    <PackageReference Include="Serilog.Sinks.Grafana.Loki" Version="8.3.0" />
```

- [ ] **Step 5: Configurar Serilog + sink Loki no Program.cs**

Reescrever `fcg-notifications-function/Program.cs`:

```csharp
using Microsoft.Extensions.Hosting;
using Serilog;
using Serilog.Sinks.Grafana.Loki;

Log.Logger = new LoggerConfiguration()
    .Enrich.WithProperty("app", "fcg-notifications-function")
    .WriteTo.Console()
    .WriteTo.GrafanaLoki(
        "http://localhost:3100",
        labels: new[] { new LokiLabel { Key = "app", Value = "fcg-notifications-function" } })
    .CreateLogger();

var host = new HostBuilder()
    .ConfigureFunctionsWorkerDefaults()
    .UseSerilog()
    .Build();

host.Run();
```

Nenhuma mudança necessária em `WelcomeEmailFunction.cs`/`PurchaseConfirmationFunction.cs` — eles já usam `ILogger<T>` injetado, que passa a fluir pelo Serilog/Loki automaticamente assim que `UseSerilog()` está registrado no host.

- [ ] **Step 6: Verificar**

```bash
cd fcg-orchestration
docker compose up -d loki grafana
cd ../fcg-notifications-function
func start
```

Em outro terminal, disparar um evento (registrar usuário via gateway, igual Task 16 Step 3), depois abrir `http://localhost:3000` → **Explore** → datasource **Loki** → query `{app="fcg-notifications-function"}`. Esperado: a linha `[EMAIL] Boas-vindas enviado para ...` aparece no Grafana, não só no terminal.

- [ ] **Step 7: Commit**

```bash
git -C fcg-orchestration add docker-compose.yml k8s/loki.yaml grafana/provisioning/datasources/datasource.yml k8s/grafana/configmap.yaml
git -C fcg-orchestration commit -m "feat: adiciona Loki para centralizar logs da function no Grafana"
cd fcg-notifications-function
git add Notifications.Function.csproj Program.cs
git commit -m "feat: envia logs para Loki via Serilog"
git push
```

---

### Task 14: Decomissionar o container `notifications-api`

**Files:**
- Modify: `fcg-orchestration/docker-compose.yml`
- Delete: `fcg-orchestration/k8s/notifications-api/` (pasta inteira)

- [ ] **Step 1: Remover do docker-compose**

Em `fcg-orchestration/docker-compose.yml`, remover o bloco inteiro do serviço `notifications-api:` (linhas 84–92 na versão atual).

- [ ] **Step 2: Remover manifests k8s**

```bash
git -C fcg-orchestration rm -r k8s/notifications-api
```

- [ ] **Step 3: Verificar que o resto sobe sem essa peça**

```bash
cd fcg-orchestration
docker compose up -d --build
docker compose ps
```
Esperado: nenhum serviço `notifications-api` na lista; todos os outros `healthy`/`running`.

- [ ] **Step 4: Commit**

```bash
git -C fcg-orchestration add docker-compose.yml
git -C fcg-orchestration commit -m "chore: remove container notifications-api (substituido por fcg-notifications-function)"
```

> O repositório `fcg-notifications-api` em si **não é apagado** — fica no GitHub como histórico da Fase 2. Só para de ser orquestrado.

---

### Task 15: README central da orchestration

**Files:**
- Modify: `fcg-orchestration/README.md` (reescrita quase completa)

- [ ] **Step 1: Atualizar diagrama de arquitetura, tabela de portas, seção de stack e links**

Reescrever `fcg-orchestration/README.md` cobrindo, nesta ordem:

1. Visão geral com o novo diagrama (Kong na frente de users-api/catalog-api; Prometheus/Grafana observando os dois; MongoDB + Redis pendurados no catalog-api; `fcg-notifications-function` fora do compose, rodando via `func start`, consumindo as mesmas filas).
2. Seção **"Stack de Observabilidade escolhida"**: Opção A — Prometheus + Grafana, self-hosted, deploy via manifests k8s em `k8s/prometheus/` e `k8s/grafana/`. Justificar a escolha (grátis, já roda em k8s, é a opção que o próprio enunciado recomenda pra observabilidade de aplicação).
3. Seção **"Persistência Poliglota"**: MongoDB guarda avaliações de jogos (`fcg-catalog-api`, coleção `reviews`) — cenário de dado não-relacional/flexível. Redis cacheia a listagem de jogos (`GET /api/Game`) por 30s — reduz round-trip ao SQL Server em toda consulta popular.
4. Seção **"API Gateway"**: Kong DB-less, config versionada em `kong/kong.yml` (compose) e `k8s/kong/configmap.yaml` (k8s). Tabela de rotas: `/api/Auth` (público), `/api/User`, `/api/Game`, `/api/purchases` (minúsculo/plural, atenção), `/api/Review` (JWT obrigatório).
5. Seção **"Serverless"**: link pro repo `fcg-notifications-function`, explicação de que substitui o container antigo, como rodar (`func start`) junto do resto.
6. Atualizar "Como rodar com Docker Compose" incluindo `kong`, `prometheus`, `grafana`, `mongo`, `redis`, `azurite` na tabela de URLs (Kong :8000, Prometheus :9090, Grafana :3000 admin/admin, Mongo :27017, Redis :6379). **Remover as linhas de `users-api (Swagger)` e `catalog-api (Swagger)` como URLs acessíveis diretamente** — desde a Task 9 essas portas não são mais publicadas no host; todo acesso externo passa por `http://localhost:8000/api/...` via Kong. Deixar isso explícito no README pra quem for gravar o vídeo não tentar acessar `:5001`/`:5002` direto.
7. Atualizar "Como fazer deploy no Kubernetes" — build/load de imagens continua igual (4 serviços, sem notifications-api), `kubectl apply -R -f k8s/` já pega Kong/Prometheus/Grafana/Mongo/Redis automaticamente por estarem em `k8s/`.
8. Atualizar "Pré-requisito: clonar os repositórios" — trocar "5 repositórios" por "4 repositórios + `fcg-notifications-function` (roda à parte, local)".
9. Atualizar seção "Links" com a URL do `fcg-notifications-function` e remover a de `fcg-notifications-api` (ou marcar como "descontinuado, ver fcg-notifications-function").

- [ ] **Step 2: Revisão manual**

Ler o README de ponta a ponta como se fosse alguém do zero seguindo o guia — confirmar que dá pra clonar tudo, subir com `docker compose up --build` e chegar no dashboard do Grafana + gateway funcionando sem nenhum passo faltando.

- [ ] **Step 3: Commit**

```bash
git -C fcg-orchestration add README.md
git -C fcg-orchestration commit -m "docs: atualiza README com gateway, observabilidade, NoSQL, cache e serverless"
```

---

### Task 16: Ensaio geral + tráfego sintético (preparação do vídeo)

**Files:** nenhum — task operacional, sem alteração de código. Existe porque a entrega exige um vídeo mostrando "métricas em tempo real" e "a arquitetura em funcionamento", e isso só é verdade se alguém já tiver rodado a stack inteira junta pelo menos uma vez antes de gravar. Todas as tasks anteriores validam cada peça isolada; esta valida o conjunto.

- [ ] **Step 1: Subir a stack inteira do zero**

```bash
cd fcg-orchestration
docker compose down -v
docker compose up -d --build
sleep 30
docker compose ps
```
Esperado: todos os serviços `running`/`healthy` — `rabbitmq`, `users-db`, `catalog-db`, `mongo`, `redis`, `azurite`, `users-api`, `catalog-api`, `payments-api`, `kong`, `prometheus`, `grafana`. Nenhum em `restarting` ou `exited`.

- [ ] **Step 2: Subir a Function em paralelo**

```bash
cd fcg-notifications-function
func start
```
Deixar rodando num terminal separado — é onde os logs da function vão aparecer durante o ensaio e a gravação.

- [ ] **Step 3: Rodar o fluxo completo uma vez, via Gateway, anotando o que aparece em cada ferramenta**

```bash
# 1. Login como admin
TOKEN_ADMIN=$(curl -s -X POST http://localhost:8000/api/Auth/login -H "Content-Type: application/json" \
  -d '{"email":"admin@fcg.com","password":"Admin@123"}' | jq -r .accessToken)

# 2. Criar um jogo (dispara instrumentação Prometheus no catalog-api)
curl -s -X POST http://localhost:8000/api/Game -H "Authorization: Bearer $TOKEN_ADMIN" \
  -H "Content-Type: application/json" -d '{"title":"Elden Ring","price":249.90,"description":"Souls-like"}'

# 3. Registrar um usuário novo (dispara UserCreatedEvent -> WelcomeEmailFunction)
curl -s -X POST http://localhost:8000/api/User -H "Content-Type: application/json" \
  -d '{"name":"Demo","email":"demo@fcg.com","password":"Demo@123"}'

# 4. Login como o usuário novo
TOKEN_DEMO=$(curl -s -X POST http://localhost:8000/api/Auth/login -H "Content-Type: application/json" \
  -d '{"email":"demo@fcg.com","password":"Demo@123"}' | jq -r .accessToken)

# 5. Listar jogos (primeira chamada = cache miss, popula Redis)
curl -s http://localhost:8000/api/Game -H "Authorization: Bearer $TOKEN_DEMO"

# 6. Pegar o Id do Elden Ring no passo 5 e comprar (dispara OrderPlaced -> PaymentProcessed -> PurchaseConfirmationFunction)
GAME_ID="<colar aqui o Id retornado no passo 5>"
curl -s -X POST http://localhost:8000/api/purchases -H "Authorization: Bearer $TOKEN_DEMO" \
  -H "Content-Type: application/json" -d "{\"gameId\":\"$GAME_ID\"}"

# 7. Avaliar o jogo (grava no MongoDB)
curl -s -X POST http://localhost:8000/api/Review -H "Authorization: Bearer $TOKEN_DEMO" \
  -H "Content-Type: application/json" -d "{\"gameId\":\"$GAME_ID\",\"rating\":5,\"comment\":\"Obra-prima\"}"

# 8. Confirmar a avaliação salva
curl -s "http://localhost:8000/api/Review/game/$GAME_ID" -H "Authorization: Bearer $TOKEN_DEMO"
```

Esperado, conferindo em paralelo:
- Terminal do `func start`: logs `[EMAIL] Boas-vindas enviado para demo@fcg.com` (passo 3) e `[EMAIL] Confirmacao de compra` (passo 6).
- Grafana → Explore → datasource Loki → `{app="fcg-notifications-function"}`: as mesmas duas linhas aparecem lá (Task 13) — **esse é o que vai pro vídeo**, não o terminal.
- `docker compose exec mongo mongosh fcg_catalog --eval "db.reviews.find().pretty()"`: mostra a avaliação do passo 7.
- Passo 8 retorna a lista com 1 item.

- [ ] **Step 4: Gerar tráfego sintético pra o Grafana não aparecer zerado na gravação**

Os painéis são baseados em `rate(...)` — com zero tráfego nos últimos minutos, as linhas ficam achatadas em zero e o vídeo não mostra nada de interessante. Rodar isso um pouco antes (ou durante) a gravação, em terminal separado:

```bash
while true; do
  curl -s -o /dev/null http://localhost:8000/api/Game -H "Authorization: Bearer $TOKEN_DEMO"
  curl -s -o /dev/null http://localhost:8000/api/Game/00000000-0000-0000-0000-000000000000 -H "Authorization: Bearer $TOKEN_DEMO"
  sleep 0.5
done
```

(a segunda chamada usa um Id inexistente de propósito — gera resposta de erro, então o painel "Taxa de erro" também mostra dado real, não fica zerado).

> **Correção aplicada durante a execução da Task 8** (achado real do implementador, verificado contra as APIs rodando): um Id inexistente retorna **400**, não 404. As duas APIs tratam "registro não encontrado" como `DomainException`, que o `ErrorHandlingMiddleware` converte pra `400 Bad Request`; 404 só acontece por rota não casada (ex: um `{id:guid}` recebendo algo que não é GUID). Além disso, essas APIs **não geram 5xx** em operação normal — só via exceção não tratada. Por isso o painel de taxa de erro foi alterado de `code=~"5.."` para `code=~"[45].."` ("Taxa de erro (4xx + 5xx)"): do jeito original ele ficaria estruturalmente vazio na gravação. Com o filtro ampliado, o `401` (sem token) e o `400` (não encontrado) do loop acima já alimentam o painel com dado real, sem precisar forjar nada na frente da câmera.

- [ ] **Step 5: Confirmar Grafana em tempo real**

Abrir `http://localhost:3000`, dashboard "FCG - Overview" (pasta FCG), com o loop do Step 4 rodando. Esperado: os 4 painéis de série temporal mostram linhas se movendo (taxa de requisição > 0, taxa de erro > 0 pelas respostas `400`/`401`, latência com valor, breakdown por status code com pelo menos `200` e `400`), e o painel "Total de requisições" com número > 0 subindo.

- [ ] **Step 6: Parar o loop de tráfego antes de gravar de verdade (opcional)**

Deixar rodando é o que dá o efeito "tempo real" no vídeo — mas se quiser controlar melhor o timing da narração, `Ctrl+C` no loop e disparar chamadas manuais pontuais enquanto fala, já que os painéis atualizam a cada 5s (`refresh: 5s` no dashboard).

- [ ] **Step 7: Registrar quaisquer ajustes encontrados**

Se algum passo acima falhar (porta errada, variável de ambiente faltando, serviço não subiu), corrigir no repositório correspondente e re-rodar este Task 16 do Step 1 antes de considerar pronto pra gravar — não commitar o Task 15 (README) como "guia central" sem ele ter sido de fato seguido do zero uma vez.

---

## Self-Review (spec coverage)

| Requisito do enunciado | Task(s) |
|---|---|
| API Gateway único, valida JWT, roteia users/catalog | 9, 10 |
| Gateway "recebe todas as requisições externas" (bloqueio de acesso direto) | 9 (Step 2, Step 7) |
| Gateway config versionada na orchestration | 9, 10 |
| Serverless: NotificationsAPI → Function, trigger direto na fila | 11, 12 |
| Serverless: repo próprio + IaC | 11, 12 |
| Observabilidade Opção A: métricas em UsersAPI/CatalogAPI | 6 |
| Dashboard Grafana: latência, contagem por status, taxa de erro | 7, 8 |
| Deploy da stack de observabilidade via k8s | 7, 8 |
| NoSQL obrigatório (driver oficial) | 1, 2, 3 |
| Cache distribuído obrigatório | 4, 5 |
| README da orchestration como guia central | 15 |
| Container antigo desligado (não roda mais 24/7) | 14 |
| Logs da Function em plataforma centralizada (não só terminal) | 13 |
| Stack inteira validada junta (não só peça por peça) + tráfego real pro Grafana no vídeo | 16 |

Nenhum gap encontrado nos requisitos técnicos. Vídeo, relatório PDF/TXT e link de documentação (Miro) são entregáveis manuais fora do escopo de código — não geram task de implementação, mas cada item deles está mapeado no checklist abaixo, item por item do enunciado, pra nada ficar esquecido na hora de montar a entrega.

---

## Checklist de Entrega (o que sai da execução do plano vs. o que é manual)

Auditoria linha a linha contra a seção "Entregáveis da Fase 3" do enunciado.

### Vídeo (até 20 min) — roteiro pronto, cada bullet aponta pro step do plano que o comprova

| Bullet do enunciado | Onde já foi validado | Falta fazer |
|---|---|---|
| "Realizar requisições via Gateway, mostrando o roteamento e a segurança" | Task 9 Steps 4–7 (login público, 401 sem token, 200 com token, porta antiga bloqueada) | Gravar a tela repetindo esses `curl`/Postman/Insomnia na hora |
| "Demonstrar a Função Serverless sendo acionada e exibir seus logs **na plataforma centralizada**" | Task 13 (Loki + Grafana Explore) + Task 16 Step 3 (fluxo dispara o evento, log aparece no Grafana, não só no terminal) | Gravar a aba Explore do Grafana filtrada por `{app="fcg-notifications-function"}` no momento em que o evento dispara |
| "Apresentar o dashboard do Grafana com métricas em tempo real" (Opção A) | Task 16 Steps 4–5 (tráfego sintético fazendo os painéis se moverem) | Gravar com o loop de tráfego rodando, senão os gráficos ficam parados |
| "Explicar como o NoSQL foi integrado à arquitetura" | Task 2/3 (Review/MongoDB) + Task 16 Step 3 (avaliação salva, conferida via `mongosh`) | Narração — explicar que avaliações de jogos vão pro Mongo, não pro SQL Server |

Isso é só a gravação em si — decisão de quem aparece, roteiro de fala, edição — que fica de fora, é manual por natureza. **Lembrete de tempo:** o vídeo tem limite de 20 minutos — os 4 bullets acima cabem tranquilo em ~10-12min narrando direto; não é preciso repetir cada `curl` do Task 16/9, um exemplo de cada já prova o ponto.

**Recomendação baseada no padrão de correção real:** o feedback do professor na Fase 2 (nota 90, texto: *"Evidenciou k8s usando o kind mostrando todo deployment dentro do cluster"*) mostra que ele valoriza especificamente ver o `kubectl get pods` rodando, não só o `docker compose up`. O enunciado da Fase 3 não exige isso explicitamente no vídeo, mas como os manifestos do Kong/Prometheus/Grafana/Mongo/Redis (Tasks 1,4,7,8,10) são parte do entregável de código, vale a pena incluir 30-60s extra no vídeo fazendo `kubectl apply -R -f k8s/` e `kubectl get pods -n fcg` mostrando tudo `Running` — reforça exatamente o que já rendeu nota alta antes, com pouco custo adicional de gravação.

### Códigos-fonte nos repositórios

| Bullet do enunciado | Task | Status após execução do plano |
|---|---|---|
| Repositórios dos microsserviços com instrumentação de observabilidade | 6 | UsersAPI + CatalogAPI expõem `/metrics` |
| Link para o novo repositório da Função Serverless | 11 | `fcg-notifications-function` criado público no GitHub |
| Repositório de orquestração com manifestos do Gateway e da stack de monitoramento | 9, 10, 7, 8 | `k8s/kong/`, `k8s/prometheus/`, `k8s/grafana/` |
| Código com novos drivers de NoSQL e Cache | 2, 3, 5 | `MongoDB.Driver`, `Microsoft.Extensions.Caching.StackExchangeRedis` |
| README da orchestration como guia central | 15 | Reescrito cobrindo toda a stack nova |

Tudo isso é gerado pela execução das Tasks 1–15 — não sobra nada manual aqui além de dar `git push` nos 5 repositórios (4 existentes + o novo) no final.

### Relatório de entrega (PDF ou TXT) — 100% manual, plano não gera isso

Nenhuma task cobre isto porque depende de dados que só você tem. Mas dá pra parar de adivinhar o formato: baixei os relatórios que vocês **já entregaram e tiveram nota 90/100** nas Fases 1 e 2 (Moodle FIAP, atividade avaliada), pra usar de gabarito em vez de inventar estrutura nova.

**Precedente real (`relatorio_entrega_grupo6.txt`, Fase 2, nota 90, avaliado 20/07/2026):**

```
TECH CHALLENGE - FASE 2
Relatório de Entrega

Nome do grupo: Grupo 6

Participantes e usernames no Discord:
- Carlos Eduardo Menegassi (Discord: CarlosEM_ - RM371683)
- Pedro Henrique Ribeiro Custódio (Discord: Pedro Custodio RM373420)
- Yuri Lucka Carriel Rodrigues (Discord: Yuri Lucka - RM371938)
- Rafael Moura Gagliard (Discord: Rafael Gagliard - RM371921)

Link da documentação:
- https://github.com/YuriLucka/fcg-orchestration (README principal com instruções de execução Docker/Kubernetes)

Link do(s) repositório(s):
- Orquestração: https://github.com/YuriLucka/fcg-orchestration
- Usuários (UsersAPI): https://github.com/YuriLucka/fcg-users-api
- Catálogo (CatalogAPI): https://github.com/YuriLucka/fcg-catalog-api
- Pagamentos (PaymentsAPI): https://github.com/YuriLucka/fcg-payments-api
- Notificações (NotificationsAPI): https://github.com/YuriLucka/fcg-notifications-api

Link do vídeo:
- https://youtu.be/faspCuzKZmU?si=l2MGy25ttus6-fG_
```

**Achado que muda o que eu tinha escrito antes:** "link da documentação" nesse precedente **não é o Miro** — é o README do `fcg-orchestration` (que é justamente o guia central que a Task 15 deste plano reescreve). O Miro (Event Storming) nunca apareceu nos dois relatórios já avaliados. Pra Fase 3, mais seguro seguir o padrão que já pontuou 90/100 duas vezes: apontar pro README do orchestration, não pro Miro. Também vale notar: **Fase 1 usava grupo "Grupo 115"**, Fase 2 usava **"Grupo 6"** — o número do grupo muda a cada fase (é atribuído pelo Moodle, não escolhido por vocês); confirme o número atual da Fase 3 antes de preencher, não reutilize "Grupo 6" por hábito.

Checklist adaptado pra Fase 3, no mesmo formato:

- [ ] Nome do grupo (confirmar número da Fase 3 no Moodle — não necessariamente "Grupo 6")
- [ ] Participantes + Discord + RM (mesmo formato do precedente: `Nome (Discord: usuario - RMxxxxxx)`)
- [ ] Link da documentação → `https://github.com/YuriLucka/fcg-orchestration` (README central, igual precedente — Miro é opcional/extra, não obrigatório)
- [ ] Link do(s) repositório(s) — os 5 de sempre + `fcg-notifications-function` (6 links no total, um a mais que o precedente por causa do repo novo da function)
- [ ] Link do vídeo (YouTube ou outro)
- [ ] Postar o arquivo **na data da entrega** (o enunciado marca isso como requisito, não só "anexar depois")
