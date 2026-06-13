-- ============================================================================
-- Bolão Copa 2026 (Solutions Pinturas) — schema completo
-- Rodar UMA vez no Supabase: SQL Editor > New query > colar tudo > Run.
-- Toda escrita passa por RPC SECURITY DEFINER. As tabelas NÃO têm policy de
-- INSERT/UPDATE/DELETE, então chamadas REST diretas com a anon key são negadas
-- pelo RLS. A trava de horário usa now() do servidor (inviolável pelo cliente).
-- ============================================================================

-- ===== EXTENSÕES =====
create extension if not exists pgcrypto;

-- ===== TABELAS =====
create table if not exists jogos (
  id uuid primary key default gen_random_uuid(),
  grupo text default 'Grupo C',
  time_casa text not null,
  time_fora text not null,
  kickoff timestamptz not null,           -- fonte única do deadline (UTC)
  ordem int not null default 0,
  ativo boolean not null default true,
  created_at timestamptz default now()
);

create table if not exists participants (
  id uuid primary key default gen_random_uuid(),
  nome_norm text unique not null,         -- lower(trim(nome)) = identidade
  display_name text not null,
  secret_hash text not null,              -- sha256 do PIN por nome
  created_at timestamptz default now()
);

create table if not exists palpites (
  id uuid primary key default gen_random_uuid(),
  participant_id uuid not null references participants(id) on delete cascade,
  jogo_id uuid not null references jogos(id) on delete cascade,
  placar_casa smallint not null check (placar_casa between 0 and 99),
  placar_fora smallint not null check (placar_fora between 0 and 99),
  updated_at timestamptz default now(),
  unique (participant_id, jogo_id)        -- = upsert por (nome, jogo) do app original
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

-- ===== RLS LIGADO EM TUDO =====
alter table jogos        enable row level security;
alter table participants enable row level security;
alter table palpites     enable row level security;
alter table resultados   enable row level security;
alter table admins       enable row level security;

-- ===== LEITURA PÚBLICA (sem nenhuma policy de escrita) =====
drop policy if exists jogos_read       on jogos;
drop policy if exists palpites_read    on palpites;
drop policy if exists resultados_read  on resultados;
drop policy if exists admins_self      on admins;

create policy jogos_read       on jogos       for select using (true);
create policy palpites_read    on palpites    for select using (true);
create policy resultados_read  on resultados  for select using (true);
create policy admins_self      on admins      for select to authenticated using (user_id = auth.uid());

-- participants: esconder secret_hash (não dar SELECT direto na tabela)
revoke select on participants from anon, authenticated;

-- ===== VIEWS PÚBLICAS (em PG15 rodam como dono = leitura controlada) =====
create or replace view participants_public as
  select id, display_name, nome_norm from participants;
grant select on participants_public to anon, authenticated;

create or replace view palpites_public as
  select p.id, pa.display_name as nome, p.jogo_id, p.placar_casa, p.placar_fora, p.updated_at
  from palpites p
  join participants pa on pa.id = p.participant_id;
grant select on palpites_public to anon, authenticated;

-- ===== RANKING SERVER-SIDE (reproduz a regra: 6 exato / 3 vencedor-empate / 0) =====
-- left join => quem já palpitou mas ainda não tem resultado aparece com 0 (igual app original)
create or replace view ranking as
  with scored as (
    select pa.display_name as nome,
      case
        when r.jogo_id is null then 0
        when p.placar_casa = r.placar_casa and p.placar_fora = r.placar_fora then 6
        when sign(p.placar_casa - p.placar_fora) = sign(r.placar_casa - r.placar_fora) then 3
        else 0
      end as pts,
      case
        when r.jogo_id is not null and p.placar_casa = r.placar_casa and p.placar_fora = r.placar_fora
        then 1 else 0
      end as exato
    from palpites p
    join participants pa on pa.id = p.participant_id
    left join resultados r on r.jogo_id = p.jogo_id
  )
  select nome,
         coalesce(sum(pts),0)::int   as pontos,
         coalesce(sum(exato),0)::int as exatos
  from scored
  group by nome
  order by pontos desc, exatos desc, nome asc;
grant select on ranking to anon, authenticated;

-- ===== HELPER ADMIN =====
create or replace function is_admin() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from admins where user_id = auth.uid());
$$;

-- ===== RPC: reivindicar/validar nome (PIN mín. 6) =====
create or replace function claim_name(p_nome text, p_secret text)
returns uuid language plpgsql security definer set search_path = public, extensions as $$
declare v_norm text := lower(trim(p_nome)); v_id uuid; v_hash text;
begin
  if length(coalesce(trim(p_nome),'')) = 0 or length(coalesce(p_nome,'')) > 40 then
    raise exception 'Nome inválido';
  end if;
  if length(coalesce(p_secret,'')) < 6 then
    raise exception 'PIN deve ter ao menos 6 caracteres';
  end if;
  v_hash := encode(digest(p_secret,'sha256'),'hex');
  select id into v_id from participants where nome_norm = v_norm;
  if v_id is null then
    insert into participants(nome_norm, display_name, secret_hash)
    values (v_norm, trim(p_nome), v_hash) returning id into v_id;
  elsif not exists (select 1 from participants where id = v_id and secret_hash = v_hash) then
    raise exception 'Esse nome já está em uso. PIN incorreto.';
  end if;
  return v_id;
end; $$;

-- ===== RPC: lançar/editar palpite (deadline + dono checados aqui) =====
create or replace function submit_palpite(p_nome text, p_secret text, p_jogo_id uuid, p_casa int, p_fora int)
returns void language plpgsql security definer set search_path = public as $$
declare v_pid uuid; v_kick timestamptz;
begin
  v_pid := claim_name(p_nome, p_secret);
  select kickoff into v_kick from jogos where id = p_jogo_id and ativo;
  if v_kick is null then raise exception 'Jogo inexistente'; end if;
  if now() >= (v_kick - interval '1 minute') then
    raise exception 'Apostas encerradas para este jogo';
  end if;
  if p_casa < 0 or p_fora < 0 or p_casa > 99 or p_fora > 99 then
    raise exception 'Placar inválido';
  end if;
  insert into palpites(participant_id, jogo_id, placar_casa, placar_fora, updated_at)
  values (v_pid, p_jogo_id, p_casa, p_fora, now())
  on conflict (participant_id, jogo_id) do update
    set placar_casa = excluded.placar_casa,
        placar_fora = excluded.placar_fora,
        updated_at  = now();
end; $$;

-- ===== Trigger reforço (mesma trava, defesa em profundidade) =====
create or replace function enforce_deadline() returns trigger
language plpgsql security definer set search_path = public as $$
declare v_kick timestamptz;
begin
  select kickoff into v_kick from jogos where id = NEW.jogo_id;
  if v_kick is null or now() >= (v_kick - interval '1 minute') then
    raise exception 'Apostas encerradas para este jogo';
  end if;
  return NEW;
end; $$;

drop trigger if exists trg_palpite_deadline on palpites;
create trigger trg_palpite_deadline before insert or update on palpites
  for each row execute function enforce_deadline();

-- ===== RPCs ADMIN (gated por is_admin) =====
create or replace function set_resultado(p_jogo_id uuid, p_casa int, p_fora int)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'Não autorizado'; end if;
  insert into resultados(jogo_id, placar_casa, placar_fora, updated_at)
  values (p_jogo_id, p_casa, p_fora, now())
  on conflict (jogo_id) do update
    set placar_casa = excluded.placar_casa,
        placar_fora = excluded.placar_fora,
        updated_at  = now();
end; $$;

create or replace function upsert_jogo(p_id uuid, p_grupo text, p_casa text, p_fora text, p_kickoff timestamptz, p_ordem int)
returns uuid language plpgsql security definer set search_path = public as $$
declare v_id uuid;
begin
  if not is_admin() then raise exception 'Não autorizado'; end if;
  if p_id is null then
    insert into jogos(grupo, time_casa, time_fora, kickoff, ordem)
    values (coalesce(p_grupo,'Grupo C'), p_casa, p_fora, p_kickoff, coalesce(p_ordem,0))
    returning id into v_id;
  else
    update jogos set grupo = coalesce(p_grupo, grupo),
                     time_casa = p_casa,
                     time_fora = p_fora,
                     kickoff = p_kickoff,
                     ordem = coalesce(p_ordem, ordem)
    where id = p_id returning id into v_id;
  end if;
  return v_id;
end; $$;

create or replace function delete_jogo(p_id uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'Não autorizado'; end if;
  delete from jogos where id = p_id;   -- cascata: palpites + resultado do jogo
end; $$;

create or replace function admin_delete_palpite(p_id uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'Não autorizado'; end if;
  delete from palpites where id = p_id;
end; $$;

create or replace function clear_all() returns void
language plpgsql security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'Não autorizado'; end if;
  delete from palpites;
  delete from resultados;   -- "Limpar tudo" (mantém jogos e nomes)
end; $$;

-- ===== GRANTS DE EXECUÇÃO =====
grant execute on function claim_name(text,text)                              to anon, authenticated;
grant execute on function submit_palpite(text,text,uuid,int,int)             to anon, authenticated;
grant execute on function set_resultado(uuid,int,int)                        to authenticated;
grant execute on function upsert_jogo(uuid,text,text,text,timestamptz,int)   to authenticated;
grant execute on function delete_jogo(uuid)                                  to authenticated;
grant execute on function admin_delete_palpite(uuid)                         to authenticated;
grant execute on function clear_all()                                        to authenticated;

-- ===== SEED dos 3 jogos (datas do HTML, BRT = UTC-3; o admin ajusta/cria depois) =====
insert into jogos(grupo, time_casa, time_fora, kickoff, ordem)
select * from (values
  ('Grupo C', 'Brasil',  'Marrocos', timestamptz '2026-06-13 19:00:00-03', 1),
  ('Grupo C', 'Brasil',  'Haiti',    timestamptz '2026-06-19 21:30:00-03', 2),
  ('Grupo C', 'Escócia', 'Brasil',   timestamptz '2026-06-24 19:00:00-03', 3)
) as seed(grupo, time_casa, time_fora, kickoff, ordem)
where not exists (select 1 from jogos);   -- só semeia em banco vazio

-- ===== REALTIME =====
-- adiciona as tabelas à publicação (ignora se já estiverem)
do $$
begin
  begin alter publication supabase_realtime add table palpites;   exception when duplicate_object then null; end;
  begin alter publication supabase_realtime add table resultados; exception when duplicate_object then null; end;
  begin alter publication supabase_realtime add table jogos;      exception when duplicate_object then null; end;
end $$;
