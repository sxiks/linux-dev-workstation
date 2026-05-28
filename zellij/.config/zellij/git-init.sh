#!/bin/bash

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
RED='\033[0;31m'
CYAN='\033[0;36m'
NC='\033[0m'
BOLD='\033[1m'

clear
cat << "BANNER"
       /\_/\
      ( o.o )
       > ^ <
     GIT WORKSPACE
BANNER

echo ""

if [ ! -d ~/proyectos ]; then
    mkdir -p ~/proyectos
    echo -e "${YELLOW} Carpeta ~/proyectos creada${NC}"
fi

if git rev-parse --git-dir > /dev/null 2>&1; then
    BRANCH=$(git branch --show-current)
    REPO_NAME=$(basename $(git rev-parse --show-toplevel))
    
    echo -e "${GREEN} Repositorio Git activo${NC}"
    echo -e "${CYAN} Proyecto: ${BOLD}$REPO_NAME${NC}"
    echo -e "${CYAN} Rama: ${BOLD}$BRANCH${NC}"
    
    CHANGES=$(git status --short | wc -l)
    UNTRACKED=$(git status --short | grep "^??" | wc -l)
    MODIFIED=$(git status --short | grep "^ M" | wc -l)
    STAGED=$(git status --short | grep "^M" | wc -l)
    
    echo ""
    echo -e "${BOLD} Resumen:${NC}"
    [ $STAGED -gt 0 ] && echo -e "  ${GREEN} Staged: $STAGED${NC}"
    [ $MODIFIED -gt 0 ] && echo -e "  ${YELLOW} Modificados: $MODIFIED${NC}"
    [ $UNTRACKED -gt 0 ] && echo -e "  ${RED} Sin seguimiento: $UNTRACKED${NC}"
    [ $CHANGES -eq 0 ] && echo -e "  ${GREEN} Todo limpio${NC}"
    
    echo ""
    echo -e "${BLUE} Ultimos cambios:${NC}"
    git log --oneline -3 2>/dev/null || echo "  Sin commits aun"
    
else
    echo -e "${YELLOW} No detectado repositorio Git${NC}"
    echo ""
    echo -e "${BOLD} Proyectos en ~/proyectos/:${NC}"
    
    if [ "$(ls -A ~/proyectos 2>/dev/null)" ]; then
        ls -d ~/proyectos/*/ 2>/dev/null | while read dir; do
            DIR_NAME=$(basename "$dir")
            if [ -d "$dir/.git" ]; then
                echo -e "  ${GREEN} $DIR_NAME ${NC}(Git)"
            else
                echo -e "  $DIR_NAME"
            fi
        done
    else
        echo -e "  ${RED}(carpeta vacia)${NC}"
    fi
    
    echo ""
    echo -e "${CYAN} Para empezar un proyecto:${NC}"
    echo -e "  cd ~/proyectos"
    echo -e "  git clone <url>"
    echo -e "  mkdir mi-proyecto && cd mi-proyecto && git init"
fi

echo ""
echo -e "${BLUE}============================================${NC}"
echo -e "${BOLD} Alias rapidos:${NC}"
echo -e "  ${YELLOW}gs${NC}   git status    ${YELLOW}ga${NC}   git add ."
echo -e "  ${YELLOW}gc${NC}   git commit    ${YELLOW}gp${NC}   git push"
echo -e "  ${YELLOW}gl${NC}   git log       ${YELLOW}gco${NC}  git checkout"
echo -e "  ${YELLOW}gcb${NC}  nueva rama    ${YELLOW}..${NC}   cd .."
echo -e "${BLUE}============================================${NC}"

exec bash
