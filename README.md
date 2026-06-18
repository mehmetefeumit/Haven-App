# Haven

**Private and unstoppable location sharing.**

Haven is a privacy-first location sharing application. Location data which is encrypted on the device is sent to a
decentralized and customizable collection of relays which run the Nostr protocol. It is (from what I can tell) the only
location sharing application on the market which can **prove** that it encrypts and handles the location of its users securely
and does not sell any personal information to 3rd parties.

**IMPORTANT:** Haven is still in active development. The following still needs to be done before it is ready for a 1.0 release: 
* Beta tests and incorporating user feedback.
* **3rd party security audit.**
* Improvements in the CI and testing.
* Clearer documentation (i.e. threat model, what different entities like tile providers and relays can see (if anything)).

## Install (beta)

Haven is in beta. Pick whichever channel you trust most — they all ship the
**same app signed with the same key**, so you can move between the direct
channels and still get updates.

### Android

- **Direct APK** — download from the [Releases page](https://github.com/mehmetefeumit/Haven-App/releases).
  Most people want **`app-arm64-v8a-release.apk`** (virtually every phone from the
  last several years). `armeabi-v7a` is only for very old 32-bit devices; `x86_64`
  is only for emulators/ChromeOS. Then open the file to install (Android will ask
  you to allow installs from your browser/file manager the first time).
- **Obtainium** (recommended — auto-updates) — install
  [Obtainium](https://github.com/ImranR98/Obtainium), tap **Add App**, and paste:
  `https://github.com/mehmetefeumit/Haven-App`. It auto-selects the right APK for
  your device. To receive beta builds, enable **Include prereleases** for Haven.
- **Zapstore** (Nostr-native) — install [Zapstore](https://zapstore.dev) and
  search for Haven.

### iOS

- **TestFlight** — planned for the beta period (invite link to follow).

### Verify before you install

Integrity (did the file download intact?):

```bash
sha256sum -c app-arm64-v8a-release.apk.sha256
```

Authenticity (is it really signed by Haven's key, not an impostor?) — compare the
signing certificate against the fingerprint below, e.g. with
[AppVerifier](https://github.com/soupslurpr/AppVerifier) on-device, or:

```bash
apksigner verify --print-certs app-arm64-v8a-release.apk   # look for the SHA-256 digest
```

Haven release signing certificate SHA-256:

```
<published after the first release-signed build — see haven/DEVELOPMENT.md>
```

> **One key across every channel.** The direct APK, Obtainium, and Zapstore all
> ship the exact same APK signed with the same key, so updates flow seamlessly
> between them. Installing a build signed by a *different* key would require
> uninstalling first — and **uninstalling deletes your local encrypted data**
> (your identity, circles, and contacts). Stick to one of these channels.

## AI Disclaimer
Haven was written entirely using AI. It was initially a vibe-coding experiment to see how far this way of programming
could take me. I applied software development best practices which I know and use in my full-time job as a software developer,
but did so entirely through AI agents. This also includes asking AI to check for privacy or security risks in the code.

Since I have never seen Haven's code, I will never cut a 1.0 release until I get an official security audit from a 3rd party

Hence, until the official audit is in, please be aware that Haven has been entirely coded by AI, with me only steering it through prompts. For what it's worth, I prompted it A LOT for both implementing and validating Haven's privacy and security.

## License

MIT. See [`LICENSE`](LICENSE).

## References

- More on Nostr — https://nostr.com/
- Marmot Protocol specification — https://github.com/marmot-protocol/marmot
- Marmot Development Kit (Rust SDK) — https://github.com/parres-hq/mdk
