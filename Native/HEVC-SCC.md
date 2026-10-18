# HEVC Screen Content Coding feasibility

The requested codec is the HEVC **Screen Content Coding extension (SCC)**,
not ordinary HEVC Main/Main10, HEVC Main Still Picture or an encoder's
screen-content quality preset. Those cannot be relabeled SCC.

On October 16, 2026, the connected Pixel 8 (Android API 37) was inspected with
`MediaCodecList.ALL_CODECS`, HEVC profile/level enumeration and
`MediaCodec.getSupportedVendorParameters()`:

| Encoder | Implementation | Advertised HEVC profiles |
| --- | --- | --- |
| `c2.exynos.hevc.encoder` | Hardware | Main, Main10, Main10 HDR10, Main10 HDR10+ |
| `c2.android.hevc.encoder` | Software | Main, MainStill |

Neither encoder advertises an SCC profile. The hardware encoder's exposed vendor
controls include high-quality mode, CU lossless coding, QP ranges, reference
frames and motion-vector controls, but no identified SCC selector. The software
encoder exposes no vendor parameters. Absence from these APIs establishes that
we have no supported SCC selection path; it does not prove that every private
firmware feature is impossible. A vendor quality control alone would not prove
that an emitted bitstream uses SCC.

Consequently, switching scrcpy's `video_codec` to `h265` would provide ordinary
HEVC, not fulfill the SCC request. The SCC investigation initially left production codec configuration unchanged.
Following the separate request for regular HEVC, companion 0.14 now uses HEVC Main
for hybrid Bluetooth/Wi-Fi video; this does not enable SCC. Direct ADB remains
controlled by its existing codec preference and input path. A strict SCC-only policy using the
currently exposed encoders would prevent this phone from starting a mirror.

This limitation applies to both Bluetooth and Wi-Fi: the phone encodes before
transport, and the handoff retains that stream. A separate Android software-SCC
encoder integration would be required unless another supported encoder becomes
available. Before enabling it, benchmark CPU cost, sustained fps, latency, thermal
behavior and quality at the existing Bluetooth bitrate, then verify actual SCC
bitstream syntax and Mac decoding. Mac SCC hardware decode has **not** been
established by this investigation. A normal HEVC decoder listing does not prove
SCC compatibility.

Reproduce the device inspection with JDK, Android SDK 36 and an authorized ADB
device (use `--serial` if more than one device is connected):

```sh
python3 tools/probe-hevc-scc.py
```

The probe compiles into a local temporary directory, pushes a uniquely named DEX
to `/data/local/tmp`, enumerates capabilities, briefly creates/releases each HEVC
encoder to list vendor parameters, and deletes the DEX afterward. It never
configures capture, encodes the screen, changes display power or installs an app.

References:

- [HEVC SCC extension and reference software](https://hevc.hhi.fraunhofer.de/scc)
- [Android HEVC profile constants](https://developer.android.com/reference/android/media/MediaCodecInfo.CodecProfileLevel)
- [Android vendor parameter enumeration](https://developer.android.com/reference/android/media/MediaCodec#getSupportedVendorParameters())
