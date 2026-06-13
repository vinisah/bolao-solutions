# Bolão Copa 2026 — Solutions Pinturas

Bolão dos jogos do Brasil, **compartilhado entre todos os participantes**, **100% gratuito**,
com **trava automática de horário** (a aposta de cada jogo fecha **1 minuto antes do início**).

- **Frontend:** página única `index.html` hospedada no **GitHub Pages** (grátis).
- **Backend:** **Supabase** (Postgres + Auth + Realtime, plano Free, sem cartão).
- **Segurança:** toda escrita passa por funções no banco (RPC). A trava de horário usa o
  **relógio do servidor** — não dá para burlar mudando o relógio do celular nem chamando a API na mão.

---

## Pontuação

| Pontos | Quando |
|---|---|
| **6** | Acertou o vencedor **e** o placar exato |
| **3** | Acertou o vencedor (ou que seria empate) |
| **0** | Errou |

Desempate: maior pontuação → mais placares exatos → ordem alfabética.

---

## Passo a passo de publicação

### 1) Supabase (uma vez)

1. Acesse **supabase.com** → *Start your project* → entre com GitHub/e-mail (sem cartão).
2. **New project**: nome `bolao-solutions`, defina uma senha de banco forte (guarde-a),
   região **South America (São Paulo)**, plano **Free**. Aguarde ~2 min.
3. Menu **SQL Editor** → *New query* → cole **todo** o conteúdo de [`supabase/schema.sql`](supabase/schema.sql) → **Run**.
   (Cria tabelas, RLS, views, RPCs, a trava de horário e semeia os 3 jogos.)
4. Menu **Authentication → Sign in / Providers**: deixe **Email** habilitado.
   Em **Authentication → Users → Add user → Create new user**: e-mail + senha do **organizador**
   e marque **Auto Confirm User**. Clique no usuário criado e **copie o User UID**.
5. Volte ao **SQL Editor** → *New query* → rode (troque pelo UID copiado):
   ```sql
   insert into admins(user_id) values ('COLE-O-UID-AQUI');
   ```
   Agora **só esse usuário** pode lançar resultados, gerenciar jogos e limpar dados.
6. Menu **Project Settings (engrenagem) → API**: copie **Project URL**
   (`https://xxxx.supabase.co`) e a chave **anon public**.
   > ⚠️ **Nunca** use ou exponha a chave **service_role**.
7. (Realtime) Menu **Database → Replication**: confirme que `jogos`, `palpites` e `resultados`
   estão na publicação `supabase_realtime` (o `schema.sql` já tenta adicionar).

### 2) Configurar o `index.html`

Abra `index.html` e, no topo do `<script>`, preencha:

```js
const SUPABASE_URL = 'https://SEU-PROJETO.supabase.co';
const SUPABASE_ANON_KEY = 'SUA-CHAVE-ANON-PUBLIC';
```

> A chave anon **é pública por design** e pode ficar no HTML — a segurança está no banco (RLS + RPC).

### 3) GitHub Pages (uma vez)

1. Crie um repositório **público** (ex.: `bolao-solutions`). *(Pages é grátis em repo público.)*
2. Suba os arquivos: `index.html`, a pasta `supabase/`, a pasta `.github/` e este `README.md`.
3. **Settings → Pages**: *Source* = **Deploy from a branch**, *Branch* = **main**, pasta **/ (root)** → **Save**.
4. Em ~1–2 min aparece a URL pública: `https://SEU-USUARIO.github.io/bolao-solutions/`.
   Compartilhe com os participantes.

### 4) Keep-alive (recomendado)

O projeto Free pausa após ~7 dias sem uso. O workflow [`.github/workflows/keepalive.yml`](.github/workflows/keepalive.yml)
faz um ping a cada 3 dias. Em **Settings → Secrets and variables → Actions**, crie dois secrets:

- `SUPABASE_URL` = a Project URL
- `SUPABASE_ANON_KEY` = a chave anon public

---

## Como usar

- **Participante:** digita **nome** + um **PIN** (mín. 6 caracteres, fica salvo no navegador) e o palpite
  no formato `2 x 1`. Só pode apostar enquanto o cronômetro do jogo não zerar (fecha 1 min antes do início).
  O PIN evita que outra pessoa mude o palpite no seu nome.
- **Organizador (admin):** clica em **Admin**, entra com e-mail/senha do Supabase e ganha acesso a:
  lançar resultado oficial, **cadastrar/editar/excluir jogos** (com data e hora) e **Limpar tudo**.

---

## Limitações conhecidas

- **PIN por nome** é proteção leve (não é login forte por pessoa). Suficiente para um bolão de empresa.
- Free tier **pausa em 7 dias** ociosos (mitigado pelo keep-alive; dados nunca são perdidos).
- Os jogos vêm semeados com as datas do HTML (em horário de Brasília); o admin edita quando quiser.

## Verificação rápida

Abra a URL em dois aparelhos: ao lançar um palpite num, ele aparece no outro em ~1–2 s.
Para testar a trava: no Supabase, edite o `kickoff` de um jogo para daqui a ~30 s e veja a aposta
fechar sozinha 1 min antes (o servidor rejeita mesmo via API direta ou com o relógio adulterado).
