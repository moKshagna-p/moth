# UI design rules

- Every new or modified Moth UI component must follow a proper frosted Liquid Glass design. Preserve this treatment whenever tweaking existing UI.
- Standalone Moth buttons, including wallpaper actions, must show their frosted surface at rest, not only on hover. Use a shared treatment so new controls stay consistent. Related wallpaper actions share one frosted capsule with clear, borderless icons. Inside a frosted picker or list panel, use clean, borderless rows that share the panel’s glass surface; avoid a separate glass outline around every row.
- Use native macOS SwiftUI Liquid Glass APIs (`glassEffect`, `.glass` / `.glassProminent` button styles, and `GlassEffectContainer` for related glass surfaces). Prefer the frosted `.regular` material, with restrained tinting and consistent shapes.
- Apply glass after layout and appearance modifiers. Enable interactive glass for controls, and avoid opaque backgrounds or stacked glass layers that hide the material's blur and translucency.
- Keep text and icons clearly readable over light, dark, and detailed wallpapers. Preserve accessibility labels, keyboard interactions, and system accessibility adaptations, including Reduce Transparency and Increase Contrast.
- Verify modified UI in the running local app, including its glass appearance and contrast; a successful build alone does not prove the visual result.
- Apply glass to Moth's own controls and surfaces; preserve the appearance of third-party web content.
