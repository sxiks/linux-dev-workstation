#!/usr/bin/env bash
#
# ~/dotfiles/scripts/restore_config.sh
#
# Aplica en ESTE PC la configuración guardada en el repo (apps/configs/<id>/files/).
# Antes de sobrescribir hace backup en ~/.local/state/dotfiles/config-backups/.
#
# Perfiles de configuración (CF1): ver docs/CONFIGS.md.
# Solo viaja configuración; nunca estado (historial, sesiones) ni secretos.
#
# Uso:
#   ./restore_config.sh zen-browser                 (preview: qué cambiaría en este PC)
#   ./restore_config.sh zen-browser --diff          (preview con el detalle de cada cambio)
#   ./restore_config.sh zen-browser --apply         (escribe; pide confirmación)
#   ./restore_config.sh zen-browser --apply --yes   (sin preguntar; para el bootstrap)
#
# Con --apply la app tiene que estar cerrada. Sin terminal, --apply exige --yes.

set -euo pipefail

DOTFILES_DIR="${DOTFILES_DIR:-$HOME/dotfiles}"
MODE="preview"
ASSUME_YES="0"
SHOW_DIFF="0"
PROFILE_ID=""

for arg in "$@"; do
  case "$arg" in
    --preview) MODE="preview" ;;
    --apply) MODE="apply" ;;
    --yes) ASSUME_YES="1" ;;
    --diff) SHOW_DIFF="1" ;;
    -*) echo "Argumento desconocido: $arg" >&2; exit 1 ;;
    *)
      if [[ -n "$PROFILE_ID" ]]; then
        echo "ERROR: indica un solo perfil (recibidos: $PROFILE_ID y $arg)." >&2
        exit 1
      fi
      PROFILE_ID="$arg"
      ;;
  esac
done

if [[ -z "$PROFILE_ID" ]]; then
  echo "Uso: $(basename "$0") <perfil> [--preview|--apply] [--yes] [--diff]" >&2
  if [[ -d "$DOTFILES_DIR/apps/configs" ]]; then
    echo "Perfiles disponibles:" >&2
    for d in "$DOTFILES_DIR"/apps/configs/*/config.yaml; do
      [[ -f "$d" ]] && echo "  $(basename "$(dirname "$d")")" >&2
    done
  fi
  exit 1
fi
if [[ "$ASSUME_YES" == "1" && "$MODE" != "apply" ]]; then
  echo "ERROR: --yes solo tiene sentido con --apply." >&2
  exit 1
fi

echo "=== restore_config.sh — modo $MODE ==="

if ! command -v python3 >/dev/null 2>&1; then
  echo "ERROR: python3 no está disponible. Abortando." >&2
  exit 1
fi
if ! python3 -c "import yaml" >/dev/null 2>&1; then
  echo "ERROR: falta la dependencia python3-yaml (sudo apt install python3-yaml)." >&2
  exit 1
fi

# Motor compartido con capture_config.sh: scripts/lib/config_engine.py.
SCRIPT_DIR="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"
ENGINE="$SCRIPT_DIR/lib/config_engine.py"
if [[ ! -f "$ENGINE" ]]; then
  echo "ERROR: no existe el motor $ENGINE. Abortando." >&2
  exit 1
fi

# -B: no escribe __pycache__ en scripts/lib.
set +e
python3 -B "$ENGINE" "$DOTFILES_DIR" "restore" "$PROFILE_ID" "$MODE" "$ASSUME_YES" "$SHOW_DIFF"
ENGINE_EXIT=$?
set -e

echo
echo "=== restore_config.sh finalizado (código: $ENGINE_EXIT) ==="
exit "$ENGINE_EXIT"
