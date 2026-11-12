#!/usr/bin/env bash
#
# ~/dotfiles/scripts/import_apps.sh
#
# Compara el ESTADO DESEADO (apps/manifest.yaml, filtrado por machine-type)
# contra el ESTADO INSTALADO REAL, y propone SOLO instalaciones de lo que
# falta y cumple todas las reglas de candidatura automática.
#
# NUNCA modifica manifest.yaml. NUNCA ejecuta export_apps.sh.
# NUNCA desinstala nada. NUNCA agrega repositorios/claves de terceros.
#
# Uso:
#   ./import_apps.sh --preview                    (default)
#   ./import_apps.sh --preview --check-releases   (consulta la API de GitHub)
#   ./import_apps.sh --apply
#   ./import_apps.sh --apply --machine=escritorio
#
# --check-releases: verifica contra la API pública de GitHub (sin token,
# 60 consultas/hora por IP) que el asset declarado de cada binario existe
# y tiene digest SHA256 oficial. Una consulta por binario con 'asset'.
# Sin este flag, el script no consulta la API de GitHub.

set -euo pipefail

DOTFILES_DIR="${DOTFILES_DIR:-$HOME/dotfiles}"
MANIFEST="$DOTFILES_DIR/apps/manifest.yaml"
MODE="preview"
MACHINE_OVERRIDE=""
CHECK_RELEASES="0"

for arg in "$@"; do
  case "$arg" in
    --preview) MODE="preview" ;;
    --apply) MODE="apply" ;;
    --machine=*) MACHINE_OVERRIDE="${arg#*=}" ;;
    --check-releases) CHECK_RELEASES="1" ;;
    *) echo "Argumento desconocido: $arg" >&2; exit 1 ;;
  esac
done

TMPDIR="$(mktemp -d)"
cleanup() { rm -rf "$TMPDIR"; }
trap cleanup EXIT

echo "=== import_apps.sh — modo $MODE ==="

# --- 1. Pre-flight ---
if ! command -v python3 >/dev/null 2>&1; then
  echo "ERROR: python3 no está disponible. Abortando." >&2
  exit 1
fi
if ! python3 -c "import yaml" >/dev/null 2>&1; then
  echo "ERROR: falta la dependencia python3-yaml." >&2
  echo "Instálala con: sudo apt install python3-yaml" >&2
  exit 1
fi
if [[ ! -f "$MANIFEST" ]]; then
  echo "ERROR: no existe $MANIFEST. Abortando." >&2
  exit 1
fi
if ! python3 -c "import yaml; yaml.safe_load(open('$MANIFEST'))" >/dev/null 2>&1; then
  echo "ERROR: $MANIFEST no es YAML válido. Abortando." >&2
  exit 1
fi

# Motor Python del script: archivo real del repo (scripts/lib/import_engine.py).
# readlink -f resuelve el script aunque se invoque por un enlace simbólico.
SCRIPT_DIR="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"
ENGINE="$SCRIPT_DIR/lib/import_engine.py"
if [[ ! -f "$ENGINE" ]]; then
  echo "ERROR: no existe el motor $ENGINE. Abortando." >&2
  exit 1
fi

# --- 2. machine-type ---
if [[ -n "$MACHINE_OVERRIDE" ]]; then
  MACHINE_TYPE="$MACHINE_OVERRIDE"
elif [[ -f "$HOME/.config/machine-type" ]]; then
  MACHINE_TYPE="$(cat "$HOME/.config/machine-type")"
else
  echo "ERROR: no se pudo determinar machine-type (~/.config/machine-type no existe)." >&2
  exit 1
fi
echo "Máquina detectada: $MACHINE_TYPE"
echo

# --- 3. Prerrequisitos por manager ---
: > "$TMPDIR/prereqs.txt"

# Flatpak: el remote flathub se comprueba POR SCOPE, porque cada candidata
# se instala en el scope que declara (install_scope). Claves: flatpak_user
# y flatpak_system.
if command -v flatpak >/dev/null 2>&1; then
  for fp_scope in user system; do
    if flatpak remotes "--$fp_scope" --columns=name 2>/dev/null | grep -qi '^flathub$'; then
      echo "flatpak_${fp_scope}|ok" >> "$TMPDIR/prereqs.txt"
    else
      echo "flatpak_${fp_scope}|no_flathub" >> "$TMPDIR/prereqs.txt"
    fi
  done
else
  echo "flatpak_user|missing" >> "$TMPDIR/prereqs.txt"
  echo "flatpak_system|missing" >> "$TMPDIR/prereqs.txt"
fi

if command -v snap >/dev/null 2>&1; then
  echo "snap|ok" >> "$TMPDIR/prereqs.txt"
else
  echo "snap|missing" >> "$TMPDIR/prereqs.txt"
fi

if command -v apt-get >/dev/null 2>&1; then
  echo "apt|ok" >> "$TMPDIR/prereqs.txt"
else
  echo "apt|missing" >> "$TMPDIR/prereqs.txt"
fi

# --- 4a. Detección: TODOS los flatpak instalados ---
flatpak list --app --columns=application 2>/dev/null > "$TMPDIR/flatpak_installed.txt" || true

# --- 4a-bis. Detección de scope real por app (C3-H) ---
# Uso exclusivo: permitir comparar install_scope declarado contra el scope
# real y emitir [WARN_SCOPE] informativo. No sustituye ni altera
# flatpak_installed.txt de arriba, que sigue siendo la única fuente para
# determinar si una app "está instalada" (en cualquiera de los dos scopes).
flatpak list --app --user --columns=application 2>/dev/null > "$TMPDIR/flatpak_installed_user.txt" || true
flatpak list --app --system --columns=application 2>/dev/null > "$TMPDIR/flatpak_installed_system.txt" || true

# --- 4b. Detección: TODOS los snap instalados, filtrados a type:app ---
: > "$TMPDIR/snap_installed.txt"
is_snap_app() {
  local name="$1"
  snap info "$name" 2>/dev/null | awk -F': ' '/^type:/{print $2; exit}' | grep -qx "app"
}
if command -v snap >/dev/null 2>&1; then
  while IFS= read -r line; do
    name="$(awk '{print $1}' <<< "$line")"
    [[ -z "$name" ]] && continue
    if is_snap_app "$name"; then
      echo "$name" >> "$TMPDIR/snap_installed.txt"
    fi
  done < <(snap list 2>/dev/null | tail -n +2)
fi

# --- 4c. Detección: estado apt de TODAS las entradas apt declaradas ---
python3 -c "
import yaml
data = yaml.safe_load(open('$MANIFEST'))
for a in data['apps']:
    if a['manager'] == 'apt':
        print(a['app'])
" > "$TMPDIR/apt_declared.txt"

: > "$TMPDIR/apt_status.txt"
while IFS= read -r pkg; do
  [[ -z "$pkg" ]] && continue
  # ^[ih]i: instalado ('ii') o instalado y retenido con apt-mark hold ('hi').
  if dpkg -l "$pkg" 2>/dev/null | grep -q "^[ih]i"; then
    echo "${pkg}|installed" >> "$TMPDIR/apt_status.txt"
  else
    echo "${pkg}|missing" >> "$TMPDIR/apt_status.txt"
  fi
done < "$TMPDIR/apt_declared.txt"

# --- 4d. Detección: estado de TODOS los binarios declarados ---
python3 -c "
import yaml, hashlib, os
data = yaml.safe_load(open('$MANIFEST'))
for a in data['apps']:
    if a['manager'] != 'binary':
        continue
    dest = (a.get('source') or {}).get('destination')
    if not dest:
        print(f\"{a['app']}|nodest\")
        continue
    dest = os.path.expanduser(dest)
    if os.path.isfile(dest):
        print(f\"{a['app']}|installed\")
    else:
        print(f\"{a['app']}|missing\")
" > "$TMPDIR/binary_status.txt"

# --- 5. Motor Python: scripts/lib/import_engine.py (archivo real, stdin libre para input()) ---
# -B: no escribe __pycache__ en scripts/lib al importar common.py.
python3 -B "$ENGINE" \
  "$MANIFEST" "$MACHINE_TYPE" "$MODE" \
  "$TMPDIR/flatpak_installed.txt" "$TMPDIR/snap_installed.txt" \
  "$TMPDIR/apt_status.txt" "$TMPDIR/binary_status.txt" "$TMPDIR/prereqs.txt" \
  "$TMPDIR/flatpak_installed_user.txt" "$TMPDIR/flatpak_installed_system.txt" \
  "$CHECK_RELEASES"
ENGINE_EXIT=$?

echo
echo "=== import_apps.sh finalizado (código: $ENGINE_EXIT) ==="
exit "$ENGINE_EXIT"
