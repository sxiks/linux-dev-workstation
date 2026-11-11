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
import sys, yaml, os, subprocess, json, hashlib, tarfile, zipfile, tempfile, shutil
import urllib.request, urllib.error

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


# --- Etapa A: verificación e instalación de binarios vía GitHub Releases ---
# Estas funciones son 100% genéricas: no contienen el nombre de ninguna
# aplicación. Solo se activan para entradas manager:binary que declaren el
# bloque 'asset'. Ninguna entrada sin 'asset' pasa por aquí -- conservan su
# comportamiento previo exactamente igual.

def resolve_release_tag(version):
    """
    Deriva el tag real de GitHub a partir del campo 'version' ya existente
    en el manifest, sin agregar un campo nuevo ni una segunda fuente de
    verdad. Regla verificada contra las 4 herramientas reales de Etapa A:
    el tag de GitHub siempre lleva 'v'; 'version' a veces ya la incluye.
    """
    return version if version.startswith('v') else f'v{version}'


def fetch_github_release(owner_repo, tag):
    """
    Devuelve (release_json, error). error es None si la consulta tuvo éxito.
    Nunca lanza excepción hacia el llamador -- todo error se captura y se
    convierte en un mensaje explícito, diferenciando los 3 casos que
    requieren un diagnóstico distinto: release inexistente, límite de
    tasa de la API agotado, y cualquier otro error HTTP/de red.
    """
    url = f"https://api.github.com/repos/{owner_repo}/releases/tags/{tag}"
    req = urllib.request.Request(
        url,
        headers={"Accept": "application/vnd.github+json",
                 "User-Agent": "dotfiles-import-apps"})
    try:
        with urllib.request.urlopen(req, timeout=15) as resp:
            return json.loads(resp.read().decode()), None
    except urllib.error.HTTPError as e:
        if e.code == 404:
            return None, f"el release '{tag}' no existe en {owner_repo} (HTTP 404)"
        remaining = e.headers.get('X-RateLimit-Remaining') if e.headers else None
        if e.code == 403 and remaining == '0':
            reset = e.headers.get('X-RateLimit-Reset', 'desconocido')
            return None, (f"límite de tasa de la API de GitHub agotado "
                           f"(X-RateLimit-Remaining=0, reset={reset}). "
                           f"No es un fallo de '{tag}' -- reintentar más tarde.")
        return None, f"HTTP {e.code} al consultar el release {tag} de {owner_repo}"
    except Exception as e:
        return None, f"error de red al consultar el release {tag} de {owner_repo}: {e}"


def find_exact_asset(release_json, asset_name):
    """
    Coincidencia EXACTA de nombre, nunca por similitud. Devuelve
    (asset_info|None, lista_de_nombres_reales) -- la lista real siempre se
    devuelve para poder mostrarla en el mensaje de error.
    """
    assets = release_json.get('assets', [])
    real_names = [a['name'] for a in assets]
    for a in assets:
        if a['name'] == asset_name:
            return a, real_names
    return None, real_names


def owner_repo_from_origin(origin_url):
    return origin_url.replace('https://github.com/', '').rstrip('/')


def resolve_asset_name(asset_template, tag):
    """
    Sustituye {version} SOLO si el template lo contiene, usando el tag
    sin el prefijo 'v' (un único carácter, no una tira de caracteres --
    ver por qué esto importa: 'v0.62.1'.lstrip('v') funciona por
    coincidencia, pero lstrip() quita CUALQUIER 'v' inicial repetida,
    no un prefijo; aquí se quita explícitamente un único prefijo 'v').
    """
    version_sin_v = tag[1:] if tag.startswith('v') else tag
    return asset_template.replace('{version}', version_sin_v)


def verify_release_asset(entry):
    """
    Fase de SOLO VERIFICACIÓN (sin descargar ni instalar). Resuelve el
    release, busca el asset por coincidencia exacta, y confirma que existe
    un digest oficial. Devuelve un dict con 'ok' (bool) y 'detail' (str).
    Se usa para el reporte informativo de --preview; nunca dispara una
    instalación por sí sola.
    """
    src = entry.get('source') or {}
    asset = entry.get('asset') or {}
    origin = src.get('origin')
    version = src.get('version')

    if not origin or not asset.get('name') or not asset.get('type'):
        return {'ok': False, 'detail': 'entrada sin origin/asset.name/asset.type completos'}

    owner_repo = owner_repo_from_origin(origin)
    tag = resolve_release_tag(version)
    asset_name = resolve_asset_name(asset['name'], tag)

    release_json, err = fetch_github_release(owner_repo, tag)
    if err:
        return {'ok': False, 'detail': err}

    asset_info, real_names = find_exact_asset(release_json, asset_name)
    if asset_info is None:
        return {'ok': False,
                'detail': f"asset '{asset_name}' no encontrado en {tag}. "
                          f"Assets reales: {real_names}"}

    digest = asset_info.get('digest')
    if not digest or not str(digest).startswith('sha256:'):
        return {'ok': False,
                'detail': f"asset '{asset_name}' encontrado pero sin digest "
                          f"oficial de GitHub (campo 'digest' ausente o "
                          f"con formato inesperado: {digest!r})"}

    return {'ok': True,
            'detail': f"asset '{asset_name}' encontrado, digest={digest}"}


def download_file(url, dest_path):
    try:
        urllib.request.urlretrieve(url, dest_path)
        return True, ""
    except Exception as e:
        return False, f"error al descargar {url}: {e}"


def verify_sha256(filepath, expected_digest):
    if not expected_digest or not str(expected_digest).startswith('sha256:'):
        return False, f"digest oficial ausente o con formato inesperado: {expected_digest!r}"
    expected_hex = expected_digest.split('sha256:', 1)[1]
    real_hex = hashlib.sha256(open(filepath, 'rb').read()).hexdigest()
    if real_hex != expected_hex:
        return False, f"digest no coincide: esperado sha256:{expected_hex}, obtenido sha256:{real_hex}"
    return True, ""


def _is_safe_member_path(dest_dir, member_path):
    """
    Rechaza rutas absolutas y cualquier '../' que permita escapar de
    dest_dir (path traversal / 'Zip Slip'). Se aplica a cada miembro
    ANTES de extraerlo, tanto para tar.gz como para zip.
    """
    if os.path.isabs(member_path):
        return False
    resolved = os.path.realpath(os.path.join(dest_dir, member_path))
    dest_real = os.path.realpath(dest_dir)
    return resolved == dest_real or resolved.startswith(dest_real + os.sep)


def extract_asset(filepath, asset_type, dest_dir):
    """
    Único punto que conoce los tipos de archivo soportados. Agregar un
    tipo nuevo (ej. tar_xz) se hace aquí, una sola vez, nunca por app.
    Valida cada miembro contra path traversal antes de extraer nada.
    """
    try:
        if asset_type == 'tar_gz':
            with tarfile.open(filepath, 'r:gz') as tf:
                miembros = tf.getmembers()
                for m in miembros:
                    if not _is_safe_member_path(dest_dir, m.name):
                        return False, f"miembro con ruta insegura detectado en el tar.gz: '{m.name}'"
                tf.extractall(dest_dir, members=miembros)
            return True, ""
        elif asset_type == 'zip':
            with zipfile.ZipFile(filepath) as zf:
                nombres = zf.namelist()
                for n in nombres:
                    if not _is_safe_member_path(dest_dir, n):
                        return False, f"miembro con ruta insegura detectado en el zip: '{n}'"
                zf.extractall(dest_dir)
            return True, ""
        else:
            return False, f"tipo de asset no soportado: {asset_type!r}"
    except Exception as e:
        return False, f"error al extraer ({asset_type}): {e}"


def install_binaries_from_extraction(extract_dir, binaries):
    """
    binaries: lista de {'name': <ruta relativa dentro del extraído>,
    'destination': <ruta final>}. Soporta 1 o varios binarios.

    Diseño en 3 fases para MINIMIZAR el riesgo de instalación parcial
    cuando hay más de un binario (caso Yazi: yazi + ya). NO es una
    garantía transaccional completa -- ver el límite real más abajo:
      1) Validar que TODOS los binarios de origen existen -- si falta
         cualquiera, no se toca ningún destino. Esto cubre el caso más
         común de fallo (binario ausente tras extraer) con garantía
         total: cero destinos tocados.
      2) Copiar TODOS a una zona de staging temporal (aislada del
         destino final).
      3) Mover (rename) cada uno a su destino final SOLO si el staging
         completo tuvo éxito.

    LÍMITE REAL: si el fallo ocurre DURANTE la fase 3 (ej. el segundo
    'move' falla por permisos mientras el primero ya se movió), esta
    función SÍ puede dejar una instalación parcial -- no revierte los
    movimientos ya realizados. En ese caso se reporta explícitamente
    cuáles quedaron instalados antes del fallo, para que sea visible,
    nunca silencioso. No hay rollback transaccional implementado.
    """
    # Fase 1: validar que todos los orígenes existen antes de tocar nada
    for b in binaries:
        src = os.path.join(extract_dir, b['name'])
        if not os.path.isfile(src):
            return False, f"binario esperado no encontrado tras extraer: '{b['name']}' (ningún destino fue modificado)"

    # Fase 2: copiar todos a staging temporal
    staging_dir = tempfile.mkdtemp(prefix="install_staging_")
    staged = []
    try:
        for b in binaries:
            src = os.path.join(extract_dir, b['name'])
            staged_path = os.path.join(staging_dir, os.path.basename(b['destination']))
            try:
                shutil.copy2(src, staged_path)
                os.chmod(staged_path, 0o755)
            except Exception as e:
                return False, f"error al preparar '{b['name']}' antes de instalar: {e} (ningún destino fue modificado)"
            staged.append((staged_path, os.path.expanduser(b['destination'])))

        # Fase 3: mover cada binario ya validado a su destino final
        movidos = []
        for staged_path, dest in staged:
            try:
                dest_parent = os.path.dirname(dest)
                if dest_parent:
                    os.makedirs(dest_parent, exist_ok=True)
                shutil.move(staged_path, dest)
                os.chmod(dest, 0o755)
                movidos.append(dest)
            except Exception as e:
                return False, (f"error al instalar en destino final '{dest}': {e}. "
                                f"Binarios ya instalados antes de este fallo: {movidos or '(ninguno)'}")
        return True, ""
    finally:
        shutil.rmtree(staging_dir, ignore_errors=True)


def install_release_binary(entry):
    """
    Orquesta el ciclo completo: verificar -> descargar -> verificar digest
    -> extraer -> instalar binarios. Aborta en el primer paso que falle.
    Hasta el paso de instalar binarios (fases 1-2 de
    install_binaries_from_extraction), la garantía es total: cero
    cambios en destino si algo falla antes. Ver el docstring de
    install_binaries_from_extraction para el límite real durante el
    movimiento final con más de un binario. Devuelve (ok, detail).
    NO SE LLAMA TODAVÍA desde --apply mientras install_policy sea manual.
    """
    src = entry.get('source') or {}
    asset = entry.get('asset') or {}
    binaries = entry.get('binaries') or []
    origin = src.get('origin')
    version = src.get('version')

    owner_repo = owner_repo_from_origin(origin)
    tag = resolve_release_tag(version)
    asset_name = resolve_asset_name(asset['name'], tag)

    release_json, err = fetch_github_release(owner_repo, tag)
    if err:
        return False, err

    asset_info, real_names = find_exact_asset(release_json, asset_name)
    if asset_info is None:
        return False, (f"asset '{asset_name}' no encontrado en {tag}. "
                        f"Assets reales: {real_names}")

    digest = asset_info.get('digest')

    with tempfile.TemporaryDirectory() as tmp:
        download_path = os.path.join(tmp, asset_name)
        ok, err = download_file(asset_info['browser_download_url'], download_path)
        if not ok:
            return False, err

        ok, err = verify_sha256(download_path, digest)
        if not ok:
            return False, err

        extract_dir = os.path.join(tmp, 'extracted')
        os.makedirs(extract_dir, exist_ok=True)
        ok, err = extract_asset(download_path, asset['type'], extract_dir)
        if not ok:
            return False, err

        ok, err = install_binaries_from_extraction(extract_dir, binaries)
        if not ok:
            return False, err

    return True, f"instalado correctamente desde {asset_name} (digest verificado)"

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


def print_preview(candidatas, ya_instaladas, skip_equiv, manuales, ignoradas, fuera_scope,
                   scope_warning_suffix):
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
        print(f"  [OK] {a['display_name']:<20} {a['manager']:<8} {a['app']}{scope_warning_suffix(a)}")
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
        release_check = ''
        if a['manager'] == 'binary' and a.get('asset'):
            result = verify_release_asset(a)
            if result['ok']:
                release_check = f"  [RELEASE_CHECK: OK -- {result['detail']}]"
            else:
                release_check = f"  [RELEASE_CHECK: ERROR -- {result['detail']}]"
        print(f"  [MANUAL][{estado}] {a['display_name']:<18} {a['manager']:<8} "
              f"v={version} origen={origin} destino={dest}{scope_warning_suffix(a)}{release_check}")
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
     apt_status_file, binary_status_file, prereqs_file,
     flatpak_user_file, flatpak_system_file) = sys.argv[1:11]

    data = yaml.safe_load(open(manifest_path))
    apps = data['apps']

    flatpak_set = load_lines(flatpak_file)
    snap_set = load_lines(snap_file)
    apt_status = load_pairs(apt_status_file)
    binary_status = load_pairs(binary_status_file)
    prereqs = load_pairs(prereqs_file)

    # --- C3-H: sets de scope real de Flatpak, solo para WARN_SCOPE informativo ---
    flatpak_user_set = load_lines(flatpak_user_file)
    flatpak_system_set = load_lines(flatpak_system_file)

    def flatpak_actual_scope(app_id):
        in_user = app_id in flatpak_user_set
        in_system = app_id in flatpak_system_set
        if in_user and in_system:
            return 'both'
        if in_user:
            return 'user'
        if in_system:
            return 'system'
        return None

    def scope_warning_suffix(a):
        """
        Devuelve un sufijo informativo "[WARN_SCOPE: ...]" si el manager es
        flatpak y el scope real difiere del declarado. NUNCA dispara ninguna
        acción (ni reinstalación, ni movimiento entre scopes) -- es
        puramente para el reporte impreso.
        """
        if a['manager'] != 'flatpak':
            return ''
        actual = flatpak_actual_scope(a['app'])
        if actual is None or actual == 'both':
            return ''
        declared = a.get('install_scope')
        if actual != declared:
            return f"  [WARN_SCOPE: declarado={declared} real={actual}]"
        return ''

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

    print_preview(candidatas, ya_instaladas, skip_equiv, manuales, ignoradas, fuera_scope,
                  scope_warning_suffix)

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
  "$TMPDIR/apt_status.txt" "$TMPDIR/binary_status.txt" "$TMPDIR/prereqs.txt" \
  "$TMPDIR/flatpak_installed_user.txt" "$TMPDIR/flatpak_installed_system.txt"
ENGINE_EXIT=$?

echo
echo "=== import_apps.sh finalizado (código: $ENGINE_EXIT) ==="
exit "$ENGINE_EXIT"
