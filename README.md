# SonyControl

Menu-bar app to switch Noise Cancelling / Ambient Sound / Off on a Sony WF-1000XM5 from a Mac,
with ambient level, voice focus and battery. Protocol from [Gadgetbridge](https://codeberg.org/Freeyourgadget/Gadgetbridge).

    ./build.sh && open build/SonyControl.app

Copy `build/SonyControl.app` to `/Applications` before ticking "Launch at login".

`probe/` is a debug CLI that sends raw payloads, e.g. `./probe/sonyprobe 66:17` reads the ambient state.
