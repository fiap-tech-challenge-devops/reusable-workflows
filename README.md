# reusable-workflows

CI/CD compartilhado do **ToggleMaster**: workflows reutilizáveis chamados pelas esteiras dos cinco microsserviços e do repositório de infraestrutura, mais os composite actions que essas esteiras usam por dentro.

Os cinco serviços executam o mesmo pipeline — build, lint, análise de segurança, imagem e promoção — mudando apenas a linguagem. Manter isso em cinco repositórios significaria corrigir o mesmo bug cinco vezes. Aqui a definição vive uma vez; cada serviço tem um arquivo de poucas linhas que a chama.

## Workflow ou action?

As duas formas existem aqui porque resolvem problemas diferentes, e a escolha nem sempre é de gosto:

| | Reusable workflow | Composite action |
|---|---|---|
| Unidade | um ou mais **jobs** | um ou mais **steps** |
| Runner | próprio, isolado do chamador | o **mesmo** do job que o chama |
| Enxerga arquivos do chamador | não | sim |
| Chamado com | `uses:` no nível do job | `uses:` no nível do step |

A regra prática: se a peça precisa de arquivos produzidos por steps vizinhos, **tem** de ser action. Foi o que definiu o [`terraform-plan-summary`](actions/terraform-plan-summary/) — ele lê o plano binário deixado pelo step anterior, e esse arquivo não pode virar artifact porque contém valores sensíveis em texto claro.

Faz parte de um conjunto de quatro repositórios:

| Repositório | Papel |
|---|---|
| [`terraform-aws-modules`](https://github.com/fiap-tech-challenge-devops/terraform-aws-modules) | Biblioteca de módulos Terraform reutilizáveis |
| [`togglemaster-iac`](https://github.com/fiap-tech-challenge-devops/togglemaster-iac) | Provisiona a infraestrutura AWS |
| [`togglemaster-gitops`](https://github.com/fiap-tech-challenge-devops/togglemaster-gitops) | Manifests Helm consumidos pelo Argo CD |
| **`reusable-workflows`** | **Workflows de CI/CD compartilhados (este repo)** |

## Estrutura

```
.github/workflows/
├── terraform-plan.yml   # esteira de plano de IaC (pronta)
├── go-ci.yaml           # CI dos serviços em Go (auth, evaluation)        — previsto
├── python-ci.yaml       # CI dos serviços em Python (flag, targeting, analytics) — previsto
└── cd.yaml              # promoção da imagem no repositório GitOps        — previsto

actions/
└── terraform-plan-summary/   # resumo de plano por IA, sem vazar valores

test/
└── run-local.sh         # testa os actions sem rede e sem AWS
```

## Esteira de IaC

O [`terraform-plan.yml`](.github/workflows/terraform-plan.yml) roda validação de sintaxe, varredura de segurança (Trivy + Checkov) e um plano por stage, com resumo por IA e comentário no PR. Consumido hoje pelo [`togglemaster-iac`](https://github.com/fiap-tech-challenge-devops/togglemaster-iac):

```yaml
jobs:
  iac:
    name: iac
    uses: fiap-tech-challenge-devops/reusable-workflows/.github/workflows/terraform-plan.yml@v1.0.0
    with:
      stages: '[{"stage":"infra","required":true},{"stage":"addons","required":false}]'
      summary-stage: infra
      state-bucket-prefix: togglemaster-iac-tfstate
    secrets:
      aws-oidc-role-arn: ${{ secrets.AWS_OIDC_ROLE_ARN_VITAO }}
      openai-api-key: ${{ secrets.OPENAI_API_KEY }}
```

> **Atenção ao nome dos checks.** Um workflow chamado reporta como `<job do caller> / <job do chamado>` — com o job acima chamado `iac`, os checks viram `iac / Plan (infra)`, `iac / Security` e assim por diante. Se houver ruleset exigindo status checks, ele precisa listar exatamente esses nomes, prefixo incluído. Renomear o job do caller quebra o merge de todos os PRs abertos.

O plano é **descartado** ao fim do run: não vira artifact e não é reaplicado. O arquivo de plano contém todos os valores dos atributos em texto claro, inclusive senhas, e um artifact do Actions é baixável por qualquer pessoa com leitura no repositório. O apply replaneja no próprio run.

## Como um serviço consome

No repositório do microsserviço, `.github/workflows/ci.yaml`:

```yaml
name: CI

on:
  pull_request:
    branches: [main]
  push:
    branches: [main]

jobs:
  ci:
    uses: fiap-tech-challenge-devops/reusable-workflows/.github/workflows/go-ci.yaml@v1
    with:
      service-name: auth-service
    secrets: inherit
```

A referência é uma **tag**, não `main`: um commit aqui não deve alterar o comportamento da esteira de cinco serviços sem uma mudança explícita em cada um.

## Estágios do CI

| Estágio | Go | Python |
|---|---|---|
| **Build & test** | `go build`, `go test` | `pytest` |
| **Lint** | `golangci-lint` | `flake8` |
| **Segurança** | `gitleaks`, `horusec`, `trivy fs` | idem |
| **Imagem** | `docker buildx`, `trivy image`, SBOM, push no ECR | idem |

### O gate de segurança

Vulnerabilidade de severidade **CRITICAL** falha o pipeline imediatamente. Não há aprovação manual que contorne — o build não produz imagem.

As três ferramentas cobrem frentes distintas: `gitleaks` procura segredos versionados, `horusec` faz SAST no código (encapsulando `gosec` e `bandit`, o que permite uma configuração só para as duas linguagens) e `trivy fs` faz SCA nas dependências. Depois do build, `trivy image` escaneia a imagem montada, incluindo os pacotes do sistema-base que a análise de código-fonte não enxerga.

### Tag da imagem

Formato `v<versão>-<commit-curto>`, por exemplo `v1.0.0-a1b2c3d`.

Os repositórios ECR são criados com `IMMUTABLE`: uma tag publicada não pode ser reapontada. Isso garante que a imagem auditada na esteira é exatamente a que roda no cluster.

## O estágio de CD

Após o push da imagem, o workflow de CD atualiza a tag em `apps/<serviço>/values.yaml` no repositório [`togglemaster-gitops`](https://github.com/fiap-tech-challenge-devops/togglemaster-gitops). O Argo CD detecta o commit e sincroniza o cluster.

O CD roda apenas em push para `main`. Pull Requests executam CI completo, incluindo build de imagem e scans, mas não promovem nada.

## Segredos necessários

Configurados na organização e herdados via `secrets: inherit`:

| Segredo | Uso |
|---|---|
| `AWS_ROLE_ARN` | Role assumida via OIDC para login no ECR |
| `GITOPS_TOKEN` | Escrita no repositório GitOps — o `GITHUB_TOKEN` padrão não alcança outro repositório |

## Versionamento

Alterações que mudem entradas ou comportamento recebem uma tag nova. Os serviços migram individualmente atualizando a referência `@vN` — assim uma mudança pode ser validada em um serviço antes de alcançar os cinco.
