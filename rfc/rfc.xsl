<?xml version="1.0" encoding="UTF-8"?>
<xsl:stylesheet version="1.0"
  xmlns:xsl="http://www.w3.org/1999/XSL/Transform"
  xmlns:rfc="https://froth.1.foo/rfc"
  exclude-result-prefixes="rfc">

  <xsl:output method="html" encoding="UTF-8" indent="yes"/>

  <!-- Root template -->
  <xsl:template match="/rfc:rfc">
    <html lang="en">
    <head>
      <meta charset="utf-8"/>
      <meta name="viewport" content="width=device-width, initial-scale=1"/>
      <title>RFC <xsl:value-of select="@number"/> — <xsl:value-of select="rfc:meta/rfc:title"/></title>
      <style>
        :root {
          --bg: #fff; --fg: #1a1a1a; --muted: #666; --border: #ddd;
          --link: #004080; --link-hover: #0066cc; --accent: #8b0000;
          --code-bg: #f5f5f5; --header-bg: #f8f8f8;
        }
        @media (prefers-color-scheme: dark) {
          :root {
            --bg: #1a1a1a; --fg: #e0e0e0; --muted: #999; --border: #333;
            --link: #6699cc; --link-hover: #88bbee; --accent: #cc6666;
            --code-bg: #2a2a2a; --header-bg: #222;
          }
        }
        * { margin: 0; padding: 0; box-sizing: border-box; }
        body {
          font-family: 'Iowan Old Style', 'Palatino Linotype', Palatino, Georgia, serif;
          background: var(--bg); color: var(--fg);
          line-height: 1.65; max-width: 42em; margin: 0 auto;
          padding: 2em 1.5em;
        }
        header {
          border-bottom: 2px solid var(--fg); margin-bottom: 2em; padding-bottom: 1em;
        }
        .header-line {
          display: flex; justify-content: space-between; align-items: baseline;
          font-size: 0.85em; color: var(--muted); margin-bottom: 0.5em;
        }
        .back { font-size: 0.85em; color: var(--muted); text-decoration: none; }
        .back:hover { color: var(--link-hover); }
        h1 { font-size: 1.4em; line-height: 1.3; margin: 0.5em 0; }
        h2 {
          font-size: 1.1em; margin: 2em 0 0.8em; padding-bottom: 0.3em;
          border-bottom: 1px solid var(--border);
        }
        p { margin: 0.8em 0; text-align: justify; hyphens: auto; }
        a { color: var(--link); }
        a:hover { color: var(--link-hover); }
        sup a { text-decoration: none; color: var(--accent); font-size: 0.75em; }
        pre {
          background: var(--code-bg); border: 1px solid var(--border);
          padding: 1em; overflow-x: auto; margin: 1em 0;
          font-size: 0.85em; line-height: 1.5;
        }
        code {
          font-family: 'JetBrains Mono', 'SF Mono', 'Fira Code', monospace;
          font-size: 0.9em;
        }
        pre code { font-size: inherit; }
        figure {
          margin: 1.5em 0; text-align: center;
        }
        figure img {
          max-width: 100%; height: auto;
          border: 1px solid var(--border); border-radius: 4px;
        }
        figcaption {
          font-size: 0.85em; color: var(--muted); margin-top: 0.5em;
          font-style: italic;
        }
        ol, ul { margin: 0.8em 0 0.8em 2em; }
        li { margin: 0.4em 0; }
        dl {
          display: grid; grid-template-columns: auto 1fr;
          gap: 0.3em 1.5em; font-size: 0.9em; margin: 1em 0;
        }
        dt { font-weight: bold; color: var(--muted); }
        dd { margin: 0; }
        .status { font-variant: small-caps; letter-spacing: 0.05em; }
        .references { font-size: 0.9em; }
        .references li { margin: 0.6em 0; word-break: break-all; }
        footer {
          margin-top: 3em; padding-top: 1em; border-top: 1px solid var(--border);
          font-size: 0.85em; color: var(--muted);
        }
        @media (max-width: 600px) {
          body { padding: 1em; }
          dl { grid-template-columns: 1fr; }
          dt { margin-top: 0.5em; }
        }
        @media print {
          body { max-width: none; font-size: 10pt; }
          a { color: inherit; text-decoration: underline; }
          pre { border: 1px solid #ccc; }
        }
      </style>
    </head>
    <body>
      <header>
        <div class="header-line">
          <span class="project">Froth Project</span>
          <span class="rfc-id">RFC <xsl:value-of select="@number"/></span>
        </div>
        <a href="/rfc" class="back">&#x2190; All RFCs</a>
        <h1><xsl:value-of select="rfc:meta/rfc:title"/></h1>
      </header>

      <main>
        <!-- Metadata -->
        <div class="rfc-meta">
          <dl>
            <dt>Status</dt><dd class="status"><xsl:value-of select="rfc:meta/rfc:status"/></dd>
            <dt>Author</dt><dd><xsl:value-of select="rfc:meta/rfc:author"/></dd>
            <dt>Date</dt><dd><xsl:value-of select="rfc:meta/rfc:date"/></dd>
            <xsl:if test="rfc:meta/rfc:supersedes">
              <dt>Supersedes</dt><dd><xsl:value-of select="rfc:meta/rfc:supersedes"/></dd>
            </xsl:if>
            <xsl:if test="rfc:meta/rfc:related">
              <dt>Related</dt><dd><xsl:value-of select="rfc:meta/rfc:related"/></dd>
            </xsl:if>
            <xsl:if test="rfc:meta/rfc:classification">
              <dt>Classification</dt><dd><xsl:value-of select="rfc:meta/rfc:classification"/></dd>
            </xsl:if>
            <xsl:if test="rfc:meta/rfc:research">
              <dt>Research</dt><dd><xsl:value-of select="rfc:meta/rfc:research"/></dd>
            </xsl:if>
          </dl>
        </div>

        <!-- Sections -->
        <xsl:apply-templates select="rfc:section"/>

        <!-- References -->
        <xsl:if test="rfc:references">
          <section id="references">
            <h2>References</h2>
            <ol class="references">
              <xsl:for-each select="rfc:references/rfc:ref">
                <li>
                  <xsl:attribute name="id">ref-<xsl:value-of select="@id"/></xsl:attribute>
                  <xsl:if test="@number">
                    [<xsl:value-of select="@number"/>]
                  </xsl:if>
                  <xsl:text> </xsl:text>
                  <xsl:value-of select="rfc:title"/>
                  <xsl:if test="rfc:url">
                    <xsl:text> </xsl:text>
                    <a>
                      <xsl:attribute name="href"><xsl:value-of select="rfc:url"/></xsl:attribute>
                      <xsl:value-of select="rfc:url"/>
                    </a>
                  </xsl:if>
                </li>
              </xsl:for-each>
            </ol>
          </section>
        </xsl:if>
      </main>

      <footer>
        <p>
          <a>
            <xsl:attribute name="href">/rfc/froth-rfc<xsl:value-of select="@number"/>.xml</xsl:attribute>
            XML source
          </a>
          &#xB7;
          <a href="/rfc">Index</a>
        </p>
      </footer>
    </body>
    </html>
  </xsl:template>

  <!-- Section -->
  <xsl:template match="rfc:section">
    <section>
      <xsl:attribute name="id"><xsl:value-of select="@id"/></xsl:attribute>
      <h2><xsl:value-of select="@title"/></h2>
      <xsl:apply-templates/>
    </section>
  </xsl:template>

  <!-- Subsection (h3) -->
  <xsl:template match="rfc:subsection">
    <section class="subsection">
      <xsl:attribute name="id"><xsl:value-of select="@id"/></xsl:attribute>
      <h3><xsl:value-of select="@title"/></h3>
      <xsl:apply-templates/>
    </section>
  </xsl:template>

  <!-- Paragraph -->
  <xsl:template match="rfc:p">
    <p><xsl:apply-templates/></p>
  </xsl:template>

  <!-- Code block -->
  <xsl:template match="rfc:code">
    <pre><code>
      <xsl:if test="@lang">
        <xsl:attribute name="class">language-<xsl:value-of select="@lang"/></xsl:attribute>
      </xsl:if>
      <xsl:value-of select="."/>
    </code></pre>
  </xsl:template>

  <!-- Figure -->
  <xsl:template match="rfc:figure">
    <figure>
      <img loading="lazy">
        <xsl:attribute name="src"><xsl:value-of select="@src"/></xsl:attribute>
        <xsl:attribute name="alt"><xsl:value-of select="@alt"/></xsl:attribute>
      </img>
      <xsl:if test="rfc:caption">
        <figcaption><xsl:apply-templates select="rfc:caption"/></figcaption>
      </xsl:if>
    </figure>
  </xsl:template>

  <!-- Lists -->
  <xsl:template match="rfc:list[@type='numbered']">
    <ol><xsl:apply-templates select="rfc:item"/></ol>
  </xsl:template>

  <xsl:template match="rfc:list[@type='lettered']">
    <ol type="a"><xsl:apply-templates select="rfc:item"/></ol>
  </xsl:template>

  <xsl:template match="rfc:list[@type='bullet']">
    <ul><xsl:apply-templates select="rfc:item"/></ul>
  </xsl:template>

  <xsl:template match="rfc:item">
    <li>
      <xsl:if test="rfc:label">
        <strong><xsl:value-of select="rfc:label"/>) </strong>
      </xsl:if>
      <xsl:apply-templates select="rfc:p"/>
    </li>
  </xsl:template>

  <!-- Inline: citation -->
  <xsl:template match="rfc:cite"><sup><a><xsl:attribute name="href">#ref-<xsl:value-of select="@ref"/></xsl:attribute>[<xsl:value-of select="@ref"/>]</a></sup></xsl:template>

  <!-- Inline: emphasis -->
  <xsl:template match="rfc:em">
    <em><xsl:apply-templates/></em>
  </xsl:template>

  <!-- Inline: strong -->
  <xsl:template match="rfc:strong">
    <strong><xsl:apply-templates/></strong>
  </xsl:template>

  <!-- Inline: code -->
  <xsl:template match="rfc:c">
    <code><xsl:apply-templates/></code>
  </xsl:template>

  <!-- Inline: link -->
  <xsl:template match="rfc:link">
    <a>
      <xsl:attribute name="href"><xsl:value-of select="@href"/></xsl:attribute>
      <xsl:apply-templates/>
    </a>
  </xsl:template>

  <!-- Inline: RFC cross-reference -->
  <xsl:template match="rfc:rfc-ref">
    <a>
      <xsl:attribute name="href">/rfc/<xsl:value-of select="@number"/></xsl:attribute>
      RFC-<xsl:value-of select="@number"/>
    </a>
  </xsl:template>

</xsl:stylesheet>
