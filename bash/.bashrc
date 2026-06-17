# ~/.bashrc: executed by bash(1) for non-login shells.

# If not running interactively, don't do anything
case $- in
    *i*) ;;
      *) return;;
esac

HISTCONTROL=ignoreboth
shopt -s histappend
HISTSIZE=1000
HISTFILESIZE=2000
shopt -s checkwinsize

if [ -z "${debian_chroot:-}" ] && [ -r /etc/debian_chroot ]; then
    debian_chroot=$(cat /etc/debian_chroot)
fi

case "$TERM" in
    xterm-color|*-256color) color_prompt=yes;;
esac

if [ "$color_prompt" = yes ]; then
    PS1='${debian_chroot:+($debian_chroot)}\[\033[01;32m\]\u@\h\[\033[00m\]:\[\033[01;34m\]\w\[\033[00m\]\$ '
else
    PS1='${debian_chroot:+($debian_chroot)}\u@\h:\w\$ '
fi
unset color_prompt force_color_prompt

case "$TERM" in
xterm*|rxvt*)
    PS1="\[\e]0;${debian_chroot:+($debian_chroot)}\u@\h: \w\a\]$PS1"
    ;;
*)
    ;;
esac

if [ -x /usr/bin/dircolors ]; then
    test -r ~/.dircolors && eval "$(dircolors -b ~/.dircolors)" || eval "$(dircolors -b)"
    alias ls='ls --color=auto'
fi

if [ -f ~/.bash_aliases ]; then
    . ~/.bash_aliases
fi

if ! shopt -oq posix; then
  if [ -f /usr/share/bash-completion/bash_completion ]; then
    . /usr/share/bash-completion/bash_completion
  elif [ -f /etc/bash_completion ]; then
    . /etc/bash_completion
  fi
fi

# ═══════════════════════════════════════════
# PATHS Y CARGAS
# ═══════════════════════════════════════════
export PATH="$HOME/.local/bin:$HOME/.spicetify:$HOME/.linutil:$HOME/.opencode/bin:$HOME/bin:/usr/share/code/bin:$PATH"

# SSH AGENT (Comentado para evitar bloqueos al abrir terminal)
# if [ -z "$SSH_AUTH_SOCK" ]; then
#     eval "$(ssh-agent -s)" &>/dev/null
#     ssh-add ~/.ssh/id_ed25519 2>/dev/null
# fi

# RUST CARGO
[ -f "$HOME/.cargo/env" ] && . "$HOME/.cargo/env"

# ═══════════════════════════════════════════
# ALIASES
# ═══════════════════════════════════════════
alias gs='git status'
alias gss='git status --short'
alias gd='git diff'
alias gc='git commit -m'
alias ga='git add .'
alias gp='git push'
alias gpl='git pull'
alias gco='git checkout'
alias gcb='git checkout -b'
alias ni='npm install'
alias nr='npm run'
alias nrd='npm run dev'
alias ..='cd ..'
alias ...='cd ../..'
alias ll='ls -la'
alias c='clear'
alias zj='zellij'
alias ya='yazi'

#alias gitui='gitui -t ~/.config/gitui/theme.ron'
alias kt='kitty'

# Sincronización robusta
alias dotpull='~/dotfiles/scripts/dotpull'
alias dotpush='cd ~/dotfiles && git status'

# Identidad local de la máquina
if [ -f "$HOME/.config/machine-type" ]; then
    export MODO_PC=$(cat "$HOME/.config/machine-type")
else
    export MODO_PC="laptop"
fi

# Selector inteligente de layout
zellij-work() {
    local layout_pc1="$HOME/dotfiles/zellij/layouts/pc1.kdl"
    local layout_laptop="$HOME/dotfiles/zellij/layouts/laptop.kdl"

    if [ "$MODO_PC" = "escritorio" ]; then
        exec zellij --layout "$layout_pc1"
    else
        exec zellij --layout "$layout_laptop"
    fi
}

export NVM_DIR="$HOME/.nvm"
[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"  # This loads nvm
[ -s "$NVM_DIR/bash_completion" ] && \. "$NVM_DIR/bash_completion"  # This loads nvm bash_completion
