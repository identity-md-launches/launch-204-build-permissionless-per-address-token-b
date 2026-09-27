// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {RateLimiter} from "../src/RateLimiter.sol";
import {DeployRateLimiter} from "../script/DeployRateLimiter.s.sol";
import {BucketModel} from "./BucketModel.sol";

contract RateLimiterTest is Test {
    uint256 internal constant CAPACITY = 10;
    uint256 internal constant INTERVAL = 60;
    uint256 internal constant T0 = 1_700_000_000;

    RateLimiter internal limiter;
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    event Consumed(address indexed account, uint256 amount, uint256 remaining);

    function setUp() public {
        vm.warp(T0);
        limiter = new RateLimiter(CAPACITY, INTERVAL);
    }

    // ---------------------------------------------------------------------------------------------
    // Construction
    // ---------------------------------------------------------------------------------------------

    function test_constructorStoresParameters() public view {
        assertEq(limiter.capacity(), CAPACITY);
        assertEq(limiter.refillInterval(), INTERVAL);
        assertEq(limiter.MAX_PARAMETER(), type(uint64).max);
    }

    function test_constructorRejectsZeroCapacity() public {
        vm.expectRevert(abi.encodeWithSelector(RateLimiter.InvalidCapacity.selector, 0));
        new RateLimiter(0, INTERVAL);
    }

    function test_constructorRejectsZeroInterval() public {
        vm.expectRevert(abi.encodeWithSelector(RateLimiter.InvalidRefillInterval.selector, 0));
        new RateLimiter(CAPACITY, 0);
    }

    function testFuzz_constructorRejectsOversizedParameters(uint256 oversized) public {
        oversized = bound(oversized, uint256(type(uint64).max) + 1, type(uint256).max);
        vm.expectRevert(abi.encodeWithSelector(RateLimiter.InvalidCapacity.selector, oversized));
        new RateLimiter(oversized, INTERVAL);
        vm.expectRevert(abi.encodeWithSelector(RateLimiter.InvalidRefillInterval.selector, oversized));
        new RateLimiter(CAPACITY, oversized);
    }

    function test_deployScriptUsesDocumentedDemoParameters() public {
        DeployRateLimiter deployer = new DeployRateLimiter();
        DeployRateLimiter.Config memory config = deployer.demoConfig();
        assertEq(config.capacity, 10);
        assertEq(config.refillInterval, 60);
        RateLimiter deployed = deployer.deploy(config);
        assertEq(deployed.capacity(), 10);
        assertEq(deployed.refillInterval(), 60);
        assertEq(deployed.available(alice), 10);
    }

    function test_deployScriptRefusesMainnet() public {
        DeployRateLimiter deployer = new DeployRateLimiter();
        vm.chainId(1);
        vm.expectRevert(bytes("DeployRateLimiter: mainnet deployment is not authorised"));
        deployer.run();
    }

    // ---------------------------------------------------------------------------------------------
    // Initial state and argument validation
    // ---------------------------------------------------------------------------------------------

    function test_bucketStartsFull() public view {
        assertEq(limiter.available(alice), CAPACITY);
        (uint256 credits, uint256 anchor, uint256 nextCreditAt) = limiter.bucketOf(alice);
        assertEq(credits, CAPACITY);
        assertEq(anchor, 0, "no anchor while full");
        assertEq(nextCreditAt, 0, "no refill in progress while full");
        (uint256 deficit, uint256 rawAnchor) = limiter.rawBucket(alice);
        assertEq(deficit, 0);
        assertEq(rawAnchor, 0);
        assertEq(limiter.availableAt(alice, CAPACITY), T0, "a full bucket can serve capacity now");
    }

    function test_consumeRejectsZero() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(RateLimiter.InvalidAmount.selector, 0, CAPACITY));
        limiter.consume(0);
    }

    function testFuzz_consumeRejectsAmountsAboveCapacity(uint256 amount) public {
        amount = bound(amount, CAPACITY + 1, type(uint256).max);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(RateLimiter.InvalidAmount.selector, amount, CAPACITY));
        limiter.consume(amount);
        assertEq(limiter.available(alice), CAPACITY, "a rejected call must not charge the bucket");
    }

    function test_availableAtRejectsInvalidAmounts() public {
        vm.expectRevert(abi.encodeWithSelector(RateLimiter.InvalidAmount.selector, 0, CAPACITY));
        limiter.availableAt(alice, 0);
        vm.expectRevert(abi.encodeWithSelector(RateLimiter.InvalidAmount.selector, CAPACITY + 1, CAPACITY));
        limiter.availableAt(alice, CAPACITY + 1);
    }

    function testFuzz_consumeAnyValidAmountFromFullBucket(uint256 amount) public {
        amount = bound(amount, 1, CAPACITY);
        vm.expectEmit(true, true, true, true, address(limiter));
        emit Consumed(alice, amount, CAPACITY - amount);
        vm.prank(alice);
        limiter.consume(amount);

        assertEq(limiter.available(alice), CAPACITY - amount);
        (uint256 deficit, uint256 anchor) = limiter.rawBucket(alice);
        assertEq(deficit, amount);
        assertEq(anchor, T0, "leaving the full state anchors the refill clock at the call time");
    }

    // ---------------------------------------------------------------------------------------------
    // Repeated calls within one minute
    // ---------------------------------------------------------------------------------------------

    function test_tenSingleCreditCallsWithinOneMinuteThenExhausted() public {
        for (uint256 i = 0; i < CAPACITY; ++i) {
            vm.warp(T0 + i * 5); // ten calls spread over 45 seconds, all inside the first minute
            vm.prank(alice);
            limiter.consume(1);
            assertEq(limiter.available(alice), CAPACITY - i - 1);
        }
        (uint256 deficit, uint256 anchor) = limiter.rawBucket(alice);
        assertEq(deficit, CAPACITY);
        assertEq(anchor, T0, "later calls below capacity do not move the anchor");

        // The 11th call inside the minute fails and reports when one credit arrives.
        vm.warp(T0 + 59);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(RateLimiter.InsufficientCredits.selector, 1, 0, T0 + INTERVAL));
        limiter.consume(1);

        // Exactly one interval after the bucket left the full state, one credit is back.
        vm.warp(T0 + INTERVAL);
        assertEq(limiter.available(alice), 1);
        vm.prank(alice);
        limiter.consume(1);
        assertEq(limiter.available(alice), 0);
        (deficit, anchor) = limiter.rawBucket(alice);
        assertEq(deficit, CAPACITY);
        assertEq(anchor, T0 + INTERVAL, "the anchor advanced by exactly one whole interval");

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(RateLimiter.InsufficientCredits.selector, 1, 0, T0 + 2 * INTERVAL));
        limiter.consume(1);
    }

    function test_burstOfCapacityThenAnyFurtherCallFails() public {
        vm.prank(alice);
        limiter.consume(CAPACITY);
        assertEq(limiter.available(alice), 0);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(RateLimiter.InsufficientCredits.selector, 1, 0, T0 + INTERVAL));
        limiter.consume(1);

        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(RateLimiter.InsufficientCredits.selector, CAPACITY, 0, T0 + CAPACITY * INTERVAL)
        );
        limiter.consume(CAPACITY);
    }

    function test_requestingMoreThanAvailableReportsTheRightRetryTime() public {
        vm.prank(alice);
        limiter.consume(7); // 3 left, anchor T0
        vm.warp(T0 + 100); // one credit earned at T0 + 60 -> 4 left, 40 s of progress
        assertEq(limiter.available(alice), 4);
        assertEq(limiter.availableAt(alice, 4), T0 + 100);
        assertEq(limiter.availableAt(alice, 5), T0 + 120);
        assertEq(limiter.availableAt(alice, 10), T0 + 60 + 6 * INTERVAL);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(RateLimiter.InsufficientCredits.selector, 6, 4, T0 + 180));
        limiter.consume(6);
    }

    // ---------------------------------------------------------------------------------------------
    // Long idle periods and saturation
    // ---------------------------------------------------------------------------------------------

    function test_longIdleRefillsToCapacityAndNoMore() public {
        vm.prank(alice);
        limiter.consume(CAPACITY);
        vm.warp(T0 + 365 days);
        assertEq(limiter.available(alice), CAPACITY);
        (uint256 credits, uint256 anchor, uint256 nextCreditAt) = limiter.bucketOf(alice);
        assertEq(credits, CAPACITY);
        assertEq(anchor, 0);
        assertEq(nextCreditAt, 0);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(RateLimiter.InvalidAmount.selector, CAPACITY + 1, CAPACITY));
        limiter.consume(CAPACITY + 1);

        vm.prank(alice);
        limiter.consume(CAPACITY);
        (uint256 deficit, uint256 rawAnchor) = limiter.rawBucket(alice);
        assertEq(deficit, CAPACITY);
        assertEq(rawAnchor, T0 + 365 days, "the refill clock restarts when the bucket leaves the full state");
    }

    function test_saturatedBucketDiscardsIdleTime() public {
        // Never touched, idle for a very long time: still exactly capacity, no stored progress.
        vm.warp(T0 + 1000 days + 37);
        assertEq(limiter.available(alice), CAPACITY);

        uint256 t = vm.getBlockTimestamp();
        vm.prank(alice);
        limiter.consume(1);
        (, uint256 anchor, uint256 nextCreditAt) = limiter.bucketOf(alice);
        assertEq(anchor, t);
        assertEq(nextCreditAt, t + INTERVAL);

        // Idle time before the call bought nothing: the credit is back only a full interval later.
        vm.warp(t + INTERVAL - 1);
        assertEq(limiter.available(alice), CAPACITY - 1);
        vm.warp(t + INTERVAL);
        assertEq(limiter.available(alice), CAPACITY);
    }

    function test_reachingCapacityDiscardsFractionalProgress() public {
        vm.prank(alice);
        limiter.consume(1); // 9 left, anchor T0
        vm.warp(T0 + 90); // credit back at T0 + 60, 30 s of surplus progress that must be dropped
        assertEq(limiter.available(alice), CAPACITY);

        vm.prank(alice);
        limiter.consume(1);
        (, uint256 anchor, uint256 nextCreditAt) = limiter.bucketOf(alice);
        assertEq(anchor, T0 + 90, "surplus time while full is discarded");
        assertEq(nextCreditAt, T0 + 150);
        vm.warp(T0 + 149);
        assertEq(limiter.available(alice), CAPACITY - 1);
        vm.warp(T0 + 150);
        assertEq(limiter.available(alice), CAPACITY);
    }

    // ---------------------------------------------------------------------------------------------
    // Partial refill and fractional time
    // ---------------------------------------------------------------------------------------------

    function test_partialRefillPreservesFractionalProgress() public {
        vm.prank(alice);
        limiter.consume(CAPACITY); // empty, anchor T0
        vm.warp(T0 + 150); // 2 credits earned (T0+60, T0+120), 30 s toward the third
        assertEq(limiter.available(alice), 2);
        (uint256 credits, uint256 anchor, uint256 nextCreditAt) = limiter.bucketOf(alice);
        assertEq(credits, 2);
        assertEq(anchor, T0 + 120, "anchor advances only by whole intervals");
        assertEq(nextCreditAt, T0 + 180);

        // Consuming below capacity keeps the 30 s of progress.
        vm.prank(alice);
        limiter.consume(2);
        (uint256 deficit, uint256 rawAnchor) = limiter.rawBucket(alice);
        assertEq(deficit, CAPACITY);
        assertEq(rawAnchor, T0 + 120);

        vm.warp(T0 + 179);
        assertEq(limiter.available(alice), 0);
        vm.warp(T0 + 180);
        assertEq(limiter.available(alice), 1);
        assertEq(limiter.availableAt(alice, 3), T0 + 300);
    }

    function test_consumingBelowCapacityDoesNotResetTheClock() public {
        vm.prank(alice);
        limiter.consume(3); // anchor T0
        vm.warp(T0 + 45);
        vm.prank(alice);
        limiter.consume(2);
        (uint256 deficit, uint256 anchor) = limiter.rawBucket(alice);
        assertEq(deficit, 5);
        assertEq(anchor, T0, "a call while below capacity keeps the existing anchor");
        vm.warp(T0 + 60);
        assertEq(limiter.available(alice), 6);
    }

    function test_sameBlockCallsShareOneTimestamp() public {
        vm.prank(alice);
        limiter.consume(CAPACITY);
        vm.warp(T0 + 60);
        vm.prank(alice);
        limiter.consume(1);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(RateLimiter.InsufficientCredits.selector, 1, 0, T0 + 120));
        limiter.consume(1);
    }

    // ---------------------------------------------------------------------------------------------
    // Independent callers
    // ---------------------------------------------------------------------------------------------

    function test_bucketsAreIndependentPerCaller() public {
        vm.prank(alice);
        limiter.consume(CAPACITY);
        assertEq(limiter.available(alice), 0);
        assertEq(limiter.available(bob), CAPACITY, "another caller's bucket is untouched");

        vm.warp(T0 + 30);
        vm.prank(bob);
        limiter.consume(4);
        assertEq(limiter.available(bob), 6);
        assertEq(limiter.available(alice), 0);

        (uint256 aliceDeficit, uint256 aliceAnchor) = limiter.rawBucket(alice);
        (uint256 bobDeficit, uint256 bobAnchor) = limiter.rawBucket(bob);
        assertEq(aliceDeficit, CAPACITY);
        assertEq(aliceAnchor, T0);
        assertEq(bobDeficit, 4);
        assertEq(bobAnchor, T0 + 30);

        vm.warp(T0 + 60);
        assertEq(limiter.available(alice), 1);
        assertEq(limiter.available(bob), 6);
        vm.warp(T0 + 90);
        assertEq(limiter.available(alice), 1);
        assertEq(limiter.available(bob), 7);
    }

    function test_consumeCannotBeMadeOnBehalfOfAnotherAddress() public {
        // There is no address parameter anywhere: a contract caller charges its own bucket.
        Caller proxy = new Caller(limiter);
        proxy.consume(CAPACITY);
        assertEq(limiter.available(address(proxy)), 0);
        assertEq(limiter.available(address(this)), CAPACITY);
        assertEq(limiter.available(alice), CAPACITY);
    }

    // ---------------------------------------------------------------------------------------------
    // Overflow guard
    // ---------------------------------------------------------------------------------------------

    function test_consumeRevertsWhenTheTimestampCannotBePacked() public {
        uint256 huge = uint256(type(uint128).max) + 1;
        vm.warp(huge);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(RateLimiter.TimestampOverflow.selector, huge));
        limiter.consume(1);
    }

    // ---------------------------------------------------------------------------------------------
    // Randomised call/time sequences against the simple model
    // ---------------------------------------------------------------------------------------------

    function testFuzz_matchesModelWithDemoParameters(uint256 seed) public {
        _compareWithModel(seed, CAPACITY, INTERVAL, 96);
    }

    function testFuzz_matchesModelWithRandomParameters(uint256 seed, uint256 capacity, uint256 interval) public {
        capacity = bound(capacity, 1, 25);
        interval = bound(interval, 1, 3600);
        _compareWithModel(seed, capacity, interval, 64);
    }

    // Harness state for the model comparison, kept in storage to stay within the stack limit.
    RateLimiter private subject;
    BucketModel private model;
    address[] private actors;

    function _compareWithModel(uint256 seed, uint256 capacity, uint256 interval, uint256 steps) internal {
        subject = new RateLimiter(capacity, interval);
        model = new BucketModel(capacity, interval);
        delete actors;
        actors.push(alice);
        actors.push(bob);
        actors.push(makeAddr("carol"));

        uint256 t = vm.getBlockTimestamp();
        for (uint256 i = 0; i < steps; ++i) {
            seed = uint256(keccak256(abi.encode(seed, i)));
            t += _randomDelay(seed, interval);
            vm.warp(t);
            _randomCall(seed, capacity);
            _checkAllActors(seed, capacity);
        }
    }

    function _randomDelay(uint256 seed, uint256 interval) private pure returns (uint256) {
        uint256 kind = seed % 8;
        if (kind == 0) return 0; // same-block call
        if (kind == 1) return 5 * interval + (seed >> 8) % (50 * interval); // long idle, saturating
        return (seed >> 8) % (3 * interval); // ordinary spacing, mostly sub-interval
    }

    function _randomCall(uint256 seed, uint256 capacity) private {
        address actor = actors[(seed >> 64) % actors.length];
        uint256 amount = 1 + (seed >> 96) % capacity;

        bool expected = model.consume(actor, vm.getBlockTimestamp(), amount);
        bool actual;
        vm.prank(actor);
        try subject.consume(amount) {
            actual = true;
        } catch {
            actual = false;
        }
        assertEq(actual, expected, "consume outcome differs from the model");
    }

    function _checkAllActors(uint256 seed, uint256 capacity) private {
        uint256 probe = 1 + (seed >> 128) % capacity;
        uint256 t = vm.getBlockTimestamp();
        for (uint256 a = 0; a < actors.length; ++a) {
            address actor = actors[a];
            uint256 modelAvailable = model.available(actor, t);
            assertLe(modelAvailable, capacity, "model above capacity");
            assertEq(subject.available(actor), modelAvailable, "available differs from the model");
            assertEq(
                subject.availableAt(actor, probe),
                model.availableAt(actor, t, probe),
                "availableAt differs from the model"
            );
        }
    }
}

/// @dev Helper contract: a caller that forwards `consume`, proving buckets follow `msg.sender`.
contract Caller {
    RateLimiter private immutable limiter;

    constructor(RateLimiter limiter_) {
        limiter = limiter_;
    }

    function consume(uint256 amount) external {
        limiter.consume(amount);
    }
}
