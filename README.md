# Haven

**Private and unstoppable location sharing.**

Haven is an end-to-end encrypted location sharing app that requires no personal information and uses no central server.
Your location is encrypted on your device before it leaves, and Haven runs no servers of its own, so there's simply no
data to sell, leak, or hand over. It is built on the decentralized Nostr network, and requires no phone numbers, emails,
or any personally identifiable information before you can start using it. Haven is open-source, so all of its privacy
guarantees are verifiable.

## Why use Haven?

Most technology companies we trust our most personal information with have not proven their interest in keeping our data
secure and private. Instead, our data is commodified: even entities which we do not directly interact with buy and sell it
to build a profile of who we are, where we go, and what we care about the most. This is not hypothetical — one of the most
popular family-location apps was
[found selling](https://thenextweb.com/news/family-safety-app-life360-selling-location-data-millions-users-syndication)
the [precise location data](https://www.phonearena.com/news/life360-sells-location-data_id136952) of millions of its users
to data brokers, and only [pledged to stop](https://themarkup.org/privacy/2022/01/27/life360-says-it-will-stop-selling-precise-location-data)
after public reporting forced its hand.

Haven believes that privacy is a fundamental human right. Your location data — where you work, meet loved ones, learn about
the world, and discover yourself — is yours, and no one should profit from it. If you want and need to share your location
with people you trust, no one should take advantage of it.

In a world of platforms looking for all of the data points they can learn of you, Haven is an open-source app with a single
motivation: providing the most private and permissionless way of sharing your location with the people you care about. It
will never require personal information, never sacrifice user privacy, and never exploit one of your most personal pieces of
information — your location.

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
052bf0ccb366fc4741a4dcac52e82be1df7aa7c53e3b29125b6994cd3d90c4d5
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

- Haven source code — https://github.com/mehmetefeumit/Haven-App
- More on Nostr — https://nostr.org/
- Marmot Protocol specification — https://github.com/marmot-protocol/marmot
- Marmot Development Kit (Rust SDK) — https://github.com/parres-hq/mdk
