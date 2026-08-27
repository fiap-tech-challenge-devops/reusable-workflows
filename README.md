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

## O que existe

| peça | tipo | documentação |
|---|---|---|
| `terraform-plan` | reusable workflow | [docs/terraform-plan/](docs/terraform-plan/) |
| `terraform-apply` | reusable workflow | [docs/terraform-apply/](docs/terraform-apply/) |
| `terraform-destroy` | reusable workflow | [docs/terraform-destroy/](docs/terraform-destroy/) |
| `go-ci` | reusable workflow | [docs/go-ci/](docs/go-ci/) |
| `python-ci` | reusable workflow | [docs/python-ci/](docs/python-ci/) |
| `terraform-plan-summary` | composite action | [actions/terraform-plan-summary/](actions/terraform-plan-summary/) |

Previsto: `cd` — promoção da imagem no repositório GitOps ao fim do CI.

| serviço | esteira |
|---|---|
| `auth-service`, `evaluation-service` | [`go-ci`](docs/go-ci/) |
| `flag-service`, `targeting-service`, `analytics-service` | [`python-ci`](docs/python-ci/) |

O `plan` roda os stages em **matriz** — a ordem é irrelevante e paralelo é vantagem. O `apply` e o `destroy` aplicam **um stage por chamada**, e a ordem fica no caller com `needs:`, porque matriz não encadeia dependência.

## Estrutura

```
.github/workflows/        ← plano; o GitHub não aceita subdiretórios aqui
├── terraform-plan.yml
├── terraform-apply.yml
└── terraform-destroy.yml

actions/                  ← livre; documentação e exemplo colocados
└── terraform-plan-summary/
    ├── action.yml            contrato
    ├── summarize.sh
    ├── README.md             uso e comportamento
    └── example/caller.yml

docs/                     ← documentação dos workflows, que não cabe junto deles
├── terraform-plan/
│   ├── README.md
│   └── example/caller.yml
├── terraform-apply/
├── terraform-destroy/
├── go-ci/
└── python-ci/
```

A assimetria entre `actions/` e `docs/` não é escolha: um reusable workflow é obrigado a morar plano em `.github/workflows/`, então a documentação dele vai para uma pasta paralela. Actions podem morar em qualquer lugar e ficam com tudo junto, como os módulos do [`terraform-aws-modules`](https://github.com/fiap-tech-challenge-devops/terraform-aws-modules).

## Como acrescentar um workflow ou action

Não há ferramenta para rodar nem passo de build. A documentação de referência é o próprio YAML:

1. **Escreva `description:` em todo input e secret.** Junto com `required` e `default`, isso já é a tabela de contrato — e é a única cópia, então não tem como divergir de nada.
2. **Crie a pasta de documentação.** Workflow: `docs/<nome>/`. Action: dentro da própria pasta do action.
3. **Escreva o `README.md`** com o que o YAML não diz: para que serve, o que o repositório consumidor precisa ter, as armadilhas.
4. **Escreva um `example/caller.yml` completo** — arquivo inteiro, copiável, não trecho.
5. **Acrescente a peça na tabela** [O que existe](#o-que-existe).

O que **não** fazer: repetir a lista de inputs em tabela no README. Ela nasce correta e envelhece errada, e não há nada que avise.

### Sobre os exemplos

Cada peça tem um `example/caller.yml` completo, na linha dos módulos Terraform — com uma diferença que vale saber. O `example/` de um módulo é **executável**: `terraform validate` roda lá dentro e verifica o contrato de fato. Um caller de workflow não roda isolado, porque precisa dos secrets, da conta AWS e do evento certo.

Então aqui o exemplo é referência para copiar, e não uma verificação.

## Esteira de IaC

O [`terraform-plan.yml`](.github/workflows/terraform-plan.yml) roda validação de sintaxe, varredura de segurança (Trivy + Checkov) e um plano por stage, com resumo por IA e comentário no PR. Consumido hoje pelo [`togglemaster-iac`](https://github.com/fiap-tech-challenge-devops/togglemaster-iac):

```yaml
jobs:
  iac:
    name: iac
    uses: fiap-tech-challenge-devops/reusable-workflows/.github/workflows/terraform-plan.yml@v1.1.1
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

O SHA completo do commit — `${{ github.sha }}`, quarenta caracteres. Uma imagem é sempre rastreável até o commit exato que a originou, sem tabela de correspondência no meio.

Os repositórios ECR são criados com `IMMUTABLE`: uma tag publicada não pode ser reapontada. Somado ao SHA como tag, isso fecha a rastreabilidade — a imagem auditada na esteira é exatamente a que roda no cluster, e ninguém consegue trocar o conteúdo por baixo dela.

O build também é único: o job `image` constrói, escaneia e publica na mesma execução, com `docker push` em vez de uma segunda construção. O binário auditado é o binário publicado.

## A divisão entre CI e CD

A fronteira está em **publicar a imagem** versus **apontar o cluster para ela**.

| | CI (`go-ci`, `python-ci`) | CD (previsto) |
|---|---|---|
| Roda em | pull request **e** push para `main` | apenas push para `main` |
| Faz | build, teste, lint, scans, e **publica a imagem no ECR** | atualiza a tag em `apps/<serviço>/values.yaml` no [`togglemaster-gitops`](https://github.com/fiap-tech-challenge-devops/togglemaster-gitops) |
| Efeito no cluster | nenhum | o Argo CD detecta o commit e sincroniza |

**O CI publica a imagem também em pull request**, e isso é deliberado: a imagem no ECR é o artefato que os scans auditaram. Construir em PR e publicar só depois do merge significaria publicar um binário diferente do que passou pelo gate — exatamente o problema que a consolidação do job `image` resolveu.

Publicar cedo não expõe nada: as tags são o SHA do commit e os repositórios são `IMMUTABLE`, então uma imagem de PR não pode sobrescrever nada nem ser confundida com outra. Ela simplesmente existe no registry sem que ninguém aponte para ela.

Quem decide o que roda é o CD, e só ele — a promoção acontece quando a tag muda no repositório GitOps, nunca por um push no ECR.

## Segredos necessários

Configurados na organização e herdados via `secrets: inherit`:

| Segredo | Uso |
|---|---|
| `AWS_ROLE_ARN` | Role assumida via OIDC para login no ECR |
| `GITOPS_TOKEN` | Escrita no repositório GitOps — o `GITHUB_TOKEN` padrão não alcança outro repositório |

## Versionamento

Alterações que mudem entradas ou comportamento recebem uma tag nova. Os serviços migram individualmente atualizando a referência `@vN` — assim uma mudança pode ser validada em um serviço antes de alcançar os cinco.
