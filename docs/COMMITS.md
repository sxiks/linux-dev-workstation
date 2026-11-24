# Convenciones de commit

## Formato

Mensajes en inglés, con el estilo `tipo(ámbito): descripción`:

```
feat(apps): declare Helix and LocalSend .deb
fix(bash): explicit return 0 for non-interactive shells
refactor(apps): share common engine code in scripts/lib/common.py
docs: add commit conventions
chore: update project dependencies
```

El cuerpo, si hace falta, explica **qué** cambió y **por qué**, en viñetas.

Reglas de trabajo que ya sigue el proyecto:

- Nunca `git add .`: cada archivo se añade por su nombre.
- Commit y push son pasos separados.
- En trabajo multi-PC, los commits se hacen en un PC y el otro se actualiza con `dotpull`.

## Sin atribuciones a asistentes de IA

Ningún commit de este repositorio puede contener:

| Prohibido | Ejemplos |
|---|---|
| Coautorías de Claude | `Co-Authored-By: Claude <...>`, cualquier variante con Claude o Anthropic |
| Frases de generación o asistencia | `Generated with Claude`, `Assisted by Claude`, `Hecho con Claude`, `Generado mediante Claude` |
| Enlaces o identificadores de sesiones | `Claude-Session: ...`, URLs de `claude.ai/code`, `claude.ai/chat`, `claude.ai/share` |
| Firmas equivalentes | `noreply@anthropic.com`, el emoji 🤖 usado como firma |

Los mensajes describen el cambio, no quién o qué herramienta ayudó a hacerlo.
La autoría de cada commit es la de la persona que lo hace.

Las menciones normales a Claude **sí** están permitidas cuando forman parte del
contenido del proyecto (por ejemplo, documentar la configuración de Claude Code).

## Protección automática: hook `commit-msg`

`scripts/git-hooks/commit-msg` revisa cada mensaje antes de crear el commit y lo
rechaza si encuentra alguno de los patrones anteriores. El commit no se crea y
el hook indica la línea que hay que quitar.

Se activa **una vez por clon**, en cada PC:

```bash
cd ~/dotfiles
git config core.hooksPath scripts/git-hooks
git config --get core.hooksPath   # debe mostrar: scripts/git-hooks
```

La activación es local (no viaja con `dotpull`), así que cada PC nuevo debe
hacerla. El bootstrap (Fase E) la incluirá.

Si usas Claude Code, deja también vacía su atribución en `~/.claude/settings.json`:

```json
"attribution": { "commit": "", "pr": "" }
```

## Historial

El 24 de noviembre de 2026 se retiraron de 10 commits los trailers de coautoría
y los enlaces de sesión, con `git filter-repo`. El contenido, la autoría y las
fechas se conservaron; solo cambiaron los mensajes y, por tanto, los hashes de
esos 10 commits.
