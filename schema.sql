-- Karaoke Night — esquema para Supabase.
-- El usuario y la contraseña del admin NO están acá (este archivo es público).
-- Después de correr todo, fijalos desde el SQL Editor con:
--   select fijar_clave_admin('usuario', 'contraseña');

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

-- Solo admin: quién votó a quién. El ranking se cuenta a partir de esta lista.
create or replace function lista_votos(p_clave text)
returns table (id uuid, votante text, participante_id uuid, created_at timestamptz)
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
    select v.id, v.votante, v.participante_id, v.created_at
    from votos v
    order by v.created_at desc;
end;
$$;

revoke all on function votar(uuid, text, uuid) from public;
revoke all on function mi_voto(uuid) from public;
revoke all on function lista_votos(text) from public;
grant execute on function votar(uuid, text, uuid) to anon, authenticated;
grant execute on function mi_voto(uuid) to anon, authenticated;
grant execute on function lista_votos(text) to anon, authenticated;

-- ---------- Revelación de resultados ----------
-- Estado público del evento: una sola fila.
create table if not exists evento (
  id boolean primary key default true check (id),
  votacion_abierta boolean not null default true,
  revelados integer not null default 0 check (revelados >= 0),
  total_puestos integer not null default 0 check (total_puestos >= 0)
);
insert into evento (id) values (true) on conflict (id) do nothing;

alter table evento enable row level security;
drop policy if exists "lectura publica" on evento;
create policy "lectura publica" on evento for select to anon, authenticated using (true);
grant select on evento to anon, authenticated;

-- Foto del ranking al cerrar la votación. Privada: el público solo recibe
-- lo ya revelado, vía estado_revelacion().
create table if not exists ranking_final (
  orden integer primary key,
  puesto integer not null,
  nombre text not null,
  cancion text not null,
  votos integer not null
);
alter table ranking_final enable row level security;

create or replace function cerrar_votacion(p_clave text)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not _clave_admin_valida(p_clave) then
    raise exception 'Clave incorrecta';
  end if;
  delete from ranking_final where true;
  insert into ranking_final (orden, puesto, nombre, cancion, votos)
  select
    row_number() over (order by coalesce(v.n, 0) desc, p.orden nulls last, p.created_at),
    rank() over (order by coalesce(v.n, 0) desc),
    p.nombre, p.cancion, coalesce(v.n, 0)
  from participantes p
  left join (select participante_id, count(*)::int as n from votos group by participante_id) v
    on v.participante_id = p.id;
  update evento
  set votacion_abierta = false,
      revelados = 0,
      total_puestos = (select count(*) from ranking_final)
  where id;
end;
$$;

create or replace function revelar_siguiente(p_clave text)
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  n integer;
begin
  if not _clave_admin_valida(p_clave) then
    raise exception 'Clave incorrecta';
  end if;
  update evento
  set revelados = least(revelados + 1, total_puestos)
  where id and not votacion_abierta
  returning revelados into n;
  if n is null then
    raise exception 'Primero cerrá la votación';
  end if;
  return n;
end;
$$;

create or replace function reabrir_votacion(p_clave text)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not _clave_admin_valida(p_clave) then
    raise exception 'Clave incorrecta';
  end if;
  delete from ranking_final where true;
  update evento set votacion_abierta = true, revelados = 0, total_puestos = 0 where id;
end;
$$;

-- Público: estado + solo los puestos ya revelados (se revela del último al primero).
create or replace function estado_revelacion()
returns json
language sql
stable
security definer
set search_path = public
as $$
  select json_build_object(
    'votacion_abierta', e.votacion_abierta,
    'revelados', e.revelados,
    'total', e.total_puestos,
    'puestos', coalesce((
      select json_agg(json_build_object(
        'orden', r.orden, 'puesto', r.puesto, 'nombre', r.nombre,
        'cancion', r.cancion, 'votos', r.votos) order by r.orden)
      from ranking_final r
      where r.orden > e.total_puestos - e.revelados
    ), '[]'::json)
  )
  from evento e
  where e.id;
$$;

-- Con la votación cerrada no se aceptan votos (reemplaza la versión de arriba).
create or replace function votar(p_dispositivo uuid, p_votante text, p_participante uuid)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  ya uuid;
begin
  if not (select votacion_abierta from evento where id) then
    raise exception 'La votación está cerrada';
  end if;
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

revoke all on function cerrar_votacion(text) from public;
revoke all on function revelar_siguiente(text) from public;
revoke all on function reabrir_votacion(text) from public;
revoke all on function estado_revelacion() from public;
grant execute on function cerrar_votacion(text) to anon, authenticated;
grant execute on function revelar_siguiente(text) to anon, authenticated;
grant execute on function reabrir_votacion(text) to anon, authenticated;
grant execute on function estado_revelacion() to anon, authenticated;

do $$
begin
  alter publication supabase_realtime add table evento;
exception when duplicate_object then null;
end $$;

-- ---------- Usuario, contraseña y sesiones ----------
-- El login devuelve un pase de sesión (24 h). Las funciones de admin reciben
-- ese pase en p_clave; la contraseña solo viaja una vez, al iniciar sesión.
create table if not exists sesiones_admin (
  token uuid primary key default gen_random_uuid(),
  expira timestamptz not null default now() + interval '24 hours'
);
alter table sesiones_admin enable row level security;

alter table config_admin add column if not exists usuario text;
update config_admin set usuario = 'admin' where usuario is null;
alter table config_admin alter column usuario set not null;

drop function if exists fijar_clave_admin(text);
create or replace function fijar_clave_admin(p_usuario text, p_clave text)
returns void
language sql
security definer
set search_path = public, extensions
as $$
  insert into config_admin (id, usuario, clave_hash)
  values (true, lower(trim(p_usuario)), crypt(p_clave, gen_salt('bf')))
  on conflict (id) do update set usuario = excluded.usuario, clave_hash = excluded.clave_hash;
  delete from sesiones_admin where true;
$$;

create or replace function iniciar_sesion(p_usuario text, p_clave text)
returns uuid
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  t uuid;
begin
  delete from sesiones_admin where expira < now();
  if not exists (
    select 1 from config_admin
    where usuario = lower(trim(coalesce(p_usuario, '')))
      and clave_hash = crypt(coalesce(p_clave, ''), clave_hash)
  ) then
    perform pg_sleep(0.4); -- frena a quien quiera probar claves en serie
    raise exception 'Usuario o contraseña incorrectos';
  end if;
  insert into sesiones_admin default values returning token into t;
  return t;
end;
$$;

create or replace function cerrar_sesion(p_token text)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  delete from sesiones_admin where token = p_token::uuid;
exception when invalid_text_representation then null;
end;
$$;

-- Reemplaza la versión de arriba: ahora valida el pase de sesión.
create or replace function _clave_admin_valida(p_clave text)
returns boolean
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  return exists (select 1 from sesiones_admin where token = p_clave::uuid and expira > now());
exception when invalid_text_representation then
  return false;
end;
$$;

revoke all on function fijar_clave_admin(text, text) from public, anon, authenticated;
revoke all on function _clave_admin_valida(text) from public, anon, authenticated;
revoke all on function iniciar_sesion(text, text) from public;
revoke all on function cerrar_sesion(text) from public;
grant execute on function iniciar_sesion(text, text) to anon, authenticated;
grant execute on function cerrar_sesion(text) to anon, authenticated;
