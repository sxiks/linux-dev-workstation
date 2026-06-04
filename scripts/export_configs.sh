#!/usr/bin/env bash

echo "Configuraciones gestionadas por Stow:"
echo ""

echo "~/.bashrc                     → dotfiles/bash"
echo "~/.config/kitty              → dotfiles/kitty"
echo "~/.config/zellij             → dotfiles/zellij"
echo "~/.config/yazi               → dotfiles/yazi"
echo "~/.config/fastfetch          → dotfiles/fastfetch"

echo "~/.config/fish               → dotfiles/fish"
echo "~/.config/gitui              → dotfiles/gitui"
echo "~/.config/starship.toml      → dotfiles/starship"
echo "~/.config/warp-terminal      → dotfiles/warp"

echo ""
echo "Los cambios ya están dentro del repositorio."
echo "Solo necesitas:"
echo ""
echo "git add ."
echo "git commit"
echo "git push"
