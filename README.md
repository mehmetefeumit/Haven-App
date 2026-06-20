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
after public reporting forced its hand. Even when alternatives guarantee that they do not sell location information or use it in ways the users are not aware of, their code is not open-source and therefore the claims not verifiable.

Haven believes that privacy is a fundamental human right. Your location data — where you work, meet loved ones, learn about
the world, and discover yourself — is yours, and no one should profit from it. If you want and need to share your location
with people you trust, no one should take advantage of it.

In a world of platforms looking for all of the data points they can learn of you, Haven is an open-source app with a single
motivation: providing the most private and permissionless way of sharing your location with the people you care about. It
will never require personal information, never sacrifice user privacy, and never exploit one of your most personal pieces of
information — your location.

**IMPORTANT:** Haven is still in active development. The following still needs to be done before it is ready for a 1.0 release: 
* **3rd party security audit (see AI Disclaimer below.)**
* Beta tests and incorporating user feedback.
* Allow better usage of existing Nostr keys (i.e. list of invitees from the following list), and signer support.
* Nostr-agnostic UI/UX improvements.

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

Currently, I have not decided whether Haven will be available on Play Store. 

### iOS

- **TestFlight** — Install TestFlight, and use the following link: https://testflight.apple.com/join/XMneaK7A

### Signing Certificate SHA-256
```
052bf0ccb366fc4741a4dcac52e82be1df7aa7c53e3b29125b6994cd3d90c4d5
```

## AI Disclaimer
Haven was written entirely using AI. It was initially a vibe-coding experiment to see how far this way of programming
could take me. I applied software development best practices which I know and use in my full-time job as a software developer,
but did so entirely through AI agents. This also includes asking AI to check for privacy or security risks in the code.

Since I have never seen Haven's code, I will never cut a 1.0 release until I get an official security audit from a 3rd party

Hence, until the official audit is in, please be aware that Haven has been entirely coded by AI, with me only steering it through prompts. For what it's worth, I prompted it A LOT for both implementing and validating Haven's privacy and security.

## License

MIT. See [`LICENSE`](LICENSE).

## References

- More on Nostr — https://nostr.org/
- Marmot Protocol specification — https://github.com/marmot-protocol/marmot
- Marmot Development Kit (Rust SDK) — https://github.com/parres-hq/mdk
