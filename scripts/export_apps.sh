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
  if dpkg -l "$pkg" 2>/dev/null | grep -q "^ii"; then
    ver="$(dpkg -l "$pkg" 2>/dev/null | awk '/^ii/{print $3}')"
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

# --- 4. Escribir el motor Python a un ARCHIVO real (no heredoc-a-stdin) ---
#      Esto preserva stdin para input() en modo --apply.
cat > "$TMPDIR/engine.py" <<'PYEOF'
import sys, yaml, shutil, datetime, os

def main():
    (manifest_path, equivalences_path, machine_type, mode,
     flatpak_file, snap_apps_file, apt_status_file, binary_status_file) = sys.argv[1:9]

    data = yaml.safe_load(open(manifest_path))
    apps = data['apps']

    equiv_data = yaml.safe_load(open(equivalences_path)) or {}
    alias_table = equiv_data.get('aliases', {}) or {}

    declared_flatpak = {a['app'] for a in apps if a['manager'] == 'flatpak'}
    declared_snap = {a['app'] for a in apps if a['manager'] == 'snap'}

    flatpak_installed = set()
    if os.path.isfile(flatpak_file):
        with open(flatpak_file) as f:
            flatpak_installed = {l.strip() for l in f if l.strip()}

    snap_installed = set()
    if os.path.isfile(snap_apps_file):
        with open(snap_apps_file) as f:
            snap_installed = {l.strip() for l in f if l.strip()}

    undeclared_flatpak = sorted(flatpak_installed - declared_flatpak)
    undeclared_snap = sorted(snap_installed - declared_snap)

    print("--- Flatpak: nuevas apps instaladas no declaradas ---")
    if not undeclared_flatpak:
        print("  (ninguna)")
    else:
        for i in undeclared_flatpak:
            print(f"  + {i}")
    print()

    print("--- Snap (solo type:app real, bases/runtimes excluidos): nuevas apps no declaradas ---")
    if not undeclared_snap:
        print("  (ninguna)")
    else:
        for i in undeclared_snap:
            print(f"  + {i}")
    print()

    print("--- APT (alcance limitado a lo ya declarado): verificación ---")
    if os.path.isfile(apt_status_file) and os.path.getsize(apt_status_file) > 0:
        with open(apt_status_file) as f:
            for line in f:
                status, pkg, ver = line.strip().split('|')
                print(f"  [{status}] {pkg:<20} {ver}")
    else:
        print("  (sin entradas apt declaradas)")
    print()

    print("--- Binarios declarados: verificación de presencia/hash ---")
    if os.path.isfile(binary_status_file) and os.path.getsize(binary_status_file) > 0:
        with open(binary_status_file) as f:
            for line in f:
                status, app, path = line.strip().split('|')
                print(f"  [{status}] {app:<20} {path}")
    else:
        print("  (sin entradas binary declaradas)")
    print()

    total_new = len(undeclared_flatpak) + len(undeclared_snap)
    print("=== Resumen ===")
    print(f"{total_new} apps nuevas detectadas para posible declaración.")

    if mode == "preview":
        print("(Modo preview: no se solicitó confirmación, no se escribió nada.)")
        return 0

    if total_new == 0:
        print("Nada que declarar. Saliendo sin cambios.")
        return 0

    print()
    print("=== Modo --apply: revisión interactiva ===")

    new_entries = []

    def process(app_id, manager):
        alias_key = f"{manager}:{app_id}"
        suggested_eq = alias_table.get(alias_key)

        print(f"\n--- Nueva app detectada: {app_id} ({manager}) ---")

        if suggested_eq:
            resp = input(
                f"  La tabla de equivalencias sugiere que esto es la misma "
                f"aplicación que '{suggested_eq}' (ya declarada como preferida "
                f"por otro manager). ¿Confirmas que es la misma app? [s/N]: "
            ).strip().lower()
            if resp == 's':
                entry = {
                    'app': app_id, 'display_name': app_id, 'manager': manager,
                    'equivalence_id': suggested_eq, 'scope': 'machine',
                    'machines': [machine_type], 'state': 'present',
                    'status': 'duplicate', 'preferred': False,
                    'install_policy': 'manual', 'source': {},
                    'notes': f'Detectado por export_apps.sh, confirmado como '
                             f'duplicado de {suggested_eq} vía tabla de equivalencias.'
                }
                new_entries.append(entry)
                return
            print("  Tratado como aplicación nueva (no confirmado como equivalente).")

        scope_resp = input("  Scope [common(default)/machine/omitir]: ").strip().lower() or 'common'
        if scope_resp == 'omitir':
            print("  Omitida por el usuario.")
            return
        if scope_resp not in ('common', 'machine'):
            print(f"  Valor no reconocido ('{scope_resp}'), se omite esta app por seguridad.")
            return

        default_eq = ''.join(c for c in app_id.lower() if c.isalnum() or c == '-')
        eq_id_resp = input(f"  equivalence_id [{default_eq}]: ").strip() or default_eq
        machines = [machine_type] if scope_resp == 'machine' else []

        entry = {
            'app': app_id, 'display_name': app_id, 'manager': manager,
            'equivalence_id': eq_id_resp, 'scope': scope_resp,
            'machines': machines, 'state': 'present', 'status': 'ok',
            'preferred': True, 'install_policy': 'auto', 'source': {},
            'notes': f'Agregado por export_apps.sh el {datetime.date.today()}.'
        }
        new_entries.append(entry)

    for app_id in undeclared_flatpak:
        process(app_id, 'flatpak')
    for app_id in undeclared_snap:
        process(app_id, 'snap')

    if not new_entries:
        print("\nNingún cambio confirmado. No se modifica el manifest.")
        return 0

    print("\n=== Cambios a aplicar ===")
    for e in new_entries:
        print(f"  + {e['app']} ({e['manager']}) scope={e['scope']} preferred={e['preferred']}")

    confirm = input("\n¿Escribir estos cambios en manifest.yaml? [s/N]: ").strip().lower()
    if confirm != 's':
        print("Cancelado por el usuario. No se modifica el manifest.")
        return 0

    backup_path = f"{manifest_path}.bak.{datetime.datetime.now():%Y%m%d%H%M%S}"
    shutil.copy2(manifest_path, backup_path)
    print(f"Backup creado: {backup_path}")

    data['apps'].extend(new_entries)
    with open(manifest_path, 'w') as f:
        yaml.dump(data, f, allow_unicode=True, sort_keys=False, default_flow_style=False)

    ok, error = revalidate(manifest_path)
    if not ok:
        print(f"\nERROR de invariante tras escribir: {error}")
        print("Restaurando backup automáticamente...")
        shutil.copy2(backup_path, manifest_path)
        return 1

    print("\nManifest actualizado y revalidado correctamente.")
    print(f"Se agregaron {len(new_entries)} entrada(s) nueva(s).")
    print("Recuerda: esto NO hizo git add/commit/push. Eso sigue siendo manual (dotpush).")
    return 0


def revalidate(path):
    d = yaml.safe_load(open(path))
    apps = d['apps']
    groups = {}
    for a in apps:
        groups.setdefault(a['equivalence_id'], []).append(a)
    for eq, entries in groups.items():
        preferred = [e for e in entries if e['preferred']]
        if len(preferred) > 1:
            return False, f"equivalence_id '{eq}' tiene más de un preferred:true"
    for a in apps:
        if a['preferred'] is False and a['install_policy'] != 'manual':
            return False, f"{a['app']}: preferred:false pero install_policy != manual"
        if a['status'] == 'broken' and a['install_policy'] != 'manual':
            return False, f"{a['app']}: status:broken pero install_policy != manual"
    return True, ""


if __name__ == "__main__":
    sys.exit(main())
PYEOF

# --- 5. Ejecutar el motor como archivo real (stdin queda libre para input()) ---
python3 "$TMPDIR/engine.py" \
  "$MANIFEST" "$EQUIVALENCES" "$MACHINE_TYPE" "$MODE" \
  "$TMPDIR/flatpak_installed.txt" "$TMPDIR/snap_apps.txt" \
  "$TMPDIR/apt_status.txt" "$TMPDIR/binary_status.txt"
ENGINE_EXIT=$?

echo
echo "=== export_apps.sh finalizado (código: $ENGINE_EXIT) ==="
exit "$ENGINE_EXIT"
