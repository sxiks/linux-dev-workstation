#!/usr/bin/env bash

echo "Configuraciones gestionadas por Stow:"
echo ""

echo "~/.config/zellij     → dotfiles/zellij"
echo "~/.config/kitty      → dotfiles/kitty"
echo "~/.config/fastfetch  → dotfiles/fastfetch"
echo "~/.config/yazi       → dotfiles/yazi"
echo "~/.config/fish       → dotfiles/fish"
echo "~/.config/gitui      → dotfiles/gitui"
echo "~/.config/starship   → dotfiles/starship"

echo ""
echo "No es necesario exportar configuraciones."
echo "Editar ~/.config equivale a editar el repositorio."
echo ""
echo "Usa:"
echo "  dotpush"
echo "para sincronizar cambios."
