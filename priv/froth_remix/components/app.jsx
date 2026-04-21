// Froth — main app

function App() {
  const [tweaks, setTweaks] = React.useState(window.TWEAK_DEFAULTS);
  const [tweaksOpen, setTweaksOpen] = React.useState(false);
  const [drawer, setDrawer] = React.useState({ open: false, key: null });

  // Live run state
  const [runPhase, setRunPhase] = React.useState("pending");
  const [runStep, setRunStep] = React.useState(0);
  const [paid, setPaid] = React.useState(false);
  const [podcastPlaying, setPodcastPlaying] = React.useState(false);
  const [podcastCur, setPodcastCur] = React.useState(0.33);
  const [sidebarHot, setSidebarHot] = React.useState(null);

  // Kick off canned run
  React.useEffect(() => {
    const t1 = setTimeout(() => setRunPhase("running"), 1200);
    return () => clearTimeout(t1);
  }, []);

  React.useEffect(() => {
    if (runPhase !== "running") return;
    const steps = [900, 1000, 1100, 1300];
    let cancelled = false;
    function advance(i) {
      if (cancelled) return;
      if (i > steps.length) { setRunPhase("done"); setPaid(true); return; }
      setRunStep(i);
      setTimeout(() => advance(i + 1), steps[i] || 800);
    }
    setTimeout(() => advance(1), 400);
    return () => { cancelled = true; };
  }, [runPhase]);

  // Podcast time advance while playing
  React.useEffect(() => {
    if (!podcastPlaying) return;
    const t = setInterval(() => setPodcastCur((c) => (c >= 1 ? 0 : c + 0.01)), 220);
    return () => clearInterval(t);
  }, [podcastPlaying]);

  // Lineage — sets of turn indices to highlight when hovering an artifact
  const [hotLineage, setHotLineage] = React.useState(null);
  const LINEAGE = {
    "photo-invoice":  new Set([0]),
    "parsed-invoice": new Set([0, 1, 2]),
    "payment-shell":  new Set([0, 1, 2, 3]),
    "code-fix":       new Set([0, 1, 2, 5, 6]),
    "podcast":        new Set([0, 1, 2, 5, 6, 7]),
  };
  const active = hotLineage || sidebarHot;
  const hotSet = active ? LINEAGE[active] : null;
  const isHot = (i) => hotSet && hotSet.has(i);

  // Tweaks: register edit-mode listener
  React.useEffect(() => {
    function onMsg(e) {
      if (!e.data || typeof e.data !== "object") return;
      if (e.data.type === "__activate_edit_mode") { setTweaksOpen(true); }
      if (e.data.type === "__deactivate_edit_mode") { setTweaksOpen(false); }
    }
    window.addEventListener("message", onMsg);
    window.parent.postMessage({ type: "__edit_mode_available" }, "*");
    return () => window.removeEventListener("message", onMsg);
  }, []);

  function updateTweaks(next) {
    setTweaks(next);
    window.parent.postMessage({ type: "__edit_mode_set_keys", edits: next }, "*");
  }
  function openDrawer(key) { setDrawer({ open: true, key }); }
  function closeDrawer() { setDrawer({ ...drawer, open: false }); }

  const shellCmds = [
    { kind: "cmd", txt: "swed sign --account op --to LV08HABA055100… --amount 87540 --ref 2026-00412" },
    runStep >= 1 && { kind: "ok",  txt: "signature captured · mira · 14:05:04", ms: "240ms" },
    runStep >= 2 && { kind: "cmd", txt: "sepa broadcast --tx 0x7a1c4f09" },
    runStep >= 3 && { kind: "ok",  txt: "accepted by clearer · pending confirmation", ms: "612ms" },
    runStep >= 4 && { kind: "ok",  txt: "confirmed · block 21,417,308 · fee €0.35", ms: "1.3s" },
    runPhase === "running" && runStep < 4 && { kind: "out", txt: "awaiting confirmation", live: true },
  ].filter(Boolean);

  return (
    <div className="flex h-screen bg-bg text-fg">
      <Sidebar activeKey={active} onOpen={openDrawer} onHover={setSidebarHot} />

      <main className="flex-1 flex flex-col min-w-0">
        <div className="flex-1 overflow-y-auto">
          <div className="max-w-[960px] mx-auto py-6">

            {/* Daybreak */}
            <div className="grid grid-cols-[56px_1fr_56px] gap-x-4 px-7 py-2 items-baseline">
              <div className="text-right text-fg-mute text-2xs">tue</div>
              <div className="text-fg-mute text-2xs">
                21 april 2026
                <span className="font-mono text-fg-ghost ml-3 tabular-nums">13:52 — 17:04</span>
              </div>
            </div>

            {/* 0 — Mira drops the photo */}
            <Turn who="mira" when="13:52" hot={isHot(0)} threaded={isHot(0)}>
              <Msg>ok small favor — can someone deal with this before I get on the train? soc thing, due today.</Msg>
            </Turn>
            <Turn who="mira" when="" block>
              <div
                onMouseEnter={() => setHotLineage("photo-invoice")}
                onMouseLeave={() => setHotLineage(null)}
              >
                <Artifact
                  kind="image"
                  onOpen={() => openDrawer("photo-invoice")}
                  caption="a photograph · 4032×3024 · heic"
                >
                  <ImageBody />
                </Artifact>
              </div>
            </Turn>

            {/* 1 — Vale parses, replies with a card */}
            <Turn who="vale" when="13:54" hot={isHot(1)} threaded={isHot(1)} isChild={isHot(1)}>
              <Msg>on it. OCR's clean — soc contributions line, plus twelve days interest. authorize below.</Msg>
            </Turn>
            <Turn who="vale" when="" block>
              <div
                onMouseEnter={() => setHotLineage("parsed-invoice")}
                onMouseLeave={() => setHotLineage(null)}
              >
                <Artifact
                  kind="ledger"
                  onOpen={() => openDrawer("parsed-invoice")}
                  lineage={[{ label: "from the photograph", onClick: () => openDrawer("photo-invoice") }]}
                >
                  <InvoiceCard
                    payer="State Revenue Service · LV"
                    amount="875.40"
                    due="2026-04-20 · 12 days past"
                    refNum="ref 2026-00412"
                    paid={paid}
                    txHash="0x7a1c…4f09"
                  />
                </Artifact>
              </div>
            </Turn>

            {/* 2 — Mira authorizes */}
            <Turn who="mira" when="14:04" hot={isHot(2)} threaded={isHot(2)}>
              <Msg>authorized. <span className="text-fg-mute">(touch-id, phone)</span></Msg>
            </Turn>

            {/* 3 — Orr runs the SEPA shell */}
            <Turn who="orr" when="14:05" hot={isHot(3)} threaded={isHot(3)} isChild={isHot(3)}>
              <Msg>signing from <span className="font-mono text-2xs text-amber bg-amber/10 px-1">swedbank · operating</span>.</Msg>
            </Turn>
            <Turn who="orr" when="" block>
              <div
                onMouseEnter={() => setHotLineage("payment-shell")}
                onMouseLeave={() => setHotLineage(null)}
              >
                <Artifact
                  kind="shell"
                  onOpen={() => openDrawer("payment-shell")}
                  caption={runPhase === "done" ? "SEPA signing · 4 commands · 2.2s" : "SEPA signing · live"}
                  lineage={[{ label: "binds invoice · LV-2026-00412", onClick: () => openDrawer("parsed-invoice") }]}
                >
                  <ShellBody
                    expanded={runPhase !== "done"}
                    live={runPhase === "running"}
                    cmds={shellCmds}
                    runtime="2.2s"
                    exitOk
                  />
                </Artifact>
              </div>
            </Turn>

            {/* 4 — Jonas laughs */}
            <Turn who="jonas" when="14:31">
              <Msg><span className="align-[-1px] text-base">😄</span> efficient. also — one small ugly thing.</Msg>
            </Turn>

            {/* 5 — Jonas quotes card as bug */}
            <Turn who="jonas" when="14:33" hot={isHot(5)} threaded={isHot(5)} isChild={isHot(5)} block>
              <Msg>
                on mobile the amount row walks half a pixel — tabular figures not landing. <a className="text-cyan cursor-pointer hover:underline">@orr</a> — this card:
              </Msg>
              <QuotePrior src="parsed invoice · LV-2026-00412" onOpen={() => openDrawer("parsed-invoice")}>
                <span className="font-mono text-2xs text-fg-mute">
                  .ledger-row .amt — inconsistent baseline ≤ 440px
                </span>
              </QuotePrior>
            </Turn>

            {/* 6 — Orr patches */}
            <Turn who="orr" when="14:35" hot={isHot(6)} threaded={isHot(6)} isChild={isHot(6)}>
              <Msg>read source, three-line patch. tests pass, merged to main.</Msg>
            </Turn>
            <Turn who="orr" when="" block>
              <div
                onMouseEnter={() => setHotLineage("code-fix")}
                onMouseLeave={() => setHotLineage(null)}
              >
                <Artifact
                  kind="code"
                  onOpen={() => openDrawer("code-fix")}
                  caption="commit be44e1a · main · ci green (18s)"
                  lineage={[
                    { label: "prompted by jonas' quote" },
                    { label: "renders invoice card", onClick: () => openDrawer("parsed-invoice") },
                  ]}
                >
                  <CodeBody
                    path="src/artifacts/invoice.tsx"
                    added={3}
                    deleted={2}
                    lines={[
                      { k: "ctx", a: "42", b: "42", src: `  <div <span class="text-violet">className</span>=<span class="text-peach">"ledger-row"</span>>` },
                      { k: "ctx", a: "43", b: "43", src: `    <span <span class="text-violet">className</span>=<span class="text-peach">"when"</span>>{<span class="text-cyan">row</span>.<span class="text-cyan">when</span>}</span>` },
                      { k: "del", a: "44", b: "",   src: `    <span <span class="text-violet">className</span>=<span class="text-peach">"amt"</span>>{<span class="text-cyan">row</span>.<span class="text-cyan">amt</span>}</span>` },
                      { k: "add", a: "",   b: "44", src: `    <span <span class="text-violet">className</span>=<span class="text-peach">"amt"</span> <span class="text-violet">style</span>={{` },
                      { k: "add", a: "",   b: "45", src: `      <span class="text-cyan">fontVariantNumeric</span>: <span class="text-peach">"tabular-nums"</span>,` },
                      { k: "add", a: "",   b: "46", src: `      <span class="text-cyan">fontFeatureSettings</span>: <span class="text-peach">'"tnum"'</span>` },
                      { k: "add", a: "",   b: "47", src: `    }}>{<span class="text-cyan">row</span>.<span class="text-cyan">amt</span>}</span>` },
                      { k: "ctx", a: "45", b: "48", src: `  </div>` },
                    ]}
                    review
                  />
                </Artifact>
              </div>
            </Turn>

            {/* 7 — Vale closes with a podcast */}
            <Turn who="vale" when="17:00" hot={isHot(7)} threaded={isHot(7)} isChild={isHot(7)}>
              <Msg>tuesday dispatch — six minutes, drawn from the day. transcript lives in the drawer.</Msg>
            </Turn>
            <Turn who="vale" when="" block>
              <div
                onMouseEnter={() => setHotLineage("podcast")}
                onMouseLeave={() => setHotLineage(null)}
              >
                <Artifact
                  kind="audio"
                  onOpen={() => openDrawer("podcast")}
                  lineage={[
                    { label: "draws from 34 sources in this room" },
                    { label: "cites invoice + tax fix", onClick: () => openDrawer("parsed-invoice") },
                  ]}
                >
                  <AudioBody
                    title="tuesday dispatch — tax, tabular figures, the Luna Press ratio"
                    duration="06:12"
                    bars={PODCAST_WAVE}
                    cur={podcastCur}
                    playing={podcastPlaying}
                    onTogglePlay={() => setPodcastPlaying(!podcastPlaying)}
                  />
                </Artifact>
              </div>
            </Turn>

            {/* 8 — Mira closes */}
            <Turn who="mira" when="17:04">
              <Msg>good day. shutting the laptop.</Msg>
            </Turn>

          </div>
        </div>

        <Composer />
      </main>

      <Drawer
        open={drawer.open}
        onClose={closeDrawer}
        artifact={drawer.key ? ARTIFACT_META[drawer.key] : null}
      />

      <TweaksPanel open={tweaksOpen} onClose={() => setTweaksOpen(false)} state={tweaks} setState={updateTweaks} />
    </div>
  );
}

ReactDOM.createRoot(document.getElementById("root")).render(<App />);
