# terraform-apply

Aplica **um** stage de Terraform: init com backend S3, plan para o log e apply.

Arquivo: [`.github/workflows/terraform-apply.yml`](../../.github/workflows/terraform-apply.yml)
Exemplo: [`example/caller.yml`](example/caller.yml)

## Por que um stage por chamada

A ordem entre stages vive no caller, com `needs:`:

```yaml
jobs:
  infra:
    uses: .../terraform-apply.yml@v1.0.0
    with: { stage: infra, state-bucket-prefix: meu-projeto-tfstate }
    secrets: { aws-oidc-role-arn: "${{ secrets.AWS_OIDC_ROLE_ARN }}" }

  addons:
    needs: infra
    uses: .../terraform-apply.yml@v1.0.0
    with: { stage: addons, state-bucket-prefix: meu-projeto-tfstate }
    secrets: { aws-oidc-role-arn: "${{ secrets.AWS_OIDC_ROLE_ARN }}" }
```

Matriz não serve aqui: as pernas rodam em paralelo e não há como encadear `needs:` entre elas. Um stage por chamada resolve a ordem e ainda deixa acrescentar um terceiro sem tocar no workflow compartilhado.

Isso difere do [`terraform-plan`](../terraform-plan/), que usa matriz — lá a ordem é irrelevante e paralelo é vantagem.

## Inputs e secrets

A lista completa está no bloco `on.workflow_call` de [`terraform-apply.yml`](../../.github/workflows/terraform-apply.yml).

Obrigatórios: os inputs `stage` e `state-bucket-prefix`, e o secret `aws-oidc-role-arn`.

## O gate de aprovação

O input `environment` é opcional e vazio por padrão — o apply roda direto.

Preencher com um environment do GitHub que exija revisor transforma cada chamada num portão manual. **Pense duas vezes antes de fazer isso num apply disparado por merge:** se o gate é o pull request, a aprovação no environment aprova a mesma decisão uma segunda vez, sem informação nova. E um apply parado no portão segura o grupo de `concurrency` do caller, enfileirando os merges seguintes por tempo indeterminado.

Para destroy, que roda por disparo manual e não tem pull request, o gate faz sentido — ver [`terraform-destroy`](../terraform-destroy/).

## O plano não atravessa runs

O `plan` deste workflow é para o log. O apply replaneja no mesmo job, com o mesmo state; nada é persistido entre execuções. Ver [`terraform-plan`](../terraform-plan/) para o motivo de o plano nunca virar artifact.

## O que o workflow espera do repositório consumidor

| | |
|---|---|
| Um diretório por stage | com Terraform e backend S3 parcial |
| Role AWS federada por OIDC | com permissão de criar o que o stage declara |
| Bucket de state | nomeado `<state-bucket-prefix>-<ACCOUNT_ID>` |
