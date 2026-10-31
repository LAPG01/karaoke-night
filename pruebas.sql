-- Pruebas automáticas de la base. Se pegan en Supabase > SQL Editor y se corren.
-- Trabajan sobre datos de prueba y al terminar SIEMPRE deshacen todo (el
-- "error" final es a propósito: así no queda nada escrito).
--   "PRUEBAS OK: …"     → todo bien
--   "FALLÓ: …"          → qué prueba no dio lo esperado
do $$
declare
  t text := '00000000-0000-4000-8000-00000000cafe';  -- sesión de admin de prueba
  d1 uuid := '00000000-0000-4000-8000-000000000d01';  -- identificador guardado en cada navegador
  d2 uuid := '00000000-0000-4000-8000-000000000d02';
  d3 uuid := '00000000-0000-4000-8000-000000000d03';
  d4 uuid := '00000000-0000-4000-8000-000000000d04';
  hu1 text := 'huella-celular-uno-0000000000000001';  -- huella de hardware de cada celular
  hu2 text := 'huella-celular-dos-0000000000000002';
  hu3 text := 'huella-celular-tres-000000000000003';
  ok integer := 0;
  comp_a integer;
  comp_b integer;
  h json;
  r json;
  fila text;
begin
  -- Todos los celulares de prueba entran por el WiFi del lugar (misma IP).
  perform set_config('request.headers', '{"cf-connecting-ip": "10.0.0.1"}', true);

  -- Punto de partida limpio (todo se deshace al final).
  insert into sesiones_admin (token) values (t::uuid);
  if not (select votacion_abierta from evento where id) then perform reabrir_votacion(t); end if;
  perform nueva_competencia(t, true);
  comp_a := (select competencia_id from evento where id);

  -- ===== Turnos =====
  perform agregar_participante(t, 'Ana', 'Canción A', null);
  perform agregar_participante(t, 'Beto', 'Canción B', null);
  perform agregar_participante(t, 'Caro', 'Canción C', 1);
  fila := (select string_agg(orden || ':' || nombre, ',' order by orden) from participantes);
  if fila <> '1:Caro,2:Ana,3:Beto' then raise exception 'FALLÓ turnos al agregar en 1: %', fila; end if;
  ok := ok + 1;

  perform agregar_participante(t, 'Dani', 'Canción D', 99);
  if (select orden from participantes where nombre = 'Dani') <> 4 then raise exception 'FALLÓ turno 99 debía ir al final'; end if;
  ok := ok + 1;

  perform editar_participante(t, (select id from participantes where nombre = 'Dani'), 'Dani', 'Canción D', 2);
  fila := (select string_agg(orden || ':' || nombre, ',' order by orden) from participantes);
  if fila <> '1:Caro,2:Dani,3:Ana,4:Beto' then raise exception 'FALLÓ mover a Dani al 2: %', fila; end if;
  ok := ok + 1;

  perform borrar_participante(t, (select id from participantes where nombre = 'Dani'));
  fila := (select string_agg(orden || ':' || nombre, ',' order by orden) from participantes);
  if fila <> '1:Caro,2:Ana,3:Beto' then raise exception 'FALLÓ borrar debía hacer subir al resto: %', fila; end if;
  ok := ok + 1;

  -- ===== Votos: tres celulares distintos en el mismo WiFi votan sin problema =====
  r := votar(d1, 'Votante Uno', (select id from participantes where nombre = 'Ana'), hu1);
  if not (r ->> 'ok')::boolean then raise exception 'FALLÓ voto 1: %', r; end if;
  r := votar(d2, 'Votante Dos', (select id from participantes where nombre = 'Ana'), hu2);
  if not (r ->> 'ok')::boolean then raise exception 'FALLÓ celulares distintos en el mismo WiFi deben poder votar: %', r; end if;
  r := votar(d3, 'Votante Tres', (select id from participantes where nombre = 'Beto'), hu3);
  if not (r ->> 'ok')::boolean then raise exception 'FALLÓ voto 3: %', r; end if;
  ok := ok + 1;

  begin
    perform votar(d1, 'Votante Uno', (select id from participantes where nombre = 'Beto'), hu1);
    raise exception 'FALLÓ un navegador pudo votar dos veces';
  exception when others then
    if sqlerrm not like '%Ya votaste%' then raise; end if;
  end;
  ok := ok + 1;

  -- ===== Fraude: mismo celular, otro navegador / incógnito (nuevo identificador, misma huella e IP) =====
  r := votar(d4, 'Otro Nombre', (select id from participantes where nombre = 'Beto'), hu1);
  if (r ->> 'ok')::boolean or r ->> 'motivo' <> 'mismo_celular' then
    raise exception 'FALLÓ mismo celular en incógnito debía bloquearse: %', r;
  end if;
  if (select count(*) from votos) <> 3 then raise exception 'FALLÓ el voto bloqueado se contó'; end if;
  if (select coincide_con from votos_bloqueados where dispositivo = d4) <> 'Votante Uno' then
    raise exception 'FALLÓ el intento bloqueado no quedó registrado para el admin';
  end if;
  ok := ok + 1;

  -- Reintentar desde el mismo navegador bloqueado no duplica el registro.
  perform votar(d4, 'Otro Nombre', (select id from participantes where nombre = 'Caro'), hu1);
  if (select count(*) from votos_bloqueados where dispositivo = d4) <> 1 then
    raise exception 'FALLÓ los reintentos duplicaron el registro de bloqueados';
  end if;
  ok := ok + 1;

  -- Sin huella (página vieja o llamada directa) no se puede votar.
  begin
    perform votar(gen_random_uuid(), 'Sin Huella', (select id from participantes where nombre = 'Ana'), null);
    raise exception 'FALLÓ se pudo votar sin huella';
  exception when others then
    if sqlerrm not like '%Actualizá la página%' then raise; end if;
  end;
  ok := ok + 1;

  -- Mismo modelo de celular (misma huella) pero en otra red: es otra persona, puede votar.
  perform set_config('request.headers', '{"cf-connecting-ip": "200.1.1.1"}', true);
  r := votar(gen_random_uuid(), 'Votante Datos', (select id from participantes where nombre = 'Caro'), hu1);
  if not (r ->> 'ok')::boolean then raise exception 'FALLÓ misma huella en otra red debía poder votar: %', r; end if;
  if (select ip from votos where votante = 'Votante Datos') <> '200.1.1.1' then
    raise exception 'FALLÓ no se guardó la IP del voto';
  end if;
  perform set_config('request.headers', '{"cf-connecting-ip": "10.0.0.1"}', true);
  ok := ok + 1;

  -- ===== Moderación del admin =====
  h := votos_admin(t);
  if json_array_length(h -> 'votos') <> 4 or json_array_length(h -> 'bloqueados') <> 1 then
    raise exception 'FALLÓ votos_admin: %', h;
  end if;
  ok := ok + 1;

  -- Falso positivo: el admin acepta el intento y se cuenta como voto.
  perform aceptar_bloqueado(t, (select id from votos_bloqueados where dispositivo = d4));
  if (select count(*) from votos) <> 5 or (select count(*) from votos_bloqueados) <> 0
     or (select p.nombre from votos v join participantes p on p.id = v.participante_id where v.dispositivo = d4) <> 'Caro' then
    raise exception 'FALLÓ aceptar un intento bloqueado';
  end if;
  ok := ok + 1;

  -- Anular un voto sospechoso.
  perform anular_voto(t, (select id from votos where votante = 'Votante Datos'));
  if (select count(*) from votos) <> 4 then raise exception 'FALLÓ anular un voto'; end if;
  ok := ok + 1;

  -- Descartar un intento.
  perform quitar_voto(d3);
  r := votar(d3, 'Votante Tres', (select id from participantes where nombre = 'Caro'), hu3);
  r := votar(gen_random_uuid(), 'Tramposo', (select id from participantes where nombre = 'Caro'), hu3);
  if (r ->> 'ok')::boolean then raise exception 'FALLÓ segundo intento del celular 3 debía bloquearse'; end if;
  perform descartar_bloqueado(t, (select id from votos_bloqueados where votante = 'Tramposo'));
  if (select count(*) from votos_bloqueados) <> 0 then raise exception 'FALLÓ descartar un intento'; end if;
  ok := ok + 1;

  -- Cambiar el propio voto sigue funcionando (deshacer libera la huella).
  if (select count(*) from votos where dispositivo = d3) <> 1
     or (select p.nombre from votos v join participantes p on p.id = v.participante_id where v.dispositivo = d3) <> 'Caro' then
    raise exception 'FALLÓ cambiar el voto';
  end if;
  ok := ok + 1;

  -- ===== Cerrar votación → se guarda en el historial =====
  perform cerrar_votacion(t);
  begin
    perform votar(gen_random_uuid(), 'Tarde', (select id from participantes where nombre = 'Ana'), 'huella-tarde-00000000000000000');
    raise exception 'FALLÓ se pudo votar con la votación cerrada';
  exception when others then
    if sqlerrm not like '%cerrada%' then raise; end if;
  end;
  begin
    perform quitar_voto(d1);
    raise exception 'FALLÓ se pudo deshacer un voto con la votación cerrada';
  exception when others then
    if sqlerrm not like '%cerrada%' then raise; end if;
  end;
  begin
    perform anular_voto(t, (select id from votos where dispositivo = d1));
    raise exception 'FALLÓ se pudo anular un voto con la votación cerrada';
  exception when others then
    if sqlerrm not like '%cerrada%' then raise; end if;
  end;
  ok := ok + 1;

  -- Votos finales: Ana 2 (d1, d2), Caro 2 (d3, d4). Empate en el primer puesto.
  if (select count(*) from historial_participantes where competencia_id = comp_a) <> 3
     or (select count(*) from historial_votos where competencia_id = comp_a) <> 4
     or (select count(*) from historial_participantes where competencia_id = comp_a and puesto = 1) <> 2
     or (select votos from historial_participantes where competencia_id = comp_a and nombre = 'Ana') <> 2 then
    raise exception 'FALLÓ el historial al cerrar la votación';
  end if;
  ok := ok + 1;

  -- ===== Revelación: solo sale lo revelado =====
  perform revelar_siguiente(t);
  if json_array_length(estado_revelacion() -> 'puestos') <> 1 then
    raise exception 'FALLÓ la revelación mostró más de lo revelado';
  end if;
  ok := ok + 1;

  -- ===== Reabrir, votar más y volver a cerrar: el historial se actualiza sin duplicar =====
  perform reabrir_votacion(t);
  perform votar(gen_random_uuid(), 'Votante Cuatro', (select id from participantes where nombre = 'Beto'), 'huella-celular-cuatro-00000000004');
  perform cerrar_votacion(t);
  if (select count(*) from historial_votos where competencia_id = comp_a) <> 5
     or (select count(*) from historial_participantes where competencia_id = comp_a) <> 3 then
    raise exception 'FALLÓ volver a cerrar debía actualizar el historial sin duplicar';
  end if;
  ok := ok + 1;

  -- Borrar participantes después de cerrar no toca el historial.
  perform borrar_participante(t, (select id from participantes where nombre = 'Caro'));
  if (select count(*) from historial_participantes where competencia_id = comp_a) <> 3 then
    raise exception 'FALLÓ borrar después de cerrar alteró el historial';
  end if;
  ok := ok + 1;

  -- ===== Nueva competencia: limpia todo y conserva el historial =====
  -- Un intento bloqueado pendiente (la votación sigue cerrada: no se re-guarda la competencia).
  insert into votos_bloqueados (dispositivo, votante, participante_id, huella, ip, coincide_con)
  values (gen_random_uuid(), 'Tramposo', (select id from participantes where nombre = 'Ana'), hu1, '10.0.0.1', 'Votante Uno');
  perform nueva_competencia(t, true);
  comp_b := (select competencia_id from evento where id);
  if comp_b = comp_a
     or (select count(*) from participantes) <> 0
     or (select count(*) from votos) <> 0
     or (select count(*) from votos_bloqueados) <> 0
     or not (select votacion_abierta from evento where id)
     or (select count(*) from historial_participantes where competencia_id = comp_a) <> 3
     or (select termino from competencias where id = comp_a) is null then
    raise exception 'FALLÓ nueva competencia';
  end if;
  ok := ok + 1;

  -- ===== Otra ronda sin haber cerrado: igual se guarda antes de limpiar =====
  perform agregar_participante(t, 'Eli', 'Canción E', null);
  perform agregar_participante(t, 'Fede', 'Canción F', null);
  perform cambiar_estado(t, (select id from participantes where nombre = 'Eli'), 'cantando');
  perform votar(d1, 'Votante Uno', (select id from participantes where nombre = 'Fede'), hu1);
  perform nueva_competencia(t, false);
  if (select count(*) from historial_votos where competencia_id = comp_b) <> 1
     or (select count(*) from participantes) <> 2
     or exists (select 1 from participantes where estado <> 'pendiente')
     or (select count(*) from votos) <> 0 then
    raise exception 'FALLÓ otra ronda';
  end if;
  ok := ok + 1;

  -- Una competencia vacía no ensucia el historial.
  perform nueva_competencia(t, true);
  perform nueva_competencia(t, true);
  h := historial(t);
  if json_array_length(h) <> (select count(distinct competencia_id) from historial_participantes) then
    raise exception 'FALLÓ quedaron competencias vacías en el historial';
  end if;
  ok := ok + 1;

  -- ===== Seguridad =====
  begin
    perform historial('pase-inventado');
    raise exception 'FALLÓ se pudo ver el historial sin sesión';
  exception when others then
    if sqlerrm not like '%Clave incorrecta%' then raise; end if;
  end;
  begin
    perform votos_admin('pase-inventado');
    raise exception 'FALLÓ se pudo moderar sin sesión';
  exception when others then
    if sqlerrm not like '%Clave incorrecta%' then raise; end if;
  end;
  set local role anon;
  if (select count(*) from historial_votos) <> 0
     or (select count(*) from historial_participantes) <> 0
     or (select count(*) from votos_bloqueados) <> 0 then
    raise exception 'FALLÓ el público puede leer datos privados';
  end if;
  begin
    insert into participantes (nombre, cancion, orden) values ('Intruso', 'x', 99);
    raise exception 'FALLÓ el público pudo escribir en participantes';
  exception when insufficient_privilege then null;
  end;
  begin
    insert into votos (dispositivo, votante, participante_id) values (gen_random_uuid(), 'Intruso', gen_random_uuid());
    raise exception 'FALLÓ el público pudo meter un voto directo, sin pasar por las reglas';
  exception when insufficient_privilege then null;
  end;
  reset role;
  ok := ok + 1;

  raise exception 'PRUEBAS OK: % de % pasaron (todo se deshizo, tus datos quedaron intactos)', ok, ok;
end $$;
