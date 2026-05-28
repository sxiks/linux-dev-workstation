# ~/.bashrc: executed by bash(1) for non-login shells.
# see /usr/share/doc/bash/examples/startup-files (in the package bash-doc)
# for examples

# If not running interactively, don't do anything
case $- in
    *i*) ;;
      *) return;;
esac

# don't put duplicate lines or lines starting with space in the history.
# See bash(1) for more options
HISTCONTROL=ignoreboth

# append to the history file, don't overwrite it
shopt -s histappend

# for setting history length see HISTSIZE and HISTFILESIZE in bash(1)
HISTSIZE=1000
HISTFILESIZE=2000

# check the window size after each command and, if necessary,
# update the values of LINES and COLUMNS.
shopt -s checkwinsize

# If set, the pattern "**" used in a pathname expansion context will
# match all files and zero or more directories and subdirectories.
#shopt -s globstar

# make less more friendly for non-text input files, see lesspipe(1)
#[ -x /usr/bin/lesspipe ] && eval "$(SHELL=/bin/sh lesspipe)"

# set variable identifying the chroot you work in (used in the prompt below)
if [ -z "${debian_chroot:-}" ] && [ -r /etc/debian_chroot ]; then
    debian_chroot=$(cat /etc/debian_chroot)
fi

# set a fancy prompt (non-color, unless we know we "want" color)
case "$TERM" in
    xterm-color|*-256color) color_prompt=yes;;
esac

# uncomment for a colored prompt, if the terminal has the capability; turned
# off by default to not distract the user: the focus in a terminal window
# should be on the output of commands, not on the prompt
#force_color_prompt=yes

if [ -n "$force_color_prompt" ]; then
    if [ -x /usr/bin/tput ] && tput setaf 1 >&/dev/null; then
	# We have color support; assume it's compliant with Ecma-48
	# (ISO/IEC-6429). (Lack of such support is extremely rare, and such
	# a case would tend to support setf rather than setaf.)
	color_prompt=yes
    else
	color_prompt=
    fi
fi

if [ "$color_prompt" = yes ]; then
    PS1='${debian_chroot:+($debian_chroot)}\[\033[01;32m\]\u@\h\[\033[00m\]:\[\033[01;34m\]\w\[\033[00m\]\$ '
else
    PS1='${debian_chroot:+($debian_chroot)}\u@\h:\w\$ '
fi
unset color_prompt force_color_prompt

# If this is an xterm set the title to user@host:dir
case "$TERM" in
xterm*|rxvt*)
    PS1="\[\e]0;${debian_chroot:+($debian_chroot)}\u@\h: \w\a\]$PS1"
    ;;
*)
    ;;
esac

# enable color support of ls and also add handy aliases
if [ -x /usr/bin/dircolors ]; then
    test -r ~/.dircolors && eval "$(dircolors -b ~/.dircolors)" || eval "$(dircolors -b)"
    alias ls='ls --color=auto'
    #alias dir='dir --color=auto'
    #alias vdir='vdir --color=auto'

    #alias grep='grep --color=auto'
    #alias fgrep='fgrep --color=auto'
    #alias egrep='egrep --color=auto'
fi

# colored GCC warnings and errors
#export GCC_COLORS='error=01;31:warning=01;35:note=01;36:caret=01;32:locus=01:quote=01'

# some more ls aliases
#alias ll='ls -l'
#alias la='ls -A'
#alias l='ls -CF'

# Alias definitions.
# You may want to put all your additions into a separate file like
# ~/.bash_aliases, instead of adding them here directly.
# See /usr/share/doc/bash-doc/examples in the bash-doc package.

if [ -f ~/.bash_aliases ]; then
    . ~/.bash_aliases
fi

# enable programmable completion features (you don't need to enable
# this, if it's already enabled in /etc/bash.bashrc and /etc/profile
# sources /etc/bash.bashrc).
if ! shopt -oq posix; then
  if [ -f /usr/share/bash-completion/bash_completion ]; then
    . /usr/share/bash-completion/bash_completion
  elif [ -f /etc/bash_completion ]; then
    . /etc/bash_completion
  fi
fi

#
# Cargar configuracion de VTE para Tilix
#source /etc/profile.d/vte-2.91.sh 2>/dev/null

# Configuración de PATH
export PATH="$HOME/.local/bin:$PATH"
export PATH="$HOME/.spicetify:$PATH"
export PATH="$HOME/.linutil:$PATH"

export PATH=$PATH:/home/sxiks/.spicetify


# Auto-cargar clave SSH al abrir terminal
if [ -z "$SSH_AUTH_SOCK" ]; then
    eval "$(ssh-agent -s)" &>/dev/null
    ssh-add ~/.ssh/id_ed25519 2>/dev/null
fi
# Remove problematic Docker aliases
unalias npm 2>/dev/null
unalias npx 2>/dev/null

# opencode
export PATH=/home/sxiks/.opencode/bin:$PATH
export PATH="$HOME/.local/bin:$PATH"



# ═══════════════════════════════════════════
# 🐙 ALIAS DE GIT - FLUJO DE TRABAJO ÁGIL
# ═══════════════════════════════════════════

# Estado y navegación
alias gs='git status'
alias gss='git status --short'
alias gd='git diff'
alias gdc='git diff --cached'
alias gdv='git diff --word-diff'
alias gl='git log --oneline --graph --decorate'
alias gl5='git log --oneline -5'
alias glast='git log -1 --stat'
alias gb='git branch'
alias gba='git branch -a'
alias gbd='git branch -d'
alias gbD='git branch -D'

# Cambios y commits
alias ga='git add .'
alias gaa='git add --all'
alias gap='git add -p'                    # Añadir por partes (hunks)
alias gc='git commit -m'
alias gca='git commit --amend'
alias gcn='git commit --no-edit'
alias gcf='git commit --fixup'
alias grs='git restore --staged'          # Quitar del stage
alias gr='git restore'                    # Descartar cambios locales
alias gcp='git cherry-pick'

# Ramas
alias gco='git checkout'
alias gcb='git checkout -b'               # Crear y cambiar a nueva rama
alias gm='git merge'
alias gma='git merge --abort'
alias grb='git rebase'
alias grba='git rebase --abort'
alias grbc='git rebase --continue'

# Remotos
alias gp='git push'
alias gpf='git push --force-with-lease'
alias gpu='git push -u origin HEAD'       # Push y set upstream
alias gpl='git pull'
alias gplr='git pull --rebase'
alias gf='git fetch'
alias gfa='git fetch --all'
alias grv='git remote -v'

# Stash
alias gst='git stash'
alias gstl='git stash list'
alias gstp='git stash pop'
alias gsta='git stash apply'
alias gstd='git stash drop'
alias gstc='git stash clear'

# Limpieza y utilidades
alias gcl='git clone'
alias ginit='git init'
alias gignore='git update-index --assume-unchanged'
alias gunignore='git update-index --no-assume-unchanged'
alias gclean='git clean -fd'
alias greset='git reset --hard HEAD'

# Información
alias gsh='git show'
alias gshs='git show --stat'
alias gwho='git shortlog -sn'              # Quién ha contribuido
alias gfile='git show --name-status'       # Archivos cambiados en commit
alias gtags='git tag -l'
alias gcount='git rev-list --count HEAD'   # Número de commits

# Búsqueda
alias gsearch='git log --all --grep'       # Buscar en mensajes de commit
alias gfilehist='git log --'               # Historial de un archivo

# ═══════════════════════════════════════════
# 🟢 ALIAS DE NODE/NPM
# ═══════════════════════════════════════════
alias ni='npm install'
alias nid='npm install -D'
alias nig='npm install -g'
alias nr='npm run'
alias nrd='npm run dev'
alias nrb='npm run build'
alias nrt='npm run test'
alias nrs='npm run start'
alias nw='npm run watch'
alias nci='npm ci'                         # Instalación limpia
alias nu='npm update'
alias nup='npm update --save'
alias nout='npm outdated'
alias nls='npm list --depth=0'
alias nrm='npm uninstall'
alias npx='npx'

# ═══════════════════════════════════════════
# 📁 NAVEGACIÓN RÁPIDA
# ═══════════════════════════════════════════
alias ..='cd ..'
alias ...='cd ../..'
alias ....='cd ../../..'
alias ll='ls -la'
alias l='ls -l'
alias la='ls -A'
alias lh='ls -lh'
alias lt='ls -lrt'                         # Ordenado por fecha
alias c='clear'
alias h='history'
alias path='echo $PATH | tr ":" "\n"'      # Ver PATH formateado
alias ports='ss -tulpn'                    # Ver puertos en uso
alias ip='ip -c a'                         # IPs con colores

# ═══════════════════════════════════════════
# 🛠️ HERRAMIENTAS ÚTILES
# ═══════════════════════════════════════════
alias zshrc='nano ~/.bashrc'               # Editar bashrc
alias src='source ~/.bashrc'               # Recargar bashrc
alias opencode='opencode'
alias oc='opencode'
alias zj='zellij'
alias ya='yazi'
alias kt='kitty'

# Copiar al portapapeles
alias copy='xclip -selection clipboard'

# Crear y navegar a directorio
alias mkcd='mkdir -p "$1" && cd "$1"'

# Encontrar archivos grandes
alias bigfiles='find . -type f -exec du -h {} + | sort -rh | head -10'


# Abrir carpetas en VSCode

# Abrir ruta copiada desde Yazi con VSCode
export PATH="$PATH:/usr/share/code/bin"

# Abrir con el programa predeterminado del sistema

# Abrir PDF con visor predeterminado

# Abrir documentos con LibreOffice

# Abrir imágenes con visor predeterminado
. "$HOME/.cargo/env"
