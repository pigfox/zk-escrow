# Arbiter settlements — 2026-07

AI arbiter run settling the nine disputed escrows on the live Base Sepolia
deployment.

- **Contract (proxy):** `0x8bB2ae77AcE1424a9418f32bb2b2077563eE8A84`
- **Arbiter (keyed):** `0x6BBc782624B3c604e32Ed8b8C00d273970F67d0C`
- **Chain:** Base Sepolia (84532)
- **Model:** `gpt-5.4` (full tier), provider OpenAI
- **Date:** 2026-07-24

Each ruling was produced by the model from the on-chain `DisputeRaised` evidence,
then broadcast via `resolveDispute(uint256,uint8,string)` signed by the arbiter.
Every escrow was post-verified: `getState == Resolved(6)`, transaction status
success, and a `DisputeResolved` event carrying the rationale on-chain.

| Escrow | Ruling | Rationale (short) | Tx |
|--:|:--|:--|:--|
| 5 | BuyerWins | Only buyer evidence; no seller proof of fulfillment. HTML/script in submission treated as plain text. | [`0x38451efa`](https://sepolia.basescan.org/tx/0x38451efa09b6a31a1041e4a45da888163c97f3b7c9b8adc67874b9da359808e4) |
| 6 | BuyerWins | Only a buyer statement + generic seller reply; no seller proof of delivery. | [`0x5b58b802`](https://sepolia.basescan.org/tx/0x5b58b8022fdf78ac73cc2c470d298e7889db45467cd2c895451c7ae90946438b) |
| 8 | BuyerWins | Dispute filed; seller response gives no proof of delivery or completion. | [`0xe090d3fb`](https://sepolia.basescan.org/tx/0xe090d3fb206d1f87949d22f9b1c0b8398746b60cb7e0047aa22b5cc21f1f018f) |
| 10 | BuyerWins | Buyer filed; seller shows no proof of delivery, fulfillment, or compliance. | [`0xa7c33a2c`](https://sepolia.basescan.org/tx/0xa7c33a2c9d76723628b76caba3c61d28ecc459dc33e5b4b7154df0cad74a81e7) |
| 14 | BuyerWins | Only buyer evidence; no seller counter-proof. Embedded HTML/script not treated as substantive proof. | [`0x901857da`](https://sepolia.basescan.org/tx/0x901857da41f3b11f697056433ca1c944fd50591dfa672a7aaf28c143edc56e10) |
| 15 | BuyerWins | Buyer-filed; no seller evidence of performance. HTML/script not treated as proof. | [`0x2fbc3289`](https://sepolia.basescan.org/tx/0x2fbc32895e5a2ae06835be3abe9cb90dad6f92b0368b333c10732b29c37d954a) |
| 16 | BuyerWins | Buyer filed; seller response gives no proof of delivery or compliance. | [`0x08fd5670`](https://sepolia.basescan.org/tx/0x08fd5670fa0e6127bb77895f236cf9d30c3308f44f8e91ac960c63de3dc6eb78) |
| 20 | BuyerWins | Delivery window passed; tracking number not recognized by carrier; no seller shipment evidence. | [`0xe737f6c9`](https://sepolia.basescan.org/tx/0xe737f6c9363ddd71a46bc72ede7bb5b96ce4a1a59748be8f8cadb12bf0e4e7ba) |
| 22 | BuyerWins | Delivery window passed, no arrival, tracking unrecognized; seller claim unrebutted. | [`0xdc7cff0b`](https://sepolia.basescan.org/tx/0xdc7cff0b1d95f192113b274cad5fb02e0890e4ddf99bcbabebc2d43c35eb36b8) |

## Notes

- **All nine ruled BuyerWins.** The seeded demo disputes each carry only
  buyer-side evidence (a filed dispute, or a lapsed delivery window with an
  unrecognized tracking number) and no seller proof of fulfillment, so on the
  submitted record the buyer's claim is unrebutted in every case.
- **Prompt-injection robustness:** escrows 5, 14, and 15 included HTML/script
  content in the evidence; the arbiter explicitly treated it as plain text and
  did not let it affect the decision.
- **Model tier:** this run used the full `gpt-5.4` (not the nano tier), matching
  the house convention for consequential work — an on-chain ruling is not the
  place for the cheap tier.
