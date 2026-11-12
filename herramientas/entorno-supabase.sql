-- Prepara un Postgres común para que se comporte como uno de Supabase en lo que
-- usa schema.sql: los roles de la API, el esquema de extensiones, los permisos
-- por defecto y la publicación de tiempo real. Sirve para correr schema.sql y
-- pruebas.sql en un Postgres local o en CI. En Supabase NO hace falta.
do $$
begin
  if not exists (select 1 from pg_roles where rolname = 'anon') then
    create role anon nologin noinherit;
  end if;
  if not exists (select 1 from pg_roles where rolname = 'authenticated') then
    create role authenticated nologin noinherit;
  end if;
  if not exists (select 1 from pg_roles where rolname = 'service_role') then
    create role service_role nologin noinherit bypassrls;
  end if;
end $$;

create schema if not exists extensions;
grant usage on schema public, extensions to anon, authenticated, service_role;

-- Como en Supabase: lo nuevo en public queda habilitado para la API y lo que
-- protege los datos es RLS + los revoke/grant explícitos de schema.sql.
alter default privileges in schema public grant all on tables to anon, authenticated, service_role;
alter default privileges in schema public grant all on sequences to anon, authenticated, service_role;
alter default privileges in schema public grant all on functions to anon, authenticated, service_role;

do $$
begin
  create publication supabase_realtime;
exception when duplicate_object then null;
end $$;
