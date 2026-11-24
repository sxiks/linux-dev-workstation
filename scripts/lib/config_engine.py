"""
Perfiles de configuración de apps (CF1).

Lleva la configuración de una app entre máquinas a través del repo:

  capture  máquina origen  -> apps/configs/<id>/files/   (después: commit + push)
  restore  apps/configs/<id>/files/ -> máquina destino   (después de dotpull)

Cada perfil se describe en apps/configs/<id>/config.yaml (ver docs/CONFIGS.md).
Solo viaja configuración: nunca estado (historial, sesiones) ni secretos.

Reglas fijas:
  - --preview por defecto; --apply escribe y pide confirmación (o --yes).
  - Con --apply la app tiene que estar cerrada.
  - restore hace backup de todo lo que va a sobrescribir y nunca borra
    archivos del destino; capture refleja el origen dentro del repo.
  - capture se detiene si encuentra algo con forma de secreto.
  - La ruta del HOME se guarda como @HOME@ y se repone en el destino.
"""
import datetime
import difflib
import os
import re
import shutil
import subprocess
import sys

import yaml

HOME_TOKEN = '@HOME@'
DESCRIPTOR_KEYS = {'id', 'app', 'description', 'location', 'running_check',
                   'items', 'never', 'handled_elsewhere', 'max_item_mb'}
LOCATION_KEYS = {'base', 'resolver'}
ITEM_KEYS = {'path', 'strategy', 'exclude_prefixes', 'exclude_keys', 'exclude_patterns'}
STRATEGIES = ('copy', 'prefs-merge')
RESOLVERS = ('none', 'mozilla-profile')

SECRET_PATTERNS = [
    re.compile(r'-----BEGIN [A-Z ]*PRIVATE KEY-----'),
    re.compile(r'\bgh[pousr]_[A-Za-z0-9]{36,}\b'),
    re.compile(r'\bgithub_pat_[A-Za-z0-9_]{40,}\b'),
    re.compile(r'\bsk-[A-Za-z0-9_-]{20,}\b'),
    re.compile(r'\bAKIA[0-9A-Z]{16}\b'),
    re.compile(r'\bxox[abprs]-[A-Za-z0-9-]{10,}\b'),
    re.compile(r'(?i)"(password|passwd|secret|api[_-]?key|access[_-]?token|refresh[_-]?token)"\s*:\s*"[^"]{4,}"'),
    re.compile(r'(?i)\b(password|passwd|secret|api[_-]?key|access[_-]?token)\s*=\s*\S{4,}'),
]

PREF_RE = re.compile(r'^user_pref\("((?:[^"\\]|\\.)*)",\s*(.*)\);\s*$')


# --------------------------------------------------------------- utilidades
def die(msg):
    print(f"ERROR: {msg}")
    sys.exit(1)


def read_bytes(path):
    with open(path, 'rb') as f:
        return f.read()


def is_text(data):
    try:
        data.decode('utf-8')
        return b'\x00' not in data
    except UnicodeDecodeError:
        return False


def to_repo(data, home):
    """Contenido de la máquina -> contenido versionado (HOME como @HOME@)."""
    if is_text(data):
        return data.decode('utf-8').replace(home, HOME_TOKEN).encode('utf-8')
    return data


def to_machine(data, home):
    if is_text(data):
        return data.decode('utf-8').replace(HOME_TOKEN, home).encode('utf-8')
    return data


def write_atomic(path, data, mode=0o644):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = f"{path}.cfgtmp.{os.getpid()}"
    with open(tmp, 'wb') as f:
        f.write(data)
    os.chmod(tmp, mode)
    os.replace(tmp, path)


def list_files(root):
    """Rutas relativas de los archivos regulares bajo root (sin enlaces)."""
    out = []
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames.sort()
        for name in sorted(filenames):
            full = os.path.join(dirpath, name)
            if os.path.islink(full) or not os.path.isfile(full):
                continue
            out.append(os.path.relpath(full, root))
    return out


def short(path, home):
    return path.replace(home, '~', 1) if path.startswith(home) else path


# --------------------------------------------------------------- descriptor
def load_descriptor(configs_dir, profile_id, manifest_path):
    path = os.path.join(configs_dir, profile_id, 'config.yaml')
    if not os.path.isfile(path):
        available = sorted(d for d in os.listdir(configs_dir)
                           if os.path.isfile(os.path.join(configs_dir, d, 'config.yaml'))) \
            if os.path.isdir(configs_dir) else []
        die(f"no existe el perfil '{profile_id}'. Perfiles disponibles: "
            f"{', '.join(available) or '(ninguno)'}")
    d = yaml.safe_load(open(path)) or {}
    if not isinstance(d, dict):
        die(f"{path}: debe ser un mapa")
    unknown = set(d) - DESCRIPTOR_KEYS
    if unknown:
        die(f"{path}: claves desconocidas: {', '.join(sorted(unknown))}")
    if d.get('id') != profile_id:
        die(f"{path}: 'id' debe ser '{profile_id}' (el nombre de la carpeta)")

    apps = {a['app'] for a in (yaml.safe_load(open(manifest_path)) or {}).get('apps', [])}
    if d.get('app') not in apps:
        die(f"{path}: 'app' ({d.get('app')}) no existe en apps/manifest.yaml")

    loc = d.get('location')
    if not isinstance(loc, dict) or set(loc) - LOCATION_KEYS:
        die(f"{path}: 'location' debe tener solo 'base' y 'resolver'")
    bases = loc.get('base')
    bases = [bases] if isinstance(bases, str) else bases
    if not bases or not all(isinstance(b, str) and b.startswith('~/') for b in bases):
        die(f"{path}: 'location.base' debe ser una ruta (o lista) que empiece por ~/")
    resolver = loc.get('resolver', 'none')
    if resolver not in RESOLVERS:
        die(f"{path}: resolver desconocido '{resolver}' (válidos: {', '.join(RESOLVERS)})")

    never = d.get('never') or []
    items = d.get('items')
    if not isinstance(items, list) or not items:
        die(f"{path}: 'items' debe ser una lista no vacía")
    seen = set()
    for it in items:
        if not isinstance(it, dict) or set(it) - ITEM_KEYS:
            die(f"{path}: cada item admite solo {', '.join(sorted(ITEM_KEYS))}")
        p = it.get('path')
        if not isinstance(p, str) or not p or p.startswith('/') or '..' in p.split('/'):
            die(f"{path}: ruta de item inválida '{p}' (relativa, sin '..')")
        if it.get('strategy') not in STRATEGIES:
            die(f"{path}: {p}: estrategia desconocida '{it.get('strategy')}' "
                f"(válidas: {', '.join(STRATEGIES)})")
        if it['strategy'] == 'prefs-merge' and p.endswith('/'):
            die(f"{path}: {p}: prefs-merge trabaja sobre un archivo, no una carpeta")
        norm = p.rstrip('/')
        if norm in seen:
            die(f"{path}: item repetido '{p}'")
        seen.add(norm)
        for n in never:
            nn = n.rstrip('/')
            if norm == nn or norm.startswith(nn + '/') or nn.startswith(norm + '/'):
                die(f"{path}: el item '{p}' se solapa con 'never' ('{n}')")
        for key in ('exclude_prefixes', 'exclude_keys', 'exclude_patterns'):
            if key in it and it['strategy'] != 'prefs-merge':
                die(f"{path}: {p}: '{key}' solo vale para prefs-merge")
        for pat in it.get('exclude_patterns') or []:
            try:
                re.compile(pat)
            except re.error as e:
                die(f"{path}: {p}: patrón inválido '{pat}': {e}")
    d['_bases'] = bases
    d['_resolver'] = resolver
    d['_dir'] = os.path.join(configs_dir, profile_id)
    return d


# --------------------------------------------------------------- ubicación
def _ini(path):
    import configparser
    cp = configparser.ConfigParser(interpolation=None, strict=False)
    cp.optionxform = str
    cp.read(path, encoding='utf-8')
    return cp


def resolve_location(desc, home):
    """Devuelve (carpeta_real, explicación) o (None, motivo)."""
    tried = []
    for b in desc['_bases']:
        base = os.path.join(home, b[2:])
        tried.append(short(base, home))
        if desc['_resolver'] == 'none':
            if os.path.isdir(base):
                return base, short(base, home)
            continue
        ini = os.path.join(base, 'profiles.ini')
        if not os.path.isfile(ini):
            continue
        rel = None
        source = None
        inst = os.path.join(base, 'installs.ini')
        if os.path.isfile(inst):
            ci = _ini(inst)
            for s in ci.sections():
                if ci[s].get('Default'):
                    rel, source = ci[s]['Default'], 'installs.ini'
                    break
        cp = _ini(ini)
        if not rel:
            for s in cp.sections():
                if s.startswith('Install') and cp[s].get('Default'):
                    rel, source = cp[s]['Default'], f'profiles.ini [{s}]'
                    break
        if not rel:
            for s in cp.sections():
                if s.startswith('Profile') and cp[s].get('Default') == '1':
                    rel, source = cp[s].get('Path'), f'profiles.ini [{s}] Default=1'
                    break
        if not rel:
            return None, f"{short(ini, home)} no marca ningún perfil por defecto"
        prof = rel if os.path.isabs(rel) else os.path.join(base, rel)
        if not os.path.isdir(prof):
            return None, f"el perfil por defecto ({short(prof, home)}) no existe"
        return prof, f"{short(prof, home)} (según {source})"
    return None, "no se encontró en: " + ', '.join(tried)


def app_running(desc):
    rc = desc.get('running_check') or {}
    app = rc.get('flatpak')
    if not app:
        return False
    if shutil.which('flatpak') is None:
        return False
    try:
        out = subprocess.run(['flatpak', 'ps', '--columns=application'],
                             capture_output=True, text=True, timeout=20).stdout
    except (OSError, subprocess.SubprocessError):
        return False
    return app in {l.strip() for l in out.splitlines()}


# --------------------------------------------------------------- prefs
def parse_prefs(text):
    prefs = {}
    for line in text.splitlines():
        m = PREF_RE.match(line)
        if m:
            prefs[m.group(1)] = m.group(2)
    return prefs


def pref_excluded(key, item):
    if key in (item.get('exclude_keys') or []):
        return True
    if any(key.startswith(p) for p in item.get('exclude_prefixes') or []):
        return True
    return any(re.search(p, key) for p in item.get('exclude_patterns') or [])


PREFS_HEADER = (
    "// Preferencias capturadas por capture_config.sh (perfiles de configuración, CF1).\n"
    "// Solo claves filtradas: sin datos de cuenta, telemetría, marcas de tiempo ni\n"
    "// rutas propias del equipo. restore_config.sh las fusiona en prefs.js con la\n"
    "// app cerrada; no es un user.js (no bloquea cambios hechos desde la interfaz).\n"
)


def render_prefs(prefs):
    lines = [f'user_pref("{k}", {prefs[k]});' for k in sorted(prefs)]
    return (PREFS_HEADER + '\n'.join(lines) + '\n').encode('utf-8')


# --------------------------------------------------------------- secretos
def scan_secrets(rel, data):
    if not is_text(data):
        return []
    hits = []
    for n, line in enumerate(data.decode('utf-8').splitlines(), 1):
        for pat in SECRET_PATTERNS:
            if pat.search(line):
                hits.append(f"{rel}:{n}")
                break
    return hits


# --------------------------------------------------------------- planes
class Change:
    """Una operación sobre un archivo: NUEVO / CAMBIA / IGUAL / SOBRA."""
    def __init__(self, kind, rel, dest, data=None, old=None, note=''):
        self.kind, self.rel, self.dest = kind, rel, dest
        self.data, self.old, self.note = data, old, note


def plan_capture(desc, src_root, home):
    files_dir = os.path.join(desc['_dir'], 'files')
    changes, secrets, notes = [], [], []
    max_bytes = int(float(desc.get('max_item_mb', 5)) * 1024 * 1024)
    for it in desc['items']:
        p = it['path'].rstrip('/')
        src = os.path.join(src_root, p)
        dst = os.path.join(files_dir, p)
        if it['strategy'] == 'copy':
            if it['path'].endswith('/'):
                if not os.path.isdir(src):
                    notes.append(f"{it['path']}: no existe en el origen (se omite)")
                    continue
                rels = list_files(src)
                pairs = [(os.path.join(p, r), os.path.join(src, r), os.path.join(dst, r)) for r in rels]
                if os.path.isdir(dst):
                    for r in list_files(dst):
                        if r not in rels:
                            changes.append(Change('SOBRA', os.path.join(p, r), os.path.join(dst, r),
                                                  note='ya no existe en el origen: se quita del repo'))
            else:
                if not os.path.isfile(src):
                    notes.append(f"{it['path']}: no existe en el origen (se omite)")
                    continue
                pairs = [(p, src, dst)]
            total = 0
            for rel, s, t in pairs:
                data = to_repo(read_bytes(s), home)
                total += len(data)
                secrets += scan_secrets(rel, data)
                old = read_bytes(t) if os.path.isfile(t) else None
                kind = 'NUEVO' if old is None else ('IGUAL' if old == data else 'CAMBIA')
                changes.append(Change(kind, rel, t, data, old))
            if total > max_bytes:
                die(f"{it['path']}: ocupa {total/1048576:.1f} MB (máximo {max_bytes/1048576:.0f} MB). "
                    f"Los binarios grandes no van en Git.")
        else:  # prefs-merge
            if not os.path.isfile(src):
                notes.append(f"{it['path']}: no existe en el origen (se omite)")
                continue
            text = to_repo(read_bytes(src), home).decode('utf-8')
            allp = parse_prefs(text)
            kept = {k: v for k, v in allp.items() if not pref_excluded(k, it)}
            data = render_prefs(kept)
            secrets += scan_secrets(p, data)
            old = read_bytes(dst) if os.path.isfile(dst) else None
            kind = 'NUEVO' if old is None else ('IGUAL' if old == data else 'CAMBIA')
            notes.append(f"{p}: {len(allp)} claves en el origen -> {len(kept)} se guardan, "
                         f"{len(allp) - len(kept)} excluidas por las reglas del perfil")
            changes.append(Change(kind, p, dst, data, old))
    return changes, secrets, notes


def plan_restore(desc, dst_root, home):
    files_dir = os.path.join(desc['_dir'], 'files')
    if not os.path.isdir(files_dir):
        die(f"el perfil '{desc['id']}' todavía no tiene nada capturado "
            f"(falta {short(files_dir, home)}). Ejecuta capture_config.sh en el PC de origen.")
    changes, notes = [], []
    for it in desc['items']:
        p = it['path'].rstrip('/')
        src = os.path.join(files_dir, p)
        dst = os.path.join(dst_root, p)
        if it['strategy'] == 'copy':
            if it['path'].endswith('/'):
                if not os.path.isdir(src):
                    notes.append(f"{it['path']}: no hay nada capturado (se omite)")
                    continue
                rels = list_files(src)
                pairs = [(os.path.join(p, r), os.path.join(src, r), os.path.join(dst, r)) for r in rels]
                if os.path.isdir(dst):
                    extra = [r for r in list_files(dst) if r not in rels]
                    if extra:
                        notes.append(f"{it['path']}: {len(extra)} archivo(s) del destino no están en el "
                                     f"repo; se conservan (restore nunca borra)")
            else:
                if not os.path.isfile(src):
                    notes.append(f"{it['path']}: no hay nada capturado (se omite)")
                    continue
                pairs = [(p, src, dst)]
            for rel, s, t in pairs:
                data = to_machine(read_bytes(s), home)
                old = read_bytes(t) if os.path.isfile(t) else None
                kind = 'NUEVO' if old is None else ('IGUAL' if old == data else 'CAMBIA')
                changes.append(Change(kind, rel, t, data, old))
        else:  # prefs-merge
            if not os.path.isfile(src):
                notes.append(f"{it['path']}: no hay nada capturado (se omite)")
                continue
            wanted = parse_prefs(to_machine(read_bytes(src), home).decode('utf-8'))
            old = read_bytes(dst) if os.path.isfile(dst) else None
            old_text = old.decode('utf-8') if old is not None else ''
            current = parse_prefs(old_text)
            new_keys = [k for k in wanted if k not in current]
            changed = [k for k in wanted if k in current and current[k] != wanted[k]]
            same = len(wanted) - len(new_keys) - len(changed)
            lines = old_text.splitlines()
            index = {}
            for i, line in enumerate(lines):
                m = PREF_RE.match(line)
                if m:
                    index[m.group(1)] = i
            for k in changed:
                lines[index[k]] = f'user_pref("{k}", {wanted[k]});'
            for k in sorted(new_keys):
                lines.append(f'user_pref("{k}", {wanted[k]});')
            data = ('\n'.join(lines) + '\n').encode('utf-8')
            kind = 'NUEVO' if old is None else ('IGUAL' if not new_keys and not changed else 'CAMBIA')
            notes.append(f"{p}: {len(wanted)} claves del repo -> {len(new_keys)} nuevas, "
                         f"{len(changed)} cambian, {same} ya iguales; el resto de prefs.js no se toca")
            changes.append(Change(kind, p, dst, data, old,
                                  note=f"nuevas: {', '.join(sorted(new_keys)) or '-'} | "
                                       f"cambian: {', '.join(sorted(changed)) or '-'}"))
    return changes, notes


# --------------------------------------------------------------- salida
def print_plan(title, changes, notes, show_diff):
    print(f"--- {title} ---")
    order = {'NUEVO': 0, 'CAMBIA': 1, 'SOBRA': 2, 'IGUAL': 3}
    for c in sorted(changes, key=lambda c: (order[c.kind], c.rel)):
        if c.kind == 'IGUAL':
            continue
        print(f"  [{c.kind}] {c.rel}")
        if show_diff and c.kind == 'CAMBIA' and is_text(c.data) and is_text(c.old):
            for line in difflib.unified_diff(c.old.decode('utf-8').splitlines(),
                                             c.data.decode('utf-8').splitlines(),
                                             'actual', 'nuevo', lineterm='', n=1):
                print(f"      {line}")
        elif show_diff and c.note:
            print(f"      {c.note}")
    same = sum(1 for c in changes if c.kind == 'IGUAL')
    if same:
        print(f"  ({same} archivo(s) ya iguales, sin cambios)")
    if not any(c.kind != 'IGUAL' for c in changes):
        print("  (nada que cambiar)")
    for n in notes:
        print(f"  · {n}")
    counts = {k: sum(1 for c in changes if c.kind == k) for k in order}
    print(f"\nResumen: {counts['NUEVO']} nuevos, {counts['CAMBIA']} cambian, "
          f"{counts['SOBRA']} se quitan del repo, {counts['IGUAL']} iguales.")


def confirm(assume_yes, question):
    if assume_yes:
        print("Confirmado por --yes.")
        return True
    if not sys.stdin.isatty():
        print("ERROR: --apply necesita una terminal para confirmar, o --yes. No se escribió nada.")
        return None
    return input(f"{question} [s/N]: ").strip().lower() in ('s', 'si', 'sí', 'y', 'yes')


# --------------------------------------------------------------- main
def main():
    dotfiles_dir, direction, profile_id, mode, yes_arg, diff_arg = sys.argv[1:7]
    assume_yes, show_diff = yes_arg == '1', diff_arg == '1'
    home = os.path.expanduser('~')
    configs_dir = os.path.join(dotfiles_dir, 'apps', 'configs')
    manifest = os.path.join(dotfiles_dir, 'apps', 'manifest.yaml')

    desc = load_descriptor(configs_dir, profile_id, manifest)
    print(f"Perfil: {desc['id']} ({desc['app']})")
    if desc.get('description'):
        print(f"        {desc['description']}")

    location, why = resolve_location(desc, home)
    if location is None:
        if direction == 'restore':
            die(f"no se encontró la configuración de la app en este PC: {why}.\n"
                f"       Si la app está recién instalada, ábrela una vez y ciérrala para que "
                f"cree su perfil, y vuelve a ejecutar.")
        die(f"no se encontró la configuración de la app: {why}")
    print(f"Ubicación: {why}")

    running = app_running(desc)
    if running:
        print(f"AVISO: {desc['app']} está abierta.")
    print()

    if direction == 'capture':
        changes, secrets, notes = plan_capture(desc, location, home)
        print_plan('Captura: PC -> repo (apps/configs/%s/files/)' % desc['id'], changes, notes, show_diff)
        if secrets:
            print("\nERROR: hay contenido con forma de secreto; no se captura nada:")
            for s in secrets:
                print(f"  {s}")
            print("Revisa esas líneas en el origen o excluye ese archivo del perfil.")
            return 1
    else:
        changes, notes = plan_restore(desc, location, home)
        print_plan('Restauración: repo -> PC', changes, notes, show_diff)

    for line in desc.get('handled_elsewhere') or []:
        print(f"  Fuera de este perfil: {line}")

    pending = [c for c in changes if c.kind != 'IGUAL']
    if mode == 'preview':
        print("\n(Modo preview: no se escribió nada.)")
        return 0
    if not pending:
        print("\nNada que escribir.")
        return 0
    if running:
        print(f"\nERROR: cierra {desc['app']} antes de --apply (escribe sus archivos al salir). "
              f"No se escribió nada.")
        return 1
    ok = confirm(assume_yes, "\n¿Escribir estos cambios?")
    if ok is None:
        return 1
    if not ok:
        print("Cancelado. No se escribió nada.")
        return 0

    if direction == 'restore':
        state = os.environ.get('XDG_STATE_HOME') or os.path.join(home, '.local', 'state')
        stamp = datetime.datetime.now().strftime('%Y%m%d-%H%M%S')
        backup = os.path.join(state, 'dotfiles', 'config-backups', desc['id'], stamp)
        created = []
        for c in pending:
            if c.old is not None:
                target = os.path.join(backup, c.rel)
                os.makedirs(os.path.dirname(target), exist_ok=True)
                shutil.copy2(c.dest, target)
            else:
                created.append(c.rel)
        os.makedirs(backup, exist_ok=True)
        with open(os.path.join(backup, 'NUEVOS.txt'), 'w') as f:
            f.write(''.join(f"{r}\n" for r in created))
        print(f"Backup de lo sobrescrito: {short(backup, home)}")

    for c in pending:
        if c.kind == 'SOBRA':
            os.remove(c.dest)
        else:
            mode_bits = os.stat(c.dest).st_mode & 0o777 if os.path.isfile(c.dest) else 0o644
            write_atomic(c.dest, c.data, mode_bits if direction == 'restore' else 0o644)
    print(f"Escritos: {sum(1 for c in pending if c.kind != 'SOBRA')}, "
          f"quitados del repo: {sum(1 for c in pending if c.kind == 'SOBRA')}.")
    if direction == 'capture':
        print(f"\nSiguiente: revisa con  git -C {short(dotfiles_dir, home)} status  y haz commit "
              f"nombrando los archivos de apps/configs/{desc['id']}/.")
    else:
        print(f"\nSiguiente: abre {desc['app']} y comprueba la configuración.")
    return 0


if __name__ == '__main__':
    sys.exit(main())
