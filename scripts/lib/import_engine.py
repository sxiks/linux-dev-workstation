import sys, yaml, os, subprocess, json, hashlib, tarfile, zipfile, tempfile, shutil
import urllib.request, urllib.error

from common import load_lines, load_pairs, applies_to_machine


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
                   scope_warning_suffix, check_releases):
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
    omitidos_release = 0
    for a in manuales:
        src = a.get('source') or {}
        estado = "instalado" if src.get('_installed') else "falta"
        version = src.get('version', '-')
        origin = src.get('origin') or src.get('repo_url') or 'pendiente'
        dest = src.get('destination', '-')
        release_check = ''
        if a['manager'] == 'binary' and a.get('asset') and not check_releases:
            omitidos_release += 1
        elif a['manager'] == 'binary' and a.get('asset'):
            result = verify_release_asset(a)
            if result['ok']:
                release_check = f"  [RELEASE_CHECK: OK -- {result['detail']}]"
            else:
                release_check = f"  [RELEASE_CHECK: ERROR -- {result['detail']}]"
        print(f"  [MANUAL][{estado}] {a['display_name']:<18} {a['manager']:<8} "
              f"v={version} origen={origin} destino={dest}{scope_warning_suffix(a)}{release_check}")
    if omitidos_release:
        print(f"  (RELEASE_CHECK omitido para {omitidos_release} binario(s): "
              f"usa --check-releases para verificarlos contra GitHub)")
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
            # Respeta install_scope declarado (solo para instalaciones NUEVAS;
            # nunca se mueve ni reinstala lo que ya existe en otro scope).
            if entry.get('install_scope') == 'system':
                r = subprocess.run(['sudo', 'flatpak', 'install', '--system', '-y', 'flathub', app])
            else:
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
        return any(l.startswith(('ii', 'hi')) for l in r.stdout.splitlines())
    if m == 'snap':
        r = subprocess.run(['snap', 'list'], capture_output=True, text=True)
        return any(l.split()[0] == app for l in r.stdout.splitlines()[1:] if l.split())
    return False


def main():
    (manifest_path, machine_type, mode, flatpak_file, snap_file,
     apt_status_file, binary_status_file, prereqs_file,
     flatpak_user_file, flatpak_system_file, check_releases_arg) = sys.argv[1:12]
    check_releases = (check_releases_arg == '1')

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
        prereq_key = a['manager']
        if a['manager'] == 'flatpak':
            prereq_key = f"flatpak_{a.get('install_scope')}"
        estado_prereq = prereqs.get(prereq_key, 'missing')
        if estado_prereq != 'ok':
            manuales.append(a)  # degradar a manual con motivo de prerequisito
            print(f"AVISO: {a['display_name']} degradada a manual: "
                  f"prerequisito de {prereq_key} no satisfecho ({estado_prereq}).")
        else:
            candidatas_ok.append(a)
    candidatas = candidatas_ok

    print_preview(candidatas, ya_instaladas, skip_equiv, manuales, ignoradas, fuera_scope,
                  scope_warning_suffix, check_releases)

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
