# Notes

## Shinylive app rendering options

Reference: https://github.com/posit-dev/shinylive/blob/main/src/Components/App.tsx

### `appMode`

Layout mode for the application:
- `"examples-editor-terminal-viewer"`
- `"editor-terminal-viewer"`
- `"editor-terminal"`
- `"editor-viewer"`
- `"editor-cell"`
- `"viewer"`

### `appEngine`

Runtime engine: `"python"` or `"r"`

### `appOptions`

| Option | Type | Description |
|--------|------|-------------|
| `layout` | `"horizontal"` \| `"vertical"` | Grid arrangement for editor-viewer mode |
| `viewerHeight` | `number` \| `string` | Output panel height (px or CSS units) |
| `editorHeight` | `number` \| `string` | Code editor height (px or CSS units) |
| `selectedExample` | `string` | Which example to pre-select |
| `showHeaderBar` | `boolean` | Show header bar in viewer-only mode |
| `updateUrlHashOnRerun` | `boolean` | Update URL hash encoding when code runs |
| `setWindowTitle` | `{ prefix, defaultTitle }` \| `false` | Configure window title behavior |
