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

-- ---------- Pantalla pública: todo en una consulta ----------
-- Con 100-200 celulares consultando cada ~4 s (en vez de conexiones en vivo,
-- que en el plan gratis topan en 200 y 100 mensajes/s), juntar participantes
-- y revelación en una sola llamada reduce a la mitad los pedidos.
create or replace function estado_publico()
returns json
language sql
stable
security definer
set search_path = public
as $$
  select json_build_object(
    'participantes', coalesce((
      select json_agg(json_build_object(
        'id', p.id, 'nombre', p.nombre, 'cancion', p.cancion,
        'orden', p.orden, 'estado', p.estado, 'created_at', p.created_at)
        order by p.orden nulls last, p.created_at)
      from participantes p
    ), '[]'::json),
    'revelacion', estado_revelacion()
  );
$$;

revoke all on function estado_publico() from public;
grant execute on function estado_publico() to anon, authenticated;

-- ---------- Cambiar el voto ----------
-- Deshacer el propio voto (para votar a otro). Solo con la votación abierta:
-- una vez cerrada, el ranking ya está congelado.
create or replace function quitar_voto(p_dispositivo uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not (select votacion_abierta from evento where id) then
    raise exception 'La votación está cerrada';
  end if;
  delete from votos where dispositivo = p_dispositivo;
end;
$$;

revoke all on function quitar_voto(uuid) from public;
grant execute on function quitar_voto(uuid) to anon, authenticated;

-- ---------- "orden" = turno en la fila (1..n, sin huecos ni repetidos) ----------
-- Agregar en el turno N corre un lugar a quien estaba en N y a los de abajo;
-- editar mueve y reacomoda; borrar hace subir a los de abajo.
alter table participantes alter column orden set not null;
alter table participantes drop constraint if exists turno_unico;
-- Se verifica al final de cada sentencia, así se pueden correr varios turnos de una.
alter table participantes add constraint turno_unico unique (orden) deferrable initially immediate;

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
  n integer;
  k integer;
begin
  if not _clave_admin_valida(p_clave) then
    raise exception 'Clave incorrecta';
  end if;
  -- Dos admins reordenando a la vez se esperan uno al otro.
  perform pg_advisory_xact_lock(hashtext('karaoke_turnos'));
  select count(*) into n from participantes;
  k := least(greatest(coalesce(p_orden, n + 1), 1), n + 1);
  update participantes set orden = orden + 1 where orden >= k;
  insert into participantes (nombre, cancion, orden)
  values (trim(p_nombre), trim(p_cancion), k)
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
  n integer;
  a integer;
  b integer;
begin
  if not _clave_admin_valida(p_clave) then
    raise exception 'Clave incorrecta';
  end if;
  perform pg_advisory_xact_lock(hashtext('karaoke_turnos'));
  select orden into a from participantes where id = p_id;
  if a is null then
    raise exception 'Participante no encontrado';
  end if;
  select count(*) into n from participantes;
  b := least(greatest(coalesce(p_orden, a), 1), n);
  -- Una sola sentencia: la restricción de turno único se revisa al terminarla.
  update participantes
  set orden = case
    when id = p_id then b
    when b < a then orden + 1
    else orden - 1
  end
  where orden between least(a, b) and greatest(a, b);
  update participantes
  set nombre = trim(p_nombre), cancion = trim(p_cancion)
  where id = p_id
  returning * into fila;
  return fila;
end;
$$;

create or replace function borrar_participante(p_clave text, p_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  a integer;
begin
  if not _clave_admin_valida(p_clave) then
    raise exception 'Clave incorrecta';
  end if;
  perform pg_advisory_xact_lock(hashtext('karaoke_turnos'));
  delete from participantes where id = p_id returning orden into a;
  if a is not null then
    update participantes set orden = orden - 1 where orden > a;
  end if;
end;
$$;

-- ---------- Nueva competencia / otra ronda ----------
-- Borra votos y el ranking congelado y reabre la votación. Con
-- p_borrar_participantes también vacía la lista; si no, deja a todos en
-- "pendiente" para otra ronda con la misma gente.
create or replace function nueva_competencia(p_clave text, p_borrar_participantes boolean)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not _clave_admin_valida(p_clave) then
    raise exception 'Clave incorrecta';
  end if;
  perform pg_advisory_xact_lock(hashtext('karaoke_turnos'));
  delete from votos where true;
  delete from ranking_final where true;
  if p_borrar_participantes then
    delete from participantes where true;
  else
    update participantes set estado = 'pendiente' where estado <> 'pendiente';
  end if;
  update evento set votacion_abierta = true, revelados = 0, total_puestos = 0 where id;
end;
$$;

revoke all on function nueva_competencia(text, boolean) from public;
grant execute on function nueva_competencia(text, boolean) to anon, authenticated;

-- ---------- Historial de competencias ----------
-- Cada competencia queda guardada para siempre: participantes (turno, canción,
-- votos, puesto) y cada voto (quién votó a quién y cuándo). Se guarda al
-- cerrar la votación y antes de "Nueva competencia" / "Otra ronda".
create table if not exists competencias (
  id serial primary key,
  empezo timestamptz not null default now(),
  termino timestamptz
);

create table if not exists historial_participantes (
  competencia_id integer not null references competencias(id) on delete cascade,
  turno integer not null,
  nombre text not null,
  cancion text not null,
  votos integer not null,
  puesto integer not null,
  primary key (competencia_id, turno)
);

create table if not exists historial_votos (
  id bigserial primary key,
  competencia_id integer not null references competencias(id) on delete cascade,
  votante text not null,
  participante text not null,
  votado_at timestamptz not null
);
create index if not exists historial_votos_competencia_idx on historial_votos (competencia_id);

-- Privadas: sin políticas, solo se leen con historial() y sesión de admin.
alter table competencias enable row level security;
alter table historial_participantes enable row level security;
alter table historial_votos enable row level security;

alter table evento add column if not exists competencia_id integer references competencias(id);
do $$
declare
  cid integer;
begin
  if (select competencia_id from evento where id) is null then
    insert into competencias default values returning id into cid;
    update evento set competencia_id = cid where id;
  end if;
end $$;
alter table evento alter column competencia_id set not null;

-- Guarda (o reemplaza) la foto de la competencia en curso. Interna: no se expone.
create or replace function _archivar_competencia()
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  cid integer;
begin
  select competencia_id into cid from evento where id;
  delete from historial_participantes where competencia_id = cid;
  delete from historial_votos where competencia_id = cid;
  insert into historial_participantes (competencia_id, turno, nombre, cancion, votos, puesto)
  select cid, p.orden, p.nombre, p.cancion, coalesce(v.n, 0),
         rank() over (order by coalesce(v.n, 0) desc)
  from participantes p
  left join (select participante_id, count(*)::int as n from votos group by participante_id) v
    on v.participante_id = p.id;
  insert into historial_votos (competencia_id, votante, participante, votado_at)
  select cid, v.votante, p.nombre, v.created_at
  from votos v
  join participantes p on p.id = v.participante_id;
end;
$$;
revoke all on function _archivar_competencia() from public, anon, authenticated;

-- Reemplaza la versión de arriba: cerrar la votación también guarda en el historial.
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
  perform _archivar_competencia();
end;
$$;

-- Reemplaza la versión de arriba: guarda antes de limpiar y abre una competencia nueva.
create or replace function nueva_competencia(p_clave text, p_borrar_participantes boolean)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  anterior integer;
  nueva integer;
begin
  if not _clave_admin_valida(p_clave) then
    raise exception 'Clave incorrecta';
  end if;
  perform pg_advisory_xact_lock(hashtext('karaoke_turnos'));
  -- Si estaba cerrada ya se guardó al cerrarla (y quizás cambiaron participantes después).
  if (select votacion_abierta from evento where id) then
    perform _archivar_competencia();
  end if;
  select competencia_id into anterior from evento where id;
  update competencias set termino = now() where id = anterior;

  delete from votos where true;
  delete from ranking_final where true;
  if p_borrar_participantes then
    delete from participantes where true;
  else
    update participantes set estado = 'pendiente' where estado <> 'pendiente';
  end if;

  insert into competencias default values returning id into nueva;
  update evento
  set competencia_id = nueva, votacion_abierta = true, revelados = 0, total_puestos = 0
  where id;
  -- Una competencia sin participantes no aporta nada al historial.
  delete from competencias c
  where c.id = anterior
    and not exists (select 1 from historial_participantes h where h.competencia_id = c.id);
end;
$$;

-- Solo admin: todo el historial, la más reciente primero.
create or replace function historial(p_clave text)
returns json
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  actual integer;
  resultado json;
begin
  if not _clave_admin_valida(p_clave) then
    raise exception 'Clave incorrecta';
  end if;
  select competencia_id into actual from evento where id;
  select coalesce(json_agg(json_build_object(
    'id', c.id,
    'empezo', c.empezo,
    'termino', c.termino,
    'actual', c.id = actual,
    'participantes', (
      select coalesce(json_agg(json_build_object(
        'turno', h.turno, 'nombre', h.nombre, 'cancion', h.cancion,
        'votos', h.votos, 'puesto', h.puesto) order by h.puesto, h.turno), '[]'::json)
      from historial_participantes h where h.competencia_id = c.id),
    'votos', (
      select coalesce(json_agg(json_build_object(
        'votante', v.votante, 'participante', v.participante, 'hora', v.votado_at)
        order by v.votado_at), '[]'::json)
      from historial_votos v where v.competencia_id = c.id)
  ) order by c.id desc), '[]'::json)
  into resultado
  from competencias c
  where exists (select 1 from historial_participantes h where h.competencia_id = c.id);
  return resultado;
end;
$$;

revoke all on function nueva_competencia(text, boolean) from public;
revoke all on function historial(text) from public;
grant execute on function nueva_competencia(text, boolean) to anon, authenticated;
grant execute on function historial(text) to anon, authenticated;
