// Artifact deep-dive drawer — history, provenance, descendants (Tailwind edition)

function Drawer({ open, onClose, artifact }) {
  if (!artifact) return null;
  return (
    <>
      {/* Scrim */}
      <div
        className={[
          "fixed inset-0 bg-void/70 z-40 transition-opacity",
          open ? "opacity-100 pointer-events-auto" : "opacity-0 pointer-events-none",
        ].join(" ")}
        onClick={onClose}
      />
      {/* Panel */}
      <aside
        className={[
          "fixed top-0 right-0 bottom-0 w-[600px] z-50 bg-bg border-l border-line overflow-y-auto",
          "transition-transform duration-200",
          open ? "translate-x-0" : "translate-x-full",
        ].join(" ")}
      >
        {/* Head */}
        <div className="sticky top-0 bg-bg border-b border-line px-6 py-4 flex items-baseline gap-3">
          <span className="text-2xs text-fg-mute">{artifact.kindLabel}</span>
          <span className="font-medium text-fg tracking-tight flex-1 min-w-0 whitespace-nowrap overflow-hidden text-ellipsis">{artifact.name}</span>
          <button
            className="text-fg-mute hover:text-fg px-1 font-sans"
            onClick={onClose}
          >close ✕</button>
        </div>

        {/* Meta */}
        <div className="px-6 py-4 border-b border-line">
          <dl className="grid grid-cols-[100px_1fr] gap-x-4 gap-y-1 text-sm">
            <dt className="text-fg-mute text-2xs">id</dt>
            <dd className="m-0 text-fg font-mono text-2xs">{artifact.id}</dd>
            <dt className="text-fg-mute text-2xs">version</dt>
            <dd className="m-0 text-fg">{artifact.version}</dd>
            <dt className="text-fg-mute text-2xs">by</dt>
            <dd className="m-0 text-fg">{artifact.by}</dd>
            <dt className="text-fg-mute text-2xs">created</dt>
            <dd className="m-0 text-fg font-mono text-2xs tabular-nums">{artifact.created}</dd>
          </dl>
        </div>

        {/* Provenance */}
        <div className="px-6 py-4 border-b border-line">
          <h4 className="font-sans text-2xs text-fg-mute mb-2 flex items-baseline gap-2">
            <span>provenance</span>
            <span className="text-fg-ghost font-normal">· upstream {artifact.ancestors?.length || 0}, downstream {artifact.descendants?.length || 0}</span>
          </h4>
          <div className="text-sm">
            {artifact.ancestors?.map((a, i) => (
              <div key={"a" + i} className="flex items-baseline gap-2 py-1" style={{ paddingLeft: i * 20 }}>
                <span className="text-fg-ghost font-mono text-2xs">└</span>
                <span className="text-fg-mute text-2xs">{a.kind}</span>
                <span className="text-fg font-medium">{a.name}</span>
                <span className="text-fg-mute text-2xs ml-auto">{a.by}</span>
              </div>
            ))}
            <div
              className="flex items-baseline gap-2 py-1 border-l-2 border-amber bg-amber/10 pl-2"
              style={{ marginLeft: (artifact.ancestors?.length || 0) * 20 }}
            >
              <span className="text-amber font-mono text-2xs">●</span>
              <span className="text-amber text-2xs">{artifact.kindLabel}</span>
              <span className="text-fg font-medium">{artifact.name}</span>
              <span className="text-fg-mute text-2xs ml-auto">(this)</span>
            </div>
            {artifact.descendants?.map((d, i) => (
              <div key={"d" + i} className="flex items-baseline gap-2 py-1" style={{ paddingLeft: ((artifact.ancestors?.length || 0) + 1 + i) * 20 }}>
                <span className="text-fg-ghost font-mono text-2xs">└</span>
                <span className="text-fg-mute text-2xs">{d.kind}</span>
                <span className="text-fg font-medium">{d.name}</span>
                <span className="text-fg-mute text-2xs ml-auto">{d.by}</span>
              </div>
            ))}
            {(!artifact.descendants || artifact.descendants.length === 0) && (
              <div
                className="text-fg-ghost text-2xs py-1"
                style={{ marginLeft: ((artifact.ancestors?.length || 0) + 1) * 20 }}
              >— no descendants yet —</div>
            )}
          </div>
        </div>

        {/* History */}
        <div className="px-6 py-4 border-b border-line">
          <h4 className="font-sans text-2xs text-fg-mute mb-2 flex items-baseline gap-2">
            <span>history</span>
            <span className="text-fg-ghost font-normal">· {artifact.history?.length || 0} entries</span>
          </h4>
          <div className="space-y-0.5">
            {artifact.history?.map((h, i) => {
              const opColor = h.op === "create" ? "text-green" : h.op === "revise" ? "text-amber" : h.op === "cite" ? "text-cyan" : "text-fg-mute";
              return (
                <div key={i} className="grid grid-cols-[72px_56px_1fr_auto] gap-3 text-sm">
                  <span className="font-mono text-2xs text-lavender tabular-nums">{h.when}</span>
                  <span className={"text-2xs " + opColor}>{h.op}</span>
                  <span className="text-fg-dim">{h.what}</span>
                  <span className="text-fg-mute text-2xs">{h.by}</span>
                </div>
              );
            })}
          </div>
        </div>

        {/* Body preview */}
        {artifact.body && (
          <div className="px-6 py-4">
            <h4 className="font-sans text-2xs text-fg-mute mb-2">preview</h4>
            <div className="text-sm text-fg-dim" dangerouslySetInnerHTML={{ __html: artifact.body }} />
          </div>
        )}
      </aside>
    </>
  );
}

Object.assign(window, { Drawer });
