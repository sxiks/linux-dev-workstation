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
#   ./import_apps.sh --apply
#   ./import_apps.sh --apply --machine=escritorio

set -euo pipefail

DOTFILES_DIR="${DOTFILES_DIR:-$HOME/dotfiles}"
MANIFEST="$DOTFILES_DIR/apps/manifest.yaml"
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

if command -v flatpak >/dev/null 2>&1; then
  if flatpak remotes --user --columns=name 2>/dev/null | grep -qi '^flathub$'; then
    echo "flatpak|ok" >> "$TMPDIR/prereqs.txt"
  else
    echo "flatpak|no_flathub" >> "$TMPDIR/prereqs.txt"
  fi
else
  echo "flatpak|missing" >> "$TMPDIR/prereqs.txt"
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
  if dpkg -l "$pkg" 2>/dev/null | grep -q "^ii"; then
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

# --- 5. Motor Python (archivo real, stdin libre para input()) ---
cat > "$TMPDIR/engine.py" <<'PYEOF'
import sys, yaml, os, subprocess

def load_lines(path):
    if not os.path.isfile(path):
        return set()
    with open(path) as f:
        return {l.strip() for l in f if l.strip()}

def load_pairs(path):
    d = {}
    if not os.path.isfile(path):
        return d
    with open(path) as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            k, v = line.split('|', 1)
            d[k] = v
    return d

def applies_to_machine(entry, machine_type):
    if entry['scope'] == 'common':
        return True
    return machine_type in (entry.get('machines') or [])

def is_installed(entry, flatpak_set, snap_set, apt_status, binary_status):
    m = entry['manager']
    if m == 'flatpak':
        return entry['app'] in flatpak_set
    if m == 'snap':
        return entry['app'] in snap_set
    if m == 'apt':
        return apt_status.get(entry['app']) == 'installed'
    if m == 'binary':
        return binary_status.get(entry['app']) == 'installed'
    return False


def classify(apps, machine_type, flatpak_set, snap_set, apt_status, binary_status):
    candidatas, ya_instaladas, skip_equiv = [], [], []
    manuales, ignoradas, fuera_scope = [], [], []

    installed_map = {}
    for a in apps:
        installed_map[(a['manager'], a['app'])] = is_installed(
            a, flatpak_set, snap_set, apt_status, binary_status)

    for a in apps:
        if not applies_to_machine(a, machine_type):
            fuera_scope.append(a)
            continue
        if a['status'] == 'broken':
            ignoradas.append((a, 'broken'))
            continue
        if not a['preferred']:
            ignoradas.append((a, 'no preferida / duplicado'))
            continue

        # Regla dura: apt_third_party_repo siempre manual, independientemente
        # de install_policy. Y toda entrada install_policy:manual va siempre
        # a la sección MANUAL, esté o no instalada -- así se conserva la
        # visibilidad de fuente/versión/destino que se pidió explícitamente,
        # en vez de "esconderla" dentro de "ya instaladas".
        is_third_party_repo = (a.get('source') or {}).get('download_method') == 'apt_third_party_repo'
        if a['install_policy'] == 'manual' or is_third_party_repo:
            manuales.append(a)
            continue

        installed_here = installed_map[(a['manager'], a['app'])]
        if installed_here:
            ya_instaladas.append(a)
            continue

        # ¿Algún hermano de equivalencia ya instalado?
        hermano_instalado = None
        for b in apps:
            if b is a:
                continue
            if b['equivalence_id'] != a['equivalence_id']:
                continue
            if installed_map.get((b['manager'], b['app'])):
                hermano_instalado = b
                break
        if hermano_instalado:
            skip_equiv.append((a, hermano_instalado))
            continue

        candidatas.append(a)

    return candidatas, ya_instaladas, skip_equiv, manuales, ignoradas, fuera_scope


def print_preview(candidatas, ya_instaladas, skip_equiv, manuales, ignoradas, fuera_scope):
    print("--- Candidatas automáticas (se instalarían con --apply) ---")
    if not candidatas:
        print("  (ninguna)")
    for a in candidatas:
        print(f"  [FALTA] {a['display_name']:<20} {a['manager']:<8} {a['app']}")
    print()

    print("--- Ya instaladas (sin acción) ---")
    if not ya_instaladas:
        print("  (ninguna)")
    for a in ya_instaladas:
        print(f"  [OK] {a['display_name']:<20} {a['manager']:<8} {a['app']}")
    print()

    print("--- Bloqueadas por equivalencia ya instalada (sin acción) ---")
    if not skip_equiv:
        print("  (ninguna)")
    for a, hermano in skip_equiv:
        print(f"  [SKIP] {a['display_name']}: equivalente ya instalado vía "
              f"{hermano['manager']} ({hermano['app']}). "
              f"Manifest prefiere {a['manager']}. No se instala automáticamente.")
    print()

    print("--- Declaradas como manual (acción humana pendiente) ---")
    if not manuales:
        print("  (ninguna)")
    for a in manuales:
        src = a.get('source') or {}
        estado = "instalado" if src.get('_installed') else "falta"
        version = src.get('version', '-')
        origin = src.get('origin') or src.get('repo_url') or 'pendiente'
        dest = src.get('destination', '-')
        print(f"  [MANUAL][{estado}] {a['display_name']:<18} {a['manager']:<8} "
              f"v={version} origen={origin} destino={dest}")
    print()

    print("--- Ignoradas (broken / no preferidas, nunca candidatas) ---")
    if not ignoradas:
        print("  (ninguna)")
    for a, razon in ignoradas:
        print(f"  [IGNORED] {a['display_name']:<20} {a['manager']:<8} motivo={razon}")
    print()

    print("--- Fuera de scope (pertenecen a otra máquina) ---")
    if not fuera_scope:
        print("  (ninguna)")
    for a in fuera_scope:
        print(f"  [SCOPE] {a['display_name']:<20} machines={a.get('machines')}")
    print()

    print("=== Resumen ===")
    print(f"{len(candidatas)} candidatas para instalar automáticamente.")
    print(f"{len(ya_instaladas)} ya instaladas (sin acción).")
    print(f"{len(skip_equiv)} bloqueadas por equivalencia ya instalada.")
    print(f"{len(manuales)} declaradas manuales.")
    print(f"{len(ignoradas)} ignoradas (broken/duplicado).")
    print(f"{len(fuera_scope)} fuera de scope.")


def install_one(entry):
    m, app = entry['manager'], entry['app']
    try:
        if m == 'flatpak':
            r = subprocess.run(['flatpak', 'install', '--user', '-y', 'flathub', app])
        elif m == 'apt':
            r = subprocess.run(['sudo', 'apt-get', 'install', '-y', app])
        elif m == 'snap':
            r = subprocess.run(['sudo', 'snap', 'install', app])
        else:
            print(f"  [ERROR] Manager no soportado para instalación automática: {m}")
            return False
        return r.returncode == 0
    except Exception as e:
        print(f"  [ERROR] Excepción al instalar {app}: {e}")
        return False


def verify_one(entry, flatpak_set_cmd, snap_set_cmd):
    m, app = entry['manager'], entry['app']
    if m == 'flatpak':
        r = subprocess.run(['flatpak', 'list', '--app', '--columns=application'],
                            capture_output=True, text=True)
        return app in r.stdout.splitlines()
    if m == 'apt':
        r = subprocess.run(['dpkg', '-l', app], capture_output=True, text=True)
        return any(l.startswith('ii') for l in r.stdout.splitlines())
    if m == 'snap':
        r = subprocess.run(['snap', 'list'], capture_output=True, text=True)
        return any(l.split()[0] == app for l in r.stdout.splitlines()[1:] if l.split())
    return False


def main():
    (manifest_path, machine_type, mode, flatpak_file, snap_file,
     apt_status_file, binary_status_file, prereqs_file) = sys.argv[1:9]

    data = yaml.safe_load(open(manifest_path))
    apps = data['apps']

    flatpak_set = load_lines(flatpak_file)
    snap_set = load_lines(snap_file)
    apt_status = load_pairs(apt_status_file)
    binary_status = load_pairs(binary_status_file)
    prereqs = load_pairs(prereqs_file)

    # Marcar estado "instalado" dentro de source para el reporte manual
    for a in apps:
        src = a.get('source') or {}
        src['_installed'] = is_installed(a, flatpak_set, snap_set, apt_status, binary_status)
        a['source'] = src

    candidatas, ya_instaladas, skip_equiv, manuales, ignoradas, fuera_scope = classify(
        apps, machine_type, flatpak_set, snap_set, apt_status, binary_status)

    # Filtrar candidatas cuyo prerequisito de manager no esté ok
    candidatas_ok = []
    for a in candidatas:
        estado_prereq = prereqs.get(a['manager'], 'missing')
        if estado_prereq != 'ok':
            manuales.append(a)  # degradar a manual con motivo de prerequisito
            print(f"AVISO: {a['display_name']} degradada a manual: "
                  f"prerequisito de {a['manager']} no satisfecho ({estado_prereq}).")
        else:
            candidatas_ok.append(a)
    candidatas = candidatas_ok

    print_preview(candidatas, ya_instaladas, skip_equiv, manuales, ignoradas, fuera_scope)

    if mode == "preview":
        print("\n(Modo preview: no se instaló nada.)")
        return 0

    if not candidatas:
        print("\nNo hay candidatas automáticas. Nada que instalar.")
        return 0

    print(f"\n=== Modo --apply: {len(candidatas)} instalación(es) propuestas ===")
    for a in candidatas:
        print(f"  + {a['display_name']} ({a['manager']}: {a['app']})")

    confirm = input("\n¿Proceder con estas instalaciones? [s/N]: ").strip().lower()
    if confirm != 's':
        print("Cancelado por el usuario. No se instaló nada.")
        return 0

    any_error = False
    for a in candidatas:
        print(f"\nInstalando {a['display_name']} ({a['manager']}: {a['app']})...")
        ok = install_one(a)
        verified = verify_one(a, flatpak_set, snap_set) if ok else False
        if ok and verified:
            print(f"  [OK] {a['display_name']} instalada y verificada.")
        else:
            print(f"  [ERROR] {a['display_name']} — instalación o verificación fallida.")
            any_error = True

    return 1 if any_error else 0


if __name__ == "__main__":
    sys.exit(main())
PYEOF

python3 "$TMPDIR/engine.py" \
  "$MANIFEST" "$MACHINE_TYPE" "$MODE" \
  "$TMPDIR/flatpak_installed.txt" "$TMPDIR/snap_installed.txt" \
  "$TMPDIR/apt_status.txt" "$TMPDIR/binary_status.txt" "$TMPDIR/prereqs.txt"
ENGINE_EXIT=$?

echo
echo "=== import_apps.sh finalizado (código: $ENGINE_EXIT) ==="
exit "$ENGINE_EXIT"
