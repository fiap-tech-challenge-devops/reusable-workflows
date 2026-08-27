# go-ci

Esteira de CI dos microsserviços em Go: build, teste, lint, varredura de segurança, imagem e publicação no ECR.

Arquivo: [`.github/workflows/go-ci.yml`](../../.github/workflows/go-ci.yml)
Exemplo: [`example/caller.yml`](example/caller.yml)

Consumido por `auth-service` e `evaluation-service`. Para os serviços em Python, ver [`python-ci`](../python-ci/).

## Uso

```yaml
jobs:
  ci:
    uses: fiap-tech-challenge-devops/reusable-workflows/.github/workflows/go-ci.yml@v1.1.1
    with:
      ecr-repository: togglemaster/auth-service
      go-version: "1.21"
      aws-region: us-east-1
    secrets:
      AWS_ROLE_ARN: ${{ secrets.AWS_OIDC_ROLE_ARN }}
```

## Inputs e secrets

A lista completa está no bloco `on.workflow_call` de [`go-ci.yml`](../../.github/workflows/go-ci.yml).

Obrigatórios: o input `ecr-repository` e o secret `AWS_ROLE_ARN`. Os demais tem default: `go-version` e `1.21` e `aws-region` e `us-east-1`.

O `ecr-repository` é o caminho **dentro** do registry, sem o host — `togglemaster/auth-service`, não `762103020993.dkr.ecr.us-east-1.amazonaws.com/togglemaster/auth-service`. O host vem do `amazon-ecr-login` em tempo de execução.

## Os cinco jobs e a ordem entre eles

```
build-test ──┬── lint          (não bloqueia)
             │
             └── Security ──── docker ──── ecr-push
```

| job | o que faz | reprova a esteira? |
|---|---|---|
| `build-test` | `go mod download`, `go build ./...`, `go test ./...` | **sim** |
| `lint` | `golangci-lint` | **não** — tem `continue-on-error` |
| `Security` | `gosec` (SAST) e `trivy fs` (SCA) | **sim**, só o Trivy |
| `docker` | build local da imagem e `trivy image` | **sim** |
| `ecr-push` | autentica por OIDC, faz login no ECR e publica | **sim** |

O `lint` roda em paralelo com o `Security` e não é dependência de ninguém — o `docker` espera apenas `build-test` e `Security`. Estilo de código não impede uma imagem de subir; vulnerabilidade impede.

## O gate de segurança

Este é o ponto da Fase 3, e a regra é explícita: **vulnerabilidade CRITICAL reprova imediatamente.**

| ferramenta | frente | reprova? |
|---|---|---|
| `gosec` | SAST — código-fonte | não (`continue-on-error`) |
| `trivy fs` | SCA — dependências | **sim**, em `CRITICAL` |
| `trivy image` | imagem montada, incluindo o sistema-base | **sim**, em `CRITICAL` |

As três cobrem camadas diferentes. O `trivy image` é o que pega vulnerabilidade em pacote do sistema operacional da imagem-base — coisa que nenhuma análise de código-fonte enxerga.

O `gosec` não reprova de propósito: SAST em Go tem taxa de falso positivo alta o bastante para travar a esteira por engano. Ele reporta, você lê.

## Autenticação: nenhuma chave estática

O `ecr-push` assume a role por OIDC:

```yaml
permissions:
  id-token: write     # sem isto o job nem pede o token
  contents: read
```

O `AWS_ROLE_ARN` é o ARN da role, não uma credencial. Quem quiser entender o mecanismo, ver a documentação de OIDC do [`togglemaster-iac`](https://github.com/fiap-tech-challenge-devops/togglemaster-iac/tree/main/docs/esteira).

A role (`github-actions-ecr-push`) é criada pelo stage `bootstrap` do `togglemaster-iac` e é **a mesma para os cinco serviços**. A trust policy restringe por `sub`, com um padrão por repositório: o `auth-service` não consegue se passar pelo `flag-service`.

## O que o workflow espera do repositório consumidor

| | |
|---|---|
| `go.mod` na raiz | o `setup-go` usa para o cache |
| `Dockerfile` na raiz | o build usa `context: .` |
| Secret `AWS_ROLE_ARN` | ARN da role de CI |
| Repositório ECR já criado | vem do `bootstrap`, não do CI |

## Duas coisas que ainda não estão aqui

**A imagem é construída duas vezes.** O job `docker` monta e escaneia localmente; o `ecr-push` monta de novo, agora com `push: true`. Como são jobs distintos, rodam em runners distintos e a imagem carregada no primeiro não existe no segundo.

Na prática funciona, mas o artefato escaneado não é literalmente o publicado. Consolidar os dois jobs num só, ou passar a imagem por artifact, resolveria.

**Não há etapa de CD.** A Fase 3 pede que o fim do CI atualize a tag da imagem no repositório GitOps. Isso ainda não existe aqui — está previsto como `cd.yaml`.

Vale notar também que a tag publicada hoje é o `github.sha` completo, enquanto o [README do repositório](../../README.md) descreve o formato `v<versão>-<commit-curto>`.
