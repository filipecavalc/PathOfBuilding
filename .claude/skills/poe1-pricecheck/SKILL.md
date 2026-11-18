---
name: poe1-pricecheck
description: Dá uma faixa de preço justa (venda rápida, justo, teto) para um item do Path of Exile 1 que o usuário quer vender. O usuário só cola o item (Ctrl+Alt+C); a ferramenta trade_price do Path of Building busca anúncios comparáveis no trade oficial e resume, e o poe.ninja cobre gemas, currency e outros itens de bulk. Use quando pedirem para precificar, fazer price check, avaliar ou anunciar um item do PoE1.
---

# PoE1 Price Check

O usuário cola o item e recebe o preço. Faça todo o resto sem pedir nada a ele: nada de abrir links,
clicar ou copiar anúncios. Nunca chute um preço; se faltar dado, diga o que falta.

## Pré-requisitos

- **Path of Building aberto com o servidor MCP** (ferramentas `mcp__path-of-building__*`). Se elas não
  aparecerem, peça para abrir o PoB e reconectar o MCP (`/mcp`). Carregue a ferramenta com
  `ToolSearch` (`select:mcp__path-of-building__trade_price`) se ela estiver adiada.
- **PoB logado no Path of Exile** (aba Import/Export, "Authorize with Path of Exile"). Build aberto não é
  necessário.
- **Item copiado com Ctrl+Alt+C.** Ctrl+C funciona, mas sem tiers, e a resposta deve avisar.

## Fluxo

1. Chame `trade_price` com `item` = o texto colado.
   - Passe `league` só se o usuário disser a liga; sem ela, a ferramenta pega a liga de desafio atual.
   - A ferramenta lê o item, escolhe o que define o preço e faz no máximo 3 buscas (Instant Buyout).
   - Ela afrouxa ou aperta a busca sozinha, converte pela cotação do Currency Exchange e resume os 20
     anúncios mais baratos.
2. Leia o `verdict`:
   - **`price`**: use `price.quick` / `price.fair` / `price.ceiling`, `confidence`, `why`, `market`,
     `searches`, `drivers`.
   - **`cheap`**: o item vale no máximo uns 5c. Responda "vendor ou 1–5c", com o total de anúncios e o
     preço mínimo, sem refinar.
   - **`bulk`** (gema, currency, divination card, fragmento, mapa): rode, a partir da pasta desta skill,
     `python scripts/ninja.py price --league <liga> --name "<bulk.name>" --class "<bulk.kind>"`.
     - Para gemas, acrescente `--level`, `--quality` e `--corrupted` conforme `bulk`.
     - Preço por unidade; multiplique pelo `bulk.stack` se houver.
     - Liga atual: a de `trade_price` de outro item, ou `Covens` em 17/11/2026.
   - **`no_data`**: chame de novo com `drop` = a chave do driver menos importante (o último com
     `used: true`). Se ainda não houver dados, diga que o item precisa de avaliação manual e mostre o link
     da última busca.
3. Se a confiança for baixa, explique os motivos de `why`. Só refine (com `drop` ou `stats`) se o usuário
   pedir.
4. Erro de limite do site: espere o tempo indicado e tente uma vez mais. Precifique um item por vez.

## Resposta (sempre neste formato, em português)

- **Faixa:** venda rápida, justo e teto, em chaos, com o equivalente em divine quando passar de ~1 div.
- **Base:**
  - total de anúncios comparáveis e quantos entraram na conta;
  - a busca usada (`basedOn`) e o que ela exigiu (`filters`: links, corrupção, mínimos);
  - a confiança;
  - o link (`searches[].url`) para o usuário conferir.
- **Por quê:**
  - os 2–3 drivers do item (`drivers` com `used: true`);
  - o que a busca afrouxou ou apertou;
  - afixos livres (`item.open`), se houver.
- **Como anunciar:**
  - em chaos abaixo de ~1 div, em divine acima;
  - no Merchant's Tab o preço é firme e mudar tem espera, então confira antes;
  - se não vender em ~1 dia, desça para o justo ou para a venda rápida.

## Regras

- Só leitura: nunca compre, nunca mande mensagem a vendedor, nunca anuncie.
- Fale só do que o retorno mostra. `filters` traz tudo o que a busca exigiu: não diga que um filtro faltou sem
  olhar ali, e não desloque a faixa por palpite ("deve valer mais porque…"). Se achar que algo ficou de fora,
  diga o que é e ofereça uma busca com `stats` ou `drop`.
- Os totais vêm do PoB e podem diferir da soma das linhas coladas: um enchant ou implicit de "modifier
  magnitudes" aumenta os mods, e o texto do Ctrl+Alt+C mostra o valor antes do aumento (`item.boosted` e
  `notes` dizem quais). Use os números da ferramenta e, se citar uma linha, cite os dois valores.
- Nunca acesse a API do trade pelo terminal nem por navegador; o acesso é só pelo PoB. Nunca peça cookie,
  token ou senha.
- O poe.ninja mostra preço pedido, não preço de venda. Para único, o número dele é o piso da variante; o
  `trade_price` já cuida dos únicos.
