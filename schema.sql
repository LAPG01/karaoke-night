-- Karaoke Night — esquema para Supabase.
-- La clave de admin NO está acá (este archivo es público). Después de correr
-- esto, fijala una vez desde el SQL Editor con:
--   select fijar_clave_admin('tu-clave');

create extension if not exists pgcrypto with schema extensions;

create table if not exists participantes (
  id uuid primary key default gen_random_uuid(),
  nombre text not null check (length(trim(nombre)) > 0),
  cancion text not null check (length(trim(cancion)) > 0),
  orden integer,
  estado text not null default 'pendiente'
    check (estado in ('pendiente', 'cantando', 'listo')),
  created_at timestamptz not null default now()
);

-- Como mucho una persona cantando a la vez.
create unique index if not exists un_solo_cantando
  on participantes ((true)) where estado = 'cantando';

alter table participantes enable row level security;

drop policy if exists "lectura publica" on participantes;
create policy "lectura publica" on participantes
  for select to anon, authenticated
  using (true);

-- Tabla privada: RLS activo y sin políticas = nadie la lee desde el navegador.
create table if not exists config_admin (
  id boolean primary key default true check (id),
  clave_hash text not null
);
alter table config_admin enable row level security;

create or replace function fijar_clave_admin(p_clave text)
returns void
language sql
security definer
set search_path = public, extensions
as $$
  insert into config_admin (id, clave_hash)
  values (true, crypt(p_clave, gen_salt('bf')))
  on conflict (id) do update set clave_hash = excluded.clave_hash;
$$;

create or replace function _clave_admin_valida(p_clave text)
returns boolean
language sql
security definer
set search_path = public, extensions
as $$
  select exists (
    select 1 from config_admin
    where clave_hash = crypt(coalesce(p_clave, ''), clave_hash)
  );
$$;

create or replace function verificar_clave(p_clave text)
returns boolean
language sql
security definer
set search_path = public
as $$
  select _clave_admin_valida(p_clave);
$$;

create or replace function agregar_participante(
  p_clave text, p_nombre text, p_cancion text, p_orden integer default null
)
returns participantes
language plpgsql
security definer
set search_path = public
as $$
declare
  fila participantes;
begin
  if not _clave_admin_valida(p_clave) then
    raise exception 'Clave incorrecta';
  end if;
  insert into participantes (nombre, cancion, orden)
  values (trim(p_nombre), trim(p_cancion), p_orden)
  returning * into fila;
  return fila;
end;
$$;

create or replace function editar_participante(
  p_clave text, p_id uuid, p_nombre text, p_cancion text, p_orden integer default null
)
returns participantes
language plpgsql
security definer
set search_path = public
as $$
declare
  fila participantes;
begin
  if not _clave_admin_valida(p_clave) then
    raise exception 'Clave incorrecta';
  end if;
  update participantes
  set nombre = trim(p_nombre), cancion = trim(p_cancion), orden = p_orden
  where id = p_id
  returning * into fila;
  if fila.id is null then
    raise exception 'Participante no encontrado';
  end if;
  return fila;
end;
$$;

-- Al poner a alguien "cantando", quien estaba cantando pasa a "listo".
create or replace function cambiar_estado(p_clave text, p_id uuid, p_estado text)
returns participantes
language plpgsql
security definer
set search_path = public
as $$
declare
  fila participantes;
begin
  if not _clave_admin_valida(p_clave) then
    raise exception 'Clave incorrecta';
  end if;
  if p_estado = 'cantando' then
    update participantes set estado = 'listo'
    where estado = 'cantando' and id <> p_id;
  end if;
  update participantes set estado = p_estado
  where id = p_id
  returning * into fila;
  if fila.id is null then
    raise exception 'Participante no encontrado';
  end if;
  return fila;
end;
$$;

create or replace function borrar_participante(p_clave text, p_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not _clave_admin_valida(p_clave) then
    raise exception 'Clave incorrecta';
  end if;
  delete from participantes where id = p_id;
end;
$$;

-- Por defecto Postgres deja ejecutar cualquier función a PUBLIC: se cierra
-- todo y se abre solo lo que el navegador necesita.
revoke all on function fijar_clave_admin(text) from public, anon, authenticated;
revoke all on function _clave_admin_valida(text) from public, anon, authenticated;
revoke all on function verificar_clave(text) from public;
revoke all on function agregar_participante(text, text, text, integer) from public;
revoke all on function editar_participante(text, uuid, text, text, integer) from public;
revoke all on function cambiar_estado(text, uuid, text) from public;
revoke all on function borrar_participante(text, uuid) from public;

grant select on participantes to anon, authenticated;
grant execute on function verificar_clave(text) to anon, authenticated;
grant execute on function agregar_participante(text, text, text, integer) to anon, authenticated;
grant execute on function editar_participante(text, uuid, text, text, integer) to anon, authenticated;
grant execute on function cambiar_estado(text, uuid, text) to anon, authenticated;
grant execute on function borrar_participante(text, uuid) to anon, authenticated;

-- Lista en vivo: la pantalla pública se actualiza sola.
do $$
begin
  alter publication supabase_realtime add table participantes;
exception when duplicate_object then null;
end $$;

-- ---------- Votación del público ----------
-- Un voto por dispositivo (identificador aleatorio guardado en el navegador).
create table if not exists votos (
  id uuid primary key default gen_random_uuid(),
  dispositivo uuid not null unique,
  votante text not null check (length(trim(votante)) between 2 and 40),
  participante_id uuid not null references participantes(id) on delete cascade,
  created_at timestamptz not null default now()
);
create index if not exists votos_participante_idx on votos (participante_id);

-- Sin políticas: nadie lee ni escribe la tabla directo desde el navegador.
alter table votos enable row level security;

create or replace function votar(p_dispositivo uuid, p_votante text, p_participante uuid)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  ya uuid;
begin
  if length(trim(coalesce(p_votante, ''))) < 2 then
    raise exception 'Escribí tu nombre';
  end if;
  select participante_id into ya from votos where dispositivo = p_dispositivo;
  if ya is not null then
    raise exception 'Ya votaste';
  end if;
  insert into votos (dispositivo, votante, participante_id)
  values (p_dispositivo, left(trim(p_votante), 40), p_participante);
  return p_participante;
exception
  when unique_violation then raise exception 'Ya votaste';
  when foreign_key_violation then raise exception 'Ese participante ya no está en la lista';
end;
$$;

create or replace function mi_voto(p_dispositivo uuid)
returns uuid
language sql
stable
security definer
set search_path = public
as $$
  select participante_id from votos where dispositivo = p_dispositivo;
$$;

create or replace function resultados(p_clave text)
returns table (participante_id uuid, votos bigint)
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if not _clave_admin_valida(p_clave) then
    raise exception 'Clave incorrecta';
  end if;
  return query
    select v.participante_id, count(*) from votos v group by v.participante_id;
end;
$$;

revoke all on function votar(uuid, text, uuid) from public;
revoke all on function mi_voto(uuid) from public;
revoke all on function resultados(text) from public;
grant execute on function votar(uuid, text, uuid) to anon, authenticated;
grant execute on function mi_voto(uuid) to anon, authenticated;
grant execute on function resultados(text) to anon, authenticated;
