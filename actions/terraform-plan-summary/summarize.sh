#!/usr/bin/env bash
#
# Resume um plano do Terraform com IA enviando só a estrutura. Ver README.md.
# Configuração por variável de ambiente (action.yml). Nunca falha: todo erro
# sai com zero e sem escrever resumo.

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

# Descarta os VALORES e mantém só endereço, tipo, ação e nomes de atributos.
# "terraform show -json" não redige nada — sem esta redução, as senhas vazariam.
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

# Sem mudanças: mensagem estática, sem gastar requisição e sem rodapé de IA.
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

# Isolado para que trocar de provedor não encoste na redução acima.
chamar_modelo () {
  local estrutura="$1" saida="$2"

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

# Filtrar por tipo, não por índice: pode vir bloco de raciocínio antes da mensagem.
jq -r '
  [ .output[]?
    | select(.type == "message")
    | .content[]?
    | select(.type == "output_text")
    | .text
  ] | join("\n")
' "$TMP/resposta.json" > "$OUTPUT_FILE"

# Conteúdo, não tamanho: "jq -r" vazio grava 1 byte de quebra de linha e [ -s ] aceita.
if ! grep -q '[^[:space:]]' "$OUTPUT_FILE" 2>/dev/null; then
  desistir "Resposta sem texto — resumo ignorado."
fi

# Só aqui o texto veio mesmo do modelo.
printf '\n%s\n' "${FOOTER:?}" >> "$OUTPUT_FILE"

{
  echo "summary-file=$OUTPUT_FILE"
  echo "has-changes=true"
} >> "$GITHUB_OUTPUT"
