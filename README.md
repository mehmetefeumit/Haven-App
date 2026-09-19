# Haven

**Private and censorship-resistant location sharing.**

Haven is an end-to-end encrypted location sharing app that requires no personal information at sign-up and uses no central server. 
Your location is encrypted on your device before it is sent to decentralized Nostr relays. It can only be decrypted by members of 
your location sharing circle after they fetch your latest location information from the relays. You can select the relays you
want to send location updates through, and/or run and use your own relays. Haven requires no phone numbers, emails, 
or any personally identifiable information before you can start using it.

## AI Disclaimer
Haven was written entirely using AI. It was initially a vibe-coding experiment to see how far this way of programming
could take me. I applied software development best practices which I know and use in my full-time job as a software developer,
but did so entirely through AI agents. This also includes asking AI to check for privacy or security risks in the code, and using
AI to create a testing suite that confirms the Haven's privacy features.

Since I have never seen Haven's code, I will never cut a 1.0 release until I get an official security audit from a 3rd party.

## Install (beta)

### Android

- **Direct APK** — download from the [Releases page](https://github.com/mehmetefeumit/Haven-App/releases).
  Most people want **`app-arm64-v8a-release.apk`**. `armeabi-v7a` is only for very old 32-bit devices; `x86_64`
  is only for emulators/ChromeOS.
- **Obtainium** — install
  [Obtainium](https://github.com/ImranR98/Obtainium), tap **Add App**, and paste:
  `https://github.com/mehmetefeumit/Haven-App`. It auto-selects the right APK for
  your device. To receive beta builds, enable **Include prereleases** for Haven.
- **Zapstore** — install [Zapstore](https://zapstore.dev) and
  search for Haven.

### iOS

- **TestFlight** — Install TestFlight, and use the following link: https://testflight.apple.com/join/XMneaK7A

### Signing Certificate SHA-256
```
com.oblivioustech.haven
05:2B:F0:CC:B3:66:FC:47:41:A4:DC:AC:52:E8:2B:E1:DF:7A:A7:C5:3E:3B:29:12:5B:69:94:CD:3D:90:C4:D5
```

## License

MIT. See [`LICENSE`](LICENSE).

## References

- More on Nostr — https://nostr.org/
- Marmot Protocol specification — https://github.com/marmot-protocol/marmot
- Marmot Development Kit (Rust SDK) — https://github.com/marmot-protocol/mdk
