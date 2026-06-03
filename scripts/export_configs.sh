#!/bin/bash
echo "--- Iniciando exportación de configuraciones y listas ---"

# 1. Exportar listas de paquetes
echo "Generando listas de paquetes..."
apt-mark showmanual > ~/dotfiles/apt_packages.txt
flatpak list --app --columns=application > ~/dotfiles/flatpak_packages.txt
snap list | awk 'NR>1 {print $1}' | grep -vE 'core|snapd|bare|gtk' > ~/dotfiles/snap_packages.txt

# 2. Sincronizar carpetas de configuración
echo "Copiando configuraciones a ~/dotfiles..."
cp -r ~/.config/fastfetch ~/dotfiles/.config/
cp -r ~/.config/btop ~/dotfiles/.config/

# 3. Empujar todo
echo "Subiendo cambios..."
git push origin main
