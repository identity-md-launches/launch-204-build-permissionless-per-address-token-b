// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/// @title BucketModel
/// @notice A deliberately naive reference model of the token bucket, used only by the tests.
///
/// The model stores each bucket as a single quantity of "credit-seconds" `S` in the range
/// `[0, capacity * interval]`:
///   * a fresh bucket has `S = capacity * interval` (full),
///   * time advancing by `dt` adds `dt` to `S`, clamped at `capacity * interval`,
///   * `n` credits are available when `S / interval >= n`, and consuming them subtracts `n * interval`.
///
/// This representation is intentionally different from the contract's `deficit` / `refillAnchor`
/// pair, so agreement between the two on random call/time sequences is meaningful evidence that
/// the contract's timestamp accounting matches the specification.
contract BucketModel {
    uint256 public immutable capacity;
    uint256 public immutable interval;

    mapping(address => bool) private _seen;
    mapping(address => uint256) private _creditSeconds;
    mapping(address => uint256) private _lastSeen;

    constructor(uint256 capacity_, uint256 interval_) {
        capacity = capacity_;
        interval = interval_;
    }

    /// @notice Advance `account`'s bucket to time `t` (must not go backwards).
    function sync(address account, uint256 t) public {
        uint256 full = capacity * interval;
        if (!_seen[account]) {
            _seen[account] = true;
            _creditSeconds[account] = full;
        } else {
            uint256 s = _creditSeconds[account] + (t - _lastSeen[account]);
            _creditSeconds[account] = s > full ? full : s;
        }
        _lastSeen[account] = t;
    }

    /// @notice Whole credits available at time `t`.
    function available(address account, uint256 t) external returns (uint256) {
        sync(account, t);
        return _creditSeconds[account] / interval;
    }

    /// @notice Try to consume `n` credits at time `t`; returns whether it succeeded.
    function consume(address account, uint256 t, uint256 n) external returns (bool) {
        sync(account, t);
        if (n == 0 || n > capacity) return false;
        if (_creditSeconds[account] / interval < n) return false;
        _creditSeconds[account] -= n * interval;
        return true;
    }

    /// @notice Earliest time at which `n` credits are available (assuming `n <= capacity`).
    function availableAt(address account, uint256 t, uint256 n) external returns (uint256) {
        sync(account, t);
        uint256 s = _creditSeconds[account];
        if (s / interval >= n) return t;
        return t + (n * interval - s);
    }
}
