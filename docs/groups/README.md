# Groups

The **group** is the optional, recursive middle level of the project hierarchy
(Project → Group → Component → Code; see `docs/ARCHITECTURE.md` §4). A group is a
**subsystem: a collection of specs** that share integration/contracts. Groups own no
business logic — their children do — but per **D7** a group MAY own *thin orchestration
glue* (a dispatcher/router whose only reason to change is the child topology).

## When a group exists

Groups are **demand-driven**: one is created exactly when the **area-vs-split gate**
(see `docs/specs/document-taxonomy.spec.md` § Area-vs-split gate) returns "split" —
i.e. a spec's facets have different reasons to change and share no mutable state, so
they become ≥2 sibling specs that form a subsystem. A single spec never needs a group.
Small projects never trigger a split and skip this layer entirely.

## How membership is encoded

**Logical overlay, not physical nesting (D5).** Spec docs stay flat in `docs/specs/`.
A group is `docs/groups/<name>.md` (template: `docs/templates/group.md`) with bidirectional
ownership: the group lists `contains: [child, …]`; each child declares `parent: <group>`.
The integrity of that round-trip is enforced by `scripts/validate-group-membership.sh`.

## Where shared modules live (D8)

Share at the lowest common ancestor: one spec → that spec's subtree; one group's children →
the **group's subtree** (`scripts/<group>/`), owned by a substrate child; multiple groups →
`scripts/lib/` (owned by `shared-components`). Crossing up an altitude triggers the
`extract-shared-component` methodology (#630).
