#!/usr/bin/env bash
#
# Resume um plano do Terraform com IA, enviando apenas a ESTRUTURA do plano.
#
# Mora num arquivo próprio, e não embutido no action.yml, para poder ser
# executado e verificado (bash -n, test/run-local.sh) sem precisar extrair YAML.
#
# Configuração vem toda por variável de ambiente — ver action.yml.
# Depende de: terraform, jq, curl. Todos presentes no ubuntu-latest.
#
# Contrato: NUNCA falha. Todo caminho de erro sai com zero, sem escrever resumo.
# O resumo é informativo; quem decide o merge é o plan.

set -euo pipefail

: "${OUTPUT_FILE:?OUTPUT_FILE não definido}"
: "${GITHUB_OUTPUT:?GITHUB_OUTPUT não definido}"

TMP="${RUNNER_TEMP:-/tmp}/tf-plan-summary"
mkdir -p "$TMP"

desistir () {
  echo "$1"
  rm -f "$OUTPUT_FILE"
  {
    echo "summary-file="
    echo "has-changes="
  } >> "$GITHUB_OUTPUT"
  exit 0
}

if [ -z "${OPENAI_API_KEY:-}" ]; then
  desistir "Chave da API ausente — resumo ignorado."
fi

if [ ! -f "${PLAN_FILE:?}" ]; then
  desistir "Plano '$PLAN_FILE' não encontrado em $(pwd) — resumo ignorado."
fi

# ── 1. Reduzir o plano a estrutura pura ───────────────────────────────────────
#
# Este é o passo que torna todo o resto seguro. "terraform show -json" NÃO
# redige valores sensíveis: a senha aparece em texto claro ao lado do próprio
# "sensitive": true. Só o "terraform show" humano redige.
#
# O filtro abaixo descarta todos os VALORES e mantém endereço, tipo, ação e os
# NOMES dos atributos que mudam. É isso, e só isso, que sai da máquina.
terraform show -json "$PLAN_FILE" > "$TMP/plan.json"

jq '
  def atributos_alterados($antes; $depois; $desconhecido):
    ( [ $depois | keys_unsorted[] | select($antes[.] != $depois[.]) ]
      + [ $desconhecido | keys_unsorted[] ]
    ) | unique;

  {
    contagem: (
      [ .resource_changes[]?
        | select(.change.actions != ["no-op"])
        | .change.actions | join("+")
      ]
      | group_by(.)
      | map({ acao: .[0], quantidade: length })
    ),
    recursos: [
      .resource_changes[]?
      | select(.change.actions != ["no-op"])
      | {
          endereco: .address,
          tipo: .type,
          acoes: .change.actions,
          atributos: atributos_alterados(
            .change.before // {};
            .change.after // {};
            .change.after_unknown // {}
          )
        }
    ],
    outputs: [
      (.output_changes // {})
      | to_entries[]
      | select(.value.actions != ["no-op"])
      | { nome: .key, acoes: .value.actions }
    ]
  }
' "$TMP/plan.json" > "$TMP/estrutura.json"

# ── 2. Plano sem mudanças: mensagem estática, sem chamar a API ────────────────
#
# Pagar uma requisição para o modelo dizer "não há mudanças", quando o jq acima
# já sabe disso com certeza, seria desperdício — e a redação variaria a cada
# execução. Por isso este caminho não leva o rodapé de "gerado por IA": não foi.
if [ "$(jq '.recursos | length' "$TMP/estrutura.json")" = "0" ] \
   && [ "$(jq '.outputs | length' "$TMP/estrutura.json")" = "0" ]; then
  echo "Nenhuma mudança no plano — mensagem estática, sem chamar a API."
  printf '%s\n' "${NO_CHANGES_MESSAGE:?}" > "$OUTPUT_FILE"
  {
    echo "summary-file=$OUTPUT_FILE"
    echo "has-changes=false"
  } >> "$GITHUB_OUTPUT"
  exit 0
fi

# ── 3. Chamar o modelo ────────────────────────────────────────────────────────
#
# Isolado numa função: acrescentar outro provedor depois é aditivo e não encosta
# na redução acima, que é a parte de que a segurança depende.
#
# Responses API (/v1/responses), não o antigo /v1/chat/completions — a
# documentação da OpenAI recomenda o primeiro para geração de texto.
chamar_modelo () {
  local estrutura="$1" saida="$2"

  # Corpo montado com jq, nunca por interpolação de string: o JSON reduzido e o
  # prompt precisam ser escapados corretamente.
  jq -n \
    --rawfile estrutura "$estrutura" \
    --arg modelo "${MODEL:?}" \
    --arg instrucoes "${INSTRUCTIONS:?}" \
    --arg rotulo "${LABEL:-}" \
    '{
      model: $modelo,
      input: (
        $instrucoes
        + "\n\n"
        + (if $rotulo == "" then "Estrutura do plano:" else "Estrutura do plano — " + $rotulo + ":" end)
        + "\n\n```json\n" + $estrutura + "\n```"
      )
    }' > "$TMP/request.json"

  curl -sS -o "$saida" -w '%{http_code}' \
    https://api.openai.com/v1/responses \
    -H "content-type: application/json" \
    -H "authorization: Bearer ${OPENAI_API_KEY}" \
    --data @"$TMP/request.json"
}

HTTP="$(chamar_modelo "$TMP/estrutura.json" "$TMP/resposta.json")" || HTTP="000"

if [ "$HTTP" != "200" ]; then
  echo "API respondeu HTTP $HTTP."
  jq -r '.error.message? // "sem detalhe"' "$TMP/resposta.json" 2>/dev/null || true
  desistir "Resumo ignorado."
fi

# O array "output" pode trazer outros itens além da mensagem (blocos de
# raciocínio, chamadas de ferramenta). Filtrar por tipo, em vez de pegar
# output[0].content[0], evita gravar o item errado quando isso acontece.
jq -r '
  [ .output[]?
    | select(.type == "message")
    | .content[]?
    | select(.type == "output_text")
    | .text
  ] | join("\n")
' "$TMP/resposta.json" > "$OUTPUT_FILE"

# Testar conteúdo, não tamanho: "jq -r" sobre resultado vazio grava uma quebra
# de linha, e [ -s ] considera 1 byte como arquivo preenchido — o resumo sairia
# como um bloco em branco com o rodapé embaixo.
if ! grep -q '[^[:space:]]' "$OUTPUT_FILE" 2>/dev/null; then
  desistir "Resposta sem texto — resumo ignorado."
fi

# O rodapé mora no arquivo, e só neste caminho: é o único em que a resposta veio
# mesmo do modelo. Quem exibe o resumo apenas reproduz o arquivo, sem
# acrescentar nada — e portanto sem precisar saber a origem do texto.
printf '\n%s\n' "${FOOTER:?}" >> "$OUTPUT_FILE"

{
  echo "summary-file=$OUTPUT_FILE"
  echo "has-changes=true"
} >> "$GITHUB_OUTPUT"
