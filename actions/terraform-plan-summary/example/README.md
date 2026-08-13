# Exemplo — terraform-plan-summary

O [`caller.yml`](caller.yml) é um workflow completo e mínimo: autentica na AWS, planeja, resume e publica no resumo do run.

## Diferença em relação aos exemplos dos módulos Terraform

Nos módulos, `example/` é executável — `terraform validate` roda ali dentro e verifica o contrato de fato. **Aqui não dá.** Um workflow só executa dentro de um repositório com os secrets certos, uma conta AWS e o evento certo.

Então este arquivo é referência para copiar, não algo que se possa rodar isolado.

## Para adaptar

| trocar | por |
|---|---|
| `infra` | o diretório do seu Terraform |
| `AWS_OIDC_ROLE_ARN` | o nome do seu secret de role |
| `us-east-1` | sua região |
| `@v1.0.0` | a tag que você quer fixar |

## Os dois pontos fáceis de errar

**`-out=tfplan` no plan.** O action lê o plano binário, não a saída de texto. Sem `-out`, ele não encontra o plano e desiste em silêncio — sem falhar o job, porque nunca falha.

**`continue-on-error: true` no step do resumo.** O action não falha sozinho, mas essa linha é o que garante que nenhum comportamento inesperado dele reprove o pull request. O resumo é conveniência; quem decide o merge é o plan.
