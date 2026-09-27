// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/// @title RateLimiter
/// @notice Permissionless per-address token-bucket rate limiter.
///
/// Every address owns one bucket of `capacity` whole credits that starts full. A bucket earns one
/// credit every `refillInterval` seconds while it is below capacity and never holds more than
/// `capacity`. `consume(amount)` spends `amount` credits from the caller's bucket and reverts when
/// the bucket does not hold that many. There is no owner, no pause, no allow-list and no way to
/// change the parameters after deployment.
///
/// Timestamp accounting (the exact rules the tests and README refer to):
///
/// * A bucket is stored as `deficit` (credits missing from a full bucket) and `refillAnchor`.
///   Untouched storage reads as `deficit == 0`, which is why every bucket is initially full.
/// * `refillAnchor` is only meaningful while `deficit > 0`. It is the timestamp at which the most
///   recent whole credit was accrued, or the timestamp at which the bucket left the full state,
///   whichever happened last. Refill progress at time `t` is `t - refillAnchor`; the next credit
///   accrues at `refillAnchor + refillInterval`.
/// * Synchronising a bucket at time `t` computes `earned = (t - refillAnchor) / refillInterval`.
///   If `earned < deficit`, `deficit -= earned` and `refillAnchor += earned * refillInterval`, so
///   the remainder `(t - refillAnchor) % refillInterval` is kept as progress toward the next credit.
///   If `earned >= deficit`, the bucket becomes full and any surplus time is discarded.
/// * While a bucket is full no time accrues at all. The first `consume` that takes it below
///   capacity sets `refillAnchor = block.timestamp`, so the refill clock starts at that moment.
/// * All calls within one block share `block.timestamp`; the granularity of the limiter is the
///   block timestamp, which validators can nudge by a few seconds.
contract RateLimiter {
    /// @dev Packed into one storage slot. `deficit <= capacity <= 2**64`, `refillAnchor` is a
    /// block timestamp; both are range-checked before being narrowed.
    struct Bucket {
        uint128 deficit;
        uint128 refillAnchor;
    }

    /// @notice Upper bound on `capacity` and `refillInterval`; keeps every product below 2**128.
    uint256 public constant MAX_PARAMETER = type(uint64).max;

    /// @notice Whole credits a bucket holds when full and the largest amount one call may consume.
    uint256 public immutable capacity;

    /// @notice Seconds needed to earn one credit while a bucket is below capacity.
    uint256 public immutable refillInterval;

    mapping(address account => Bucket bucket) private _buckets;

    /// @notice Emitted after every successful `consume`.
    /// @param account The caller whose bucket was charged.
    /// @param amount Credits removed.
    /// @param remaining Credits left in the bucket right after the call.
    event Consumed(address indexed account, uint256 amount, uint256 remaining);

    error InvalidCapacity(uint256 capacity);
    error InvalidRefillInterval(uint256 refillInterval);
    /// @notice `amount` must be in `1..capacity`.
    error InvalidAmount(uint256 amount, uint256 capacity);
    /// @notice The bucket holds `available` credits; `amount` credits are first available at `availableAt`.
    error InsufficientCredits(uint256 amount, uint256 available, uint256 availableAt);
    /// @notice `block.timestamp` does not fit the packed anchor (unreachable on real chains).
    error TimestampOverflow(uint256 timestamp);

    /// @param capacity_ Whole credits per bucket, `1..MAX_PARAMETER`. Demo deployment: 10.
    /// @param refillInterval_ Seconds per credit, `1..MAX_PARAMETER`. Demo deployment: 60.
    constructor(uint256 capacity_, uint256 refillInterval_) {
        if (capacity_ == 0 || capacity_ > MAX_PARAMETER) revert InvalidCapacity(capacity_);
        if (refillInterval_ == 0 || refillInterval_ > MAX_PARAMETER) revert InvalidRefillInterval(refillInterval_);
        capacity = capacity_;
        refillInterval = refillInterval_;
    }

    /// @notice Spend `amount` credits from the caller's bucket.
    /// @dev Only `msg.sender`'s bucket is read or written. Reverts with `InvalidAmount` when
    /// `amount` is outside `1..capacity` and with `InsufficientCredits` when the synchronised
    /// bucket holds fewer than `amount` credits.
    function consume(uint256 amount) external {
        if (amount == 0 || amount > capacity) revert InvalidAmount(amount, capacity);

        uint256 now_ = block.timestamp;
        Bucket memory bucket = _synced(_buckets[msg.sender], now_);
        uint256 credits = capacity - bucket.deficit;
        if (credits < amount) revert InsufficientCredits(amount, credits, _availableAt(bucket, now_, amount));

        if (bucket.deficit == 0) {
            // Leaving the full state: the refill clock starts now, previous idle time is discarded.
            bucket.refillAnchor = _toUint128(now_);
        }
        // amount <= capacity <= MAX_PARAMETER < 2**64, so the narrowing cannot truncate.
        // forge-lint: disable-next-line(unsafe-typecast)
        bucket.deficit += uint128(amount);
        _buckets[msg.sender] = bucket;

        emit Consumed(msg.sender, amount, credits - amount);
    }

    /// @notice Credits `account` could consume in a call made at the current block timestamp.
    function available(address account) external view returns (uint256) {
        return capacity - _synced(_buckets[account], block.timestamp).deficit;
    }

    /// @notice Earliest block timestamp at which `account` can consume `amount` credits.
    /// @dev Returns `block.timestamp` when the credits are already available. Reverts with
    /// `InvalidAmount` when `amount` is outside `1..capacity`.
    function availableAt(address account, uint256 amount) external view returns (uint256) {
        if (amount == 0 || amount > capacity) revert InvalidAmount(amount, capacity);
        return _availableAt(_synced(_buckets[account], block.timestamp), block.timestamp, amount);
    }

    /// @notice Synchronised accounting view of `account`'s bucket.
    /// @return credits Whole credits currently available.
    /// @return refillAnchor Timestamp accounting anchor; `0` while the bucket is full.
    /// @return nextCreditAt Timestamp of the next credit; `0` while the bucket is full.
    function bucketOf(address account)
        external
        view
        returns (uint256 credits, uint256 refillAnchor, uint256 nextCreditAt)
    {
        Bucket memory bucket = _synced(_buckets[account], block.timestamp);
        credits = capacity - bucket.deficit;
        if (bucket.deficit != 0) {
            refillAnchor = bucket.refillAnchor;
            nextCreditAt = refillAnchor + refillInterval;
        }
    }

    /// @notice Raw storage of `account`'s bucket, for auditing the accounting described above.
    function rawBucket(address account) external view returns (uint256 deficit, uint256 refillAnchor) {
        Bucket storage bucket = _buckets[account];
        return (bucket.deficit, bucket.refillAnchor);
    }

    /// @dev Applies the refill rules to a bucket for time `now_` without writing storage.
    function _synced(Bucket memory bucket, uint256 now_) private view returns (Bucket memory) {
        if (bucket.deficit == 0) return bucket; // Full: no time accrues.

        // `refillAnchor` was set from a block timestamp no later than `now_`; timestamps do not go
        // backwards, so this subtraction cannot underflow on a real chain.
        uint256 earned = (now_ - bucket.refillAnchor) / refillInterval;
        if (earned >= bucket.deficit) {
            bucket.deficit = 0;
            bucket.refillAnchor = 0;
        } else {
            // earned < deficit <= 2**64 and earned * refillInterval <= now_ - refillAnchor, so
            // neither narrowing can truncate. Rounding `earned` down before multiplying is the
            // specification: only whole intervals move the anchor, the remainder is kept as progress.
            // forge-lint: disable-next-line(unsafe-typecast)
            bucket.deficit -= uint128(earned);
            // forge-lint: disable-next-line(unsafe-typecast, divide-before-multiply)
            bucket.refillAnchor += uint128(earned * refillInterval);
        }
        return bucket;
    }

    /// @dev Earliest timestamp at which a synchronised bucket holds `amount` credits.
    function _availableAt(Bucket memory bucket, uint256 now_, uint256 amount) private view returns (uint256) {
        uint256 credits = capacity - bucket.deficit;
        if (credits >= amount) return now_;
        // Below capacity here, so `refillAnchor` is live and the k-th missing credit accrues at
        // `refillAnchor + k * refillInterval`.
        return bucket.refillAnchor + (amount - credits) * refillInterval;
    }

    function _toUint128(uint256 value) private pure returns (uint128) {
        if (value > type(uint128).max) revert TimestampOverflow(value);
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint128(value);
    }
}
