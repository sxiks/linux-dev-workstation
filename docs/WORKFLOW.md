# Workflow de sincronización

## Cambiar configuraciones

Editar:

~/.config/...

Luego ejecutar:

dotpush

---

## Actualizar otro equipo

Ejecutar:

dotpull

---

## Instalar aplicaciones nuevas

Actualizar listado:

export_apps

Luego:

dotpush

---

## Actualizar configuración GNOME

Ejecutar:

export_gnome

Luego:

dotpush

---

## Agregar nuevos archivos al repositorio

1. Crear dentro de dotfiles
2. Aplicar Stow

Ejemplo:

stow --restow -t ~ .

3. Verificar symlinks
4. Ejecutar dotpush

---

## Flujo habitual

PC1:
editar → dotpush

PC2:
dotpull

---

## Layouts Zellij

PC1 usa:

layouts/pc1.kdl

PC2 usa:

layouts/laptop.kdl

La selección ocurre mediante:

scripts/zellij-launcher

y el archivo local:

~/.local/share/machine-role

Este archivo NO se sincroniza.
