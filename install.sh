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
echo "1. Instalar paquetes necesarios"
echo "2. Configurar machine-type"
echo "3. Verificar enlaces de Stow"
echo "4. Iniciar sesión en Warp"
echo "5. Configurar Syncthing"
echo ""
echo "Verificando enlaces importantes..."

readlink -f ~/.config/fish/config.fish 2>/dev/null || true
readlink -f ~/.config/gitui/theme.ron 2>/dev/null || true
readlink -f ~/.config/starship.toml 2>/dev/null || true
readlink -f ~/.config/warp-terminal/settings.toml 2>/dev/null || true
