---
title: pollmd
layout: hextra-home
toc: false
---

<div class="hx-mt-6 hx-mb-6">
{{< hextra/hero-headline >}}
  Minimal newsletter polls&nbsp;<br class="sm:hx-block hx-hidden" />in Markdown
{{< /hextra/hero-headline >}}
</div>
<br>
<div class="hx-mb-12">
{{< hextra/hero-subtitle >}}
  A ~200-line Go service that records anonymous poll &nbsp;<br class="sm:hx-block hx-hidden" />into a single DuckDB file, querying with Quack Protocol.
{{< /hextra/hero-subtitle >}}
</div>
<br>
<div class="hx-mb-6">
{{< hextra/hero-button text="Overview and Philosophy" link="docs" >}}
</div>
<br>
<div class="hx-mt-6"></div>

<br>
<div class="hx-mt-12 hx-mb-8">
<h2 class="hx-text-4xl hx-font-bold hx-tracking-tight hx-text-gray-900 dark:hx-text-gray-50">What Makes pollmd Different?</h2>
</div>

{{< hextra/feature-grid >}}
  {{< hextra/feature-card
    title="Markdown-native links"
    subtitle="Just paste `[Awesome](https://q.ssp.sh/2026-06-04/awesome)` into your newsletter. One click records one vote. No embeds, no iframes, no JavaScript."
    class="aspect-auto md:aspect-[1.1/1] max-md:min-h-[340px]"
    style="background: radial-gradient(ellipse at 50% 80%,rgba(255,93,98,0.15),hsla(0,0%,100%,0));"
  >}}
  {{< hextra/feature-card
    title="No cookies, no JS"
    subtitle="No fingerprinting. IP, User-Agent, and a daily salt are hashed and immediately discarded. The salt rotates every midnight UTC, so yesterday's hashes can't be reproduced."
    class="aspect-auto md:aspect-[1.1/1] max-lg:min-h-[340px]"
    style="background: radial-gradient(ellipse at 50% 80%,rgba(49,80,170,0.15),hsla(0,0%,100%,0));"
  >}}
  {{< hextra/feature-card
    title="One binary, one file"
    subtitle="~200 lines of Go, one DuckDB file. No external database, no Redis, no JS bundle. Read the whole source in an afternoon."
    class="aspect-auto md:aspect-[1.1/1] max-md:min-h-[340px]"
    style="background: radial-gradient(ellipse at 50% 80%,rgba(210,126,153,0.15),hsla(0,0%,100%,0));"
  >}}
  {{< hextra/feature-card
    title="Per-newsletter flexibility"
    subtitle="Invent any answer slug per issue — `awesome`, `meh`, `keep`, `unsubscribe`. Or lock the allowed set per survey with `make survey-create`."
    class="aspect-auto md:aspect-[1.1/1] max-md:min-h-[340px]"
    style="background: radial-gradient(ellipse at 50% 80%,rgba(101,133,148,0.15),hsla(0,0%,100%,0));"
  >}}
  {{< hextra/feature-card
    title="SQL from your laptop"
    subtitle="DuckDB + Quack gives you `make survey-result` for a bar-chart tally, or drop into a `duckdb` prompt and run arbitrary SQL against the live file."
    class="aspect-auto md:aspect-[1.1/1] max-lg:min-h-[340px]"
    style="background: radial-gradient(ellipse at 50% 80%,rgba(228,104,118,0.15),hsla(0,0%,100%,0));"
  >}}
  {{< hextra/feature-card
    title="Self-host anywhere"
    subtitle="Railway, Linux (EC2/Hetzner/anywhere), or FreeBSD — each platform has a guide. Vote endpoint and Quack admin channel share one Go process."
    class="aspect-auto md:aspect-[1.1/1] max-md:min-h-[340px]"
    style="background: radial-gradient(ellipse at 50% 80%,rgba(20,16,33,0.15),hsla(0,0%,100%,0));"
  >}}
{{< /hextra/feature-grid >}}

<br>

![pollmd result page](/images/landing-page-poll.png)
_Rendered poll, but you can also just use Markdown links_

<br>

<div class="hx-mt-12 hx-mb-8">
<h2 class="hx-text-4xl hx-font-bold hx-tracking-tight hx-text-gray-900 dark:hx-text-gray-50">Documentation:</h2>
</div>

{{< cards cols="3" >}}
  {{< card link="docs" title="Overview" subtitle="What pollmd is, why it exists, and the philosophy behind it." >}}
  {{< card link="docs/install" title="Install" subtitle="Railway, Linux/EC2/Hetzner, or FreeBSD — pick a deploy target." >}}
  {{< card link="docs/usage" title="Usage" subtitle="Writing the markdown links, locking answers per newsletter." >}}
  {{< card link="docs/architecture" title="Architecture" subtitle="How HTTP, DuckDB, and the Quack channel fit into one Go process." >}}
  {{< card link="docs/querying" title="Querying" subtitle="`make survey-result`, ad-hoc SQL, the Quack workaround." >}}
  {{< card link="docs/privacy" title="Privacy" subtitle="How the voter hash and the daily salt rotation work." >}}
{{< /cards >}}


<br>

<div class="hx-mb-6">
{{< hextra/hero-button text="Getting Started: Install" link="docs/install" >}}
</div>
<br>


<div class="hx-mt-12 hx-mb-8">
<h2 class="hx-text-4xl hx-font-bold hx-tracking-tight hx-text-gray-900 dark:hx-text-gray-50">Links:</h2>
</div>

- [GitHub Repository](https://github.com/sspaeti/pollmd)
- [Changelog](https://github.com/sspaeti/pollmd/blob/main/CHANGELOG.md)
- [Initial AI design spec](https://github.com/sspaeti/pollmd/blob/main/docs/prompts/initial/2026-06-04-newsletter-survey-design.md)
