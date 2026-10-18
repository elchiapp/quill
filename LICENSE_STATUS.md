# License status

Checked on 2026-10-18. The original `digimata/quill` repository now redirects
to [`humanitas-labs/quill`](https://github.com/humanitas-labs/quill).

Upstream now publishes an MIT license, copyright 2026 Humanitas Labs. The
verified upstream revision is `aad60f98e680720dd24a30115580f226ae36c12c` on
`master`; its LICENSE blob is `5e1a686a5701a26257d562c5b751b4bd1e76708c`.
An unmodified copy is retained in `Packaging/Licenses/Quill-MIT.txt` and must
travel with binary distributions. The previous July note that upstream had
no license is no longer current.

This packaging task does not choose a new public license for DropSift-specific
contributions. Do not describe the entire fork as MIT-licensed solely because
the upstream component is MIT-licensed.

Bundled dependencies retain their own terms. Packaging collects license and
NOTICE files from the exact Swift and npm dependencies, plus notices for the
prebuilt NeMo text-processing framework. The FFmpeg native dependency also
requires its upstream license, source and rebuild information; npm metadata
for the JavaScript wrapper alone is not a complete license inventory.

Model weights are not bundled with the app. Model download sources and model
licenses remain separate from the app's code licenses.

Before a public or commercial release, review the final binary, dependency
notices, source obligations, and the license for this fork's own work. This is
an engineering inventory, not legal advice or a legal clearance opinion.
