# RateLimiter — permissionless per-address token bucket

A standalone Foundry project containing `RateLimiter`, a per-address token-bucket rate limiter with
no owner, no pause switch and no admin path. Every address gets one bucket that starts full; calling
`consume(n)` spends `n` whole credits from the caller's own bucket and reverts when the bucket does
not hold that many.

Demo parameters (what the tests and the documented deployment use):

| Parameter | Value |
| --- | --- |
| capacity (whole credits, also the maximum per call) | 10 |
| refill | 1 credit every 60 seconds |
| initial state of every bucket | full (10 credits) |
| `consume(n)` accepted range | 1 ≤ n ≤ 10 |

## Layout

```
foundry.toml                     Foundry configuration (solc auto-detected to 0.8.24, no ffi, no fs access)
src/RateLimiter.sol              the contract
script/DeployRateLimiter.s.sol   reviewable deployment script (`run()` reads env, `deploy()` is tested directly)
test/RateLimiter.t.sol           unit, failure, fuzz and model-comparison tests
test/BucketModel.sol             naive "credit-seconds" reference model used by the randomised tests
lib/forge-std/                   forge-std v1.9.7 vendored as ordinary files (no submodule, no network needed)
DEPLOYMENT.md                    deployment parameters, procedure and record
```

## Exact behaviour

### State

Each address has a `Bucket {uint128 deficit; uint128 refillAnchor;}` in one storage slot.

* `deficit` is the number of credits missing from a full bucket. `available = capacity - deficit`.
  Untouched storage reads as `deficit == 0`, which is why every bucket is initially full without
  any registration step.
* `refillAnchor` is the timestamp-accounting anchor. It is meaningful only while `deficit > 0`.

### Timestamp accounting

All times are `block.timestamp` (seconds). The rules, in the order the contract applies them:

1. **Synchronise.** If `deficit == 0` nothing happens: a full bucket accrues no time at all.
   Otherwise `earned = (now - refillAnchor) / refillInterval` (integer division).
   * If `earned >= deficit` the bucket becomes full (`deficit = 0`) and any surplus time, whole or
     fractional, is discarded.
   * Else `deficit -= earned` and `refillAnchor += earned * refillInterval`. The anchor moves only
     by whole intervals, so the remainder `(now - refillAnchor) % refillInterval` is preserved as
     progress toward the next credit. After synchronisation `now - refillAnchor < refillInterval`
     always holds for a non-full bucket.
2. **Validate.** `consume(n)` reverts with `InvalidAmount(n, capacity)` unless `1 <= n <= capacity`.
   This check happens before any accounting, so an invalid amount never touches the bucket.
3. **Check credits.** If `available < n` the call reverts with
   `InsufficientCredits(n, available, availableAt)` where
   `availableAt = refillAnchor + (n - available) * refillInterval` is the earliest block timestamp
   at which `n` credits will be present if nothing else is consumed.
4. **Charge.** If the bucket was full before this call, `refillAnchor = now`: the refill clock starts
   the moment the bucket leaves the full state, and idle time before that is worth nothing. If the
   bucket was already below capacity the anchor is left untouched, so partial progress survives.
   Then `deficit += n` and `Consumed(msg.sender, n, available - n)` is emitted.

Consequences worth knowing:

* Ten calls of `consume(1)` within the first 60 seconds succeed; the eleventh reverts. The first
  credit returns exactly 60 seconds after the *first* call (the moment the bucket left the full
  state), not 60 seconds after the eleventh attempt.
* A bucket emptied at `T` holds exactly 2 credits at `T + 150` (credits at `T + 60` and `T + 120`),
  and consuming those 2 keeps the 30 seconds of progress: the next credit arrives at `T + 180`.
* A bucket that reaches capacity at `T + 60` and is left alone until `T + 90` has lost the extra
  30 seconds: consuming 1 credit at `T + 90` makes the next credit arrive at `T + 150`.
* A never-used or long-idle bucket holds exactly `capacity` credits, never more.
* All calls in one block see the same timestamp. Several calls from one address in one block are
  simply charged one after another against the same synchronised bucket.
* Only `msg.sender`'s bucket is ever read or written. A contract that forwards `consume` charges its
  own bucket, not its caller's.

### Interface

| Function | Purpose |
| --- | --- |
| `consume(uint256 n)` | Spend `n` credits from the caller's bucket. Reverts `InvalidAmount` / `InsufficientCredits`. |
| `available(address)` | Credits the address could consume right now. |
| `availableAt(address, uint256 n)` | Earliest timestamp at which `n` credits are available (`block.timestamp` if already). |
| `bucketOf(address)` | Synchronised view: `(credits, refillAnchor, nextCreditAt)`; the last two are `0` while full. |
| `rawBucket(address)` | Raw stored `(deficit, refillAnchor)` for auditing the accounting. |
| `capacity()`, `refillInterval()`, `MAX_PARAMETER()` | Immutable parameters and their upper bound (`2^64 - 1`). |

Constructor: `constructor(uint256 capacity, uint256 refillInterval)`, both in `1..MAX_PARAMETER`,
otherwise `InvalidCapacity` / `InvalidRefillInterval`. Bounding both at `2^64 - 1` keeps every
product in the contract below `2^128`, so the packed `uint128` fields and the `availableAt`
arithmetic cannot overflow. Demo deployment: `(10, 60)`.

## Tests

`test/RateLimiter.t.sol` (25 tests, all deterministic apart from fuzz inputs):

* **Construction and script**: parameters stored; zero and oversized parameters revert; the deploy
  script's documented demo config produces `(10, 60)`; `run()` refuses chain id 1.
* **Initial state and validation**: buckets start full with no anchor; `consume(0)` and any
  `consume(n > 10)` revert without touching the bucket; `availableAt` validates the same range.
* **Repeated calls within one minute**: ten single-credit calls spread over 45 s succeed, the
  eleventh fails at `T + 59` with `availableAt = T + 60`, succeeds at `T + 60`, and the anchor
  advances by exactly one interval. Also a burst of `consume(10)` followed by failures whose error
  data reports the correct retry time.
* **Long idle and saturation**: an empty bucket after a year holds exactly 10; a never-used bucket
  after 1000 days holds exactly 10; idle time while full buys nothing; reaching capacity discards
  fractional progress.
* **Partial refill**: two credits after 150 s, anchor at `T + 120`, fractional 30 s preserved across
  a consume, credit boundaries checked at `T + 179` / `T + 180`.
* **Independent callers**: one address draining its bucket leaves another untouched; anchors are
  tracked per address; a forwarding contract charges itself.
* **Overflow guard**: a block timestamp above `2^128 - 1` reverts with `TimestampOverflow`.
* **Randomised sequences versus a simple model**: `test/BucketModel.sol` represents each bucket as
  a single "credit-seconds" quantity clamped at `capacity * interval`, a deliberately different
  representation from the contract's `deficit` / anchor pair. Two fuzz tests replay 96 (demo
  parameters) and 64 (random capacity 1..25, interval 1..3600 s) steps of random caller, random
  delay (same block, sub-interval, multi-interval and long saturating idles) and random amount, and
  after every step compare the success/failure outcome, `available` for every actor and
  `availableAt` for a random probe amount. 256 fuzz runs each by default.

## Reproduction

Requires Foundry (developed and checked with forge 1.8.3) and solc 0.8.24 in the local svm cache.
No other dependency is fetched: forge-std is vendored in `lib/`.

```bash
forge build --offline
forge test --offline
forge fmt --check
forge test --offline -vvv --match-test testFuzz_matchesModel   # the model comparison only
forge script script/DeployRateLimiter.s.sol:DeployRateLimiter --offline  # local dry run, no broadcast
```

### Toolchain

Every source file pins `pragma solidity 0.8.24;`, so forge's version auto-detection compiles the
project with solc 0.8.24. The compiler version is intentionally not hard-pinned through the
`solc = "..."` key in `foundry.toml` (see the comment there): an exact pragma already guarantees
0.8.24 for this code, and not forcing it lets harness files with a different 0.8.x pin compile in
the same tree. The compiler is never pointed at an executable path.

Offline builds only work when the binary is already cached. With network access, one of

```bash
forge build                 # downloads solc 0.8.24 on first use
svm install 0.8.24          # if the svm CLI is installed
```

populates the cache (`~/.svm/0.8.24/` or `~/.local/share/svm/0.8.24/` depending on the forge
build). A previous attempt at this project failed for exactly this reason (`can't install missing
solc 0.8.24 in offline mode`), so the check above is worth running before an offline verification.

## Assumptions

* **Timestamps are monotonic.** `refillAnchor` is always set from a block timestamp no later than
  the current one. The chain guarantees non-decreasing timestamps, so `now - refillAnchor` cannot
  underflow. In a test that warps backwards past an anchor the call would revert (checked
  arithmetic); that is not a supported scenario.
* **Timestamps fit in 128 bits.** `block.timestamp` is `uint256` in the EVM but is below `2^64` on
  every real network. The contract still checks and reverts with `TimestampOverflow` rather than
  truncating.
* **Granularity is the block timestamp.** Validators can shift a block's timestamp by a few seconds
  within protocol limits; a credit may therefore appear a few seconds earlier or later than wall
  clock time. The limiter is not suitable where seconds of drift matter.
* **Per address, not per person.** Anyone can create unlimited addresses, each with its own full
  bucket. This contract limits the rate of a single address; it is not a Sybil defence or a global
  throttle.
* **Permissionless and immutable.** There is no owner, pause, upgrade or parameter change. To
  change parameters, deploy a new instance and point clients at it.
* **No value handling.** The contract holds no ETH or tokens and has no `receive` or `fallback`.

## Operational responsibilities

* Whoever deploys chooses `capacity` and `refillInterval` once; they cannot be changed afterwards.
  The documented demo values are `(10, 60)`.
* Integrators should read `availableAt(account, n)` (or the `InsufficientCredits` error data) to
  schedule retries instead of polling.
* Because the limiter is permissionless and per address, applications that need a per-user limit
  must bind users to addresses by other means.
* Tests passing is not a security audit. Anything that guards value with this contract should get an
  independent adversarial review before release.

## Incomplete checks and known gaps

* **No on-chain deployment was broadcast from this environment.** There is no funded Sepolia
  account or RPC credential available here, and the contributor rules forbid using a wallet key.
  `DEPLOYMENT.md` records the exact parameters, constructor arguments, the local dry run and the
  command an operator runs to complete the Sepolia deployment. The address, transaction hash and
  explorer link fields there are unfilled until that happens.
* The randomised comparison uses 256 fuzz runs of at most 96 steps with three actors and delays up
  to 55 intervals; multi-year gaps are covered by dedicated unit tests, not by the model fuzz.
* Backward-moving timestamps and timestamps above `2^128` are asserted to revert but are not
  reachable on a real chain, so their handling is defensive rather than specified behaviour.
* Gas is not benchmarked or asserted.
* This project deliberately contains no ERC-20: the task explicitly says not to create a token.
