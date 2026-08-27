# python-ci

Esteira de CI dos microsserviços em Python: build, teste, lint, varredura de segurança, imagem e publicação no ECR.

Arquivo: [`.github/workflows/python-ci.yml`](../../.github/workflows/python-ci.yml)
Exemplo: [`example/caller.yml`](example/caller.yml)

Consumido por `flag-service`, `targeting-service` e `analytics-service`. Para os serviços em Go, ver [`go-ci`](../go-ci/).

## Uso

```yaml
jobs:
  ci:
    uses: fiap-tech-challenge-devops/reusable-workflows/.github/workflows/python-ci.yml@v1.1.1
    with:
      ecr-repository: togglemaster/flag-service
      python-version: "3.9"
      aws-region: us-east-1
    secrets:
      AWS_ROLE_ARN: ${{ secrets.AWS_OIDC_ROLE_ARN }}
```

## Inputs e secrets

A lista completa está no bloco `on.workflow_call` de [`python-ci.yml`](../../.github/workflows/python-ci.yml).

Obrigatórios: o input `ecr-repository` e o secret `AWS_ROLE_ARN`. Os demais tem default: `python-version` e `3.9` e `aws-region` e `us-east-1`.

O `ecr-repository` é o caminho **dentro** do registry, sem o host — `togglemaster/flag-service`. O host vem do `amazon-ecr-login` em tempo de execução.

## Os quatro jobs e a ordem entre eles

```
build-test ──┬── lint          (não bloqueia)
             │
             └── security ──── image
```

| job | o que faz | reprova a esteira? |
|---|---|---|
| `build-test` | instala dependências, `compileall`, e `pytest` se houver teste | **sim** |
| `lint` | `ruff check` | **não** — tem `continue-on-error` |
| `security` | `bandit` (SAST) e `trivy fs` (SCA) | **sim**, só o Trivy |
| `image` | autentica por OIDC, constroi, escaneia com `trivy image` e publica | **sim** |

## Teste opcional, e por quê

Python não tem compilação que pegue erro de digitação, então o job faz duas coisas antes de testar:

```yaml
- run: python -m compileall .
```

Isso valida a **sintaxe** de todos os arquivos. É a rede mínima para um repositório sem teste nenhum — pega o erro de digitação que só apareceria em produção, no import.

Depois um step detecta se existe teste:

```yaml
if find . -type f \( -name "test_*.py" -o -name "*_test.py" \) | grep -q .; then
```

Havendo `test_*.py` ou `*_test.py`, roda `pytest`. Não havendo, registra no log e segue.

A alternativa seria reprovar quem não tem teste. O enunciado da Fase 3 pede testes unitários *"se existirem"*, e travar a esteira por ausência de teste impediria o serviço de ir para o ECR por um motivo que não é segurança.

## O gate de segurança

**Vulnerabilidade CRITICAL reprova imediatamente.**

| ferramenta | frente | reprova? |
|---|---|---|
| `bandit` | SAST — código-fonte | não (`continue-on-error`) |
| `trivy fs` | SCA — dependências do `requirements.txt` | **sim**, em `CRITICAL` |
| `trivy image` | imagem montada, incluindo o sistema-base | **sim**, em `CRITICAL` |

O `bandit -ll` filtra por severidade média para cima. Ele não reprova de propósito: SAST em Python acusa muito padrão que é intencional (`subprocess`, `assert` em teste), e travar por isso viraria ruído que se aprende a ignorar — o pior resultado possível para uma ferramenta de segurança.

Quem barra é o Trivy, nas duas frentes: dependência declarada e pacote do sistema-base da imagem.

## Autenticação: nenhuma chave estática

O job `image` assume a role por OIDC antes de construir:

```yaml
permissions:
  id-token: write     # sem isto o job nem pede o token
  contents: read
```

O `AWS_ROLE_ARN` é o ARN da role, não uma credencial. A role (`github-actions-ecr-push`) vem do stage `bootstrap` do `togglemaster-iac` e é **a mesma para os cinco serviços** — a trust policy tem um padrão de `sub` por repositório, então um não consegue se passar por outro.

Mecanismo detalhado: [documentação de OIDC do `togglemaster-iac`](https://github.com/fiap-tech-challenge-devops/togglemaster-iac/tree/main/docs/esteira).

## O que o workflow espera do repositório consumidor

| | |
|---|---|
| `requirements.txt` na raiz | o `pip install -r` falha sem ele |
| `Dockerfile` na raiz | o build usa `context: .` |
| Secret `AWS_ROLE_ARN` | ARN da role de CI |
| Repositório ECR já criado | vem do `bootstrap`, não do CI |

Testes, se houver, nomeados `test_*.py` ou `*_test.py` — o `pytest` roda só quando esse padrão é encontrado.

## Uma construção, um artefato

O job `image` constrói, escaneia e publica **na mesma execução**, e as três etapas apontam para a mesma referência resolvida uma única vez:

```yaml
- name: Resolve image URI
  id: img
  run: echo "uri=${{ steps.login-ecr.outputs.registry }}/${{ inputs.ecr-repository }}:${{ github.sha }}" >> "$GITHUB_OUTPUT"
```

O push usa `docker push`, e não `build-push-action` com `push: true`. A diferença importa: o segundo dispararia uma **nova construção**, e o que fosse publicado não seria o binário que passou pelo scan.

Com build e push em jobs separados isso era inevitável — cada job roda no seu runner, e a imagem carregada num não existe no outro.

## O que ainda não está aqui

**A etapa de CD.** Esta esteira publica a imagem no ECR — inclusive em pull request, de propósito, para que o artefato publicado seja o mesmo que os scans auditaram.

Apontar o cluster para uma imagem é outra coisa, e será um workflow separado: ele atualiza a tag em `apps/<serviço>/values.yaml` no repositório GitOps, apenas em push para `main`. Ainda não escrito.
