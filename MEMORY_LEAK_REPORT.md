# TapTapLoot — Memory Leak Investigation

> This analysis was produced with the assistance of **Claude Code** (Anthropic).

**Date:** 2026-06-01
**Investigator notes:** read-only analysis. The original Steam install and save data were **not** modified.

---

## 1. What kind of software is it / how it was built

| Property | Finding |
|---|---|
| Engine | **Unity** (URP 2D — Universal Render Pipeline modules present) |
| Scripting backend | **Mono** (not IL2CPP) — folder `MonoBleedingEdge\` present |
| Implication | Game logic ships as managed **.NET DLLs** that decompile cleanly. **`.pdb` symbol files are shipped too**, so decompilation recovers real method/field names. |
| Game code | `TapTapLoot_Data\Managed\Assembly-CSharp.dll` (766 KB) |
| Developer | Turtle Knight Games (`app.info`) — makers of *Bongo Cat* |
| Notable libs | DOTween (tweening), protobuf-net + Newtonsoft.Json (serialization), Steamworks.NET, SDL2-CS, WallstopStudios.UnityHelpers (the attribute/effect framework) |
| Genre | Keyboard-driven idle/clicker RPG with multiplayer + Bongo Cat IPC integration |

**How I analyzed it (reproducible):**
1. Located install at `C:\Program Files (x86)\Steam\steamapps\common\TapTapLoot` (left untouched).
2. Copied `...\TapTapLoot_Data\Managed\` into this workspace (`.\Managed\`).
3. Installed the ILSpy CLI: `dotnet tool install --global ilspycmd`.
4. Decompiled to C#: `ilspycmd .\Managed\Assembly-CSharp.dll -o .\decompiled -p` → 610 `.cs` files.

---

## 2. THE memory leak (primary, confirmed)

### `TapTapLoot.Actors.BongoCatBuffSystem` — unbounded growth + leaked ScriptableObjects + buffs never removed

File: `decompiled\TapTapLoot.Actors\BongoCatBuffSystem.cs`

```csharp
private List<AttributeEffect> storedBuffs = new List<AttributeEffect>();

public void Buff(string attribute, float factor) {
    AttributeEffect attributeEffect = CreateEffect(attribute, factor);   // new SO
    storedBuffs.Add(attributeEffect);
    GameManager.Instance.LocalPlayer.Attributes.AddEffect(attributeEffect);
}

public void UnBuff(string attribute, float factor) {
    AttributeEffect attributeEffect = CreateEffect(attribute, factor);   // *** a BRAND-NEW SO ***
    storedBuffs.Remove(attributeEffect);                                 // removes nothing
    GameManager.Instance.LocalPlayer.Attributes.DeleteEffect(attributeEffect); // removes nothing
}

private AttributeEffect CreateEffect(string attribute, float value) {
    AttributeEffect attributeEffect = ScriptableObject.CreateInstance<AttributeEffect>();
    attributeEffect.modifications.Add(new AttributeModification(attribute, ModificationAction.Multiplication, value));
    attributeEffect.durationType = ModifierDurationType.Infinite;
    return attributeEffect;
}
```

**Why it leaks (three compounding problems):**

`AttributeEffect` is a Unity `ScriptableObject` and does **not** override `Equals`/`GetHashCode` (verified: only `ItemData`/`ItemInstance` override them in the whole assembly). So it uses **reference equality**.

`UnBuff` creates a *new* object and then asks the list and the player's effect dictionary to remove *that* object. The original effect created by `Buff` has a different reference, so:

1. **`storedBuffs.Remove(...)` matches nothing** → `storedBuffs` grows forever.
2. **`Attributes.DeleteEffect(...)` matches nothing** → the player's `m_activeEffects` dictionary (in `ActorAttributes.cs`) grows forever, and the actual stat buff is **never removed** (gameplay bug: buffs silently stack/permanent).
3. **The new SO from `UnBuff` is orphaned immediately.** Runtime-created `ScriptableObject`s are **not** garbage-collected by Unity — they remain as leaked native objects until explicitly `Object.Destroy`-ed. Nothing in the codebase ever destroys an `AttributeEffect` (verified: zero `Destroy(...effect...)` calls).

**How often it runs (the multiplier):**

`BongoCat.IPC\Ipc.cs` drives it from `Update()`:

```csharp
private void Update() {
    if (_buff != null) { _buffSystem.UpdateBuffs(_buff); _buff = null; }
    ...
}
```

`_buff` is fed by a background named-pipe thread (Bongo Cat / companion-app integration — a core feature). Each `UpdateBuffs(buffs)` call:
- `UnBuff`s every previous buff → N orphaned SOs, removes nothing;
- `Buff`s every new buff → N more SOs, **+N** to `storedBuffs`, **+N** to the player's `m_activeEffects`.

So **every buff update permanently adds 2·N leaked ScriptableObjects and grows two collections by N**, with none of it ever reclaimed. Over a long idle session this is exactly the steady, unbounded climb you're seeing. As a side effect the player's effect dictionary keeps growing, so per-frame stat recomputation also slows down over time.

**Root cause in one line:** using `CreateEffect(...)` to *identify which buff to remove* is wrong for reference-typed `ScriptableObject`s — removal must use the *same instance* that was added.

### Suggested fix (do NOT apply to the Steam install)

Track the actual instances and destroy them on removal, e.g.:

```csharp
private readonly Dictionary<(string attr, float factor), AttributeEffect> _active = new();

public void Buff(string attribute, float factor) {
    var key = (attribute, factor);
    if (_active.ContainsKey(key)) return;
    var fx = CreateEffect(attribute, factor);
    _active[key] = fx;
    GameManager.Instance.LocalPlayer.Attributes.AddEffect(fx);
}

public void UnBuff(string attribute, float factor) {
    if (_active.TryGetValue((attribute, factor), out var fx)) {
        GameManager.Instance.LocalPlayer.Attributes.DeleteEffect(fx);
        _active.Remove((attribute, factor));
        Object.Destroy(fx);   // reclaim the runtime ScriptableObject
    }
}
```

(`UpdateBuffs` should diff against the previously applied set using the same instances. Ideally `ActorAttributes.DeleteEffect` should also `Object.Destroy` the effect once removed.)

---

## 3. Secondary leak (real, lower severity)

### `EnemySpawner.ScaleAndApplyEffectsToActor` creates a ScriptableObject per spawn that is never destroyed

File: `decompiled\TapTapLoot\EnemySpawner.cs:313–327`

```csharp
private void ScaleAndApplyEffectsToActor(Actor actor, List<BaseEventEffect> effects) {
    AttributeEffect attributeEffect = ScriptableObject.CreateInstance<AttributeEffect>(); // every spawn
    ...
    actor.ApplyEffect(attributeEffect);
}
```

Every enemy spawn allocates a fresh `AttributeEffect` SO. When an enemy is recycled through the object pool, `ActorAttributes.Set()` / `DeleteEffect()` drop the old effect references **without `Object.Destroy`-ing them**. In an idle clicker that spawns enemies continuously for hours, these orphaned SOs accumulate. Same class of bug as above (runtime SO never destroyed), just slower. Fix: cache/reuse the effect, or `Object.Destroy` it when the actor is despawned.

`AtkBuff.cs:74`, `SlimeKing.cs:119`, and `ScaleEnemyTrigger.cs:24` use the same `CreateInstance<AttributeEffect>()` pattern and are worth auditing for the same lifecycle gap, though they fire far less often.

---

## 4. Things I checked and cleared (so you don't re-chase them)

- **`IncidentText`** (damage/heal/status numbers): each spawned text self-destroys via the DOTween `OnComplete` callback after ~1.5 s. Bounded — not a leak.
- **`ChainLightningSpellV2`**: its `m_lightningAnimators` list is capped at `m_maxHits` (5) and **reused**, with `CleanUp()` on destroy. Not unbounded.
- **`GenericObjectPooler`**: correct get/return/clear semantics. Sound.
- **`EnemySpawner` event subscriptions & actor lists**: balanced `+=`/`-=` in `OnEnable`/`OnDisable`; listeners removed before re-adding (lines 294–295); actors removed from `m_actives`/`m_fighters` on death. Clean.

(An automated first-pass sweep flagged ~15 "suspects," but most were speculative — the ones above were verified false positives by reading the actual code.)

---

## 5. Bottom line

The leak you're observing is almost certainly **`BongoCatBuffSystem.UnBuff` failing to remove buffs** because it compares freshly-created `ScriptableObject` instances by reference. The result is monotonic growth of `storedBuffs`, the player's active-effects dictionary, and orphaned `AttributeEffect` ScriptableObjects — driven on a loop by the Bongo Cat IPC buff feed. `EnemySpawner`'s per-spawn effect allocation is a smaller secondary contributor.

This is the developer's bug to fix in source; nothing here is something you can patch safely in the shipped DLL without risking your install/save. Best action: report it to Turtle Knight Games (it reproduces simply: leave the game running with the Bongo Cat buff integration active and watch managed-object count / memory climb).
