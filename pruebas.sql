-- Pruebas automáticas de la base. Se pegan en Supabase > SQL Editor y se corren.
-- Trabajan sobre datos de prueba y al terminar SIEMPRE deshacen todo (el
-- "error" final es a propósito: así no queda nada escrito).
--   "PRUEBAS OK: …"     → todo bien
--   "FALLÓ: …"          → qué prueba no dio lo esperado
do $$
declare
  t text := '00000000-0000-4000-8000-00000000cafe';  -- sesión de admin de prueba
  d1 uuid := '00000000-0000-4000-8000-000000000d01';  -- celulares de prueba
  d2 uuid := '00000000-0000-4000-8000-000000000d02';
  d3 uuid := '00000000-0000-4000-8000-000000000d03';
  ok integer := 0;
  comp_a integer;
  comp_b integer;
  h json;
  fila text;
  err text;
begin
  -- Punto de partida limpio (todo se deshace al final).
  insert into sesiones_admin (token) values (t::uuid);
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

  -- ===== Votos =====
  perform votar(d1, 'Votante Uno', (select id from participantes where nombre = 'Ana'));
  perform votar(d2, 'Votante Dos', (select id from participantes where nombre = 'Ana'));
  perform votar(d3, 'Votante Tres', (select id from participantes where nombre = 'Beto'));
  begin
    perform votar(d1, 'Votante Uno', (select id from participantes where nombre = 'Beto'));
    raise exception 'FALLÓ un celular pudo votar dos veces';
  exception when others then
    if sqlerrm not like '%Ya votaste%' then raise; end if;
  end;
  ok := ok + 1;

  perform quitar_voto(d3);
  perform votar(d3, 'Votante Tres', (select id from participantes where nombre = 'Caro'));
  if (select count(*) from votos where dispositivo = d3) <> 1
     or (select p.nombre from votos v join participantes p on p.id = v.participante_id where v.dispositivo = d3) <> 'Caro' then
    raise exception 'FALLÓ cambiar el voto';
  end if;
  ok := ok + 1;

  -- ===== Cerrar votación → se guarda en el historial =====
  perform cerrar_votacion(t);
  begin
    perform votar(gen_random_uuid(), 'Tarde', (select id from participantes where nombre = 'Ana'));
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
  ok := ok + 1;

  if (select count(*) from historial_participantes where competencia_id = comp_a) <> 3
     or (select count(*) from historial_votos where competencia_id = comp_a) <> 3
     or (select nombre from historial_participantes where competencia_id = comp_a and puesto = 1) <> 'Ana'
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
  perform votar(gen_random_uuid(), 'Votante Cuatro', (select id from participantes where nombre = 'Beto'));
  perform cerrar_votacion(t);
  if (select count(*) from historial_votos where competencia_id = comp_a) <> 4
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
  perform nueva_competencia(t, true);
  comp_b := (select competencia_id from evento where id);
  if comp_b = comp_a
     or (select count(*) from participantes) <> 0
     or (select count(*) from votos) <> 0
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
  perform votar(d1, 'Votante Uno', (select id from participantes where nombre = 'Fede'));
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
  set local role anon;
  if (select count(*) from historial_votos) <> 0 or (select count(*) from historial_participantes) <> 0 then
    raise exception 'FALLÓ el público puede leer el historial';
  end if;
  begin
    insert into participantes (nombre, cancion, orden) values ('Intruso', 'x', 99);
    raise exception 'FALLÓ el público pudo escribir en participantes';
  exception when insufficient_privilege then null;
  end;
  reset role;
  ok := ok + 1;

  raise exception 'PRUEBAS OK: % de % pasaron (todo se deshizo, tus datos quedaron intactos)', ok, ok;
end $$;
