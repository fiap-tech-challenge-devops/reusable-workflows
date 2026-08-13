#!/usr/bin/env bash
#
# Teste local do action terraform-plan-summary, sem rede e sem AWS.
#
# Dubla `terraform` (imprime um fixture) e `curl` (devolve uma resposta
# canônica), roda o summarize.sh de verdade e verifica o resultado.
#
#   bash test/run-local.sh
#
# Duas coisas que este teste protege, ambas bugs que já aconteceram:
#
#   1. Ler a resposta por índice (output[0].content[0]) pega o item errado
#      quando o modelo devolve um bloco de raciocínio antes da mensagem.
#   2. [ -s arquivo ] aceita o byte de quebra de linha que `jq -r` grava sobre
#      um resultado vazio, e o resumo sai como um bloco em branco.
#
# E a garantia central: nenhum VALOR de atributo pode chegar ao corpo do
# request. Os fixtures plantam valores CANARIO-* justamente para isso.

set -uo pipefail

RAIZ="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# ACTION_DIR permite apontar para uma cópia do action. Serve para teste de
# mutação: altere a cópia de propósito e confirme que este harness reprova —
# um teste que nunca falha não está protegendo nada.
ACTION="${ACTION_DIR:-$RAIZ/actions/terraform-plan-summary}"
TRAB="$(mktemp -d)"
trap 'rm -rf "$TRAB"' EXIT

falhas=0
ok ()    { printf '  \033[32mok\033[0m    %s\n' "$1"; }
falha () { printf '  \033[31mFALHA\033[0m %s\n' "$1"; falhas=$((falhas + 1)); }

# ── jq: usa o do sistema, ou baixa para o diretório temporário ────────────────
if command -v jq >/dev/null 2>&1; then
  JQ="$(command -v jq)"
else
  echo "jq não encontrado — baixando para $TRAB"
  case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*) ALVO="jq-windows-amd64.exe"; JQ="$TRAB/jq.exe" ;;
    Darwin)               ALVO="jq-macos-amd64";       JQ="$TRAB/jq" ;;
    *)                    ALVO="jq-linux-amd64";       JQ="$TRAB/jq" ;;
  esac
  curl -sSL -o "$JQ" "https://github.com/jqlang/jq/releases/download/jq-1.7.1/$ALVO" || {
    echo "não foi possível baixar o jq; instale-o e rode de novo"; exit 1; }
  chmod +x "$JQ" 2>/dev/null || true
fi

# ── dublês ───────────────────────────────────────────────────────────────────
mkdir -p "$TRAB/bin"
ln -sf "$JQ" "$TRAB/bin/jq" 2>/dev/null || cp "$JQ" "$TRAB/bin/jq"

cat > "$TRAB/bin/terraform" <<'EOF'
#!/usr/bin/env bash
# "terraform show -json <plano>" imprime o fixture apontado por FIXTURE
cat "$FIXTURE"
EOF

# Escreve um dublê de curl que devolve $1 como HTTP e $2 como corpo.
dublar_curl () {
  local http="$1" corpo="$2"
  cat > "$TRAB/bin/curl" <<EOF
#!/usr/bin/env bash
saida=""; ant=""
for a in "\$@"; do [ "\$ant" = "-o" ] && saida="\$a"; ant="\$a"; done
# guarda o corpo do request para as asserções de vazamento
for a in "\$@"; do case "\$a" in --data@*|@*) cp "\${a#*@}" "$TRAB/request-capturado.json" 2>/dev/null || true ;; esac; done
cat > "\$saida" <<'CORPO'
$corpo
CORPO
printf '%s' "$http"
EOF
  chmod +x "$TRAB/bin/curl"
}

chmod +x "$TRAB/bin/terraform"
export PATH="$TRAB/bin:$PATH"

# ── ambiente que o action normalmente injeta ─────────────────────────────────
export RUNNER_TEMP="$TRAB/runner-temp"
export PLAN_FILE="tfplan"
export OUTPUT_FILE="resumo-ia.md"
export MODEL="gpt-5.6-terra"
export LABEL="infra"
export INSTRUCTIONS="Resuma o plano."
export FOOTER="_Resumo gerado por IA a partir da estrutura do plano._"
export NO_CHANGES_MESSAGE="**Nenhuma alteração.**"

MSG_OK='{"output":[{"type":"reasoning","summary":[]},{"type":"message","role":"assistant","content":[{"type":"output_text","text":"Sobe o banco de flags e substitui a tabela."}]}]}'
MSG_VAZIA='{"output":[{"type":"reasoning","summary":[]}]}'
MSG_ERRO='{"error":{"message":"quota estourada"}}'

# Roda o script num diretório limpo. Não ecoa nada; os testes inspecionam o
# estado deixado para trás (arquivo de resumo, GITHUB_OUTPUT, saída capturada).
rodar () {
  rm -rf "$TRAB/wd"; mkdir -p "$TRAB/wd"; touch "$TRAB/wd/tfplan"
  rm -f "$TRAB/request-capturado.json"
  export GITHUB_OUTPUT="$TRAB/wd/gh_output"; : > "$GITHUB_OUTPUT"
  ( cd "$TRAB/wd" && bash "$ACTION/summarize.sh" ) > "$TRAB/wd/saida.txt" 2>&1
  echo $?
}

saida_de ()   { cat "$TRAB/wd/saida.txt"; }
resumo ()     { cat "$TRAB/wd/$OUTPUT_FILE" 2>/dev/null; }
tem_resumo () { [ -f "$TRAB/wd/$OUTPUT_FILE" ]; }
gh_out ()     { cat "$TRAB/wd/gh_output" 2>/dev/null; }

echo
echo "sintaxe"
bash -n "$ACTION/summarize.sh" && ok "summarize.sh passa em bash -n" || falha "summarize.sh tem erro de sintaxe"

echo
echo "caminho principal — plano com mudanças"
export FIXTURE="$RAIZ/test/fixtures/plan-com-mudancas.json"
export OPENAI_API_KEY="sk-dummy"
dublar_curl 200 "$MSG_OK"
codigo="$(rodar)"
[ "$codigo" = "0" ]                                   && ok "sai com zero"                  || falha "saiu com $codigo"
tem_resumo                                            && ok "escreve o resumo"              || falha "não escreveu o resumo"
resumo | grep -q "Sobe o banco de flags"              && ok "pega a mensagem, não o bloco de raciocínio" || falha "leu o item errado da resposta"
[ "$(resumo | grep -c 'gerado por IA')" = "1" ]       && ok "rodapé presente, uma única vez" || falha "rodapé ausente ou duplicado"
gh_out | grep -q 'has-changes=true'                   && ok "has-changes=true"              || falha "has-changes errado"

echo
echo "vazamento — nenhum VALOR pode chegar ao request"
if [ -f "$TRAB/request-capturado.json" ]; then
  canarios="$(grep -o 'CANARIO-[A-Z-]*' "$RAIZ/test/fixtures/plan-com-mudancas.json" | sort -u | wc -l)"
  [ "$canarios" -ge 5 ] && ok "fixture tem $canarios valores-canário plantados" || falha "fixture com poucos canários"
  if grep -q 'CANARIO-' "$TRAB/request-capturado.json"; then
    falha "VAZOU: $(grep -o 'CANARIO-[A-Z-]*' "$TRAB/request-capturado.json" | sort -u | tr '\n' ' ')"
  else
    ok "nenhum valor-canário no corpo do request"
  fi
  "$JQ" -e 'type == "object"' "$TRAB/request-capturado.json" >/dev/null 2>&1 \
    && ok "corpo do request é JSON válido" || falha "corpo do request não é JSON válido"
  "$JQ" -e '.messages? == null and .input != null' "$TRAB/request-capturado.json" >/dev/null 2>&1 \
    && ok "usa o formato da Responses API" || falha "corpo não está no formato da Responses API"
else
  falha "o request não foi capturado — o dublê de curl não recebeu --data @arquivo"
fi

echo
echo "plano sem mudanças — mensagem estática, sem chamar a API"
export FIXTURE="$RAIZ/test/fixtures/plan-sem-mudancas.json"
cat > "$TRAB/bin/curl" <<'EOF'
#!/usr/bin/env bash
echo "curl NAO deveria ter sido chamado" >&2
exit 99
EOF
chmod +x "$TRAB/bin/curl"
codigo="$(rodar)"
[ "$codigo" = "0" ]                              && ok "sai com zero"           || falha "saiu com $codigo"
tem_resumo                                       && ok "escreve a mensagem"     || falha "não escreveu a mensagem"
resumo | grep -q 'Nenhuma alteração'             && ok "mensagem estática"      || falha "mensagem estática ausente"
resumo | grep -q 'gerado por IA'                 && falha "rodapé de IA num texto que a IA não escreveu" || ok "sem rodapé de IA"
saida_de | grep -q 'NAO deveria ter sido chamado' && falha "chamou a API à toa" || ok "não chamou a API"
gh_out | grep -q 'has-changes=false'             && ok "has-changes=false"      || falha "has-changes errado"

echo
echo "caminhos de desistência — nenhum pode escrever resumo nem falhar"
export FIXTURE="$RAIZ/test/fixtures/plan-com-mudancas.json"

dublar_curl 429 "$MSG_ERRO"; codigo="$(rodar)"
[ "$codigo" = "0" ] && ! tem_resumo && ok "HTTP 429: sai zero, sem resumo" || falha "HTTP 429 mal tratado (exit $codigo)"

dublar_curl 401 "$MSG_ERRO"; codigo="$(rodar)"
[ "$codigo" = "0" ] && ! tem_resumo && ok "HTTP 401: sai zero, sem resumo" || falha "HTTP 401 mal tratado (exit $codigo)"

dublar_curl 200 "$MSG_VAZIA"; codigo="$(rodar)"
[ "$codigo" = "0" ] && ! tem_resumo && ok "resposta sem texto: sai zero, sem resumo" || falha "resposta vazia mal tratada (exit $codigo)"

dublar_curl 200 "$MSG_OK"
OPENAI_API_KEY="" codigo="$(OPENAI_API_KEY="" rodar)"
[ "$codigo" = "0" ] && ! tem_resumo && ok "sem chave: sai zero, sem resumo" || falha "chave ausente mal tratada (exit $codigo)"

export OPENAI_API_KEY="sk-dummy"
rm -rf "$TRAB/wd"; mkdir -p "$TRAB/wd"   # sem tocar no tfplan
export GITHUB_OUTPUT="$TRAB/wd/gh_output"; : > "$GITHUB_OUTPUT"
( cd "$TRAB/wd" && bash "$ACTION/summarize.sh" ) > "$TRAB/wd/saida.txt" 2>&1
codigo=$?
[ "$codigo" = "0" ] && ! tem_resumo && ok "plano inexistente: sai zero, sem resumo" || falha "plano ausente mal tratado (exit $codigo)"

echo
if [ "$falhas" -eq 0 ]; then
  printf '\033[32mtodos os testes passaram\033[0m\n\n'
  exit 0
fi
printf '\033[31m%s teste(s) falharam\033[0m\n\n' "$falhas"
exit 1
