import sys, yaml, shutil, datetime, os
from common import load_lines, validate_manifest

def main():
    (manifest_path, equivalences_path, machine_type, mode,
     flatpak_file, snap_apps_file, apt_status_file, binary_status_file,
     flatpak_user_file, flatpak_system_file) = sys.argv[1:11]

    data = yaml.safe_load(open(manifest_path))
    apps = data['apps']

    equiv_data = yaml.safe_load(open(equivalences_path)) or {}
    alias_table = equiv_data.get('aliases', {}) or {}

    declared_flatpak = {a['app'] for a in apps if a['manager'] == 'flatpak'}
    declared_snap = {a['app'] for a in apps if a['manager'] == 'snap'}

    flatpak_installed = load_lines(flatpak_file)

    snap_installed = load_lines(snap_apps_file)

    # --- C3-H: sets de scope real de Flatpak, para determine_install_scope() ---
    flatpak_user = load_lines(flatpak_user_file)

    flatpak_system = load_lines(flatpak_system_file)

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

    def determine_install_scope(app_id, manager):
        """
        Determina install_scope para una entrada nueva (invariantes C3-G),
        sin inventar valores. Devuelve 'user' o 'system', o None si no se
        puede determinar con seguridad -- en cuyo caso el llamador NO debe
        escribir la entrada.
        """
        if manager == 'apt':
            return 'system'   # invariante dura: apt siempre system
        if manager == 'snap':
            return 'system'   # invariante dura: snap siempre system
        if manager == 'flatpak':
            in_user = app_id in flatpak_user
            in_system = app_id in flatpak_system
            if in_user and not in_system:
                return 'user'
            if in_system and not in_user:
                return 'system'
            if in_user and in_system:
                resp = input(
                    f"  '{app_id}' está instalada en AMBOS scopes de Flatpak "
                    f"(--user y --system) a la vez. install_scope no se puede "
                    f"determinar automáticamente sin inventar un valor. "
                    f"¿Cuál declaras como scope canónico? [user/system/omitir]: "
                ).strip().lower()
                if resp in ('user', 'system'):
                    return resp
                return None
            # Ni en --user ni en --system: la detección no pudo confirmar
            # el scope real. No se asume nada.
            return None
        # 'binary' nunca llega aquí: process() solo se invoca para flatpak
        # y snap (únicos managers detectados como "no declarados"). Se deja
        # explícito por seguridad ante cambios futuros de este script.
        return None

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
                install_scope = determine_install_scope(app_id, manager)
                if install_scope is None:
                    print(f"  No se pudo determinar install_scope para "
                          f"'{app_id}' con seguridad. Esta entrada NO se "
                          f"escribirá; decláralo manualmente en manifest.yaml.")
                    return
                entry = {
                    'app': app_id, 'display_name': app_id, 'manager': manager,
                    'equivalence_id': suggested_eq, 'scope': 'machine',
                    'install_scope': install_scope,
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

        install_scope = determine_install_scope(app_id, manager)
        if install_scope is None:
            print(f"  No se pudo determinar install_scope para '{app_id}' "
                  f"con seguridad. Esta entrada NO se escribirá; decláralo "
                  f"manualmente en manifest.yaml.")
            return

        default_eq = ''.join(c for c in app_id.lower() if c.isalnum() or c == '-')
        eq_id_resp = input(f"  equivalence_id [{default_eq}]: ").strip() or default_eq
        machines = [machine_type] if scope_resp == 'machine' else []

        entry = {
            'app': app_id, 'display_name': app_id, 'manager': manager,
            'equivalence_id': eq_id_resp, 'scope': scope_resp,
            'install_scope': install_scope,
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

    ok, error = validate_manifest(manifest_path)
    if not ok:
        print(f"\nERROR de invariante tras escribir: {error}")
        print("Restaurando backup automáticamente...")
        shutil.copy2(backup_path, manifest_path)
        return 1

    print("\nManifest actualizado y revalidado correctamente.")
    print(f"Se agregaron {len(new_entries)} entrada(s) nueva(s).")
    print("Recuerda: esto NO hizo git add/commit/push. Eso sigue siendo manual (dotpush).")
    return 0


if __name__ == "__main__":
    sys.exit(main())
