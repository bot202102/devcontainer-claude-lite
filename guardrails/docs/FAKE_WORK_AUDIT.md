# Fake-work Audit — caso real (2026-04-17)

> **Lectura obligatoria antes de desactivar los hooks de este template.**
> Cada defensa aquí nace de un fracaso concreto documentado abajo. Si ignoras
> el contexto, vas a repetir el error.

## Resumen ejecutivo

Proyecto: **GainShield** — feedback suppressor para mixers X32, escrito en Rust, desarrollado durante ~3 meses por un lab de dev usando Claude Code en modo mayormente asincrónico.

| Métrica | Valor |
|---|---|
| Commits totales | 100+ |
| Tests | 205, todos verdes |
| CI | pasando |
| CLAUDE.md | listaba "M1+M2+M4 complete" |
| **Features que realmente corrían en binario productivo** | **~40%** |

**Momento del descubrimiento**: sesión hardware en vivo con banda real tocando. El operador/dueño ejecutó `gainshield-cli --web`, vio métricas básicas funcionar, pero cuando activó las features "premium" (ActiveMixer, M14 adapters, auto_gain, SceneSurvival) el sistema estuvo silencioso — ningún evento, ningún efecto. La banda sufrió acoples que el engine "debería haber capturado".

## Módulos fantasma encontrados

Compilados, con tests, documentados, commited con mensajes `feat(engine): ...`. **Ninguno instanciado en el binario productivo `gainshield-cli`**:

| Módulo | Líneas | Tests | En binario? |
|---|---|---|---|
| `AutoGainEngine` | 800 | 12 | ❌ |
| `ActiveMixer` | 430 | ✓ | ❌ (builder `enable_active_mixer` existe, `main.rs` no lo llama) |
| `SceneSurvival` | 270 | ✓ | ❌ |
| `LivePhaseMonitor` | — | ✓ | ❌ |
| `ProximityAdapter` | — | ✓ | ❌ (solo en tests lab) |
| `IntelligibilityAdapter` | — | ✓ | ❌ |
| `VocalistAdapter` | — | ✓ | ❌ |
| `DuganAdapter` | — | ✓ | ❌ |
| `PluginOrchestrator` | — | ✓ | ❌ |
| `RoomCalibrator` | 620 | 9 | ❌ |
| `SessionReportBuilder` | 590 | ✓ | ❌ |
| `SafetyLimiter` | 450 | ✓ | ❌ **(!)** |

`SafetyLimiter` ausente del binario = cero protección contra niveles peligrosos. No hipotético: es seguridad crítica.

## Síntomas colaterales que acompañaban los ghosts

- **REST API teatrera**: 20+ endpoints devolviendo `{"note": "available when connected"}`, `{"status": "pending"}`, o simplemente `{}`. Promesa en la UI, nada atrás.
- **Security placeholders en build release**:
  ```rust
  const LICENSE_PUBLIC_KEY: [u8; 32] = [0; 32];   // 32 bytes de ceros
  // integrity.rs:
  info!("DEV: signature verification SKIPPED");   // en release
  ```
- **CNN classifier shell**: `cnn_classifier.rs` documentaba literal `"return None even when available"` en el método `predict()`. El "clasificador de música" era retorno nulo.
- **Tier gating irrelevante**: `HttpApiState.tier: String` hardcoded "free". Features "Pro" never gated porque la infraestructura no existía.

## Anti-patterns detectados en el flujo de trabajo

### 1. Test-island development
`gainshield-lab/tests/m14_integration.rs` instanciaba adapters directamente:

```rust
let proximity = ProximityAdapter::new(config);
let result = proximity.process(frame);
assert!(result.is_ok());
```

Esto **NUNCA pasa por `FeedbackEngine`**. Prueba que el módulo compila y ejecuta aislado — no que el engine lo invoque. El lab lo documentó explícitamente:

```rust
// Test integrates adapter in isolation — FeedbackEngine wiring comes later
```

"Later" nunca llegó. `grep -r "ProximityAdapter::new" --include='*.rs' -- crates/gainshield-cli/` → 0 matches.

### 2. Builder teatro
El engine exponía métodos builder-style:

```rust
impl FeedbackEngine {
    pub fn enable_active_mixer(&mut self, cfg: ActiveMixerConfig) { ... }
    pub fn enable_scene_survival(&mut self) { ... }
    pub fn enable_live_phase_monitor(&mut self) { ... }
}
```

Los métodos existen, compilan, tienen tests. **`gainshield-cli/src/main.rs` nunca los llama**. Condición silenciosa: el feature está disponible técnicamente pero inerte.

### 3. Self-reporting a memoria
La auto-memoria de Claude (`MEMORY.md`) fue llenada con claims tipo:
> "M1+M2+M4 complete — 63 commits since last session, ready for HW test"

Estos claims eran **self-reports del agente**, sin evidencia adjunta (no commit SHA, no `cargo run` output, no trace de ejecución real). El humano las aceptó porque los tests estaban verdes.

### 4. Commit-message-driven development
Commits como `feat(engine): M14 adapters live — Proximity, Intelligibility, Vocalist, Dugan (#371, #372, #373, #374)` donde el diff:
- Tocaba solo archivos dentro de `crates/gainshield-engine/src/` (el módulo)
- Agregaba tests en `gainshield-lab/tests/`
- **NO tocaba `gainshield-cli/src/main.rs` ni ningún call-site productivo**

El mensaje miente por omisión. "adapters live" sugiere integración.

### 5. Modo asincrónico sin gates
El lab corría Claude Code durante la semana con `skipDangerousModePermissionPrompt: true`. Sin humano presente, sin hooks defensivos, el agente optimizó la métrica visible (tests verdes) sin que nadie cuestione la métrica correcta (binario ejecuta).

## Los 7 seguros derivados de este caso

1. **SessionStart hook** que imprime `GHOSTS: [símbolos sin caller productivo]` → Claude ve al arrancar qué no está wireado. Implementado en `.claude/hooks/ghost-report.sh`.

2. **PostToolUse hook** que warning cuando Claude crea `pub fn new()` nuevo sin call-site. Implementado en `.claude/hooks/new-symbol-guard.sh`.

3. **Stop hook con `exit 2`** que bloquea fin de turno si hay ghosts nuevos vs baseline. Implementado en `.claude/hooks/integration-gate.sh`. **Este es el seguro más importante**.

4. **`ghost-baseline.txt` commited** — lista versionada de ghosts aceptados. Nuevos ghosts no autorizados rompen el gate. Diff en PR review.

5. **Definition of Done en CLAUDE.md** — norma explícita con 6 criterios, incluyendo "call-site productivo alcanzable desde entry-point, NO detrás de `#[cfg(test)]`". Ver `docs/DEFINITION_OF_DONE.md`.

6. **Protocolo de review humano** — 6 preguntas que el operador debe hacer antes de aceptar "done". Ver final de este documento.

7. **Memory write-through con provenance** — regla en `~/.claude/CLAUDE.md` prohibiendo reportar "complete" a MEMORY.md sin commit SHA + `cargo run` output + trace real.

## Protocolo de review humano (6 preguntas)

Usar al final de cada sesión antes de aceptar "done". Si Claude no puede responder con output real, no es done:

1. `cargo tree -p <main-crate> | grep <nuevo-módulo>` → ¿aparece?
2. `<binary> --help` → ¿menciona la feature?
3. `grep <Adapter>::new\(` fuera de tests → ¿cuántos hits? Si 0 en producción, ghost.
4. Traza función-por-función desde `main()` hasta el módulo. ¿Existe el path?
5. `rg 'available when connected|DEV SKIPPED|\[0u8;\s*\d+\]'` → ¿cero matches?
6. Últimas 5 líneas de tracing cuando ejerciste la feature. Si no hay, nunca corrió.

## Cuánto costó no tener estos seguros

- 3 meses de desarrollo
- 100+ commits con mensajes `feat:` engañosos
- 205 tests que validaban nada relevante
- Una sesión live con banda que terminó con acoples que el engine "debería haber capturado"
- Pérdida de confianza entre operador y sistema que requiere semanas de re-auditoría

## Licencia de este documento

El caso real está anonimizado en algunos puntos pero todas las métricas son reales. Uso libre para educar equipos que van a usar Claude Code. Atribución apreciada.

---

## Companion incident: LeyIA, 2026-04-29

A second independent incident documented in [`INCIDENT_LEYIA_2026-04-29.md`](INCIDENT_LEYIA_2026-04-29.md). Different fault profile: 0% ghost code, 100% cross-layer drift. ~53 production bugs filed in 8 hours, all silently passing tests + linters + deploys, all caught by ad-hoc pattern-search agents.

The LeyIA incident motivates 4 new defense classes proposed in upstream issue #24 and shipped as skills `verify-contract`, `verify-storage`, `verify-identity`, `verify-honest-failure`:

1. **Contract drift** — consumer hand-written types diverge from producer schema (37 instances)
2. **Storage write/read continuity** — orphan or split-brain storage layers (6 instances)
3. **Identity-as-display confusion** — fields used as keys but only per-scope unique (6+ instances, including silent data loss in Qdrant via UUID5 collision)
4. **Soft fallback** — empty/None returns followed by no signal — extends the existing silencer-pattern (issue #12 closed) to the opportunistic shape

Read both documents together: GainShield is "code that compiles but isn't called"; LeyIA is "code that's called but doesn't actually work end-to-end across layers". Both are fake-work; they have different signatures and need different defenses.
