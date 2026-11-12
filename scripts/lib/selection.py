"""
Selección declarativa por máquina (M2).

Una app entra en el plan de una máquina si su grupo está seleccionado
(o la app está en 'include') y no está en 'exclude'. La selección de cada
máquina vive versionada en apps/machines/<machine-type>.yaml.

Reglas de fallo seguro: un grupo, una app o una clave desconocidos son
errores explícitos; nunca se ignoran ni se adivinan.
"""
import os
import yaml

DEFAULT_GROUP = 'default'
SELECTION_KEYS = ('groups', 'include', 'exclude')


def load_group_catalog(apps_dir):
    """
    Devuelve (conjunto_de_grupos, error). 'default' siempre es válido:
    agrupa las entradas del manifest que no declaran 'groups'.
    """
    path = os.path.join(apps_dir, 'groups.yaml')
    if not os.path.isfile(path):
        return {DEFAULT_GROUP}, None
    data = yaml.safe_load(open(path)) or {}
    groups = data.get('groups') or {}
    if not isinstance(groups, dict):
        return None, f"{path}: 'groups' debe ser un mapa nombre -> datos del grupo"
    return set(groups) | {DEFAULT_GROUP}, None


def entry_groups(entry):
    return entry.get('groups') or [DEFAULT_GROUP]


def _str_list(data, key, path):
    value = data.get(key)
    if value is None:
        return [], None
    if not isinstance(value, list) or not all(isinstance(v, str) for v in value):
        return None, f"{path}: '{key}' debe ser una lista de textos"
    return value, None


def load_machine_selection(apps_dir, machine_type, known_groups, apps):
    """
    Devuelve (selección, error). Sin archivo de máquina se seleccionan
    todos los grupos conocidos (comportamiento anterior a M2) y
    selection['source'] queda en None para que el llamador lo avise.
    """
    path = os.path.join(apps_dir, 'machines', f'{machine_type}.yaml')
    if not os.path.isfile(path):
        return {'groups': set(known_groups), 'include': set(),
                'exclude': set(), 'source': None}, None

    data = yaml.safe_load(open(path)) or {}
    if not isinstance(data, dict):
        return None, f"{path}: debe ser un mapa con las claves {', '.join(SELECTION_KEYS)}"
    unknown_keys = sorted(set(data) - set(SELECTION_KEYS))
    if unknown_keys:
        return None, (f"{path}: claves no soportadas todavía: {', '.join(unknown_keys)} "
                      f"(soportadas: {', '.join(SELECTION_KEYS)})")

    lists = {}
    for key in SELECTION_KEYS:
        value, error = _str_list(data, key, path)
        if error:
            return None, error
        lists[key] = value

    unknown_groups = sorted(set(lists['groups']) - set(known_groups))
    if unknown_groups:
        return None, f"{path}: grupos desconocidos: {', '.join(unknown_groups)}"

    app_ids = {a['app'] for a in apps}
    for key in ('include', 'exclude'):
        unknown_apps = sorted(set(lists[key]) - app_ids)
        if unknown_apps:
            return None, f"{path}: '{key}' nombra apps que no están en el manifest: {', '.join(unknown_apps)}"

    both = sorted(set(lists['include']) & set(lists['exclude']))
    if both:
        return None, f"{path}: apps a la vez en 'include' y 'exclude': {', '.join(both)}"

    return {'groups': set(lists['groups']), 'include': set(lists['include']),
            'exclude': set(lists['exclude']), 'source': path}, None


def is_selected(entry, selection):
    if entry['app'] in selection['exclude']:
        return False
    if entry['app'] in selection['include']:
        return True
    return any(g in selection['groups'] for g in entry_groups(entry))
