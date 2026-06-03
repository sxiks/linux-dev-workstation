#!/usr/bin/env bash

set -euo pipefail

echo ""
echo "================================="
echo " Dotfiles Bootstrap Installer"
echo "================================="
echo ""

# --------------------------------------------------
# Verificar dependencias mínimas
# --------------------------------------------------

if ! command -v stow >/dev/null 2>&1; then
    echo "Instalando GNU Stow..."
    sudo apt update
    sudo apt install -y stow
fi

# --------------------------------------------------
# Aplicar dotfiles
# --------------------------------------------------

echo ""
echo "Aplicando dotfiles..."
stow --restow -t ~ .

# --------------------------------------------------
# Configurar tipo de máquina
# --------------------------------------------------

echo ""
echo "Selecciona el tipo de equipo:"
echo ""
echo "1) Laptop"
echo "2) Escritorio"
echo ""

read -rp "Opción: " choice

mkdir -p ~/.config

case "$choice" in
    1)
        echo "laptop" > ~/.config/machine-type
        ;;
    2)
        echo "escritorio" > ~/.config/machine-type
        ;;
    *)
        echo "Opción inválida"
        exit 1
        ;;
esac

echo ""
echo "Tipo configurado:"
cat ~/.config/machine-type

# --------------------------------------------------
# Reaplicar stow
# --------------------------------------------------

echo ""
echo "Reaplicando enlaces..."
stow --restow -t ~ .

# --------------------------------------------------
# Final
# --------------------------------------------------

echo ""
echo "================================="
echo " Bootstrap completado"
echo "================================="
echo ""
echo "Próximos pasos:"
echo ""
echo "1. Ejecutar import_apps.sh"
echo "2. Ejecutar import_gnome.sh"
echo "3. Configurar Syncthing"
echo "4. Reiniciar sesión GNOME"
echo ""
