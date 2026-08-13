# terraform-destroy

Destrói **um** stage de Terraform, com limpeza opcional do cluster EKS antes.

Arquivo: [`.github/workflows/terraform-destroy.yml`](../../.github/workflows/terraform-destroy.yml)
Exemplo: [`example/caller.yml`](example/caller.yml)

## A ordem é o inverso do apply

Um stage por chamada, encadeado com `needs:` no caller — mesma forma do [`terraform-apply`](../terraform-apply/), na direção contrária:

```yaml
jobs:
  addons:
    uses: .../terraform-destroy.yml@v1.0.0
    with: { stage: addons, eks-cleanup: true, ... }

  infra:
    needs: addons
    uses: .../terraform-destroy.yml@v1.0.0
    with: { stage: infra, ... }
```

## `eks-cleanup`: por que existe

Load balancers criados pelo AWS Load Balancer Controller e nós criados pelo Karpenter **não estão no tfstate** — quem os cria são controllers rodando dentro do cluster. Se sobreviverem ao destroy, ficam órfãos e seguram a VPC: o `terraform destroy` trava em `DependencyViolation` ao tentar remover as subnets.

Com `eks-cleanup: true`, o job remove antes do destroy, nesta ordem:

1. **Applications do Argo CD** — primeiro, senão ele recria tudo que vier a seguir
2. **Ingresses** — cada um tem um ALB associado
3. **Services `type=LoadBalancer`** — cada um é um NLB
4. **NodePools e EC2NodeClasses do Karpenter** — remove as instâncias provisionadas

Depois espera 90 segundos para os controllers processarem as remoções na AWS.

> **Ligue apenas no primeiro stage da cadeia.** Ligar em todos repete a limpeza e o `sleep 90` sem efeito. Exige `eks-cluster-ssm-parameter`; sem ele o job falha em vez de destruir com o cluster sujo.

Se o cluster já não existir ou o parâmetro não estiver no SSM, o step sai limpo — destruir um ambiente já parcialmente removido não quebra.

## Inputs e secrets

A lista completa está no bloco `on.workflow_call` de [`terraform-destroy.yml`](../../.github/workflows/terraform-destroy.yml).

Obrigatórios: os inputs `stage` e `state-bucket-prefix`, e o secret `aws-oidc-role-arn`.

## O gate de aprovação

Aqui, ao contrário do apply, **use o `environment`.** O destroy roda por `workflow_dispatch`: não há pull request, não há revisão e não há plano para ler antes. O environment é a única confirmação humana no caminho.

A confirmação por texto digitado (`confirm: DESTROY`) fica no caller, como um job `guard` — ela é específica do projeto e pertence a onde o gatilho é declarado.

## O que sobrevive

O bucket de state não é destruído: ele pertence ao stage de bootstrap, que não faz parte desta cadeia. Repositórios ECR também sobrevivem, se estiverem no bootstrap — o que evita o `RepositoryNotEmptyException` quando há imagem publicada.
