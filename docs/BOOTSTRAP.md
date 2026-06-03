# Bootstrap de una Nueva Máquina

Esta guía permite reconstruir completamente el entorno desde cero.

---

# 1. Instalar herramientas básicas

```bash
sudo apt update

sudo apt install -y \
git \
stow \
curl \
wget
```

---

# 2. Clonar repositorio

```bash
git clone git@github.com:sxiks/sync.git ~/dotfiles

cd ~/dotfiles
```

---

# 3. Aplicar dotfiles

```bash
stow --restow -t ~ .
```
---

# 4. Ejecutar instalador

```bash
cd ~/dotfiles

chmod +x install.sh

./install.sh
```
---

# 5. Instalar aplicaciones

```bash
./import_apps.sh
```

---

# 7. Restaurar GNOME

```bash
./import_gnome.sh
```

Cerrar sesión y volver a entrar.

---

# 8. Configurar Syncthing

Instalar:

```bash
sudo apt install syncthing
```

Conectar con los demás equipos.

Sincronizar:

```bash
~/Documents
```

---

# 9. Verificaciones

## Kitty

Abrir:

```bash
kitty
```

Debe iniciar Zellij automáticamente.

---

## Zellij

Verificar launcher:

```bash
~/scripts/zellij-launcher
```

---

## Git

```bash
dotpull
```

---

## Yazi

```bash
yazi
```

---

## Fastfetch

```bash
fastfetch
```

---

# Resultado esperado

La nueva máquina tendrá:

- mismos dotfiles
- mismas aplicaciones
- misma apariencia GNOME
- mismos proyectos
- mismos layouts de Zellij
