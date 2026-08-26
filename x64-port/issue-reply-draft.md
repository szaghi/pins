@JohannesWorks thank you, that was exactly the missing piece.

For anyone who finds this issue later, the short version: `NINA/External` now comes from a git repository instead of the Nextcloud zip.

```bash
git clone --depth 1 https://github.com/nitr57/pins.external.git
rsync -a pins.external/linux-x64/ <publish-dir>/External/linux-x64/
cp      pins.external/JPLEPH      <publish-dir>/External/JPLEPH
```

It uses Git LFS, so it has to be cloned rather than fetched file by file. Downloading through the API gives you 133-byte pointer files, which fail at load time in a way that looks like a corrupt library.

I checked every `.so` in `linux-x64` and they are all genuine ELF x86-64: ASI (camera, EAF focuser, EFW filter wheel), Nitecrawler, NOVAS, Oasis, SOFA, ToupTek, Wanderer. After copying them in, my x64 build loads them:

```
DllLoader: Loading bundled library: .../External/linux-x64/SOFA/libsofa_c.so
DllLoader: Loading bundled library: .../External/linux-x64/NOVAS/libnovas_c.so
DllLoader: Loading bundled library: .../External/linux-x64/ToupTek/libtoupcam.so
```

The `Ephemeris file not found` error goes away once `JPLEPH` is in place too. That resolves the crash I was hitting on `libsofa_c.so`.

Two notes that may be useful to others:

Before I found the repo I rebuilt SOFA and NOVAS from the sources already in this tree, and both compile cleanly for x86-64: SOFA from the 248 files in `SOFA/SOFA/src` (excluding the `t_sofa_c.c` test harness), NOVAS through its existing `NOVAS31/Makefile`. Useful as a fallback, though obviously it cannot produce the proprietary vendor SDKs.

Separately, gear driven through INDI does not need `External` at all. `NINA.INDI` has no `DllLoader` references and reaches hardware through `indiserver` over TCP, so the vendor SDK lives in the INDI driver process. I confirmed this with the simulators: with drivers loaded into the FIFO, PINS picked them up live.

```
INDIClient.CheckForNewDevice  Found Telescope Simulator INDI device (indi_simulator_telescope) v1.0
INDIClient.CheckForNewDevice  Found CCD Simulator INDI device (indi_simulator_ccd) v1.0
```

@nitr57, the workflow at `.github/workflows/build-pins-package.yml` still points at the old Nextcloud URL, which is what sends people down this path.

Thanks also to @acocalypso, whose `pinsx64` scripts are where the `pins.external` URL surfaced.
