# Perfiles de configuración de apps

Un **perfil de configuración** lleva la configuración de una app de un PC a
otro a través del repo, igual que el manifest lleva qué apps instalar:

```
PC origen                          repo                         PC destino
capture_config.sh <id> --apply ──► apps/configs/<id>/files/ ──► restore_config.sh <id> --apply
                                   (commit + push)  (dotpull)
```

- `apps/manifest.yaml` decide **qué** se instala.
- `apps/configs/<id>/` decide **cómo queda configurada** esa app.

## Qué viaja y qué no

| Capa | Qué es | Cómo viaja | ¿En el repo? |
|---|---|---|---|
| Configuración | Preferencias, temas, mods, atajos, CSS, archivos `.conf` | Perfil de configuración | **Sí** |
| Estado y datos | Historial, marcadores, pestañas, bases de datos, volúmenes Docker | Sincronización propia de la app, o backup aparte | **No** |
| Secretos | Contraseñas, tokens, llaves SSH, `.env` | Cifrados (CF5, pendiente) o se vuelven a introducir | **Nunca en claro** |

El repo se trata como público: nada de URLs privadas, historial ni secretos.

## Qué tan realista es por tipo de app

| Tipo | Ejemplos | Se lleva | Va por otra vía | Realismo |
|---|---|---|---|---|
| Terminal y CLI | kitty, fish, starship, helix, zellij, yazi | Todo | — (ya lo hace Stow) | Alto |
| Editores | VS Code | `settings.json`, atajos, snippets, lista de extensiones | Caché | Alto |
| Navegadores | Zen, Firefox | Preferencias filtradas, mods, CSS, atajos, contenedores | Historial, contraseñas, extensiones y pestañas: cuenta Mozilla | Medio-alto |
| Apps GNOME | Solanum, Tangram, escritorio | Claves dconf elegidas | — | Alto (CF3) |
| Grabación | OBS | Perfiles y escenas | Rutas y dispositivos: ajustes por PC | Medio |
| Clientes de BD | DBeaver, pgAdmin | Conexiones sin contraseña | Contraseñas | Alto |
| Servicios del sistema | MySQL server, Docker daemon, SSH | `/etc/mysql/conf.d/*.cnf`, `/etc/docker/daemon.json` | — | Alto (CF4) |
| Datos de servicios | Bases MySQL, volúmenes Docker | No es configuración | `mysqldump`, backup de volúmenes | Otro mecanismo (CF6) |
| Stacks Docker (homelab) | `compose.yaml` | Compose y `.env.example` | `.env` real, cifrado | Alto |
| Apps con cuenta propia | Spotify, Warp | Casi nada | La cuenta | No hace falta |

## Uso

```bash
# PC origen, con la app CERRADA
~/dotfiles/scripts/capture_config.sh zen-browser            # preview: qué cambiaría en el repo
~/dotfiles/scripts/capture_config.sh zen-browser --diff     # preview con el detalle
~/dotfiles/scripts/capture_config.sh zen-browser --apply    # escribe en el repo
git -C ~/dotfiles status                                    # revisar y hacer commit + push

# PC destino, después de dotpull, con la app instalada, abierta una vez y CERRADA
~/dotfiles/scripts/restore_config.sh zen-browser            # preview: qué cambiaría en el PC
~/dotfiles/scripts/restore_config.sh zen-browser --apply    # escribe (con backup)
```

Sin argumentos, los dos scripts listan los perfiles disponibles.

## Reglas fijas

- `--preview` es el modo por defecto. `--apply` pide confirmación; `--yes` la
  omite (bootstrap). Sin terminal, `--apply` exige `--yes`.
- Con `--apply` la app tiene que estar cerrada: muchas apps escriben su
  configuración al salir y pisarían el cambio.
- **restore** hace backup de todo lo que sobrescribe en
  `~/.local/state/dotfiles/config-backups/<id>/<fecha>/` (con `NUEVOS.txt`, la
  lista de archivos que no existían) y **nunca borra** archivos del destino.
- **capture** refleja el origen dentro del repo: si un archivo desapareció en
  el origen, se quita del repo (aparece como `[SOBRA]` en el preview; Git lo
  conserva en el historial).
- **capture** se detiene si encuentra algo con forma de secreto (llaves
  privadas, tokens de GitHub u OpenAI, `password=`…) y no escribe nada.
- La ruta del HOME se guarda como `@HOME@` y se repone en el destino.
- Un item de más de `max_item_mb` (5 MB por defecto) se rechaza: los binarios
  grandes no van en Git.
- `dotpull` nunca restaura nada por su cuenta.

## Estructura de un perfil

```
apps/configs/<id>/
  config.yaml     descriptor (qué, dónde, cómo, qué nunca)
  files/          contenido capturado (lo genera capture_config.sh)
```

### Referencia de `config.yaml`

| Clave | Obligatoria | Significado |
|---|---|---|
| `id` | Sí | Igual al nombre de la carpeta |
| `app` | Sí | Entrada `app` del manifest a la que pertenece |
| `description` | No | Una línea |
| `location.base` | Sí | Ruta o lista de rutas candidatas, empezando por `~/`; se usa la primera que exista |
| `location.resolver` | No | `none` (la base es la carpeta) o `mozilla-profile` (perfil activo según `installs.ini` y `profiles.ini`) |
| `running_check.flatpak` | No | Id Flatpak para comprobar si la app está abierta |
| `items` | Sí | Lista de `{path, strategy}`; una ruta que termina en `/` es una carpeta |
| `never` | No | Rutas que nunca pueden formar parte del perfil; un item que se solape es un error |
| `handled_elsewhere` | No | Lo que viaja por otra vía, solo informativo |
| `max_item_mb` | No | Tamaño máximo por item (5 por defecto) |

Cualquier clave desconocida, estrategia inválida, ruta con `..` o `app` que no
exista en el manifest es un error explícito.

### Estrategias

| Estrategia | Para qué | Capture | Restore |
|---|---|---|---|
| `copy` | Archivos y carpetas que la app lee tal cual | Copia al repo | Copia al PC; no borra lo que sobre |
| `prefs-merge` | `prefs.js` de apps Mozilla | Guarda solo las claves que no excluyen `exclude_prefixes`, `exclude_keys` y `exclude_patterns` | Fusiona en el `prefs.js` del destino: cambia o añade esas claves y no toca el resto |

`prefs-merge` no usa `user.js` a propósito: `user.js` reimpone sus valores en
cada arranque y pisa lo que se cambie desde la interfaz.

Pendientes: `link` (Stow), `dconf`, `command`, `system` (`/etc` con sudo),
`secret` (cifrado) y ajustes por máquina.

## Perfil actual: `zen-browser`

- **Viaja:** `chrome/` (CSS, logo y mods), `zen-themes.json`, `user.js`,
  `customKeys.json`, `containers.json`, `handlers.json` y `prefs.js` filtrado.
- **Por la cuenta Mozilla:** marcadores, contraseñas, historial, extensiones,
  Espacios y pestañas.
- **Nunca:** contraseñas y certificados, cookies, `storage/`, sesiones,
  `signedInUser.json`, `xulstore.json` (depende de la pantalla) y
  `search.json.mozlz4` (lleva un hash ligado a la ruta del perfil).
- **Fuera por tamaño:** `wallpaper/`.

En un PC nuevo: instalar Zen (`import_apps.sh --apply --only=app.zen_browser.zen`),
abrirlo una vez y cerrarlo para que cree su perfil, y entonces `restore_config.sh`.

## Añadir un perfil nuevo

1. Crear `apps/configs/<id>/config.yaml` con el `app` del manifest.
2. Listar en `items` solo configuración; poner en `never` el estado y los secretos.
3. `capture_config.sh <id>` en preview y revisar la lista; después `--apply`.
4. Commit nombrando los archivos de `apps/configs/<id>/`.

## Hoja de ruta

| Fase | Contenido |
|---|---|
| CF1 | Motor, `copy`, `prefs-merge`, resolvedor Mozilla, perfil de Zen |
| CF2 | Integración con `import_apps.sh` (`--with-configs`) y `status` (diferencias repo/PC) |
| CF3 | `dconf` y `command` (apps GNOME, extensiones de VS Code, pgAdmin) |
| CF4 | `system`: archivos en `/etc` con sudo (MySQL, Docker daemon) |
| CF5 | Secretos cifrados con sops + age |
| CF6 | Backups de datos (mysqldump, volúmenes) como herramienta aparte |

El motor no sabe nada de escritorios: un servidor de homelab es otro
`machine-type`, y un stack Docker es un perfil más (compose en `files/`,
`.env` cifrado en CF5, volúmenes con CF6).
