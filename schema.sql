-- =============================================================================
-- Karaoke Night — esquema completo de la base (Supabase / PostgreSQL 15+)
-- =============================================================================
-- Cómo usarlo en un proyecto nuevo de Supabase:
--   1. SQL Editor > New query > pegar todo este archivo > Run.
--   2. Fijar usuario y contraseña del admin (no van en este archivo, que es público):
--        select fijar_clave_admin('usuario', 'contraseña');
--   3. Probarlo con pruebas.sql (se deshace solo).
--
-- Idea general de la seguridad:
--   * Todas las tablas tienen RLS. El público solo puede LEER participantes y
--     evento; nunca escribe en una tabla directamente.
--   * Todo lo demás pasa por funciones (SECURITY DEFINER) que validan las reglas:
--     las del público (votar, deshacer el voto) y las del admin, que además
--     exigen un pase de sesión válido (_clave_admin_valida).
--   * La clave de admin vive hasheada (bcrypt) en una tabla sin acceso público.
-- =============================================================================

create extension if not exists pgcrypto with schema extensions;


-- =============================================================================
-- 1. Tablas
-- =============================================================================

-- Cada competencia (la de ahora y las del historial).
create table if not exists competencias (
  id serial primary key,
  empezo timestamptz not null default now(),
  termino timestamptz
);

-- Estado del evento: una sola fila (id = true).
create table if not exists evento (
  id boolean primary key default true check (id),
  votacion_abierta boolean not null default true,
  revelados integer not null default 0 check (revelados >= 0),
  total_puestos integer not null default 0 check (total_puestos >= 0),
  competencia_id integer not null references competencias(id)
);

do $$
declare
  cid integer;
begin
  if not exists (select 1 from evento) then
    insert into competencias default values returning id into cid;
    insert into evento (id, competencia_id) values (true, cid);
  end if;
end $$;

-- "orden" es el turno en la fila: 1..n, sin huecos ni repetidos.
create table if not exists participantes (
  id uuid primary key default gen_random_uuid(),
  nombre text not null check (length(trim(nombre)) > 0),
  cancion text not null check (length(trim(cancion)) > 0),
  orden integer not null,
  estado text not null default 'pendiente' check (estado in ('pendiente', 'cantando', 'listo')),
  created_at timestamptz not null default now(),
  -- Diferible: un corrimiento de turnos se valida al terminar la sentencia.
  constraint turno_unico unique (orden) deferrable initially immediate
);
-- Como mucho una persona cantando a la vez.
create unique index if not exists un_solo_cantando on participantes ((true)) where estado = 'cantando';

-- Un voto por navegador (dispositivo) y, además, por celular (huella + IP).
create table if not exists votos (
  id uuid primary key default gen_random_uuid(),
  dispositivo uuid not null unique,
  votante text not null check (length(trim(votante)) between 2 and 40),
  participante_id uuid not null references participantes(id) on delete cascade,
  created_at timestamptz not null default now(),
  huella text,
  ip text,
  senales text[] not null default '{}',  -- señales de navegador falsificado
  pais text                              -- país de la IP según Cloudflare
);
create index if not exists votos_participante_idx on votos (participante_id);
create index if not exists votos_huella_ip_idx on votos (huella, ip);

-- Intentos de votar desde un celular que ya votó: el admin los acepta o descarta.
create table if not exists votos_bloqueados (
  id uuid primary key default gen_random_uuid(),
  dispositivo uuid not null unique,
  votante text not null,
  participante_id uuid not null references participantes(id) on delete cascade,
  huella text not null,
  ip text,
  coincide_con text not null,
  created_at timestamptz not null default now()
);

-- Foto del ranking al cerrar la votación (lo que se revela de a uno).
create table if not exists ranking_final (
  orden integer primary key,
  puesto integer not null,
  nombre text not null,
  cancion text not null,
  votos integer not null,
  participante_id uuid
);

-- Historial: cada competencia, guardada para siempre.
create table if not exists historial_participantes (
  competencia_id integer not null references competencias(id) on delete cascade,
  turno integer not null,
  nombre text not null,
  cancion text not null,
  votos integer not null,
  puesto integer not null,
  participante_id uuid,
  primary key (competencia_id, turno)
);

create table if not exists historial_votos (
  id bigserial primary key,
  competencia_id integer not null references competencias(id) on delete cascade,
  votante text not null,
  participante text not null,
  votado_at timestamptz not null,
  participante_id uuid
);
create index if not exists historial_votos_competencia_idx on historial_votos (competencia_id);

-- Admin: usuario y contraseña (hash bcrypt) y pases de sesión de 24 h.
create table if not exists config_admin (
  id boolean primary key default true check (id),
  usuario text not null,
  clave_hash text not null
);

create table if not exists sesiones_admin (
  token uuid primary key default gen_random_uuid(),
  expira timestamptz not null default now() + interval '24 hours'
);

-- Marca del evento, editable desde el admin. El logo es una imagen (data URI).
create table if not exists marca (
  id boolean primary key default true check (id),
  evento text not null default 'Karaoke Night' check (length(trim(evento)) between 1 and 40),
  organizador text not null default '' check (length(organizador) <= 40),
  logo text check (logo is null or (logo ~ '^data:image/(png|jpeg|webp);base64,[A-Za-z0-9+/=]+$' and length(logo) <= 400000)),
  color_principal text not null default '#e0314b' check (color_principal ~ '^#[0-9a-fA-F]{6}$'),
  color_destacado text not null default '#f6b21a' check (color_destacado ~ '^#[0-9a-fA-F]{6}$'),
  version integer not null default 1
);
insert into marca (id) values (true) on conflict (id) do nothing;


-- =============================================================================
-- 2. Seguridad de las tablas
-- =============================================================================

alter table competencias enable row level security;
alter table evento enable row level security;
alter table participantes enable row level security;
alter table votos enable row level security;
alter table votos_bloqueados enable row level security;
alter table ranking_final enable row level security;
alter table historial_participantes enable row level security;
alter table historial_votos enable row level security;
alter table config_admin enable row level security;
alter table sesiones_admin enable row level security;
alter table marca enable row level security;

-- Lo único que el público lee directo: la lista y el estado del evento.
drop policy if exists "lectura publica" on participantes;
create policy "lectura publica" on participantes for select to anon, authenticated using (true);
drop policy if exists "lectura publica" on evento;
create policy "lectura publica" on evento for select to anon, authenticated using (true);

-- Nadie escribe directo en una tabla: todo pasa por las funciones de abajo.
revoke insert, update, delete, truncate on all tables in schema public from anon, authenticated;
grant select on participantes, evento to anon, authenticated;


-- =============================================================================
-- 3. Funciones internas (no se pueden llamar desde el navegador)
-- =============================================================================

-- IP real del cliente. Cloudflare pisa este encabezado: no se puede falsificar.
create or replace function _ip_cliente()
returns text
language sql
stable
set search_path = public
as $$
  select nullif(current_setting('request.headers', true), '')::json ->> 'cf-connecting-ip';
$$;

-- País de la IP según Cloudflare ("T1" = red Tor, "XX" = desconocido).
create or replace function _pais_cliente()
returns text
language sql
stable
set search_path = public
as $$
  select nullif(current_setting('request.headers', true), '')::json ->> 'cf-ipcountry';
$$;

-- Las funciones de admin reciben en p_clave el pase de sesión, no la contraseña.
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

-- Guarda (o reemplaza) en el historial la foto de la competencia en curso.
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
  insert into historial_participantes (competencia_id, turno, nombre, cancion, votos, puesto, participante_id)
  select cid, p.orden, p.nombre, p.cancion, coalesce(v.n, 0),
         rank() over (order by coalesce(v.n, 0) desc), p.id
  from participantes p
  left join (select participante_id, count(*)::int as n from votos group by participante_id) v
    on v.participante_id = p.id;
  insert into historial_votos (competencia_id, votante, participante, votado_at, participante_id)
  select cid, v.votante, p.nombre, v.created_at, p.id
  from votos v
  join participantes p on p.id = v.participante_id;
end;
$$;


-- =============================================================================
-- 4. API pública (pantalla de los votantes)
-- =============================================================================

-- Lo ya revelado del ranking (se revela del último al primero).
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

-- Todo lo que necesita la pantalla pública en una sola consulta (cada ~4 s).
-- La marca viaja solo como número de versión: el logo pesa y se pide aparte.
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
        order by p.orden, p.created_at)
      from participantes p
    ), '[]'::json),
    'revelacion', estado_revelacion(),
    'marca_version', (select version from marca where id)
  );
$$;

create or replace function marca_publica()
returns json
language sql
stable
security definer
set search_path = public
as $$
  select json_build_object(
    'evento', evento, 'organizador', organizador, 'logo', logo,
    'color_principal', color_principal, 'color_destacado', color_destacado,
    'version', version)
  from marca where id;
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

-- Un voto por navegador y por celular. Misma huella + misma IP que un voto
-- existente = mismo celular (otro navegador o incógnito): no se cuenta y queda
-- como intento bloqueado para que el admin lo acepte o lo descarte.
create or replace function votar(
  p_dispositivo uuid, p_votante text, p_participante uuid, p_huella text,
  p_senales text[] default '{}'
)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  v_ip text := _ip_cliente();
  ya uuid;
  duenio text;
  senales text[];
begin
  if not (select votacion_abierta from evento where id) then
    raise exception 'La votación está cerrada';
  end if;
  if length(trim(coalesce(p_votante, ''))) < 2 then
    raise exception 'Escribí tu nombre';
  end if;
  if length(coalesce(p_huella, '')) < 16 then
    raise exception 'Actualizá la página para poder votar';
  end if;
  -- Solo señales conocidas: lo que llega del navegador no se guarda a ciegas.
  senales := array(
    select distinct s from unnest(coalesce(p_senales, '{}')) s
    where s = any (array['automatizado', 'computadora', 'sin_tactil', 'gpu_pc',
                         'plugins', 'so_no_coincide', 'pantalla', 'zona_horaria'])
  );
  -- Dos pestañas del mismo celular votando a la vez se esperan una a la otra.
  perform pg_advisory_xact_lock(hashtext('voto:' || p_huella || coalesce(v_ip, '')));

  select participante_id into ya from votos where dispositivo = p_dispositivo;
  if ya is not null then
    raise exception 'Ya votaste';
  end if;

  select votante into duenio
  from votos
  where huella = p_huella and ip is not distinct from v_ip
  limit 1;
  if duenio is not null then
    -- Sin raise: el intento tiene que quedar guardado para el admin.
    insert into votos_bloqueados (dispositivo, votante, participante_id, huella, ip, coincide_con)
    values (p_dispositivo, left(trim(p_votante), 40), p_participante, p_huella, v_ip, duenio)
    on conflict (dispositivo) do update
      set votante = excluded.votante,
          participante_id = excluded.participante_id,
          coincide_con = excluded.coincide_con,
          created_at = now();
    return json_build_object('ok', false, 'motivo', 'mismo_celular');
  end if;

  insert into votos (dispositivo, votante, participante_id, huella, ip, senales, pais)
  values (p_dispositivo, left(trim(p_votante), 40), p_participante, p_huella, v_ip, senales, _pais_cliente());
  return json_build_object('ok', true, 'participante', p_participante);
exception
  when unique_violation then raise exception 'Ya votaste';
  when foreign_key_violation then raise exception 'Ese participante ya no está en la lista';
end;
$$;

-- Deshacer el propio voto para votar a otro. Solo con la votación abierta.
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


-- =============================================================================
-- 5. Admin: acceso
-- =============================================================================

-- Solo se corre desde el SQL Editor (no tiene permiso público). Cierra todas las sesiones.
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

-- Devuelve un pase de sesión de 24 h. La contraseña viaja solo esta vez.
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

create or replace function verificar_clave(p_clave text)
returns boolean
language sql
security definer
set search_path = public
as $$
  select _clave_admin_valida(p_clave);
$$;


-- =============================================================================
-- 6. Admin: participantes y turnos
-- =============================================================================

-- Agregar en el turno N corre un lugar a quien estaba en N y a los de abajo.
-- Sin turno (null) o con uno mayor al último: al final.
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

-- Editar: cambiar el turno mueve a la persona y reacomoda a los del medio.
-- El nombre corregido también se corrige en el ranking congelado y el historial.
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

  update ranking_final set nombre = fila.nombre, cancion = fila.cancion where participante_id = p_id;
  update historial_participantes set nombre = fila.nombre, cancion = fila.cancion where participante_id = p_id;
  update historial_votos set participante = fila.nombre where participante_id = p_id;
  return fila;
end;
$$;

-- Borrar: los de abajo suben un lugar.
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


-- =============================================================================
-- 7. Admin: votos y moderación
-- =============================================================================

-- Votos (con sus sospechas) e intentos bloqueados, en una sola consulta.
create or replace function votos_admin(p_clave text)
returns json
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if not _clave_admin_valida(p_clave) then
    raise exception 'Clave incorrecta';
  end if;
  return json_build_object(
    'votos', coalesce((
      select json_agg(json_build_object(
        'id', v.id, 'votante', v.votante, 'participante_id', v.participante_id,
        'created_at', v.created_at,
        'sospechas', array_remove(v.senales || array[
          case
            when v.pais = 'T1' then 'ip_tor'
            when v.pais = 'XX' then 'ip_desconocida'
            when v.pais is not null and v.pais <> 'VE' then 'ip_extranjera:' || v.pais
          end
        ], null)) order by v.created_at desc)
      from votos v), '[]'::json),
    'bloqueados', coalesce((
      select json_agg(json_build_object(
        'id', b.id, 'votante', b.votante, 'participante_id', b.participante_id,
        'coincide_con', b.coincide_con, 'created_at', b.created_at) order by b.created_at desc)
      from votos_bloqueados b), '[]'::json)
  );
end;
$$;

-- Falso positivo (otra persona con el mismo modelo de celular): se cuenta el voto.
create or replace function aceptar_bloqueado(p_clave text, p_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  b votos_bloqueados;
begin
  if not _clave_admin_valida(p_clave) then
    raise exception 'Clave incorrecta';
  end if;
  if not (select votacion_abierta from evento where id) then
    raise exception 'La votación está cerrada';
  end if;
  select * into b from votos_bloqueados where id = p_id;
  if b.id is null then
    raise exception 'Ese intento ya no está';
  end if;
  insert into votos (dispositivo, votante, participante_id, huella, ip)
  values (b.dispositivo, b.votante, b.participante_id, b.huella, b.ip)
  on conflict (dispositivo) do nothing;
  delete from votos_bloqueados where id = p_id;
end;
$$;

create or replace function descartar_bloqueado(p_clave text, p_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not _clave_admin_valida(p_clave) then
    raise exception 'Clave incorrecta';
  end if;
  delete from votos_bloqueados where id = p_id;
end;
$$;

-- Anular un voto sospechoso. Solo con la votación abierta (cerrada, ya está
-- congelada y guardada en el historial).
create or replace function anular_voto(p_clave text, p_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not _clave_admin_valida(p_clave) then
    raise exception 'Clave incorrecta';
  end if;
  if not (select votacion_abierta from evento where id) then
    raise exception 'La votación está cerrada';
  end if;
  delete from votos where id = p_id;
end;
$$;


-- =============================================================================
-- 8. Admin: cierre, revelación, competencias, historial y marca
-- =============================================================================

-- Congela el ranking y lo guarda en el historial.
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
  insert into ranking_final (orden, puesto, nombre, cancion, votos, participante_id)
  select
    row_number() over (order by coalesce(v.n, 0) desc, p.orden, p.created_at),
    rank() over (order by coalesce(v.n, 0) desc),
    p.nombre, p.cancion, coalesce(v.n, 0), p.id
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

-- Nueva competencia (p_borrar_participantes) u otra ronda con los mismos.
-- Antes de limpiar guarda lo que haya, si la votación seguía abierta (si estaba
-- cerrada ya se guardó al cerrarla).
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
  if (select votacion_abierta from evento where id) then
    perform _archivar_competencia();
  end if;
  select competencia_id into anterior from evento where id;
  update competencias set termino = now() where id = anterior;

  delete from votos where true;
  delete from votos_bloqueados where true;
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

-- Todo el historial, la competencia más reciente primero.
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

-- p_logo: null = dejar el que está, '' = quitarlo, data URI = reemplazarlo.
create or replace function guardar_marca(
  p_clave text, p_evento text, p_organizador text, p_logo text,
  p_color_principal text, p_color_destacado text
)
returns json
language plpgsql
security definer
set search_path = public
as $$
begin
  if not _clave_admin_valida(p_clave) then
    raise exception 'Clave incorrecta';
  end if;
  update marca
  set evento = trim(p_evento),
      organizador = trim(coalesce(p_organizador, '')),
      logo = case when p_logo is null then logo when p_logo = '' then null else p_logo end,
      color_principal = lower(p_color_principal),
      color_destacado = lower(p_color_destacado),
      version = version + 1
  where id;
  return marca_publica();
end;
$$;


-- =============================================================================
-- 9. Permisos de ejecución
-- =============================================================================
-- Postgres deja ejecutar cualquier función a PUBLIC por defecto: se cierra todo
-- y se abre solo lo que llama el navegador.

revoke all on all functions in schema public from public, anon, authenticated;

grant execute on function
  estado_publico(),
  estado_revelacion(),
  marca_publica(),
  mi_voto(uuid),
  votar(uuid, text, uuid, text, text[]),
  quitar_voto(uuid),
  iniciar_sesion(text, text),
  cerrar_sesion(text),
  verificar_clave(text),
  agregar_participante(text, text, text, integer),
  editar_participante(text, uuid, text, text, integer),
  borrar_participante(text, uuid),
  cambiar_estado(text, uuid, text),
  votos_admin(text),
  aceptar_bloqueado(text, uuid),
  descartar_bloqueado(text, uuid),
  anular_voto(text, uuid),
  cerrar_votacion(text),
  revelar_siguiente(text),
  reabrir_votacion(text),
  nueva_competencia(text, boolean),
  historial(text),
  guardar_marca(text, text, text, text, text, text)
to anon, authenticated;


-- =============================================================================
-- 10. Tiempo real (el panel de admin se actualiza solo)
-- =============================================================================

do $$
begin
  alter publication supabase_realtime add table participantes;
exception when duplicate_object then null;
end $$;
do $$
begin
  alter publication supabase_realtime add table evento;
exception when duplicate_object then null;
end $$;
