# Stock E Ink update modes and selection

**Device:** PocketBook 626 Plus (U626), stock firmware 5.20.1157.  
**Evidence base:** static analysis of the supplied stock-system dump, including \`boot/default.wbf\`, \`rootfs/lib/modules/epdc.ko\`, \`ebrmain/cramfs.img\`, and the applications and libraries extracted from it.

This document describes the factory system only. The native Linux port's renderer and update policy are documented separately in [EINK.md](EINK.md).

## 1. Waveform data

The factory E Ink driver is \`rootfs/lib/modules/epdc.ko\` (Linux 3.0.8). It is loaded by \`rootfs/etc/init.d/rcS\` using:

\`\`\`sh
insmod /lib/modules/epdc.ko
\`\`\`

The driver contains the default path \`/boot/default.wbf\` and strings for waveform status and override interfaces (\`waveform_name\`, \`waveform_info\`, \`waveform_status\`, and \`waveform_override\`). The stock boot script does not explicitly pass a waveform parameter, so the driver uses its default.

The supplied dump contains the following:

- \`boot/default.wbf\` and \`boot/waveform.wbf\` are byte-for-byte identical.
- SHA-256 of both files: \`bc3e0338e3b537dfb69470727cae0bbba3e10aa62f82cc1a47fd7737447cc05f\`.
- The WBF contains the factory waveform table for the ED060XD4 panel: 14 temperature intervals and six modes — INIT, DU, GC16, GL16, A2, and DU4.

See [EINK.md](EINK.md#factory-waveform-14-temperatures--6-modes) for the decoded transition capabilities and scan counts at different temperatures.

### Do not confuse the WBF with \`rootfs/system/*.bin\`

The root filesystem also contains these files:

| File | Size |
|---|---:|
| \`a2.bin\` | 262,476 bytes |
| \`du.bin\` | 32,988 bytes |
| \`gc16.bin\` | 262,364 bytes |
| \`local.bin\` | 262,364 bytes |
| \`short_gc16.bin\` | 131,292 bytes |
| \`short_du.bin\` | 16,604 bytes |

The statically inspected references did not establish that the stock EPDC loads these files for normal screen updates. The driver points to a WBF file under \`/boot\`. Therefore, the filenames alone do not establish a direct mapping such as “\`gc16.bin\` is the waveform used by every \`PartialUpdate\` call”.

## 2. PocketBook launcher

\`monitor.app\` is the main process started during boot; the user-facing launcher is implemented separately in \`bookshelf.app\`. The latter contains \`pocketbook::desktop::UpdateController\`, which maps an internal update request type to an InkView API call.

| Launcher request type | InkView call | WBF mode |
|---:|---|---|
| 1 | \`PartialUpdateBW\` | DU |
| 2 | \`PartialUpdate\` | GC16 |
| 3 | \`FullUpdate\` | GC16 |
| 4 | \`DynamicUpdateA2\` | A2 (with a fallback path) |
| 5 | \`PartialUpdateBlack\` | GC16 |

The launcher call sites inspected in the binary contain requests of types **2 and 3**:

- Normal redraws of launcher elements, application icons, and the panel request partial GC16 updates.
- Scrolling launcher items also requests partial GC16 updates.
- Some transitions between states or views request a full GC16 update.

The main update mode used by the stock launcher during ordinary operation is therefore **GC16**, including for partial updates. DU and A2 are present in the launcher's update dispatcher, but their regular use was not found in the inspected launcher call sites.

## 3. Other applications

Static inspection of application binaries found the following references to InkView update APIs:

| Application | Update calls found | Corresponding modes |
|---|---|---|
| \`settings.app\` | \`PartialUpdateBW\`, \`PartialUpdate\` | DU, GC16 |
| \`eink-reader.app\` | \`DynamicUpdateBW\` | DU |
| \`picviewer.app\` | \`DynamicUpdateA2\`, \`ExitUpdateA2\`, \`PartialUpdate\`, \`FullUpdate\` | A2, GC16 |
| \`scribble.app\` | \`PartialUpdateBW\`, \`PartialUpdate\` | DU, GC16 |

These are observations from static binary analysis, not a runtime trace. The presence of a call shows that an application can request that update path; it does not establish how often it does so or all the conditions under which it is selected.

The boot animation resource \`hourglass.bin\` contains commands with \`waveform=1\` and \`waveform=4\`, corresponding to DU and A2. This is a separate animation-specific setting, not the launcher's general update policy.

## 4. Qt applications

Qt uses PocketBook's own platform backend, \`libqpocketbook2.so\`. Its \`EinkScreen\` class routes update types from \`doRedraw()\` and \`doManualRedraw()\` to InkView APIs.

The backend provides the following paths:

| Backend request | InkView call | Mode |
|---|---|---|
| Full update | \`FullUpdate\` | GC16 |
| Partial update | \`PartialUpdate\` | GC16 |
| BW partial / dynamic BW | \`PartialUpdateBW\` / \`DynamicUpdateBW\` | DU |
| HQ partial / soft HQ | HQ-related InkView variants | GL16, with a GC16 path |
| DU4 partial | \`PartialUpdateDU4\` | DU4 |
| Dynamic A2 | \`DynamicUpdateA2\` | A2 |

The backend also contains \`ExitUpdateA2\` and update-completion wait paths. This allows Qt applications to leave A2 and return to other update modes instead of remaining in one waveform mode permanently.

This table describes branches available in the backend's dispatcher. It does not mean that every Qt application uses every mode, or that every branch is reached during normal use.

## 5. Interpretation and limitations

1. **The update API and the waveform mode are different layers.** \`PartialUpdate\` and \`FullUpdate\` describe InkView requests; in the launcher, both map to GC16. The internal request-type numbers used by \`UpdateController\` and the Qt backend are not WBF mode indices.
2. **HQ is not the name of a separate WBF mode.** The driver also contains HQ/Shadow transition filtering. This should not be conflated with the GL16 waveform mode. See [EINK.md](EINK.md#optional-white-halo-filters-experimental) for the filter analysis.
3. **A mode can only perform transitions supported by the WBF at the current temperature.** Finding a DU, A2, or DU4 call does not mean that the mode can perform arbitrary grayscale transitions. For example, A2 is limited to 0↔15 transitions. See the [transition table in EINK.md](EINK.md#factory-waveform-14-temperatures--6-modes).
4. **This is a static analysis.** A complete account of runtime selection would require tracing calls on the device and observing the EPDC parameters while applications are running.

### Summary

The stock PocketBook 626 Plus launcher primarily redraws through **partial GC16**; some view or state transitions request **full GC16**. Other inspected applications use DU and GC16, while the image viewer also has an A2 path. The Qt backend exposes a wider set of paths, including DU, GL16, DU4, GC16, and A2. The factory waveform data is supplied through the WBF file; the available evidence does not support a direct one-to-one mapping from the names of the \`system/*.bin\` files to individual InkView update calls.
