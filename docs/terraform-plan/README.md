# terraform-plan

Esteira de plano para repositórios de IaC: validação de sintaxe, varredura de segurança e um plano por stage, com resumo por IA e comentário no pull request.

Arquivo: [`.github/workflows/terraform-plan.yml`](../../.github/workflows/terraform-plan.yml)
Exemplo: [`example/caller.yml`](example/caller.yml)

> A documentação mora aqui, e não ao lado do workflow, porque o GitHub não aceita subdiretórios em `.github/workflows/`.

## Uso

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
      aws-oidc-role-arn: ${{ secrets.AWS_OIDC_ROLE_ARN }}
      openai-api-key: ${{ secrets.OPENAI_API_KEY }}
```

## Inputs e secrets

A lista completa está no bloco `on.workflow_call` de [`terraform-plan.yml`](../../.github/workflows/terraform-plan.yml), com descrição e default de cada entrada — onde ela não tem como ficar desatualizada.

Obrigatórios: os inputs `stages` e `state-bucket-prefix`, e o secret `aws-oidc-role-arn`. Todo o resto tem default, e `openai-api-key` é opcional (sem ela, o resumo simplesmente não aparece).

## Os stages

O input `stages` é um JSON. Cada entrada precisa de duas chaves:

| chave | efeito |
|---|---|
| `stage` | o diretório a planejar |
| `required` | `false` faz a falha do plano **não** reprovar o job |

`required: false` existe para stages que dependem de outro já aplicado. No ToggleMaster, o `addons` lê do SSM parâmetros que só o apply do `infra` cria — num ambiente ainda não provisionado o plan dele falha, e isso não deve bloquear o pull request.

## Nome dos checks

Um workflow chamado reporta o status check como `<job do caller> / <job do chamado>`. Com o job do caller chamado `iac`, os checks ficam:

```
iac / Validate (infra)
iac / Validate (addons)
iac / Security
iac / Plan (infra)
iac / Plan (addons)
```

Se houver ruleset exigindo status checks, ele precisa listar exatamente esses nomes, prefixo incluído. **Renomear o job do caller trava o merge de todos os pull requests abertos**, esperando checks que ninguém mais reporta.

## O plano é descartado

Não vira artifact e não é reaplicado no apply. O arquivo de plano contém todos os valores dos atributos em texto claro — inclusive senhas — e um artifact do Actions é baixável por qualquer pessoa com leitura no repositório.

É também por isso que o resumo por IA é um [composite action](../../actions/terraform-plan-summary/) e não outro reusable workflow: ele precisa rodar no mesmo job que gerou o plano, porque um `workflow_call` roda em runner próprio e não enxergaria o arquivo.

## O que o workflow espera do repositório consumidor

| | |
|---|---|
| Um diretório por stage | com Terraform e backend S3 parcial |
| `trivy.yaml` na raiz | ou outro caminho via `trivy-config` |
| `.checkov.yaml` na raiz | ou outro caminho via `checkov-config` |
| Role AWS federada por OIDC | com permissão de leitura do state e de plan |
| Bucket de state | nomeado `<state-bucket-prefix>-<ACCOUNT_ID>` |
