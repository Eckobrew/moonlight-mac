# Third-party software

MoonlightMac is distributed under GPLv3; see `LICENSE`. The following components
are vendored in this source tree and linked into the application:

| Component | Upstream | Included license |
| --- | --- | --- |
| moonlight-common-c | https://github.com/moonlight-stream/moonlight-common-c | Sources/MoonlightCommonC/LICENSE.txt (GPLv3 with upstream's OpenSSL exception) |
| ENet (GameStream fork) | https://github.com/cgutman/enet | Sources/MoonlightCommonC/enet/LICENSE (MIT) |
| nanors, including its bundled obl code | https://github.com/sleepybishop/nanors | Sources/MoonlightCommonC/nanors/LICENSE (MIT) |
| Opus | https://opus-codec.org/ | Sources/Copus/COPYING (BSD-style; see the included text and source headers) |

moonlight-qt (https://github.com/moonlight-stream/moonlight-qt, GPLv3) is an
architecture and protocol reference for this implementation. Native keyboard
protocol fixes and certificate-pairing checks were checked against its upstream
implementation. Existing copyright and license notices in bundled files remain
applicable.

Upstream licenses were restored on 22 October 2026. This checkout did not record
exact imported revisions for moonlight-common-c, ENet or nanors; no revision is
claimed here. Future dependency updates should record immutable upstream commits
and retain local patches. Opus carries its upstream version/release metadata in
Sources/Copus.

The packaging script includes these notices and all listed license texts in
Contents/Resources/Licenses. When distributing a binary, provide its matching
source revision and build instructions as well.

The optional experimental renderer uses
[libplacebo](https://github.com/haasn/libplacebo) (LGPL 2.1 or later) and
[MoltenVK](https://github.com/KhronosGroup/MoltenVK) (Apache 2.0). Enabled app
packages embed these dylibs and their non-system linked dependencies. The
packager requires license/notice files for every embedded library and includes
them under `Contents/Resources/Licenses/Vulkan`; the exact runtime inventory is
recorded in `Contents/Resources/vulkan-runtime.json`. Unbundled development
executables use an external Vulkan loader. See [renderer build notes](Docs/LIBPLACEBO_VULKAN.md).
