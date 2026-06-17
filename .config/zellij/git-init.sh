#!/bin/bash
DIM='\033[2;37m'
GREY='\033[0;37m'
MUTED='\033[38;5;240m'
SOFT='\033[38;5;245m'
ACCENT='\033[38;5;39m'
BRANCH='\033[38;5;214m'
NC='\033[0m'

clear

cd ~/github || exit

# ── GITFLOW ────────────────────────────────────────
echo -e "\n${MUTED}─── GITFLOW ──────────────────────────────────${NC}"
echo -e " ${SOFT}Feature${NC}                      ${SOFT}Merge & Push${NC}"
echo -e "  ${ACCENT}git flow feature start${NC} ${DIM}<n>${NC}"
echo -e "  ${DIM}git add . && git commit -m ${BRANCH}\"feat: ...\"${NC}"
echo -e "  ${ACCENT}git flow feature finish${NC} ${DIM}<n>${NC}"
echo -e "  ${DIM}git push origin develop${NC}"
echo -e ""
echo -e " ${SOFT}Release${NC}                      ${SOFT}Hotfix${NC}"
echo -e "  ${ACCENT}git flow release start${NC} ${DIM}<v>${NC}   ${ACCENT}git flow hotfix start${NC} ${DIM}<v>${NC}"
echo -e "  ${ACCENT}git flow release finish${NC} ${DIM}<v>${NC}  ${ACCENT}git flow hotfix finish${NC} ${DIM}<v>${NC}"
echo -e "  ${DIM}git push origin main --tags${NC}"

# ── CONVENTIONAL COMMITS ───────────────────────────
echo -e "\n${MUTED}─── COMMITS ──────────────────────────────────${NC}"
printf "  ${BRANCH}%-8s${NC}${DIM}%-18s${NC}  ${BRANCH}%-8s${NC}${DIM}%s${NC}\n" "feat:"  "nueva función"   "fix:"   "corrección"
printf "  ${BRANCH}%-8s${NC}${DIM}%-18s${NC}  ${BRANCH}%-8s${NC}${DIM}%s${NC}\n" "docs:"  "documentación"  "chore:" "ajuste/config"

# ── ALIAS ──────────────────────────────────────────
echo -e "\n${MUTED}─── ALIAS ────────────────────────────────────${NC}"
printf "  ${ACCENT}%-5s${NC}${DIM}%-16s${NC}${ACCENT}%-5s${NC}${DIM}%s${NC}\n" "gs" "status"    "ga"  "add ."
printf "  ${ACCENT}%-5s${NC}${DIM}%-16s${NC}${ACCENT}%-5s${NC}${DIM}%s${NC}\n" "gc" "commit"    "gp"  "push"
printf "  ${ACCENT}%-5s${NC}${DIM}%-16s${NC}${ACCENT}%-5s${NC}${DIM}%s${NC}\n" "gl" "tree"      "gco" "checkout"
printf "  ${ACCENT}%-5s${NC}${DIM}%-16s${NC}${ACCENT}%-5s${NC}${DIM}%s${NC}\n" "gcb" "new branch" ".."  "cd .."
echo -e "${MUTED}──────────────────────────────────────────────${NC}"

exec fish
