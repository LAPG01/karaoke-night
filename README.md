# Karaoke Night

Página para una competencia de karaoke, pensada para celular y para compartir por QR.

- `index.html` — lo que abre el público: pide el nombre, muestra quién canta,
  quién sigue y la lista, en vivo. Cada persona tiene **un voto** (uno por celular).
- `admin.html` — panel con clave: agregar/editar/borrar participantes, pasar al
  siguiente turno y ver el ranking de votos (solo el admin ve los números).

Hecha con HTML/CSS/JS sin build, Supabase (base de datos + tiempo real) y GitHub Pages.

## Archivos

| Archivo | Qué es |
|---|---|
| `index.html`, `admin.html` | Las dos páginas |
| `app.js`, `styles.css` | Código y estilos compartidos |
| `config.js` | URL y clave pública de Supabase (pública por diseño) |
| `schema.sql` | Tablas, permisos y funciones de la base |

## Seguridad

- La clave pública de Supabase va en el navegador a propósito. Lo que protege los
  datos son las políticas RLS y las funciones de `schema.sql`.
- La clave de admin **no está en este repo**: vive hasheada (bcrypt) en una tabla
  privada. Para cambiarla, en Supabase > SQL Editor:
  ```sql
  select fijar_clave_admin('la-nueva-clave');
  ```
- "Un voto por persona" es un voto por dispositivo: alcanza para un evento, pero
  alguien que borre los datos del navegador podría votar de nuevo.

## Después del evento

Para borrar todo y reusarla: `delete from votos; delete from participantes;`
