# Next release: use the magrathean.uk/solutions URLs

Release trigger (1 October 2026). Before or as part of the **next release** of
anything built from this repository, replace the former product-site URLs and
support addresses below. The former domains currently 301 to the new pages, but
those redirects end when the domains lapse (most expire in May 2027). Delete
this file once every reference is updated and released.

| Former | Current |
| --- | --- |
| `https://auditex.hu/<path>` | `https://magrathean.uk/solutions/auditex/<path>` |
| `https://codexex.eu/<path>` | `https://magrathean.uk/solutions/codexex/<path>` |
| `https://nodexapp.eu/<path>` | `https://magrathean.uk/solutions/nodex/<path>` |
| `https://termexapp.eu/<path>` | `https://magrathean.uk/solutions/termex/<path>` |
| `https://teslacam.eu/<path>` | `https://magrathean.uk/solutions/tescam/<path>` |
| `https://teslatlas.eu/<path>` | `https://magrathean.uk/solutions/teslatlas/<path>` (old `/privacy/` and `/terms/` → `/app/privacy/`, `/app/terms/`; donate → `https://magrathean.uk/donate/?product=teslatlas`) |
| `https://magrathean.uk/apps/<slug>/` | `https://magrathean.uk/solutions/<slug>/` |
| Product support e-mail | `contact+<slug>@magrathean.uk` (`auditex`, `codexex`, `nodex`, `termex`, `tescam`, `teslatlas`); `contact+teslacam@` becomes `contact+tescam@` |

Also update the App Store Connect marketing, support and privacy URLs for each
app. Historical records (release-key files, changelogs, archived plans) may keep
their original URLs when the value is part of the record.

## References found in this repository

- `.github/SECURITY.md:39` — `This document describes repository policy, not a security audit or a guarantee about user-provided recordings, operating-system services, or`
- `.github/SUPPORT.md:3` — `For product help, use [Tescam's website](https://teslacam.eu/) or email [contact+teslacam@magrathean.uk](mailto:contact+teslacam@magrathean.`
- `.venv/lib/python3.14/site-packages/teslacam_cli-0.1.0.dist-info/METADATA:35` — `<a href="https://teslacam.eu/">Website</a> ·`
- `.venv/lib/python3.14/site-packages/teslacam_cli-0.1.0.dist-info/METADATA:37` — `<a href="https://teslacam.eu/privacy/">Privacy</a>`
- `README.md:10` — `<a href="https://teslacam.eu/">Website</a> ·`
- `README.md:12` — `<a href="https://teslacam.eu/privacy/">Privacy</a>`
- `docs/development/current-asc-platform-version.md:72` — `- Marketing: `https://teslacam.eu/``
- `docs/development/current-asc-platform-version.md:73` — `- Support: `https://teslacam.eu/#support``
- `docs/development/current-asc-platform-version.md:74` — `- Privacy policy: `https://teslacam.eu/privacy/``
- `docs/development/current-asc-platform-version.md:75` — `- Terms: `https://teslacam.eu/terms/``
- `teslacam_cli.egg-info/PKG-INFO:35` — `<a href="https://teslacam.eu/">Website</a> ·`
- `teslacam_cli.egg-info/PKG-INFO:37` — `<a href="https://teslacam.eu/privacy/">Privacy</a>`
