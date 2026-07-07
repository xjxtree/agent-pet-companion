# Claude Code Notes

This repo contains the planning foundation for Agent Pet Companion. It is currently initialized with design docs and repository guidance; implementation should follow the staged V1 plan.

## Read First

1. `README.md`
2. `docs/design/product-plan-v5/AgentPetCompanion_ProductPlan_V5.md`
3. `docs/design/AgentPetCompanion_TechnicalPlan_V1_1.md`
4. `docs/design/AgentPetCompanion_ImplementationPlan_V2.md`
5. `AGENTS.md`

## Working Agreement

- Treat the design documents as the product and architecture baseline.
- Keep changes phase-oriented. M0 comes before M1, M1 before M2, and so on.
- Use SwiftUI/AppKit/Metal for the macOS shell and overlay when that code exists.
- Use Rust for PetCore, CLI, shared types, local IPC, event aggregation, and petpack validation.
- Do not introduce cloud accounts, hosted backends, public galleries, sharing, Petdex import, or Windows UI for V1.
- Do not inspect or copy auth, token, cookie, API key, or secret files from any supported agent.

## Expected Validation

For future code changes, prefer local checks that match the touched area:

- Swift/macOS: build and test the Xcode project or package target.
- Rust: `cargo fmt`, `cargo clippy`, and `cargo test` for the relevant workspace crates.
- Docs-only changes: verify links and confirm copied assets still resolve from Markdown.

When validation cannot run because the relevant project skeleton does not exist yet, state that clearly in the final response.
