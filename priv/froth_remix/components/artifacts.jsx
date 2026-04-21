// Artifact bodies — each one its own thing, no chrome. Tailwind edition.

// ─── Image — just a photograph ───────────────────────────────────────────
function ImageBody({ w = 280 }) {
  return (
    <div className="inline-block overflow-hidden bg-void" style={{ width: w }}>
      <svg viewBox="0 0 400 290" width="100%" preserveAspectRatio="xMidYMid slice">
        <defs>
          <radialGradient id="glow2" cx="46%" cy="52%" r="62%">
            <stop offset="0%" stopColor="#e8a33d" stopOpacity="0.42"/>
            <stop offset="50%" stopColor="#7a5423" stopOpacity="0.2"/>
            <stop offset="100%" stopColor="#000" stopOpacity="0"/>
          </radialGradient>
          <pattern id="paper" width="3" height="5" patternUnits="userSpaceOnUse">
            <path d="M0 5 L3 5" stroke="#2a2218" strokeWidth="0.25" opacity="0.5"/>
          </pattern>
        </defs>
        <rect width="400" height="290" fill="#070609"/>
        <g transform="rotate(-3 200 145)">
          <rect x="70" y="28" width="260" height="234" fill="#1c150c" stroke="#3a2d1c" strokeWidth="0.6"/>
          <rect x="70" y="28" width="260" height="234" fill="url(#paper)"/>
          <g fontFamily="monospace" fill="#78726a">
            <text x="84" y="52" fontSize="6.5" letterSpacing="0.4">VALSTS IEŅĒMUMU DIENESTS</text>
            <text x="84" y="63" fontSize="5" opacity="0.6">Talejas iela 1, Rīga LV-1978</text>
            <text x="84" y="88" fontSize="6">RĒĶINS</text>
            <text x="130" y="88" fontSize="6" fill="#a8a49a">2026-00412</text>
            <text x="84" y="110" fontSize="5.5">soc. apdrošināšana</text>
            <text x="280" y="110" fontSize="5.5" textAnchor="end">863.00</text>
            <text x="84" y="120" fontSize="5.5">procenti (12 d.)</text>
            <text x="280" y="120" fontSize="5.5" textAnchor="end">12.40</text>
            <line x1="84" y1="128" x2="280" y2="128" stroke="#3a2d1c" strokeWidth="0.4"/>
            <text x="84" y="140" fontSize="7" fill="#c9c3b5">KOPĀ</text>
            <text x="280" y="140" fontSize="7" fill="#e8a33d" textAnchor="end">875.40 EUR</text>
            <text x="84" y="170" fontSize="5">termiņš  2026-04-20</text>
            <text x="84" y="180" fontSize="5">maksātājs  Mira Ozola</text>
            <text x="84" y="220" fontSize="4.5" opacity="0.5">LV40003456789 · IBAN LV08 HABA …</text>
          </g>
        </g>
        <rect width="400" height="290" fill="url(#glow2)"/>
      </svg>
    </div>
  );
}

// ─── Invoice chit — subtle raised substrate ──────────────────────────────
function InvoiceCard({ payer, amount, due, refNum, paid, txHash, onPay }) {
  return (
    <div className="inline-block border border-line bg-raised p-4 min-w-[360px] max-w-[480px]">
      {/* head */}
      <div className="flex items-baseline gap-4 pb-3 border-b border-line">
        <div className="flex-1 min-w-0">
          <div className="text-fg">{payer}</div>
          <div className="font-mono text-2xs text-fg-mute tabular-nums mt-0.5">{refNum}</div>
        </div>
        <div className="text-right">
          <div className="font-sans text-2xs text-fg-mute">EUR</div>
          <div className="font-mono text-xl leading-none text-fg tabular-nums mt-1">{amount}</div>
        </div>
      </div>

      {/* grid */}
      <dl className="grid grid-cols-[80px_1fr] gap-x-4 gap-y-1 pt-3 text-sm">
        <dt className="text-fg-mute text-2xs self-center">issued</dt>
        <dd className="m-0 font-mono tabular-nums text-fg-dim">2026-04-08</dd>
        <dt className="text-fg-mute text-2xs self-center">due</dt>
        <dd className="m-0 text-fg-dim"><span className="font-mono tabular-nums">{due}</span></dd>
        <dt className="text-fg-mute text-2xs self-center">debit</dt>
        <dd className="m-0 text-fg-dim">Swedbank · operating</dd>
      </dl>

      {/* action / receipt */}
      {!paid ? (
        <div className="flex items-baseline gap-3 mt-4 pt-3 border-t border-line">
          <button
            className="no-open bg-amber text-void px-3 h-8 font-sans font-medium text-sm hover:brightness-110 transition"
            onClick={(e) => { e.stopPropagation(); onPay && onPay(); }}
          >
            authorize &nbsp;·&nbsp; {amount} EUR &nbsp;→
          </button>
          <span className="text-2xs text-fg-mute">SEPA · touch-id on phone</span>
        </div>
      ) : (
        <div className="flex flex-wrap items-baseline gap-x-2 gap-y-1 mt-4 pt-3 border-t border-dashed border-line text-2xs">
          <span className="text-green">● signed</span>
          <span className="text-green">broadcast</span>
          <span className="text-green">confirmed</span>
          <span className="text-fg-ghost">·</span>
          <span className="text-fg-mute">tx <span className="font-mono text-fg-dim">{txHash}</span></span>
          <span className="text-fg-ghost">·</span>
          <span className="text-fg-mute">settled <span className="font-mono">14:07</span></span>
        </div>
      )}
    </div>
  );
}

// ─── Shell — terminal lines, no frame ────────────────────────────────────
function ShellBody({ live, cmds, runtime, exitOk, expanded, onToggle }) {
  if (!expanded) {
    return (
      <button
        className="no-open inline-flex items-baseline gap-2 font-mono text-sm text-fg-mute hover:text-fg py-1"
        onClick={(e) => { e.stopPropagation(); onToggle && onToggle(); }}
      >
        <span className="text-fg-ghost">▸</span>
        <span className="text-green">●</span>
        <span><b className="text-fg-dim font-normal">{cmds.filter(c => c.kind === "cmd").length}</b> commands {exitOk ? "succeeded" : "failed"}</span>
        <span className="text-fg-ghost">in {runtime}</span>
      </button>
    );
  }
  return (
    <div className="font-mono text-sm max-w-[720px]">
      {cmds.map((c, i) => {
        const glyph = c.kind === "cmd" ? "$" : c.kind === "err" ? "!" : c.kind === "ok" ? "✓" : " ";
        const glyphColor =
          c.live ? "text-amber animate-blink" :
          c.kind === "cmd" ? "text-cyan" :
          c.kind === "err" ? "text-red" :
          c.kind === "ok"  ? "text-green" : "text-fg-ghost";
        const txtColor =
          c.live ? "text-fg" :
          c.kind === "cmd" ? "text-fg" :
          c.kind === "err" ? "text-red" :
          c.kind === "ok"  ? "text-green" :
          c.kind === "out" ? "text-fg-dim" : "text-fg-dim";
        return (
          <div key={i} className="grid grid-cols-[16px_1fr_auto] gap-2 items-baseline">
            <span className={"font-bold " + glyphColor}>{glyph}</span>
            <span className={txtColor}>
              {c.txt}
              {c.live && <span className="inline-block w-[7px] h-3 bg-amber align-[-2px] ml-0.5 animate-blink" />}
            </span>
            <span className="text-fg-ghost text-2xs tabular-nums">{c.ms || ""}</span>
          </div>
        );
      })}
    </div>
  );
}

// ─── Audio — compact one-row player ─────────────────────────────────────
function AudioBody({ title, duration, bars, cur = 0.33, playing = false, onTogglePlay }) {
  const curMs = Math.floor(cur * 372); // 6:12 total
  const mm = String(Math.floor(curMs / 60)).padStart(2, "0");
  const ss = String(curMs % 60).padStart(2, "0");
  const curIdx = Math.floor(cur * bars.length);
  return (
    <div className="inline-flex items-center gap-3 border border-line bg-raised pl-2 pr-3 py-2 max-w-[620px]">
      <button
        className="no-open w-7 h-7 flex items-center justify-center bg-green text-void font-mono text-xs hover:brightness-110 transition"
        onClick={(e) => { e.stopPropagation(); onTogglePlay && onTogglePlay(); }}
      >
        {playing ? "❚❚" : "▶"}
      </button>
      <div className="text-fg-dim text-sm min-w-0 max-w-[280px] truncate">{title}</div>
      <div className="flex items-end gap-[2px] h-5">
        {bars.map((h, i) => {
          const pct = i / bars.length;
          const on = pct < cur;
          const isCur = i === curIdx;
          return (
            <div
              key={i}
              className={[
                "w-[2px] transition-colors",
                on ? "bg-green" : isCur ? "bg-green shadow-[0_0_6px_-1px_#5ae38a]" : "bg-line",
              ].join(" ")}
              style={{ height: (2 + h * 14) + "px" }}
            />
          );
        })}
      </div>
      <div className="font-mono text-2xs tabular-nums text-fg-dim whitespace-nowrap">
        {mm}:{ss}<span className="text-fg-ghost"> / {duration}</span>
      </div>
    </div>
  );
}

// ─── Code diff — mono file path, clean diff ─────────────────────────────
function CodeBody({ path, added, deleted, lines, review }) {
  return (
    <div className="border border-line bg-raised max-w-[720px]">
      {/* path */}
      <div className="flex items-baseline gap-4 px-3 py-1.5 border-b border-line font-mono text-2xs">
        <span className="text-fg">{path}</span>
        <span className="ml-auto">
          <span className="text-green">+{added}</span>
          <span className="text-fg-ghost mx-1">/</span>
          <span className="text-red">−{deleted}</span>
        </span>
      </div>
      {/* diff */}
      <div className="font-mono text-2xs py-1">
        {lines.map((l, i) => {
          const bg = l.k === "add" ? "bg-green/10" : l.k === "del" ? "bg-red/10" : "";
          const marker = l.k === "add" ? "+" : l.k === "del" ? "−" : " ";
          const markerColor = l.k === "add" ? "text-green" : l.k === "del" ? "text-red" : "text-fg-ghost";
          return (
            <div key={i} className={"grid grid-cols-[32px_32px_16px_1fr] px-2 " + bg}>
              <span className="text-fg-ghost tabular-nums text-right pr-2">{l.a || ""}</span>
              <span className="text-fg-ghost tabular-nums text-right pr-2">{l.b || ""}</span>
              <span className={markerColor + " text-center"}>{marker}</span>
              <span className="text-fg-dim" dangerouslySetInnerHTML={{ __html: l.src }} />
            </div>
          );
        })}
      </div>
      {/* review */}
      {review && (
        <div className="px-3 py-2 border-t border-line text-2xs text-fg-dim">
          <span className="text-cyan font-medium mr-2">orr</span>
          tests pass <span className="font-mono text-green">42/42</span>, a visual-regression run flagged a 1px baseline shift at <span className="font-mono text-cyan">invoice.tsx:44</span> — patched above.
        </div>
      )}
    </div>
  );
}

// ─── Essay — naked prose ────────────────────────────────────────────────
function EssayBody({ eyebrow, title, lede, paragraphs }) {
  return (
    <div className="max-w-[620px]">
      {eyebrow && <div className="font-sans text-2xs text-fg-mute uppercase tracking-wider mb-2">{eyebrow}</div>}
      <h1 className="font-serif text-2xl leading-[32px] lowercase [font-variant-caps:all-small-caps] tracking-wide text-fg">{title}</h1>
      {lede && <div className="font-serif text-lg text-fg-dim italic mt-3 mb-4">{lede}</div>}
      <div className="font-serif text-base text-fg-dim space-y-3 [&>p]:m-0">
        {paragraphs.map((p, i) => <p key={i} dangerouslySetInnerHTML={{ __html: p }} />)}
      </div>
    </div>
  );
}

Object.assign(window, { EssayBody, ShellBody, AudioBody, InvoiceCard, CodeBody, ImageBody });
