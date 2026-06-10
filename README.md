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

## AI Disclaimer
Haven was written entirely using AI. It was initially a vibe-coding experiment to see how far this way of programming
could take me. I applied software development best practices which I know and use in my full-time job as a software developer,
but did so entirely through AI agents. This also includes asking AI to check for privacy or security risks in the code.

Since I have never seen Haven's code, I will never cut a 1.0 release until I get an official security audit from a 3rd party.

**Use at your own risk.**

## License

MIT. See [`LICENSE`](LICENSE).

## References

- More on Nostr — https://nostr.com/
- Marmot Protocol specification — https://github.com/marmot-protocol/marmot
- Marmot Development Kit (Rust SDK) — https://github.com/parres-hq/mdk
