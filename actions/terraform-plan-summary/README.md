# terraform-plan-summary

Resume um plano do Terraform com IA e escreve o resultado em Markdown, para ser exibido no comentário de um pull request.

Envia à API **apenas a estrutura do plano** — endereços, tipos, ações e os *nomes* dos atributos que mudam. Nenhum valor de atributo sai da máquina.

## Por que isto é um action, e não um reusable workflow

O resumo precisa rodar **no mesmo job** que gerou o plano: ele lê o plano binário deixado pelo step anterior e escreve um arquivo que os steps seguintes consomem. Um `workflow_call` roda em runner próprio e não enxerga nada disso.

Atravessar essa fronteira exigiria subir o plano como artifact — e é justamente o que o desenho recusa:

```
terraform show tfplan        → "(sensitive value)"
terraform show -json tfplan  → "senha":{"sensitive":true,"value":"615cZvPKR6Iy19FnAXEc"}
```

O valor em texto claro fica **ao lado** do próprio `"sensitive": true`. Só a saída humana redige. Um artifact do Actions é baixável por qualquer pessoa com leitura no repositório.

Um detalhe temporal agrava: antes do primeiro apply, uma senha gerada é `(known after apply)` e nem aparece no plano. Depois do apply ela vive no state — e aparece em **todo** plano seguinte.

## Por que a redução e a chamada à API vêm juntas

O valor deste action não é a chamada à API; são dez linhas de `curl`. O valor é a garantia de que nenhum valor atravessa a fronteira.

Se isto fosse dividido num "resuma este texto" genérico, um consumidor poderia passar o plano bruto e vazar tudo, sem nada no caminho para impedir. Juntos, o caminho seguro é o único caminho.

## Uso

```yaml
- name: Terraform plan
  id: plan
  working-directory: infra
  run: terraform plan -input=false -no-color -out=tfplan

- name: Resumo do plano por IA
  if: steps.plan.outcome == 'success'
  continue-on-error: true          # o resumo é informativo, nunca um gate
  uses: fiap-tech-challenge-devops/reusable-workflows/actions/terraform-plan-summary@v1.1.1
  with:
    api-key: ${{ secrets.OPENAI_API_KEY }}
    working-directory: infra
    label: infra
```

O `continue-on-error` fica no consumidor, de propósito: o action nunca falha por conta própria, mas o consumidor é quem decide o que fazer se algo inesperado acontecer.

## Pré-requisitos

O action **não** resolve, e o job precisa ter feito antes:

- `terraform` instalado e `init` executado
- `terraform plan` executado com `-out=<arquivo>`
- `jq` e `curl` disponíveis (ambos já vêm no `ubuntu-latest`)

## Inputs e outputs

A lista completa, com descrição e default de cada um, está em [`action.yml`](action.yml) — que é onde ela não tem como ficar desatualizada. Só `api-key` importa na maioria dos casos; o resto tem default razoável.

Dois outputs: `summary-file` (caminho do resumo, ou vazio) e `has-changes` (`true`/`false`).

## Comportamento

| Situação | Escreve resumo | Rodapé de IA | Chama a API |
|---|:---:|:---:|:---:|
| Plano com mudanças | sim | sim | sim |
| Plano sem mudanças | sim, mensagem estática | **não** | **não** |
| Chave ausente | não | — | não |
| Plano não encontrado | não | — | não |
| Erro HTTP (401, 429, 5xx) | não | — | sim |
| Resposta sem texto | não | — | sim |

**O action nunca falha.** Todo caminho de erro sai com zero e sem escrever arquivo. Quem decide o merge é o `plan`; o resumo é conveniência.

Plano sem mudanças não chama a API: pagar uma requisição para o modelo dizer "não há mudanças", quando a redução já sabe disso com certeza, seria desperdício — e a redação variaria a cada execução. Por isso esse caminho também não leva o rodapé de IA: não foi a IA que escreveu.

## O que é enviado

Só isto, para um plano que cria um RDS e altera uma fila:

```json
{
  "contagem": [{ "acao": "create", "quantidade": 1 }, { "acao": "update", "quantidade": 1 }],
  "recursos": [
    { "endereco": "module.rds.aws_db_instance.this", "tipo": "aws_db_instance",
      "acoes": ["create"], "atributos": ["arn", "endpoint", "engine", "identifier", "password"] },
    { "endereco": "aws_sqs_queue.eventos", "tipo": "aws_sqs_queue",
      "acoes": ["update"], "atributos": ["visibility_timeout_seconds"] }
  ],
  "outputs": [{ "nome": "cluster_name", "acoes": ["create"] }]
}
```

Note `"password"` na lista: o **nome** do atributo vai, o valor não.

## Duas linhas que parecem redundantes e não são

Se for mexer no [`summarize.sh`](summarize.sh), estas duas já quebraram antes:

```bash
# Filtrar por tipo, não por índice: pode vir bloco de raciocínio antes da mensagem.
# Conteúdo, não tamanho: "jq -r" vazio grava 1 byte de quebra de linha e [ -s ] aceita.
```

A primeira: `output[0].content[0]` pega o item errado quando o modelo devolve raciocínio antes da mensagem. A segunda: `[ -s arquivo ]` aceita o byte que `jq -r` grava sobre resultado vazio, e o resumo sai como bloco em branco com rodapé.

Nenhuma das duas dá erro visível quando quebra.

## Trocar de provedor

A chamada ao modelo está isolada na função `chamar_modelo()` do [`summarize.sh`](summarize.sh). Acrescentar outro provedor é aditivo e não encosta na redução do plano, que é a parte de que a segurança depende.

Hoje usa a **Responses API** (`/v1/responses`), não o `/v1/chat/completions` — a documentação da OpenAI recomenda a primeira para geração de texto.
