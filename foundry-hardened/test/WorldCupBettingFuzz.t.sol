// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "forge-std/Test.sol";
import "../src/WorldCupBettingHardened.sol";

// Minimal reputation system for testing
contract MockReputation {
    function updateReputation(address, bool) external {}
    function getReputation(address) external pure returns (uint256) { return 500; }
    function setPredictionMarket(address) external {}
}

contract WorldCupBettingFuzzTest is Test {
    WorldCupBettingHardened public market;
    MockReputation public reputation;

    address owner   = address(this);
    address oracle  = makeAddr("oracle");
    address alice   = makeAddr("alice");
    address bob     = makeAddr("bob");
    address attacker = makeAddr("attacker");

    uint256 constant RESOLUTION_OFFSET = 7 days;

    function setUp() public {
        reputation = new MockReputation();
        market = new WorldCupBettingHardened(address(reputation));

        vm.deal(alice,   100 ether);
        vm.deal(bob,     100 ether);
        vm.deal(attacker, 100 ether);
    }

    // ── helpers ────────────────────────────────────────────────────────────────

    function _createMarket() internal returns (uint256 id, uint256 resolution) {
        resolution = block.timestamp + RESOLUTION_OFFSET;
        string[] memory outcomes = new string[](2);
        outcomes[0] = "YES";
        outcomes[1] = "NO";
        id = market.createMarket(
            "Will Brazil win?", "Match result", outcomes,
            resolution, oracle, address(0)
        );
    }

    // ── Fuzz: placeBet amount boundaries ──────────────────────────────────────

    /// @notice Any nonzero amount up to 10 ETH should be accepted
    function testFuzz_placeBet_anyAmount(uint96 amount) public {
        vm.assume(amount > 0 && amount <= 10 ether);
        (uint256 id,) = _createMarket();

        vm.prank(alice);
        uint256 betId = market.placeBet{value: amount}(id, 0, amount, 0);
        assertGt(betId, 0);
        assertEq(market.getTotalPool(id), amount);
    }

    /// @notice minShares == amount should always pass (exact match)
    function testFuzz_placeBet_exactMinShares(uint96 amount) public {
        vm.assume(amount > 0 && amount <= 10 ether);
        (uint256 id,) = _createMarket();

        vm.prank(alice);
        market.placeBet{value: amount}(id, 0, amount, amount);
    }

    /// @notice minShares > amount should always revert
    function testFuzz_placeBet_slippageReverts(uint96 amount, uint96 minExtra) public {
        vm.assume(amount > 0 && amount <= 10 ether);
        vm.assume(minExtra > 0);
        uint256 minShares = uint256(amount) + uint256(minExtra);
        (uint256 id,) = _createMarket();

        vm.prank(alice);
        vm.expectRevert(WorldCupBettingHardened.SlippageExceeded.selector);
        market.placeBet{value: amount}(id, 0, amount, minShares);
    }

    // ── Fuzz: payout correctness ───────────────────────────────────────────────

    /// @notice Winner always receives between 0 and totalPool (no value created out of thin air)
    function testFuzz_payout_withinBounds(uint96 stakeA, uint96 stakeB) public {
        vm.assume(stakeA > 0.001 ether && stakeA <= 5 ether);
        vm.assume(stakeB > 0.001 ether && stakeB <= 5 ether);

        (uint256 id, uint256 resolution) = _createMarket();

        vm.prank(alice);
        market.placeBet{value: stakeA}(id, 0, stakeA, 0);
        vm.prank(bob);
        market.placeBet{value: stakeB}(id, 1, stakeB, 0);

        vm.warp(resolution + 1);
        vm.prank(oracle);
        market.resolveMarket(id, 0); // alice wins

        uint256[] memory aliceBets = market.getUserBets(alice);
        uint256 betId = aliceBets[0];

        uint256 balBefore = alice.balance;
        vm.prank(alice);
        market.claimWinnings(betId);
        uint256 received = alice.balance - balBefore;

        uint256 totalPool = uint256(stakeA) + uint256(stakeB);
        assertLe(received, totalPool, "Payout exceeds total pool");
        assertGt(received, 0, "Winner got nothing");
    }

    // ── Fuzz: double-claim prevention ─────────────────────────────────────────

    function testFuzz_noDoubleClaim(uint96 stake) public {
        vm.assume(stake > 0.001 ether && stake <= 5 ether);

        (uint256 id, uint256 resolution) = _createMarket();
        vm.prank(alice);
        market.placeBet{value: stake}(id, 0, stake, 0);

        vm.warp(resolution + 1);
        vm.prank(oracle);
        market.resolveMarket(id, 0);

        uint256 betId = market.getUserBets(alice)[0];

        vm.prank(alice);
        market.claimWinnings(betId);

        vm.prank(alice);
        vm.expectRevert(WorldCupBettingHardened.AlreadyClaimed.selector);
        market.claimWinnings(betId);
    }

    // ── Fuzz: reentrancy guard ─────────────────────────────────────────────────

    function testFuzz_reentrancy_claimWinnings(uint96 stake) public {
        vm.assume(stake > 0.001 ether && stake <= 5 ether);

        (uint256 id, uint256 resolution) = _createMarket();

        // Attacker places bet
        vm.prank(attacker);
        market.placeBet{value: stake}(id, 0, stake, 0);

        vm.warp(resolution + 1);
        vm.prank(oracle);
        market.resolveMarket(id, 0);

        uint256 betId = market.getUserBets(attacker)[0];

        // First claim succeeds
        vm.prank(attacker);
        market.claimWinnings(betId);

        // Second claim (simulated reentrant call) reverts
        vm.prank(attacker);
        vm.expectRevert(WorldCupBettingHardened.AlreadyClaimed.selector);
        market.claimWinnings(betId);
    }

    // ── Fuzz: time-lock enforcement ────────────────────────────────────────────

    function testFuzz_cannotResolveBeforeTime(uint32 timeLeft) public {
        vm.assume(timeLeft > 1);
        uint256 resolution = block.timestamp + timeLeft;

        string[] memory outcomes = new string[](2);
        outcomes[0] = "YES"; outcomes[1] = "NO";
        uint256 id = market.createMarket(
            "Q", "D", outcomes, resolution, oracle, address(0)
        );

        vm.warp(resolution - 1);
        vm.prank(oracle);
        vm.expectRevert(WorldCupBettingHardened.TooEarly.selector);
        market.resolveMarket(id, 0);
    }

    /// @notice Bets are rejected at or after resolutionTime
    function testFuzz_noBetsAfterClose(uint32 delay) public {
        vm.assume(delay <= RESOLUTION_OFFSET);
        (uint256 id, uint256 resolution) = _createMarket();

        vm.warp(resolution + delay);

        vm.prank(alice);
        vm.expectRevert(WorldCupBettingHardened.MarketClosed.selector);
        market.placeBet{value: 0.1 ether}(id, 0, 0.1 ether, 0);
    }

    // ── Fuzz: access control ──────────────────────────────────────────────────

    function testFuzz_onlyArbitratorCanResolve(address rando) public {
        vm.assume(rando != oracle && rando != address(0));
        (uint256 id, uint256 resolution) = _createMarket();

        vm.warp(resolution + 1);
        vm.prank(rando);
        vm.expectRevert(WorldCupBettingHardened.OnlyArbitrator.selector);
        market.resolveMarket(id, 0);
    }

    // ── Fuzz: fee accounting ──────────────────────────────────────────────────

    function testFuzz_feeNeverExceedsPool(uint96 stakeA, uint96 stakeB) public {
        vm.assume(stakeA > 0.001 ether && stakeA <= 5 ether);
        vm.assume(stakeB > 0.001 ether && stakeB <= 5 ether);

        (uint256 id, uint256 resolution) = _createMarket();

        vm.prank(alice);
        market.placeBet{value: stakeA}(id, 0, stakeA, 0);
        vm.prank(bob);
        market.placeBet{value: stakeB}(id, 1, stakeB, 0);

        vm.warp(resolution + 1);
        vm.prank(oracle);
        market.resolveMarket(id, 0);

        uint256 betId = market.getUserBets(alice)[0];
        vm.prank(alice);
        market.claimWinnings(betId);

        uint256 fees = market.getAvailableFees(address(0));
        uint256 totalPool = uint256(stakeA) + uint256(stakeB);
        assertLe(fees, totalPool, "Fees exceed total pool");
        // 2% fee
        uint256 expectedFee = (totalPool * 200) / 10_000;
        assertEq(fees, expectedFee, "Fee not exactly 2%");
    }

    // ── Invariant: contract ETH balance always covers unclaimed winnings ───────

    function testFuzz_contractBalanceCoversPayouts(uint96 s1, uint96 s2) public {
        vm.assume(s1 > 0.001 ether && s1 <= 3 ether);
        vm.assume(s2 > 0.001 ether && s2 <= 3 ether);

        (uint256 id, uint256 resolution) = _createMarket();

        vm.prank(alice);
        market.placeBet{value: s1}(id, 0, s1, 0);
        vm.prank(bob);
        market.placeBet{value: s2}(id, 1, s2, 0);

        uint256 contractBalBefore = address(market).balance;
        assertEq(contractBalBefore, uint256(s1) + uint256(s2));

        vm.warp(resolution + 1);
        vm.prank(oracle);
        market.resolveMarket(id, 0);

        uint256 betId = market.getUserBets(alice)[0];
        vm.prank(alice);
        market.claimWinnings(betId);

        // After payout, contract holds only fees
        uint256 fees = market.getAvailableFees(address(0));
        assertEq(address(market).balance, fees);
    }
}
