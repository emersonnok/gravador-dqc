-- Gravador DQC: estrutura do banco no Supabase
-- Rode este arquivo inteiro uma vez no SQL Editor do projeto.

create extension if not exists pgcrypto;

-- 1) Tabelas ---------------------------------------------------------------

create table if not exists public.gravador_sessoes (
  id uuid primary key default gen_random_uuid(),
  codigo text unique not null,
  titulo text not null,
  estado text not null default 'aguardando'
    check (estado in ('aguardando', 'gravando', 'encerrada')),
  cancelar_eco boolean not null default false,
  criada_em timestamptz not null default now(),
  iniciada_em timestamptz,
  encerrada_em timestamptz
);

create table if not exists public.gravador_participantes (
  id uuid primary key default gen_random_uuid(),
  sessao_id uuid not null references public.gravador_sessoes(id) on delete cascade,
  chave uuid not null default gen_random_uuid(),
  nome text not null,
  status text not null default 'pronto',
  microfone text,
  navegador text,
  entrou_em timestamptz not null default now(),
  gravacao_iniciou_em timestamptz,
  partes_enviadas int not null default 0,
  partes_pendentes int not null default 0,
  nivel real not null default 0,
  ultimo_sinal timestamptz not null default now(),
  erro text
);

create index if not exists gravador_participantes_sessao_idx on public.gravador_participantes (sessao_id);

-- Quem pode usar o painel
create table if not exists public.gravador_admins (
  user_id uuid primary key references auth.users(id) on delete cascade
);

alter table public.gravador_sessoes enable row level security;
alter table public.gravador_participantes enable row level security;
alter table public.gravador_admins enable row level security;

revoke all on public.gravador_sessoes, public.gravador_participantes, public.gravador_admins from anon;
grant select, insert, update, delete on public.gravador_sessoes, public.gravador_participantes to authenticated;

-- 2) Funcoes de apoio --------------------------------------------------------

create or replace function public.gravador_eh_admin() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.gravador_admins where user_id = auth.uid());
$$;

create or replace function public.gravador_agora_ms() returns double precision
language sql volatile as $$
  select extract(epoch from clock_timestamp()) * 1000;
$$;

-- 3) Regras do painel (so o admin enxerga e altera) --------------------------

drop policy if exists "gravador admin sessoes" on public.gravador_sessoes;
create policy "gravador admin sessoes" on public.gravador_sessoes
  for all to authenticated using (public.gravador_eh_admin()) with check (public.gravador_eh_admin());

drop policy if exists "gravador admin participantes" on public.gravador_participantes;
create policy "gravador admin participantes" on public.gravador_participantes
  for all to authenticated using (public.gravador_eh_admin()) with check (public.gravador_eh_admin());

-- 4) Funcoes usadas pela pagina do convidado ---------------------------------
-- O convidado nao acessa as tabelas. Ele so consegue chamar estas funcoes.

create or replace function public.gravador_ver_sessao(p_codigo text) returns json
language plpgsql security definer set search_path = public as $$
declare s public.gravador_sessoes;
begin
  select * into s from public.gravador_sessoes where codigo = p_codigo;
  if not found then
    return json_build_object('erro', 'sessao_nao_encontrada');
  end if;
  return json_build_object(
    'titulo', s.titulo, 'estado', s.estado,
    'cancelar_eco', s.cancelar_eco, 'agora_ms', public.gravador_agora_ms());
end $$;

create or replace function public.gravador_entrar(
  p_codigo text, p_nome text,
  p_microfone text default null, p_navegador text default null
) returns json
language plpgsql security definer set search_path = public as $$
declare s public.gravador_sessoes; p public.gravador_participantes;
begin
  select * into s from public.gravador_sessoes where codigo = p_codigo;
  if not found then
    return json_build_object('erro', 'sessao_nao_encontrada');
  end if;
  if s.estado = 'encerrada' then
    return json_build_object('erro', 'sessao_encerrada');
  end if;
  if coalesce(length(trim(p_nome)), 0) = 0 then
    return json_build_object('erro', 'nome_vazio');
  end if;
  if (select count(*) from public.gravador_participantes where sessao_id = s.id) >= 40 then
    return json_build_object('erro', 'sessao_lotada');
  end if;
  insert into public.gravador_participantes (sessao_id, nome, microfone, navegador)
  values (s.id, left(trim(p_nome), 60), left(p_microfone, 120), left(p_navegador, 200))
  returning * into p;
  return json_build_object(
    'participante_id', p.id, 'chave', p.chave, 'sessao_id', s.id,
    'estado', s.estado, 'agora_ms', public.gravador_agora_ms());
end $$;

create or replace function public.gravador_sinal(
  p_id uuid, p_chave uuid, p_status text,
  p_enviadas int, p_pendentes int, p_nivel real,
  p_inicio_ms double precision default null, p_erro text default null
) returns json
language plpgsql security definer set search_path = public as $$
declare v_estado text;
begin
  update public.gravador_participantes set
    status = left(p_status, 20),
    partes_enviadas = greatest(coalesce(p_enviadas, 0), 0),
    partes_pendentes = greatest(coalesce(p_pendentes, 0), 0),
    nivel = coalesce(p_nivel, 0),
    ultimo_sinal = now(),
    gravacao_iniciou_em = coalesce(gravacao_iniciou_em, to_timestamp(p_inicio_ms / 1000.0)),
    erro = left(p_erro, 200)
  where id = p_id and chave = p_chave;
  if not found then
    return json_build_object('estado', 'invalido', 'agora_ms', public.gravador_agora_ms());
  end if;
  select s.estado into v_estado
  from public.gravador_sessoes s join public.gravador_participantes p on p.sessao_id = s.id
  where p.id = p_id;
  return json_build_object('estado', v_estado, 'agora_ms', public.gravador_agora_ms());
end $$;

-- 5) Funcoes usadas pelo painel ----------------------------------------------

create or replace function public.gravador_painel(p_sessao uuid) returns json
language plpgsql security definer set search_path = public as $$
begin
  if not public.gravador_eh_admin() then
    raise exception 'sem permissao';
  end if;
  return json_build_object(
    'agora', now(),
    'sessao', (select row_to_json(s) from public.gravador_sessoes s where s.id = p_sessao),
    'participantes', coalesce((
      select json_agg(x order by x.entrou_em)
      from (
        select id, nome, status, microfone, navegador, entrou_em, gravacao_iniciou_em,
               partes_enviadas, partes_pendentes, nivel, ultimo_sinal, erro
        from public.gravador_participantes where sessao_id = p_sessao
      ) x
    ), '[]'::json)
  );
end $$;

create or replace function public.gravador_mudar_estado(p_sessao uuid, p_estado text) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.gravador_eh_admin() then
    raise exception 'sem permissao';
  end if;
  update public.gravador_sessoes set
    estado = p_estado,
    iniciada_em = case when p_estado = 'gravando' then coalesce(iniciada_em, now()) else iniciada_em end,
    encerrada_em = case when p_estado = 'encerrada' then now() else encerrada_em end
  where id = p_sessao;
end $$;

revoke execute on function public.gravador_painel(uuid) from public, anon;
revoke execute on function public.gravador_mudar_estado(uuid, text) from public, anon;
grant execute on function public.gravador_ver_sessao(text) to anon, authenticated;
grant execute on function public.gravador_entrar(text, text, text, text) to anon, authenticated;
grant execute on function public.gravador_sinal(uuid, uuid, text, int, int, real, double precision, text) to anon, authenticated;
grant execute on function public.gravador_eh_admin() to anon, authenticated;
grant execute on function public.gravador_painel(uuid) to authenticated;
grant execute on function public.gravador_mudar_estado(uuid, text) to authenticated;

-- 6) Armazenamento dos audios -------------------------------------------------

insert into storage.buckets (id, name, public)
values ('gravador-dqc', 'gravador-dqc', false)
on conflict (id) do nothing;

-- O convidado so pode enviar para a pasta dele: <sessao>/<participante>/<parte>
-- e so enquanto a sessao esta aberta (ou ate 6 horas depois de encerrada,
-- para dar tempo de terminar o envio).
create or replace function public.gravador_pode_enviar(caminho text) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (
    select 1
    from public.gravador_participantes p
    join public.gravador_sessoes s on s.id = p.sessao_id
    where s.id::text = split_part(caminho, '/', 1)
      and p.id::text = split_part(caminho, '/', 2)
      and (s.estado <> 'encerrada' or s.encerrada_em > now() - interval '6 hours')
  );
$$;

grant execute on function public.gravador_pode_enviar(text) to anon, authenticated;

drop policy if exists "gravador envia partes" on storage.objects;
create policy "gravador envia partes" on storage.objects
  for insert to anon, authenticated
  with check (bucket_id = 'gravador-dqc' and public.gravador_pode_enviar(name));

drop policy if exists "gravador admin le" on storage.objects;
create policy "gravador admin le" on storage.objects
  for select to authenticated
  using (bucket_id = 'gravador-dqc' and public.gravador_eh_admin());

drop policy if exists "gravador admin apaga" on storage.objects;
create policy "gravador admin apaga" on storage.objects
  for delete to authenticated
  using (bucket_id = 'gravador-dqc' and public.gravador_eh_admin());

-- 7) Liberar o seu usuario no painel ------------------------------------------
-- Depois de criar o seu usuario em Authentication > Users, rode a linha abaixo
-- trocando pelo seu e-mail:
--
-- insert into public.gravador_admins (user_id)
-- select id from auth.users where email = 'SEU_EMAIL_AQUI';
