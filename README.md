# Karaoke Night

Página para una competencia de karaoke, pensada para celular y para compartir por QR.

- `index.html` — lo que abre el público: pide el nombre, muestra quién canta,
  quién sigue y la lista, en vivo. Cada persona tiene **un voto** (uno por celular).
- `admin.html` — panel con clave, en cuatro pestañas: **En vivo** (pasar de turno),
  **Participantes** (agregar/editar/borrar), **Votos** (ranking y quién votó a quién,
  solo lo ve el admin) y **Final** (cerrar la votación y revelar los puestos uno por
  uno, del último al ganador, en todos los celulares a la vez).

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
- El usuario y la contraseña del admin **no están en este repo**: viven en una tabla
  privada, con la contraseña hasheada (bcrypt). Al iniciar sesión la base devuelve
  un pase que vence en 24 h; el navegador guarda ese pase, nunca la contraseña.
  Para cambiarlos, en Supabase > SQL Editor (cierra todas las sesiones abiertas):
  ```sql
  select fijar_clave_admin('usuario', 'contraseña');
  ```
- "Un voto por persona" es un voto por dispositivo: alcanza para un evento, pero
  alguien que borre los datos del navegador podría votar de nuevo.

## Después del evento

Para borrar todo y reusarla: `delete from votos; delete from participantes;`
