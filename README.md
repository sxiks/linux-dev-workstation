# Entorno Sincronizado Multi-PC

Este repositorio permite mantener sincronizados dos o más equipos Linux mediante:

- Git (dotfiles)
- Syncthing
- GNOME export/import
- Scripts de instalación de aplicaciones

---

# Procedimientos Comunes

| Objetivo Operacional | Ubicación | Comando |
|---|---|---|
| Sincronizar cambios de Kitty, Zellij o Yazi | PC origen / destino | `dotpush` / `dotpull` |
| Pasar configuración GNOME | Torre → Laptop | `./export_gnome.sh` / `./import_gnome.sh` |
| Sincronizar aplicaciones instaladas | Torre → Laptop | `./export_apps.sh && dotpush` / `dotpull && ./import_apps.sh` |
| Actualizar sistema | Cualquier PC | `update-system` |
| Sincronizar proyectos | Todas | Automático mediante Syncthing |

---

# Arquitectura

## 1. Datos y Proyectos

Gestionado por Syncthing.

Sincroniza:

- código fuente
- documentación
- apuntes
- bases de datos de prueba
- archivos personales

Ubicación:

```
~/Documents
```

---

## 2. Dotfiles

Gestionado por Git.

Sincroniza:

- Kitty
- Zellij
- Yazi
- Bash
- Scripts personalizados

Comandos:

```bash
dotpush
dotpull
```

---

## 3. Aplicaciones

Gestionado por:

```bash
export_apps.sh
import_apps.sh
```

Sincroniza:

- apt
- flatpak
- snap

---

## 4. GNOME

Gestionado por:

```bash
export_gnome.sh
import_gnome.sh
```

Sincroniza:

- atajos
- extensiones
- apariencia
- configuración general

---

# Limitaciones

## Syncthing

Ambos equipos deben conectarse eventualmente para sincronizar.

Si se modifica el mismo archivo en ambos equipos:

```
archivo.sync-conflict
```

deberá resolverse manualmente.

---

## Git

Los cambios no son automáticos.

Siempre ejecutar:

```bash
dotpush
```

antes de cambiar de equipo.

---

## Aplicaciones

Las aplicaciones se reinstalan vacías.

No sincronizan:

- sesiones
- contraseñas
- tokens
- bases de datos locales

---

## GNOME

Las configuraciones relacionadas con pantallas pueden variar entre equipos.

Puede ser necesario ajustar:

- resolución
- escala
- disposición de monitores

manualmente.

---

# Recursos Visuales

No se sincronizan automáticamente.

Se recomienda almacenar en:

```
~/Documents/Recursos
```

- wallpapers
- fuentes ttf
- fuentes otf

para que Syncthing los replique.

---

# Bootstrap de una Nueva Máquina

Consultar:

```
docs/BOOTSTRAP.md
```
