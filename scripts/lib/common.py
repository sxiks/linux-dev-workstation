"""
Código compartido por los motores de scripts/lib (M1b).

Solo contiene lo que antes estaba repetido o era reutilizable entre
import_engine.py y export_engine.py, movido sin cambios de lógica.
"""
import os
import yaml

from selection import load_group_catalog


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


def validate_manifest(path):
    """
    Invariantes duras del manifest. Devuelve (ok, error).
    Movida sin cambios desde export_engine.py (antes revalidate).
    """
    d = yaml.safe_load(open(path))
    apps = d['apps']
    known_groups, error = load_group_catalog(os.path.dirname(os.path.abspath(path)))
    if error:
        return False, error
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

        # --- Invariantes de install_scope (C3-G), exigidas desde C3-H ---
        install_scope = a.get('install_scope')
        if install_scope not in ('user', 'system'):
            return False, f"{a['app']}: install_scope inválido o ausente ('{install_scope}')"
        if a['manager'] == 'apt' and install_scope != 'system':
            return False, f"{a['app']}: manager apt exige install_scope:system"
        if a['manager'] == 'snap' and install_scope != 'system':
            return False, f"{a['app']}: manager snap exige install_scope:system"
        if a['manager'] == 'binary':
            dest = (a.get('source') or {}).get('destination')
            if dest:
                if dest.startswith('~'):
                    expected_scope = 'user'
                elif dest.startswith('/usr') or dest.startswith('/opt'):
                    expected_scope = 'system'
                else:
                    expected_scope = None
                if expected_scope and install_scope != expected_scope:
                    return False, (f"{a['app']}: install_scope:{install_scope} no coincide "
                                    f"con destination '{dest}' (esperado: {expected_scope})")

        # --- Grupos (M2): opcionales; si existen, deben estar en apps/groups.yaml ---
        if 'groups' in a:
            groups = a['groups']
            if not isinstance(groups, list) or not groups or \
                    not all(isinstance(g, str) for g in groups):
                return False, f"{a['app']}: 'groups' debe ser una lista no vacía de textos"
            for g in groups:
                if g not in known_groups:
                    return False, f"{a['app']}: grupo desconocido '{g}' (no está en apps/groups.yaml)"
    return True, ""
