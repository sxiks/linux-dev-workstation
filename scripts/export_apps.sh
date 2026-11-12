#!/usr/bin/env bash
#
# ~/dotfiles/scripts/export_apps.sh
#
# Compara el estado instalado real (Flatpak, Snap filtrado a apps reales, y
# verificación de APT/binarios ya declarados) contra apps/manifest.yaml, y
# propone SOLO altas de aplicaciones nuevas mediante diff explícito.
#
# NO calcula ni actúa sobre "declarado pero no instalado" (responsabilidad
# de import_apps.sh, Fase C3).
# NUNCA sobrescribe el manifest completo, NUNCA instala, NUNCA desinstala,
# NUNCA hace git add/commit/push.
#
# Uso:
#   ./export_apps.sh --preview                       (default)
#   ./export_apps.sh --apply
#   ./export_apps.sh --apply --machine=escritorio

set -euo pipefail

DOTFILES_DIR="${DOTFILES_DIR:-$HOME/dotfiles}"
MANIFEST="$DOTFILES_DIR/apps/manifest.yaml"
EQUIVALENCES="$DOTFILES_DIR/apps/equivalences.yaml"
MODE="preview"
MACHINE_OVERRIDE=""

for arg in "$@"; do
  case "$arg" in
    --preview) MODE="preview" ;;
    --apply) MODE="apply" ;;
    --machine=*) MACHINE_OVERRIDE="${arg#*=}" ;;
    *) echo "Argumento desconocido: $arg" >&2; exit 1 ;;
  esac
done

TMPDIR="$(mktemp -d)"
cleanup() { rm -rf "$TMPDIR"; }
trap cleanup EXIT

echo "=== export_apps.sh — modo $MODE ==="

# --- 1. Pre-flight ---
if ! command -v python3 >/dev/null 2>&1; then
  echo "ERROR: python3 no está disponible. Abortando sin cambios." >&2
  exit 1
fi
if ! python3 -c "import yaml" >/dev/null 2>&1; then
  echo "ERROR: falta la dependencia python3-yaml." >&2
  echo "Instálala con: sudo apt install python3-yaml" >&2
  echo "(Esta dependencia se integrará a install.sh en la Fase E — Bootstrap.)" >&2
  exit 1
fi
if [[ ! -f "$MANIFEST" ]]; then
  echo "ERROR: no existe $MANIFEST. Abortando." >&2
  exit 1
fi
if ! python3 -c "import yaml; yaml.safe_load(open('$MANIFEST'))" >/dev/null 2>&1; then
  echo "ERROR: $MANIFEST no es YAML válido. Abortando sin cambios." >&2
  exit 1
fi
if [[ ! -f "$EQUIVALENCES" ]]; then
  echo "AVISO: no existe $EQUIVALENCES todavía. Se tratará como tabla de alias vacía." >&2
  echo "aliases: {}" > "$TMPDIR/equivalences.yaml"
  EQUIVALENCES="$TMPDIR/equivalences.yaml"
elif ! python3 -c "import yaml; yaml.safe_load(open('$EQUIVALENCES'))" >/dev/null 2>&1; then
  echo "ERROR: $EQUIVALENCES no es YAML válido. Abortando sin cambios." >&2
  exit 1
fi

# Motor Python del script: archivo real del repo (scripts/lib/export_engine.py).
# readlink -f resuelve el script aunque se invoque por un enlace simbólico.
SCRIPT_DIR="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"
ENGINE="$SCRIPT_DIR/lib/export_engine.py"
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

# --- 3a. Detección: Flatpak -> archivo temporal, una app por línea ---
flatpak list --app --columns=application 2>/dev/null > "$TMPDIR/flatpak_installed.txt" || true

# --- 3a-bis. Detección de scope real por app (C3-H) ---
# Uso exclusivo: permitir que process() asigne install_scope a NUEVAS
# entradas sin inventar el valor. No sustituye ni altera el listado
# combinado de arriba (flatpak_installed.txt), que sigue siendo la única
# fuente para el diff de "apps no declaradas" mostrado en --preview.
flatpak list --app --user --columns=application 2>/dev/null > "$TMPDIR/flatpak_installed_user.txt" || true
flatpak list --app --system --columns=application 2>/dev/null > "$TMPDIR/flatpak_installed_system.txt" || true

# --- 3b. Detección: Snap, filtrado a type:app real (no bases/runtimes) ---
: > "$TMPDIR/snap_apps.txt"
: > "$TMPDIR/snap_status.txt"   # formato: name|status(ok|broken)

is_snap_app() {
  local name="$1"
  snap info "$name" 2>/dev/null | awk -F': ' '/^type:/{print $2; exit}' | grep -qx "app"
}

if command -v snap >/dev/null 2>&1; then
  while IFS= read -r line; do
    name="$(awk '{print $1}' <<< "$line")"
    [[ -z "$name" ]] && continue
    if is_snap_app "$name"; then
      echo "$name" >> "$TMPDIR/snap_apps.txt"
      if grep -qw "broken" <<< "$line"; then
        echo "${name}|broken" >> "$TMPDIR/snap_status.txt"
      else
        echo "${name}|ok" >> "$TMPDIR/snap_status.txt"
      fi
    fi
    # snaps que no son type:app (core*, bare, snapd, gtk-common-themes, etc.)
    # se omiten deliberadamente: nunca se consideran candidatos a aplicación.
  done < <(snap list 2>/dev/null | tail -n +2)
fi

# --- 3c. Detección: APT (solo paquetes ya declarados en el manifest) ---
: > "$TMPDIR/apt_status.txt"
python3 -c "
import yaml
data = yaml.safe_load(open('$MANIFEST'))
for a in data['apps']:
    if a['manager'] == 'apt':
        print(a['app'])
" > "$TMPDIR/apt_declared.txt"

while IFS= read -r pkg; do
  [[ -z "$pkg" ]] && continue
  # ^[ih]i: instalado ('ii') o instalado y retenido con apt-mark hold ('hi').
  if dpkg -l "$pkg" 2>/dev/null | grep -q "^[ih]i"; then
    ver="$(dpkg -l "$pkg" 2>/dev/null | awk '/^[ih]i/{print $3}')"
    echo "OK|$pkg|$ver" >> "$TMPDIR/apt_status.txt"
  else
    echo "MISSING|$pkg|-" >> "$TMPDIR/apt_status.txt"
  fi
done < "$TMPDIR/apt_declared.txt"

# --- 3d. Detección: binarios declarados (presencia + hash) ---
python3 -c "
import yaml, hashlib, os

data = yaml.safe_load(open('$MANIFEST'))
for a in data['apps']:
    if a['manager'] != 'binary':
        continue
    dest = (a.get('source') or {}).get('destination')
    if not dest:
        print(f\"NODEST|{a['app']}|-\")
        continue
    dest = os.path.expanduser(dest)
    if not os.path.isfile(dest):
        print(f\"ABSENT|{a['app']}|{dest}\")
        continue
    verification = (a.get('source') or {}).get('verification', '') or ''
    if verification.startswith('sha256:'):
        expected = verification.split('sha256:')[1].split()[0]
        real = hashlib.sha256(open(dest, 'rb').read()).hexdigest()
        status = 'OK' if real == expected else 'HASHDIFF'
        print(f'{status}|{a[\"app\"]}|{dest}')
    else:
        print(f'UNVERIFIED|{a[\"app\"]}|{dest}')
" > "$TMPDIR/binary_status.txt"

# --- 4. Motor Python: scripts/lib/export_engine.py ---
#      Se ejecuta como archivo real: stdin queda libre para input() en --apply.
# -B: no escribe __pycache__ en scripts/lib al importar common.py.
python3 -B "$ENGINE" \
  "$MANIFEST" "$EQUIVALENCES" "$MACHINE_TYPE" "$MODE" \
  "$TMPDIR/flatpak_installed.txt" "$TMPDIR/snap_apps.txt" \
  "$TMPDIR/apt_status.txt" "$TMPDIR/binary_status.txt" \
  "$TMPDIR/flatpak_installed_user.txt" "$TMPDIR/flatpak_installed_system.txt"
ENGINE_EXIT=$?

echo
echo "=== export_apps.sh finalizado (código: $ENGINE_EXIT) ==="
exit "$ENGINE_EXIT"
