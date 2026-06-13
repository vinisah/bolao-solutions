-- =============================================================================
-- Bolão Copa 2026 (Solutions Pinturas) — MODELO: login Google (auth.uid())
-- Substitui o antigo nome+PIN. Rodar UMA vez no Supabase SQL Editor.
-- Idempotente onde possível (drops com IF EXISTS). Banco já tinha 0 palpites.
--
-- PRÉ-REQUISITO no Dashboard (antes ou depois, mas necessário p/ login):
--   Authentication > Sign In / Providers > Google: habilitado, com
--     Client ID + Client Secret vindos do Google Cloud OAuth.
--   Authentication > URL Configuration:
--     Site URL     = https://vinisah.github.io/bolao-solutions/
--     Redirect URLs = https://vinisah.github.io/bolao-solutions/
--                     https://vinisah.github.io/bolao-solutions
--   Google Cloud > Credentials > OAuth client > Authorized redirect URI =
--     https://qowtuqqtdvsgphseqkrg.supabase.co/auth/v1/callback
-- =============================================================================

create extension if not exists pgcrypto;

-- ===== TABELAS BASE (mantidas; criam só em deploy novo) =====
create table if not exists jogos (
  id uuid primary key default gen_random_uuid(),
  grupo text default 'Grupo C',
  time_casa text not null,
  time_fora text not null,
  kickoff timestamptz not null,
  ordem int not null default 0,
  ativo boolean not null default true,
  created_at timestamptz default now()
);
create table if not exists resultados (
  jogo_id uuid primary key references jogos(id) on delete cascade,
  placar_casa smallint not null check (placar_casa between 0 and 99),
  placar_fora smallint not null check (placar_fora between 0 and 99),
  updated_at timestamptz default now()
);
create table if not exists admins (
  user_id uuid primary key references auth.users(id) on delete cascade
);

-- ===== 1. REMOVE O MODELO ANTIGO (nome+PIN) =====
drop function if exists submit_palpite(text, text, uuid, int, int);
drop function if exists claim_name(text, text);
drop view if exists palpites_public;
drop view if exists participants_public;
drop view if exists ranking;
drop trigger if exists trg_palpite_deadline on palpites;
drop table if exists palpites;       -- 0 linhas; recriada com user_id
drop table if exists participants;   -- some secret_hash/nome_norm de vez

-- ===== 2. PROFILES (1 perfil por conta Google) =====
create table if not exists profiles (
  user_id      uuid primary key references auth.users(id) on delete cascade,
  display_name text not null,
  email        text,
  created_at   timestamptz default now()
);
alter table profiles enable row level security;

drop policy if exists profiles_read_self   on profiles;
drop policy if exists profiles_insert_self on profiles;
drop policy if exists profiles_update_self on profiles;
-- e-mails NÃO são públicos: só o dono lê a própria linha; nomes saem por view.
create policy profiles_read_self   on profiles for select to authenticated using (user_id = auth.uid());
create policy profiles_insert_self on profiles for insert to authenticated with check (user_id = auth.uid());
create policy profiles_update_self on profiles for update to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());

revoke select on profiles from anon;
grant select, insert, update on profiles to authenticated;

-- popular profiles a partir do Google (server-side, sem confiar no cliente)
create or replace function handle_auth_user() returns trigger
language plpgsql security definer set search_path = public as $$
declare v_name text;
begin
  v_name := coalesce(
    nullif(trim(NEW.raw_user_meta_data->>'full_name'), ''),
    nullif(trim(NEW.raw_user_meta_data->>'name'), ''),
    nullif(split_part(coalesce(NEW.email,''),'@',1), ''),
    'Participante'
  );
  insert into profiles(user_id, display_name, email)
  values (NEW.id, left(v_name, 40), NEW.email)
  on conflict (user_id) do update
    set display_name = excluded.display_name, email = excluded.email;
  return NEW;
end; $$;
drop trigger if exists on_auth_user_upsert on auth.users;
create trigger on_auth_user_upsert
  after insert or update on auth.users
  for each row execute function handle_auth_user();

-- ===== 3. PALPITES (chaveado em auth.uid()) =====
create table if not exists palpites (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid not null default auth.uid() references auth.users(id) on delete cascade,
  jogo_id     uuid not null references jogos(id) on delete cascade,
  placar_casa smallint not null check (placar_casa between 0 and 99),
  placar_fora smallint not null check (placar_fora between 0 and 99),
  updated_at  timestamptz default now(),
  unique (user_id, jogo_id)          -- 1 palpite por pessoa por jogo
);
alter table palpites enable row level security;

drop policy if exists palpites_read        on palpites;
drop policy if exists palpites_insert_self on palpites;
drop policy if exists palpites_update_self on palpites;

-- leitura pública (placar do bolão é aberto)
create policy palpites_read on palpites for select using (true);

-- INSERT: só autenticado, só a própria uid (default), jogo ativo e ANTES do prazo (relógio do servidor)
create policy palpites_insert_self on palpites for insert to authenticated
  with check (
    user_id = auth.uid()
    and placar_casa between 0 and 99 and placar_fora between 0 and 99
    and exists (select 1 from jogos j where j.id = jogo_id and j.ativo and now() < j.kickoff - interval '1 minute')
  );

-- UPDATE: só a própria linha, não reatribui uid, só antes do prazo
create policy palpites_update_self on palpites for update to authenticated
  using (user_id = auth.uid())
  with check (
    user_id = auth.uid()
    and placar_casa between 0 and 99 and placar_fora between 0 and 99
    and exists (select 1 from jogos j where j.id = jogo_id and j.ativo and now() < j.kickoff - interval '1 minute')
  );
-- (sem policy de DELETE: usuário comum não apaga; só admin via RPC)

grant select on palpites to anon;
grant select, insert, update on palpites to authenticated;

-- ===== 4. TRIGGER DEADLINE (defesa em profundidade) =====
create or replace function enforce_deadline() returns trigger
language plpgsql security definer set search_path = public as $$
declare v_kick timestamptz; v_ativo boolean;
begin
  select kickoff, ativo into v_kick, v_ativo from jogos where id = NEW.jogo_id;
  if v_kick is null or not coalesce(v_ativo,false) or now() >= (v_kick - interval '1 minute') then
    raise exception 'Apostas encerradas para este jogo';
  end if;
  NEW.updated_at := now();
  return NEW;
end; $$;
drop trigger if exists trg_palpite_deadline on palpites;
create trigger trg_palpite_deadline before insert or update on palpites
  for each row execute function enforce_deadline();

-- ===== 5. VIEWS PÚBLICAS (nomes via view; e-mail nunca exposto) =====
create or replace view profiles_public as select user_id, display_name from profiles;
grant select on profiles_public to anon, authenticated;

create or replace view palpites_public as
  select p.id, coalesce(pr.display_name,'Participante') as nome,
         p.jogo_id, p.placar_casa, p.placar_fora, p.updated_at
  from palpites p
  left join profiles pr on pr.user_id = p.user_id;
grant select on palpites_public to anon, authenticated;

-- RANKING: chaveado por user_id (não funde homônimos), mostra display_name,
-- desambigua nomes repetidos só na exibição. Regra 6/3/0 + left join preservados.
create or replace view ranking as
  with scored as (
    select p.user_id,
      case when r.jogo_id is null then 0
           when p.placar_casa = r.placar_casa and p.placar_fora = r.placar_fora then 6
           when sign(p.placar_casa - p.placar_fora) = sign(r.placar_casa - r.placar_fora) then 3
           else 0 end as pts,
      case when r.jogo_id is not null and p.placar_casa = r.placar_casa and p.placar_fora = r.placar_fora then 1 else 0 end as exato
    from palpites p
    left join resultados r on r.jogo_id = p.jogo_id
  ),
  agg as (
    select user_id, coalesce(sum(pts),0)::int as pontos, coalesce(sum(exato),0)::int as exatos
    from scored group by user_id
  ),
  named as (
    select a.user_id, a.pontos, a.exatos,
           coalesce(pr.display_name,'Participante') as display_name,
           count(*)     over (partition by coalesce(pr.display_name,'Participante')) as homonimos,
           row_number() over (partition by coalesce(pr.display_name,'Participante') order by a.user_id) as rn
    from agg a
    left join profiles pr on pr.user_id = a.user_id
  )
  select case when homonimos > 1 and rn > 1 then display_name || ' (' || rn || ')' else display_name end as nome,
         pontos, exatos
  from named
  order by pontos desc, exatos desc, nome asc;
grant select on ranking to anon, authenticated;

-- ===== 6. ADMIN (mantido) =====
create or replace function is_admin() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from admins where user_id = auth.uid());
$$;

drop policy if exists admins_self on admins;
alter table admins enable row level security;
create policy admins_self on admins for select to authenticated using (user_id = auth.uid());

create or replace function set_resultado(p_jogo_id uuid, p_casa int, p_fora int)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'Não autorizado'; end if;
  insert into resultados(jogo_id, placar_casa, placar_fora, updated_at)
  values (p_jogo_id, p_casa, p_fora, now())
  on conflict (jogo_id) do update
    set placar_casa = excluded.placar_casa, placar_fora = excluded.placar_fora, updated_at = now();
end; $$;

create or replace function upsert_jogo(p_id uuid, p_grupo text, p_casa text, p_fora text, p_kickoff timestamptz, p_ordem int)
returns uuid language plpgsql security definer set search_path = public as $$
declare v_id uuid;
begin
  if not is_admin() then raise exception 'Não autorizado'; end if;
  if p_id is null then
    insert into jogos(grupo, time_casa, time_fora, kickoff, ordem)
    values (coalesce(p_grupo,'Grupo C'), p_casa, p_fora, p_kickoff, coalesce(p_ordem,0)) returning id into v_id;
  else
    update jogos set grupo = coalesce(p_grupo, grupo), time_casa = p_casa, time_fora = p_fora,
                     kickoff = p_kickoff, ordem = coalesce(p_ordem, ordem)
    where id = p_id returning id into v_id;
  end if;
  return v_id;
end; $$;

create or replace function delete_jogo(p_id uuid) returns void
language plpgsql security definer set search_path = public as $$
begin if not is_admin() then raise exception 'Não autorizado'; end if;
  delete from jogos where id = p_id; end; $$;

create or replace function admin_delete_palpite(p_id uuid) returns void
language plpgsql security definer set search_path = public as $$
begin if not is_admin() then raise exception 'Não autorizado'; end if;
  delete from palpites where id = p_id; end; $$;

create or replace function clear_all() returns void
language plpgsql security definer set search_path = public as $$
begin if not is_admin() then raise exception 'Não autorizado'; end if;
  delete from palpites; delete from resultados; end; $$;

grant execute on function set_resultado(uuid,int,int)                      to authenticated;
grant execute on function upsert_jogo(uuid,text,text,text,timestamptz,int) to authenticated;
grant execute on function delete_jogo(uuid)                                to authenticated;
grant execute on function admin_delete_palpite(uuid)                       to authenticated;
grant execute on function clear_all()                                      to authenticated;

-- ===== 7. SEED dos jogos (só em banco vazio) =====
insert into jogos(grupo, time_casa, time_fora, kickoff, ordem)
select * from (values
  ('Grupo C', 'Brasil',  'Marrocos', timestamptz '2026-06-13 19:00:00-03', 1),
  ('Grupo C', 'Brasil',  'Haiti',    timestamptz '2026-06-19 21:30:00-03', 2),
  ('Grupo C', 'Escócia', 'Brasil',   timestamptz '2026-06-24 19:00:00-03', 3)
) as seed(grupo, time_casa, time_fora, kickoff, ordem)
where not exists (select 1 from jogos);

-- ===== 8. REALTIME =====
do $$ begin
  begin alter publication supabase_realtime add table palpites;   exception when duplicate_object then null; end;
  begin alter publication supabase_realtime add table resultados; exception when duplicate_object then null; end;
  begin alter publication supabase_realtime add table jogos;      exception when duplicate_object then null; end;
  begin alter publication supabase_realtime add table profiles;   exception when duplicate_object then null; end;
end $$;

-- =============================================================================
-- 9. MIGRAR ADMIN (rodar SEPARADO, depois que o organizador logar 1x com Google)
--    Passo A: pegue o UID Google em Authentication > Users (provider=google) e:
--      insert into admins(user_id) values ('<UID-DO-GOOGLE>') on conflict do nothing;
--    Verifique no app que o painel admin aparece. SÓ ENTÃO:
--    Passo B: delete from admins where user_id = 'c6c5eb59-aafe-4e35-bf4a-e143dbef836a';
-- =============================================================================
