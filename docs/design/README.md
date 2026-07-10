# Design source index / 设计资料索引

This directory preserves the product and technical sources that define the V1 baseline. Older or duplicate visual assets are indexed here rather than deleted because they may document earlier decisions.

本目录保存定义 V1 基线的产品与技术资料。旧版或重复视觉资产不会在不确定用途时直接删除，而是在此索引，避免丢失设计决策依据。

## Current sources of truth / 当前基线

- [Product plan V5](product-plan-v5/AgentPetCompanion_ProductPlan_V5.md): navigation, Pet Studio four-field form, library, behavior, connections, overlay and V1 scope.
- [Technical plan V1.1](AgentPetCompanion_TechnicalPlan_V1_1.md): SwiftUI/AppKit/Metal app, Rust PetCore, UDS JSON-RPC, SQLite, `.petpack`, performance and connector boundaries.
- [Implementation plan V2](../plan/AgentPetCompanion_ImplementationPlan_V2.md): delivery sequence and executable validation milestones; subordinate to the two design plans above.

- [产品方案 V5](product-plan-v5/AgentPetCompanion_ProductPlan_V5.md)：导航、Pet Studio 四字段表单、宠物库、行为、连接、悬浮层与 V1 范围。
- [技术方案 V1.1](AgentPetCompanion_TechnicalPlan_V1_1.md)：SwiftUI/AppKit/Metal App、Rust PetCore、UDS JSON-RPC、SQLite、`.petpack`、性能与 connector 边界。
- [实施计划 V2](../plan/AgentPetCompanion_ImplementationPlan_V2.md)：交付顺序和可执行验证里程碑；若有冲突，以上两份设计方案优先。

## Product-plan assets / 产品方案素材

`product-plan-v5/` contains:

- the Markdown source and an exported HTML copy;
- current screen references for Pet Studio New/Session, Pet Library, Enable & Behavior, Agent Connections, and overlay resizing;
- corresponding HTML source captures under `source/`;
- two earlier Pet Studio exports (`01_pet_studio_create.png`, `02_pet_studio_ai_session.png` and matching HTML) retained as historical references.

`product-plan-v5/` 包含 Markdown、HTML 导出、当前页面参考图、对应 HTML source，以及两份较早的 Pet Studio 导出。历史素材仅作为参考，不覆盖当前产品方案。

When reviewing a visual change, compare the reference and implementation at the same viewport, appearance, and state. Screenshots alone are evidence, not a substitute for interaction, accessibility, and runtime checks.

审查视觉改动时，应在相同视口、外观模式和状态下对比参考图与实现。截图是证据，但不能替代交互、无障碍和运行时验证。
